// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

interface INextBound { function kernel() external view returns(address); }
interface INextHolderCanonical { function isCanonical(address,address,uint256,bytes32,bytes32) external view returns(bool); }
interface INextSettlementEvidence { function isCanonical(uint256,uint256,uint256,bytes32) external view returns(bool); }

/// @notice Isolated architecture prototype: custody and typed bucket capabilities only.
contract CompdVaultKernelV2NextProto {
    enum Life { ACTIVE, PAUSED, SHUTDOWN_PENDING, TERMINATED, EMERGENCY_RECOVERY }
    enum Domain { Settlement, Holder, Buyback, Recovery, Emergency }
    struct ModuleBinding { address module; bytes32 codeHash; }
    address public immutable quote; address public immutable configAdmin; address public immutable guardian;
    address public immutable recoveryTreasury; address public immutable emergencyAuthority; address public immutable emergencyWallet;
    address public immutable holderCanonical; address public immutable buybackExecutor; address public immutable strategyExecutor; address public immutable settlementEvidenceSource;
    mapping(Domain=>ModuleBinding) public moduleBinding; bool public bound;
    Life public lifecycle; uint64 public shutdownAt;
    uint64 public lastBuybackAt; uint64 public buybackPeriodStart; uint256 public buybackPeriodStartReserve; uint256 public buybackPeriodSpend;
    uint256 public strategyCapital; uint256 public buybackReserve; uint256 public protocolReserve;
    uint256 public holderRewardReserve; uint256 public accountedQuote; uint256 public activePrincipal;
    mapping(uint256=>bool) public usedRun; mapping(uint256=>uint256) public principalOf; mapping(bytes32=>bool) public consumed; uint256 public emergencyNonce;
    uint256 public emergencyQuoteBalance; uint256 public emergencyAccountedQuote; uint256 public emergencyHolderReserve; uint256 public preEmergencyDeficit; uint64 public emergencyTimestamp; uint64 public emergencyBlock; bytes32 public emergencySnapshot;
    event ModuleBound(Domain indexed domain,address indexed module,bytes32 runtimeHash);
    event BucketChange(bytes32 indexed operation,uint256 strategy,uint256 buyback,uint256 protocol,uint256 holder,uint256 accounted);
    event LifecycleChanged(Life indexed previousLife,Life indexed nextLife);
    event EmergencyEntered(uint256 indexed nonce,uint256 quoteBalance,uint256 accounted,uint256 holderReserve,uint256 preDeficit);
    error Unauthorized(); error Invalid(); error Accounting(); error Replay();
    modifier onlyModule(Domain d){if(msg.sender!=moduleBinding[d].module||msg.sender.codehash!=moduleBinding[d].codeHash)revert Unauthorized();_;}
    constructor(address q,address admin,address g,address recovery,address emergencyAuth,address emergency,address holderSource,address buyExecutor,address strategyExec,address settlementEvidence) {
        if(q!=address(0)||admin==address(0)||g==address(0)||recovery==address(0)||emergencyAuth==address(0)||emergency==address(0)||holderSource.code.length==0||buyExecutor==address(0)||strategyExec==address(0)||settlementEvidence.code.length==0)revert Invalid();
        quote=q;configAdmin=admin;guardian=g;recoveryTreasury=recovery;emergencyAuthority=emergencyAuth;emergencyWallet=emergency;holderCanonical=holderSource;buybackExecutor=buyExecutor;strategyExecutor=strategyExec;settlementEvidenceSource=settlementEvidence;lifecycle=Life.PAUSED;
    }
    receive() external payable {}
    function bind(address[5] calldata modules) external {
        if(msg.sender!=configAdmin||bound||lifecycle!=Life.PAUSED)revert Unauthorized();
        for(uint8 i;i<5;i++){address m=modules[i];if(m.code.length==0||INextBound(m).kernel()!=address(this))revert Invalid();moduleBinding[Domain(i)]=ModuleBinding(m,m.codehash);emit ModuleBound(Domain(i),m,m.codehash);}
        bound=true;
    }
    function activate() external {if(msg.sender!=configAdmin||!bound||lifecycle!=Life.PAUSED)revert Unauthorized();_life(Life.ACTIVE);_assert();}
    function seed() external payable {if(msg.sender!=configAdmin||lifecycle!=Life.ACTIVE||msg.value==0)revert Invalid();strategyCapital+=msg.value;accountedQuote+=msg.value;_emit(bytes32("SEED"));}
    function allocate(uint256 run,uint256 amount) external onlyModule(Domain.Settlement){if(lifecycle!=Life.ACTIVE||run==0||usedRun[run]||amount==0||amount>strategyCapital||amount>strategyCapital-activePrincipal)revert Invalid();usedRun[run]=true;principalOf[run]=amount;activePrincipal+=amount;accountedQuote-=amount;_send(strategyExecutor,amount);_emit(bytes32("ALLOCATE"));}
    function settle(uint256 run,uint256 principal,uint256 returned,bytes32 evidence) external onlyModule(Domain.Settlement){if((lifecycle!=Life.ACTIVE&&lifecycle!=Life.PAUSED&&lifecycle!=Life.SHUTDOWN_PENDING)||!usedRun[run]||principal==0||principal!=principalOf[run]||evidence==0||principal>activePrincipal||!INextSettlementEvidence(settlementEvidenceSource).isCanonical(run,principal,returned,evidence)||address(this).balance<accountedQuote+returned)revert Invalid();principalOf[run]=0;activePrincipal-=principal;accountedQuote+=returned;uint256 profit=returned>principal?returned-principal:0;uint256 loss=principal>returned?principal-returned:0;if(loss>strategyCapital)revert Invalid();strategyCapital-=loss;uint256 compound=profit*65/100;uint256 buy=profit*15/100;uint256 holder=profit*10/100;uint256 protocol=profit-compound-buy-holder;strategyCapital+=compound;buybackReserve+=buy;holderRewardReserve+=holder;protocolReserve+=protocol;_emit(bytes32("SETTLE"));}
    function flapRevenue(uint256 amount,bytes32 id) external onlyModule(Domain.Settlement){if(lifecycle!=Life.ACTIVE||amount==0||id==0||consumed[id]||address(this).balance<accountedQuote+amount)revert Invalid();consumed[id]=true;accountedQuote+=amount;uint256 s=amount*35/100;uint256 b=amount*15/100;strategyCapital+=s;buybackReserve+=b;protocolReserve+=amount-s-b;_emit(bytes32("FLAP"));}
    function payHolder(address to,uint256 amount,bytes32 id,bytes32 canonicalLeaf) external onlyModule(Domain.Holder){if(lifecycle!=Life.ACTIVE||to==address(0)||amount==0||amount>holderRewardReserve||id==0||canonicalLeaf==0||consumed[id]||!INextHolderCanonical(holderCanonical).isCanonical(to,quote,amount,id,canonicalLeaf))revert Invalid();consumed[id]=true;holderRewardReserve-=amount;accountedQuote-=amount;_send(to,amount);_emit(bytes32("HOLDER_PAY"));}
    function buyback(uint256 amount,bytes32 id,uint16 slippageBps,uint16 deviationBps) external onlyModule(Domain.Buyback){if(lifecycle!=Life.ACTIVE||amount==0||id==0||consumed[id]||slippageBps>300||deviationBps>300)revert Invalid();if(buybackPeriodStart==0||block.timestamp>=uint256(buybackPeriodStart)+24 hours){buybackPeriodStart=uint64(block.timestamp);buybackPeriodStartReserve=buybackReserve;buybackPeriodSpend=0;}if(buybackReserve<0.25 ether||amount>0.50 ether||amount>buybackReserve*20/100||amount>buybackPeriodStartReserve*20/100||buybackPeriodSpend+amount>buybackPeriodStartReserve*40/100||(lastBuybackAt!=0&&block.timestamp<uint256(lastBuybackAt)+6 hours))revert Invalid();consumed[id]=true;buybackPeriodSpend+=amount;lastBuybackAt=uint64(block.timestamp);buybackReserve-=amount;accountedQuote-=amount;_send(buybackExecutor,amount);_emit(bytes32("BUYBACK"));}
    function recover(uint256 amount,bytes32 id) external onlyModule(Domain.Recovery){if(lifecycle!=Life.TERMINATED||amount==0||amount>protocolReserve||id==0||consumed[id])revert Invalid();consumed[id]=true;protocolReserve-=amount;accountedQuote-=amount;_send(recoveryTreasury,amount);_emit(bytes32("RECOVER"));}
    function emergencyEnter() external {if(msg.sender!=emergencyAuthority||lifecycle==Life.TERMINATED||lifecycle==Life.EMERGENCY_RECOVERY)revert Unauthorized();_assert();uint256 vb=address(this).balance;if(vb<accountedQuote||accountedQuote<holderRewardReserve)revert Accounting();uint256 nonHolder=accountedQuote-holderRewardReserve;uint256 avail=vb-nonHolder;if(avail>holderRewardReserve)avail=holderRewardReserve;preEmergencyDeficit=holderRewardReserve-avail;emergencyQuoteBalance=vb;emergencyAccountedQuote=accountedQuote;emergencyHolderReserve=holderRewardReserve;emergencyNonce++;emergencyTimestamp=uint64(block.timestamp);emergencyBlock=uint64(block.number);emergencySnapshot=keccak256(abi.encode(address(this),block.chainid,emergencyNonce,emergencyTimestamp,emergencyBlock,uint8(lifecycle),vb,accountedQuote,holderRewardReserve,preEmergencyDeficit));_life(Life.EMERGENCY_RECOVERY);emit EmergencyEntered(emergencyNonce,vb,accountedQuote,holderRewardReserve,preEmergencyDeficit);}
    function emergencyRecoverQuote(uint256 amount,bytes32 id) external onlyModule(Domain.Emergency){if(lifecycle!=Life.EMERGENCY_RECOVERY||amount==0||id==0||consumed[id]||amount>protocolReserve)revert Invalid();consumed[id]=true;protocolReserve-=amount;accountedQuote-=amount;_send(emergencyWallet,amount);_assert();}
    function pause() external {if(msg.sender!=guardian||lifecycle!=Life.ACTIVE)revert Unauthorized();_life(Life.PAUSED);}
    function resume() external {if(msg.sender!=configAdmin||lifecycle!=Life.PAUSED)revert Unauthorized();_life(Life.ACTIVE);}
    function initiateShutdown() external {if(msg.sender!=guardian||(lifecycle!=Life.ACTIVE&&lifecycle!=Life.PAUSED))revert Unauthorized();shutdownAt=uint64(block.timestamp+72 hours);_life(Life.SHUTDOWN_PENDING);}
    function extendShutdown(uint64 next) external {if(msg.sender!=guardian||lifecycle!=Life.SHUTDOWN_PENDING||next<=shutdownAt)revert Unauthorized();shutdownAt=next;}
    function terminate() external {if(msg.sender!=guardian||lifecycle!=Life.SHUTDOWN_PENDING||block.timestamp<shutdownAt||activePrincipal!=0||holderRewardReserve!=0)revert Invalid();_life(Life.TERMINATED);}
    function _life(Life n) private {Life p=lifecycle;lifecycle=n;emit LifecycleChanged(p,n);}
    function _emit(bytes32 op) private {_assert();emit BucketChange(op,strategyCapital,buybackReserve,protocolReserve,holderRewardReserve,accountedQuote);}
    function _send(address to,uint256 amount) private { (bool ok,)=payable(to).call{value:amount}("");if(!ok)revert Invalid(); }
    function _assert() private view {if(strategyCapital+buybackReserve+protocolReserve+holderRewardReserve!=accountedQuote+activePrincipal||address(this).balance<accountedQuote)revert Accounting();}
}

/// @dev Narrow typed call surfaces. Each instance is immutable-bound to one Kernel.
abstract contract NextModuleBase { CompdVaultKernelV2NextProto public immutable kernel; constructor(address k){require(k.code.length!=0);kernel=CompdVaultKernelV2NextProto(payable(k));} }
contract CompdSettlementModuleV2NextProto is NextModuleBase { constructor(address k)NextModuleBase(k){} function allocate(uint256 r,uint256 a)external{kernel.allocate(r,a);} function settle(uint256 r,uint256 p,uint256 a,bytes32 e)external{kernel.settle(r,p,a,e);} function flap(uint256 a,bytes32 i)external{kernel.flapRevenue(a,i);} }
contract CompdHolderModuleV2NextProto is NextModuleBase { constructor(address k)NextModuleBase(k){} function pay(address to,uint256 a,bytes32 i,bytes32 leaf)external{kernel.payHolder(to,a,i,leaf);} }
contract CompdBuybackModuleV2NextProto is NextModuleBase { constructor(address k)NextModuleBase(k){} function release(uint256 a,bytes32 i,uint16 s,uint16 d)external{kernel.buyback(a,i,s,d);} }
contract CompdRecoveryModuleV2NextProto is NextModuleBase { constructor(address k)NextModuleBase(k){} function recover(uint256 a,bytes32 i)external{kernel.recover(a,i);} }
contract CompdEmergencyModuleV2NextProto is NextModuleBase { constructor(address k)NextModuleBase(k){} function recoverQuote(uint256 a,bytes32 i)external{kernel.emergencyRecoverQuote(a,i);} }
