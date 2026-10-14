// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import "./OptionAPrototype.sol";

interface ICompdProtocolLensVaultC2FG {
    function lifecycle() external view returns (uint8);
    function strategyCapital() external view returns (uint256);
    function buybackReserve() external view returns (uint256);
    function protocolReserve() external view returns (uint256);
    function holderRewardReserve() external view returns (uint256);
    function accountedQuote() external view returns (uint256);
    function activePrincipal() external view returns (uint256);
    function quote() external view returns (address);
    function settlement() external view returns (address);
    function holder() external view returns (address);
    function emergency() external view returns (address);
    function workflow() external view returns (address);
    function liability() external view returns (address);
    function registry() external view returns (address);
    function distributor() external view returns (address);
    function strategyExecutor() external view returns (address);
    function buybackExecutor() external view returns (address);
    function flapReceiver() external view returns (address);
    function settlementHash() external view returns (bytes32);
    function holderHash() external view returns (bytes32);
    function emergencyHash() external view returns (bytes32);
    function sourceHash(uint8) external view returns (bytes32);
    function sourceAddress(uint8) external view returns (address);
    function emergencySnapshot() external view returns (bytes32);
    function preEmergencyDeficit() external view returns (uint256);
    function emergencyProcessingStatus() external view returns (uint8);
    function readOnlyDiagnostics() external view returns (uint256,uint256,uint64,uint256,uint256,uint256,uint64);
}

interface ICompdProtocolLensWorkflowC2FG { function partitions() external view returns (uint256,uint256,uint256,uint256,uint256); }
interface ICompdProtocolLensTokenC2FG { function balanceOf(address) external view returns (uint256); }
interface ICompdProtocolLensRegistryC2FG {
    function scopeSummary(bytes32) external view returns (uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,bool);
}

/// @notice Optional, read-only diagnostic facade. It stores no state and has no Vault write path.
contract CompdProtocolLensV2 {
    function bucketState(address v) external view returns (uint8,uint256,uint256,uint256,uint256,uint256,uint256) {
        ICompdProtocolLensVaultC2FG x=ICompdProtocolLensVaultC2FG(v);
        return (x.lifecycle(),x.strategyCapital(),x.buybackReserve(),x.protocolReserve(),x.holderRewardReserve(),x.accountedQuote(),x.activePrincipal());
    }
    function history(address v) external view returns (uint256,uint256,uint64,uint256,uint256,uint256,uint64) { return ICompdProtocolLensVaultC2FG(v).readOnlyDiagnostics(); }
    function cumulativeProfit(address v) external view returns (uint256 a) { (a,,,,,,)=ICompdProtocolLensVaultC2FG(v).readOnlyDiagnostics(); }
    function cumulativeLoss(address v) external view returns (uint256 a) { (,a,,,,,)=ICompdProtocolLensVaultC2FG(v).readOnlyDiagnostics(); }
    function buybackPeriod(address v) external view returns (uint64,uint256,uint256,uint64) { (,,uint64 a,uint256 b,uint256 c,,uint64 d)=ICompdProtocolLensVaultC2FG(v).readOnlyDiagnostics(); return(a,b,c,d); }
    function cumulativeRevenue(address v) external view returns (uint256 a) { (,,,,,a,)=ICompdProtocolLensVaultC2FG(v).readOnlyDiagnostics(); }
    function holderPartitions(address v) external view returns (uint256,uint256,uint256,uint256,uint256,uint256,bool) {
        ICompdProtocolLensVaultC2FG x=ICompdProtocolLensVaultC2FG(v);
        (uint256 a,uint256 b,uint256 c,uint256 d,uint256 e)=ICompdProtocolLensWorkflowC2FG(x.workflow()).partitions();
        uint256 total=a+b+c+d+e;
        return(a,b,c,d,e,total,total==x.holderRewardReserve());
    }
    function holderBacking(address v) external view returns (uint256 available,uint256 deficit,uint256 emergencyCaused) {
        ICompdProtocolLensVaultC2FG x=ICompdProtocolLensVaultC2FG(v);
        uint256 reserve=x.holderRewardReserve(); uint256 aq=x.accountedQuote(); uint256 physical=ICompdProtocolLensTokenC2FG(x.quote()).balanceOf(v);
        uint256 nonHolder=aq>reserve?aq-reserve:0; uint256 free=physical>nonHolder?physical-nonHolder:0;
        available=free<reserve?free:reserve; deficit=reserve-available;
        uint256 pre=x.preEmergencyDeficit(); emergencyCaused=deficit>pre?deficit-pre:0;
    }
    function emergencyProgress(address registry,bytes32 snapshot) external view returns (uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,bool) {
        return ICompdProtocolLensRegistryC2FG(registry).scopeSummary(snapshot);
    }
    function activationDiagnostics(address v) external view returns (bool[10] memory ok) {
        ICompdProtocolLensVaultC2FG x=ICompdProtocolLensVaultC2FG(v);
        address[3] memory c=[x.settlement(),x.holder(),x.emergency()];
        bytes32[3] memory h=[x.settlementHash(),x.holderHash(),x.emergencyHash()];
        bytes32[3] memory t=[keccak256("COMPD_SETTLEMENT_CONTROLLER_V2_PROTO"),keccak256("COMPD_HOLDER_CONTROLLER_V2_PROTO"),keccak256("COMPD_EMERGENCY_CONTROLLER_V2_PROTO")];
        for(uint256 i;i<3;i++){ if(c[i].code.length==0)continue; try IProtoIdentity(c[i]).vault() returns(address owner){ok[i]=owner==v&&c[i].codehash==h[i]&&IProtoIdentity(c[i]).COMPONENT_TYPE_ID()==t[i]&&IProtoIdentity(c[i]).COMPONENT_VERSION()==2;}catch{} }
        bytes32[7] memory st=[keccak256("COMPD_HOLDER_WORKFLOW_V2"),keccak256("COMPD_HOLDER_LIABILITY_V2"),keccak256("COMPD_EMERGENCY_REGISTRY_V2"),keccak256("COMPD_HOLDER_REWARDS_DISTRIBUTOR_V2"),keccak256("COMPD_STRATEGY_EXECUTOR_V2"),keccak256("COMPD_BUYBACK_EXECUTOR_V2"),keccak256("COMPD_THIN_FLAP_RECEIVER_V2")];
        for(uint8 i;i<7;i++){address s=x.sourceAddress(i);if(s.code.length==0)continue;try IProtoIdentity(s).vault() returns(address owner){ok[i+3]=owner==v&&s.codehash==x.sourceHash(i)&&IProtoIdentity(s).COMPONENT_TYPE_ID()==st[i]&&IProtoIdentity(s).COMPONENT_VERSION()==2;}catch{}}
    }
}

/// @notice Append-only finite-scope emergency evidence model for isolated architecture testing.
/// @dev Only the immutable Vault can add scopes or advance an item from registered to attempted to resolved.
contract CompdEmergencyRegistryAggregateV2Proto {
    enum ItemState { NONE, REGISTERED, ATTEMPTED, RESOLVED }
    error OnlyVault(); error InvalidItem(); error DuplicateItem(); error InvalidTransition();
    address public immutable vault;
    mapping(bytes32=>mapping(uint8=>uint64)) private _total;
    mapping(bytes32=>mapping(uint8=>uint64)) private _resolved;
    mapping(bytes32=>mapping(bytes32=>ItemState)) public itemState;
    mapping(bytes32=>bool) public hasScope;
    event ItemRegistered(bytes32 indexed snapshot,uint8 indexed kind,bytes32 indexed item);
    event ItemAttempted(bytes32 indexed snapshot,uint8 indexed kind,bytes32 indexed item);
    event ItemResolved(bytes32 indexed snapshot,uint8 indexed kind,bytes32 indexed item);
    modifier onlyVault(){if(msg.sender!=vault)revert OnlyVault();_;}
    constructor(address v){if(v==address(0)||v.code.length==0)revert InvalidItem();vault=v;}
    function registerAsset(bytes32 s,uint8 moduleId,address asset) external onlyVault {if(s==0||moduleId>6||asset==address(0))revert InvalidItem();_register(s,0,keccak256(abi.encode(uint8(0),moduleId,asset)));}
    function registerModule(bytes32 s,uint8 moduleId,address module) external onlyVault {if(s==0||moduleId>6||module==address(0))revert InvalidItem();_register(s,1,keccak256(abi.encode(uint8(1),moduleId,module)));}
    function registerRun(bytes32 s,uint256 runId) external onlyVault {if(s==0||runId==0)revert InvalidItem();_register(s,2,keccak256(abi.encode(uint8(2),runId)));}
    function attemptAsset(bytes32 s,uint8 moduleId,address asset) external onlyVault { _attempt(s,0,keccak256(abi.encode(uint8(0),moduleId,asset))); }
    function attemptModule(bytes32 s,uint8 moduleId,address module) external onlyVault { _attempt(s,1,keccak256(abi.encode(uint8(1),moduleId,module))); }
    function attemptRun(bytes32 s,uint256 runId) external onlyVault { _attempt(s,2,keccak256(abi.encode(uint8(2),runId))); }
    function resolveAsset(bytes32 s,uint8 moduleId,address asset) external onlyVault { _resolve(s,0,keccak256(abi.encode(uint8(0),moduleId,asset))); }
    function resolveModule(bytes32 s,uint8 moduleId,address module) external onlyVault { _resolve(s,1,keccak256(abi.encode(uint8(1),moduleId,module))); }
    function resolveRun(bytes32 s,uint256 runId) external onlyVault { _resolve(s,2,keccak256(abi.encode(uint8(2),runId))); }
    function _register(bytes32 s,uint8 k,bytes32 id) private {if(itemState[s][id]!=ItemState.NONE)revert DuplicateItem();itemState[s][id]=ItemState.REGISTERED;++_total[s][k];hasScope[s]=true;emit ItemRegistered(s,k,id);}
    function _attempt(bytes32 s,uint8 k,bytes32 id) private {if(itemState[s][id]!=ItemState.REGISTERED)revert InvalidTransition();itemState[s][id]=ItemState.ATTEMPTED;emit ItemAttempted(s,k,id);}
    function _resolve(bytes32 s,uint8 k,bytes32 id) private {if(itemState[s][id]!=ItemState.ATTEMPTED)revert InvalidTransition();itemState[s][id]=ItemState.RESOLVED;++_resolved[s][k];emit ItemResolved(s,k,id);}
    function scopeSummary(bytes32 s) external view returns(uint64 totalAssets,uint64 resolvedAssets,uint64 unresolvedAssets,uint64 totalModules,uint64 resolvedModules,uint64 unresolvedModules,uint64 totalRuns,uint64 resolvedRuns,uint64 unresolvedRuns,bool complete){totalAssets=_total[s][0];resolvedAssets=_resolved[s][0];unresolvedAssets=totalAssets-resolvedAssets;totalModules=_total[s][1];resolvedModules=_resolved[s][1];unresolvedModules=totalModules-resolvedModules;totalRuns=_total[s][2];resolvedRuns=_resolved[s][2];unresolvedRuns=totalRuns-resolvedRuns;complete=hasScope[s]&&unresolvedAssets==0&&unresolvedModules==0&&unresolvedRuns==0;}
}

contract CompdProductionVaultV2KernelC2FGProto {
    enum Life { ACTIVE, PAUSED, SHUTDOWN_PENDING, TERMINATED, EMERGENCY_RECOVERY }
    error Unauthorized(); error Invalid(); error Accounting(); error Replay(); error Binding();
    uint256 public strategyCapital; uint256 public buybackReserve; uint256 public protocolReserve; uint256 public holderRewardReserve; uint256 public accountedQuote; uint256 public activePrincipal;
    uint8 public lifecycle; address public immutable quote; address public immutable guardian; address public immutable configAdmin; address public constant recoveryTreasury=0xFa8706AA97B07cb29096381f9101784bA0d1332b; address public immutable emergencyWallet; address public immutable emergencyAuthority;
    address public settlement; address public holder; address public emergency; address public workflow; address public liability; address public registry; address public distributor; address public strategyExecutor;address public buybackExecutor;address public flapReceiver;
    bytes32 public immutable settlementHash; bytes32 public immutable holderHash; bytes32 public immutable emergencyHash;
    mapping(uint8=>uint256) public consumed; mapping(bytes32=>bool) public paymentUsed; mapping(uint256=>uint256) public principalOf; mapping(uint256=>bool) public usedRun;
    uint256 private entered; bytes32 public emergencySnapshot; uint256 private cumulativeProfit; uint256 private cumulativeLoss;uint64 public shutdownAt;uint64 private lastBuybackAt;uint64 private periodStart;uint256 private periodStartReserve;uint256 private periodBuybackSpend;uint256 private cumulativeRevenue;mapping(uint8=>bytes32) public sourceHash;mapping(uint8=>address) public sourceAddress;uint256 public preEmergencyDeficit;uint256 public emergencyNonce;uint256 public emergencyQuoteBalance;uint64 public emergencyTimestamp;uint64 public emergencyBlock;uint8 public emergencyProcessingStatus;
    event Bound(uint8 indexed kind,address indexed target,bytes32 hash); event Settled(uint256 indexed run,uint256 principal,uint256 returned,uint256 profit,uint256 loss);
    modifier lock(){if(entered!=0)revert Invalid();entered=1;_;entered=0;}
    constructor(address q,address g,address ca,address ew,address ea,bytes32 sh,bytes32 hh,bytes32 eh){require(q!=address(0)&&g!=address(0)&&ca!=address(0)&&ew!=address(0)&&ea!=address(0)&&ea!=ew&&ca!=ew&&ca!=ea);quote=q;guardian=g;configAdmin=ca;emergencyWallet=ew;emergencyAuthority=ea;settlementHash=sh;holderHash=hh;emergencyHash=eh;lifecycle=uint8(Life.PAUSED);}
    function seed(uint256 amount) external {if(msg.sender!=configAdmin||IProtoToken(quote).balanceOf(address(this))<accountedQuote+amount)revert Unauthorized();strategyCapital+=amount;accountedQuote+=amount;_assertAccounting();}
    function bind(uint8 kind,address target) external {if(msg.sender!=configAdmin||lifecycle!=uint8(Life.PAUSED)||target.code.length==0)revert Binding();bytes32 expected=kind==1?settlementHash:kind==2?holderHash:emergencyHash;bytes32 typ=kind==1?IProtoSettlement(target).COMPONENT_TYPE_ID():kind==2?IProtoHolder(target).COMPONENT_TYPE_ID():IProtoEmergency(target).COMPONENT_TYPE_ID();address v=kind==1?IProtoSettlement(target).vault():kind==2?IProtoHolder(target).vault():IProtoEmergency(target).vault();uint32 ver=kind==1?IProtoSettlement(target).COMPONENT_VERSION():kind==2?IProtoHolder(target).COMPONENT_VERSION():IProtoEmergency(target).COMPONENT_VERSION();bytes32 wanted=kind==1?keccak256("COMPD_SETTLEMENT_CONTROLLER_V2_PROTO"):kind==2?keccak256("COMPD_HOLDER_CONTROLLER_V2_PROTO"):keccak256("COMPD_EMERGENCY_CONTROLLER_V2_PROTO");if(kind<1||kind>3||expected==0||target.codehash!=expected||typ!=wanted||ver!=2||v!=address(this))revert Binding();if(kind==1){if(settlement!=address(0))revert Binding();settlement=target;}else if(kind==2){if(holder!=address(0))revert Binding();holder=target;}else{if(emergency!=address(0))revert Binding();emergency=target;}emit Bound(kind,target,expected);}
    function bindSources(address w,address l,address r,address d,address sx,address bx,address rx,bytes32[7] calldata reviewed) external {if(msg.sender!=configAdmin||lifecycle!=uint8(Life.PAUSED)||workflow!=address(0))revert Binding();address[7] memory a=[w,l,r,d,sx,bx,rx];bytes32[7] memory t=[keccak256("COMPD_HOLDER_WORKFLOW_V2"),keccak256("COMPD_HOLDER_LIABILITY_V2"),keccak256("COMPD_EMERGENCY_REGISTRY_V2"),keccak256("COMPD_HOLDER_REWARDS_DISTRIBUTOR_V2"),keccak256("COMPD_STRATEGY_EXECUTOR_V2"),keccak256("COMPD_BUYBACK_EXECUTOR_V2"),keccak256("COMPD_THIN_FLAP_RECEIVER_V2")];for(uint8 i=0;i<7;i++){if(a[i].code.length==0||reviewed[i]==0||a[i].codehash!=reviewed[i]||IProtoIdentity(a[i]).vault()!=address(this)||IProtoIdentity(a[i]).COMPONENT_TYPE_ID()!=t[i]||IProtoIdentity(a[i]).COMPONENT_VERSION()!=2)revert Binding();sourceAddress[i]=a[i];sourceHash[i]=reviewed[i];}workflow=w;liability=l;registry=r;distributor=d;strategyExecutor=sx;buybackExecutor=bx;flapReceiver=rx;}
    function activate() external {if(msg.sender!=guardian||lifecycle!=uint8(Life.PAUSED)||settlement==address(0)||holder==address(0)||emergency==address(0)||workflow==address(0)||liability==address(0)||registry==address(0)||distributor==address(0)||strategyExecutor==address(0)||buybackExecutor==address(0)||flapReceiver==address(0))revert Binding();_validateController(settlement,settlementHash,keccak256("COMPD_SETTLEMENT_CONTROLLER_V2_PROTO"));_validateController(holder,holderHash,keccak256("COMPD_HOLDER_CONTROLLER_V2_PROTO"));_validateController(emergency,emergencyHash,keccak256("COMPD_EMERGENCY_CONTROLLER_V2_PROTO"));for(uint8 i=0;i<7;i++)if(sourceAddress[i].codehash!=sourceHash[i])revert Binding();_assertHolder();_assertAccounting();lifecycle=uint8(Life.ACTIVE);}
    function _validateController(address a,bytes32 h,bytes32 t) private view {if(a.code.length==0||a.codehash!=h||IProtoIdentity(a).vault()!=address(this)||IProtoIdentity(a).COMPONENT_TYPE_ID()!=t||IProtoIdentity(a).COMPONENT_VERSION()!=2)revert Binding();}
    function initiateShutdown() external {if(msg.sender!=guardian||(lifecycle!=uint8(Life.ACTIVE)&&lifecycle!=uint8(Life.PAUSED)))revert Unauthorized();lifecycle=uint8(Life.SHUTDOWN_PENDING);shutdownAt=uint64(block.timestamp+72 hours);}
    function extendShutdown(uint64 next) external {if(msg.sender!=guardian||lifecycle!=uint8(Life.SHUTDOWN_PENDING)||next<=shutdownAt)revert Invalid();shutdownAt=next;}
    function terminate() external {if(msg.sender!=guardian||lifecycle!=uint8(Life.SHUTDOWN_PENDING)||block.timestamp<shutdownAt||activePrincipal!=0||holderRewardReserve!=0)revert Invalid();lifecycle=uint8(Life.TERMINATED);}
    function resume() external {if(msg.sender!=guardian||lifecycle!=uint8(Life.PAUSED))revert Unauthorized();_validateController(settlement,settlementHash,keccak256("COMPD_SETTLEMENT_CONTROLLER_V2_PROTO"));_validateController(holder,holderHash,keccak256("COMPD_HOLDER_CONTROLLER_V2_PROTO"));_validateController(emergency,emergencyHash,keccak256("COMPD_EMERGENCY_CONTROLLER_V2_PROTO"));_assertHolder();_assertAccounting();lifecycle=uint8(Life.ACTIVE);}
    function allocate(uint256 run,uint256 amount) external lock {if(msg.sender!=strategyExecutor||lifecycle!=uint8(Life.ACTIVE)||run==0||usedRun[run]||amount==0||amount>strategyCapital-activePrincipal)revert Invalid();usedRun[run]=true;principalOf[run]=amount;activePrincipal+=amount;accountedQuote-=amount;require(IProtoToken(quote).transfer(strategyExecutor,amount));_assertAccounting();}
    function settle(uint256 run,uint256 returned,uint64 nonce,bytes32 suppliedCommit) external lock {uint256 p=principalOf[run];if(msg.sender!=strategyExecutor||lifecycle!=uint8(Life.ACTIVE)||p==0||consumed[1]!=nonce)revert Invalid();(address executor,address asset,uint256 evidencePrincipal,uint256 evidenceReturn,uint8 runState,bool settled_,bool replayed,bytes32 evidence)=IProtoRunSource(strategyExecutor).runEvidence(run);if(executor!=strategyExecutor||asset!=quote||evidencePrincipal!=p||evidenceReturn!=returned||runState!=2||!settled_||replayed||evidence==0)revert Invalid();uint256 beforeBal=IProtoToken(quote).balanceOf(address(this));require(IProtoToken(quote).transferFrom(msg.sender,address(this),returned));uint256 afterBal=IProtoToken(quote).balanceOf(address(this));if(afterBal<beforeBal||afterBal-beforeBal!=returned)revert Invalid();(bytes32 c,uint256 cp,uint256 loss_,uint256 compound_,uint256 buyback_,uint64 n,bytes32 wid,uint64 st,uint64 en)=IProtoSettlement(settlement).planRun(run,p,returned,nonce);uint256 profit=returned>p?returned-p:0;uint256 loss=p>returned?p-returned:0;uint256 bb=profit*1500/10000;uint256 hr=profit*1000/10000;uint256 pr=profit*1000/10000;uint256 compound=profit-bb-hr-pr;uint64 expectedStart=uint64(block.timestamp/28800*28800);bytes32 expectedWindow=keccak256(abi.encode(block.timestamp/28800));if(c!=suppliedCommit||c!=keccak256(abi.encode(block.chainid,address(this),settlement,uint8(1),run,quote,p,returned,nonce,evidence,expectedWindow,expectedStart,expectedStart+28800))||n!=nonce||cp!=profit||loss_!=loss||compound_!=compound||buyback_!=bb||wid!=expectedWindow||st!=expectedStart||en!=expectedStart+28800)revert Invalid();consumed[1]=nonce+1;principalOf[run]=0;activePrincipal-=p;accountedQuote+=returned;if(loss!=0){strategyCapital-=loss;cumulativeLoss+=loss;}if(profit!=0){strategyCapital+=compound;buybackReserve+=bb;holderRewardReserve+=hr;protocolReserve+=pr;if(hr!=0){uint256 old=IProtoWorkflow(workflow).windowPool(wid);IProtoWorkflow(workflow).accrueHolderPool(run,wid,st,en,hr,old+hr);}_assertHolder();cumulativeProfit+=profit;}_assertAccounting();emit Settled(run,p,returned,profit,loss);}
    function registerFlapRevenue(uint256 amount) external lock {if(msg.sender!=flapReceiver||lifecycle!=uint8(Life.ACTIVE)||amount==0)revert Unauthorized();(address asset,uint256 reported,bytes32 evidence)=IProtoReceiver(flapReceiver).revenueEvidence(amount);if(asset!=quote||reported!=amount||evidence==bytes32(0)||IProtoToken(quote).balanceOf(address(this))<accountedQuote+amount)revert Invalid();(bytes32 c,uint256 s,uint256 b,uint256 p,bytes32 ev)=IProtoSettlement(settlement).planRevenue(amount,uint64(consumed[2]));uint256 es=amount*3500/10000;uint256 eb=amount*1500/10000;uint256 ep=amount-es-eb;if(c!=keccak256(abi.encode(block.chainid,address(this),settlement,uint8(5),amount,uint64(consumed[2]),quote,amount,evidence))||ev!=evidence||s!=es||b!=eb||p!=ep)revert Invalid();consumed[2]++;accountedQuote+=amount;strategyCapital+=s;buybackReserve+=b;protocolReserve+=p;cumulativeRevenue+=amount;_assertAccounting();}
    function releaseBuyback(uint256 amount,uint16 slippage,uint16 deviation) external lock {if(block.timestamp>=periodStart+24 hours){periodStart=uint64(block.timestamp);periodStartReserve=buybackReserve;periodBuybackSpend=0;}if(periodStart==0){periodStart=uint64(block.timestamp);periodStartReserve=buybackReserve;}uint256 cap=periodStartReserve*4000/10000;(bytes32 c,bool eligible,uint256 capRead,uint64 cooldownEnd)=IProtoSettlement(settlement).planBuyback(buybackReserve,periodStartReserve,periodBuybackSpend,block.timestamp,amount,lastBuybackAt,slippage,deviation);if(msg.sender!=buybackExecutor||lifecycle!=uint8(Life.ACTIVE)||buybackReserve<0.25 ether||amount==0||amount>0.50 ether||amount>buybackReserve*2000/10000||amount>periodStartReserve*2000/10000||slippage>300||deviation>300||(lastBuybackAt!=0&&block.timestamp<lastBuybackAt+6 hours)||!eligible||capRead!=cap||cooldownEnd!=lastBuybackAt+6 hours||c!=keccak256(abi.encode(block.chainid,address(this),settlement,uint8(6),buybackReserve,periodStartReserve,periodBuybackSpend,block.timestamp,amount,lastBuybackAt,slippage,deviation))||periodBuybackSpend+amount>cap)revert Invalid();periodBuybackSpend+=amount;lastBuybackAt=uint64(block.timestamp);buybackReserve-=amount;accountedQuote-=amount;require(IProtoToken(quote).transfer(buybackExecutor,amount));IProtoBuyback(buybackExecutor).execute(amount,slippage,deviation);_assertAccounting();}
    function finalize(bytes32 id,uint32 version) external lock {(bytes32 c,uint256 amount,uint16 count)=IProtoHolder(holder).coordinateFinalize(workflow,liability,distributor,id,version);(bytes32 root,,,,,)=IProtoDistributor(distributor).candidate(id);if(c!=keccak256(abi.encode(block.chainid,address(this),holder,uint8(2),id,version,root,amount,count)))revert Invalid();IProtoWorkflow(workflow).finalize(id,version,amount);IProtoLiability(liability).finalize(id,version,amount);(bytes32 wr,uint32 v,uint256 wa,uint64 ready,uint8 status)=IProtoWorkflow(workflow).distribution(id);(bytes32 droot,uint32 dv,uint256 da,uint16 dc,uint64 dr,)=IProtoDistributor(distributor).candidate(id);(uint256 la,uint16 lc,bool finalized,bool superseded)=IProtoLiability(liability).distributionSummary(id,version);if(v!=version||dv!=version||root!=droot||wr!=root||wa!=amount||da!=amount||dc!=count||dr!=ready||status!=2||la!=amount||lc!=count||!finalized||superseded)revert Invalid();_assertHolder();_assertAccounting();}
    function pay(bytes32 id,uint32 v,uint16 ix,bytes32 expectedLeaf,address expectedTo,address expectedAsset,uint256 expectedAmount) external lock {if(lifecycle!=uint8(Life.ACTIVE))revert Invalid();(bytes32 c,address to,address asset,uint256 amount,uint8 status)=IProtoHolder(holder).planPayment(liability,id,v,ix);(bytes32 leaf,address srcTo,address srcAsset,uint256 srcAmount,uint8 srcStatus)=IProtoLiability(liability).summary(id,v,ix);(bytes32 dleaf,address dto,address das,uint256 da,uint8 ds)=IProtoDistributor(distributor).leaf(id,v,ix);if(c!=keccak256(abi.encode(block.chainid,address(this),holder,uint8(3),id,v,ix,leaf,to,asset,amount,status))||leaf!=expectedLeaf||to!=expectedTo||asset!=expectedAsset||amount!=expectedAmount||srcTo!=to||srcAsset!=asset||srcAmount!=amount||srcStatus!=2||status!=2||dleaf!=leaf||dto!=to||das!=asset||da!=amount||ds!=2||amount>holderRewardReserve)revert Invalid();bytes32 key=keccak256(abi.encode(id,v,ix));if(paymentUsed[key])revert Replay();uint256 rb=IProtoToken(asset).balanceOf(to);uint256 vb=IProtoToken(asset).balanceOf(address(this));paymentUsed[key]=true;holderRewardReserve-=amount;accountedQuote-=amount;require(IProtoToken(asset).transfer(to,amount));uint256 ra=IProtoToken(asset).balanceOf(to);uint256 va=IProtoToken(asset).balanceOf(address(this));if(ra<rb||ra-rb!=amount||vb<va||vb-va!=amount)revert Invalid();IProtoLiability(liability).paid(id,v,ix);IProtoWorkflow(workflow).paymentProcessed(id,amount);_assertHolder();_assertAccounting();}
    function correctDistribution(bytes32 id,uint32 oldVersion,bytes32 nextRoot,bytes32 reason) external lock {if(lifecycle!=uint8(Life.ACTIVE))revert Invalid();(bytes32 c,uint32 version,uint256 amount,uint16 count,uint64 ready)=IProtoHolder(holder).coordinateCorrection(workflow,liability,distributor,id,oldVersion,nextRoot,reason);if(c!=keccak256(abi.encode(block.chainid,address(this),holder,uint8(7),id,oldVersion,version,count,uint64(block.timestamp),ready))||version!=oldVersion+1||count==0||count>30||ready!=block.timestamp+1800)revert Invalid();IProtoLiability(liability).supersedeVersion(id,oldVersion);IProtoDistributor(distributor).correctCandidate(id,version,nextRoot,ready);IProtoWorkflow(workflow).correctDistributionCandidate(id,version,nextRoot,ready,amount,count);(bytes32 root,uint32 actualVersion,uint256 actualAmount,uint16 actualCount,uint64 actualReady,)=IProtoDistributor(distributor).candidate(id);(bytes32 wr,uint32 wv,uint256 wa,uint64 wready,uint8 status)=IProtoWorkflow(workflow).distribution(id);if(actualVersion!=version||wv!=version||root!=nextRoot||wr!=nextRoot||amount!=actualAmount||amount!=wa||count!=actualCount||ready!=actualReady||ready!=wready||status!=1)revert Invalid();_assertHolder();_assertAccounting();}
    function recover(bytes32 id) external lock { (uint256 amount,bool ok)=IProtoWorkflow(workflow).eligible(id);if(!ok||amount==0||amount>holderRewardReserve)revert Invalid();IProtoWorkflow(workflow).recovered(id);holderRewardReserve-=amount;accountedQuote-=amount;require(IProtoToken(quote).transfer(recoveryTreasury,amount));_assertHolder();_assertAccounting();}
    function pause() external {if(msg.sender!=guardian||lifecycle!=uint8(Life.ACTIVE))revert Unauthorized();lifecycle=uint8(Life.PAUSED);}
    function emergencyEnter() external {if(msg.sender!=emergencyAuthority||lifecycle==uint8(Life.EMERGENCY_RECOVERY)||lifecycle==uint8(Life.TERMINATED))revert Unauthorized();_assertAccounting();if(accountedQuote<holderRewardReserve)revert Accounting();uint8 old=lifecycle;uint256 vb=IProtoToken(quote).balanceOf(address(this));uint256 nonHolder=accountedQuote-holderRewardReserve;uint256 free=vb>nonHolder?vb-nonHolder:0;uint256 available=free<holderRewardReserve?free:holderRewardReserve;preEmergencyDeficit=holderRewardReserve-available;emergencyNonce++;emergencyQuoteBalance=vb;emergencyTimestamp=uint64(block.timestamp);emergencyBlock=uint64(block.number);emergencyProcessingStatus=1;lifecycle=uint8(Life.EMERGENCY_RECOVERY);emergencySnapshot=keccak256(abi.encode(address(this),block.chainid,emergencyTimestamp,emergencyBlock,emergencyNonce,old,strategyCapital,buybackReserve,protocolReserve,holderRewardReserve,accountedQuote,activePrincipal,vb,preEmergencyDeficit));}
    function emergencyTransfer(uint8 moduleId,address module,address asset,uint256 amount,bytes32 commit) external lock {if(lifecycle!=uint8(Life.EMERGENCY_RECOVERY)||asset!=quote||moduleId!=1||module!=strategyExecutor||module.code.length==0||IProtoIdentity(module).vault()!=address(this))revert Invalid();uint32 n=IProtoRegistry(registry).attempts(emergencySnapshot)+1;(bytes32 c,uint8 mid,address a,uint32 no)=IProtoEmergency(emergency).plan(module,moduleId,asset,n);if(c!=commit||mid!=moduleId||a!=asset||no!=n)revert Invalid();uint256 vb=IProtoToken(asset).balanceOf(address(this));uint256 rb=IProtoToken(asset).balanceOf(emergencyWallet);require(IProtoToken(asset).transfer(emergencyWallet,amount));uint256 va=IProtoToken(asset).balanceOf(address(this));uint256 ra=IProtoToken(asset).balanceOf(emergencyWallet);if(vb-va!=amount||ra-rb!=amount)revert Invalid();IProtoRegistry(registry).attempt(emergencySnapshot,n,module,amount,ra-rb);}
    function readOnlyDiagnostics() external view returns(uint256,uint256,uint64,uint256,uint256,uint256,uint64){return(cumulativeProfit,cumulativeLoss,periodStart,periodStartReserve,periodBuybackSpend,cumulativeRevenue,lastBuybackAt);}
    function _assertAccounting() private view {if(strategyCapital+buybackReserve+protocolReserve+holderRewardReserve!=accountedQuote+activePrincipal||IProtoToken(quote).balanceOf(address(this))<accountedQuote)revert Accounting();}
    function _assertHolder() private view { (uint256 unfinal,uint256 review,uint256 unpaid,uint256 eligible,uint256 empty)=IProtoWorkflow(workflow).partitions();if(unfinal+review+unpaid+eligible+empty!=holderRewardReserve)revert Accounting();}
}
