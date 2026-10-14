// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BBoundModule, IC2G2BStrategyExecutor, IC2G2BHolderDistributor, IC2G2BHolderLiability, IC2G2BRecoveryEvidence, IC2G2BRegistry, IC2G2BBuybackExecutor, IC2G2BBuybackQuote} from "./C2G2BTypes.sol";

interface IC2G2BTermination { function terminationReady() external view returns(bool); }

/// @notice Native-BNB custody kernel. Domain evidence/history is kept in typed modules.
contract CompdVaultKernelV2 {
    uint256 private constant BPS=10_000; uint64 private constant MIN_SHUTDOWN=72 hours;
    uint256 private constant BUYBACK_MIN=0.25 ether; uint256 private constant BUYBACK_CAP=0.50 ether;
    uint64 private constant BUYBACK_COOLDOWN=6 hours; uint64 private constant BUYBACK_PERIOD=24 hours;
    uint256 private constant MAX_POSITION_BPS=1_000; uint256 private constant MAX_TOTAL_BPS=3_000; uint8 private constant MAX_RUNS=3;
    address public constant CONFIGURATION_ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address public constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address public constant RECOVERY_TREASURY=0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address public constant BUYBACK_ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address public constant AUTOMATION_EXECUTOR=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public immutable emergencyAuthority; address public immutable emergencyWallet;
    address public immutable strategyExecutor; bytes32 public immutable strategyExecutorHash;
    address public immutable buybackExecutor; bytes32 public immutable buybackExecutorHash;
    address public immutable distributor; bytes32 public immutable distributorHash;
    address public immutable liability; bytes32 public immutable liabilityHash;
    address public immutable recoveryEvidence; bytes32 public immutable recoveryEvidenceHash;
    address public immutable quoteSource; bytes32 public immutable quoteSourceHash;
    address[6] private _modules; bytes32[6] private _moduleHashes; bool public modulesBound; bool public seeded;
    T.Lifecycle public lifecycle=T.Lifecycle.PAUSED;
    uint64 public shutdownAt; uint64 public emergencyNonce; bytes32 public emergencySnapshotId;
    T.ProcessingStatus public emergencyStatus; uint256 public preEmergencyHolderDeficit; uint256 public emergencyBNBOutflow;
    uint256 public strategyCapital; uint256 public buybackReserve; uint256 public protocolReserve;
    uint256 public holderRewardReserve; uint256 public accountedQuote; uint256 public activePrincipal;
    uint256 public cumulativeRealizedProfit; uint256 public cumulativeRealizedLoss;
    uint64 public lastBuybackAt; uint64 public buybackPeriodStart; uint256 public buybackPeriodStartReserve; uint256 public buybackPeriodSpend;
    mapping(uint256=>uint256) private _runPrincipal; mapping(uint256=>address) private _runStrategy;
    mapping(uint256=>T.RunStatus) private _runStatus; mapping(uint256=>bool) private _runUsed;
    mapping(bytes32=>bool) private _allocationUsed; mapping(bytes32=>bool) private _closeUsed;
    mapping(bytes32=>bool) private _holderPaid; mapping(bytes32=>bytes32) private _failedPaymentDigest;
    mapping(bytes32=>address) private _failedRecipient; mapping(bytes32=>uint256) private _failedAmount;
    mapping(bytes32=>bytes32) private _failedRetryIdentity; mapping(bytes32=>mapping(bytes32=>bool)) private _holderAttempts;
    mapping(bytes32=>bool) private _buybackUsed; mapping(bytes32=>bool) private _recoveryUsed;
    uint256[] private _activeRuns; bool private _entered;

    error Unauthorized(); error InvalidLifecycle(); error InvalidConfiguration(); error InvalidModule();
    error ModuleCodeChanged(); error ExternalCodeChanged(); error AccountingInvariant(); error InvalidAmount();
    error Replay(); error InvalidEvidence(); error InvalidRun(); error QuotePolicyUnavailable(); error RecoveryUnavailable();
    error ShutdownNotReady(); error EmergencyInvariantFailure(); error TransferFailed(); error HolderUnavailable();
    event LifecycleChanged(T.Lifecycle indexed beforeState,T.Lifecycle indexed afterState);
    event AccountingChanged(uint256 sc,uint256 br,uint256 pr,uint256 hr,uint256 aq,uint256 ap);
    event ModuleBound(T.ModuleId indexed id,address indexed module,bytes32 codeHash);
    event StrategyAllocated(uint256 indexed runId,address indexed strategy,uint256 principal,bytes32 allocationId);
    event StrategySettled(uint256 indexed runId,uint256 principal,uint256 returnedBNB,uint256 profit,uint256 loss,bytes32 closeId);
    event HolderPaid(bytes32 indexed useId,address indexed recipient,uint256 amount);
    event HolderPaymentFailed(bytes32 indexed useId,bytes32 indexed attemptId,address recipient,uint256 amount);
    event BuybackReleased(bytes32 indexed operationId,uint256 amount);
    event RecoveryReleased(bytes32 indexed sourceId,uint8 indexed sourceKind,uint256 amount);
    event EmergencyEntered(bytes32 indexed snapshotId,uint64 nonce,uint256 balance,uint256 aq,uint256 hr,uint256 ap,uint256 deficit);
    event EmergencyBNBRecovered(bytes32 indexed scopeId,bytes32 indexed attemptId,uint256 amount,bytes32 evidence);

    modifier onlyAdmin(){if(msg.sender!=CONFIGURATION_ADMIN)revert Unauthorized();_;}
    modifier onlyGuardian(){if(msg.sender!=GUARDIAN)revert Unauthorized();_;}
    modifier onlyModule(T.ModuleId id){uint8 i=uint8(id);address m=_modules[i];if(!modulesBound||msg.sender!=m)revert Unauthorized();if(_codeHash(m)!=_moduleHashes[i])revert ModuleCodeChanged();_;}
    modifier nonReentrant(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}

    constructor(address emergencyAuthority_,address emergencyWallet_,address strategyExecutor_,address buybackExecutor_,address distributor_,address liability_,address recoveryEvidence_,address quoteSource_){
        if(emergencyAuthority_==address(0)||emergencyWallet_==address(0)||strategyExecutor_.code.length==0||buybackExecutor_.code.length==0||distributor_.code.length==0||liability_.code.length==0)revert InvalidConfiguration();
        emergencyAuthority=emergencyAuthority_;emergencyWallet=emergencyWallet_;strategyExecutor=strategyExecutor_;strategyExecutorHash=_codeHash(strategyExecutor_);
        buybackExecutor=buybackExecutor_;buybackExecutorHash=_codeHash(buybackExecutor_);distributor=distributor_;distributorHash=_codeHash(distributor_);
        liability=liability_;liabilityHash=_codeHash(liability_);recoveryEvidence=recoveryEvidence_;recoveryEvidenceHash=recoveryEvidence_.code.length==0?bytes32(0):_codeHash(recoveryEvidence_);
        quoteSource=quoteSource_;quoteSourceHash=quoteSource_.code.length==0?bytes32(0):_codeHash(quoteSource_);
    }
    receive() external payable {if(msg.sender!=strategyExecutor)revert Unauthorized();}
    function seedStrategyCapital() external payable onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||seeded||msg.value==0)revert InvalidLifecycle();seeded=true;strategyCapital+=msg.value;accountedQuote+=msg.value;_assert(true);_emitAccounting();}
    function bindModules(address[6] calldata list) external onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||modulesBound)revert InvalidLifecycle();for(uint8 i;i<6;++i){address m=list[i];if(m==address(0)||m.code.length==0)revert InvalidModule();try IC2G2BBoundModule(m).kernel() returns(address k){if(k!=address(this))revert InvalidModule();}catch{revert InvalidModule();}try IC2G2BBoundModule(m).moduleId() returns(uint8 id){if(id!=i)revert InvalidModule();}catch{revert InvalidModule();}try IC2G2BBoundModule(m).moduleVersion() returns(uint32 v){if(v!=2)revert InvalidModule();}catch{revert InvalidModule();}for(uint8 j;j<i;++j)if(list[j]==m)revert InvalidModule();_modules[i]=m;_moduleHashes[i]=_codeHash(m);emit ModuleBound(T.ModuleId(i),m,_moduleHashes[i]);}modulesBound=true;}
    function moduleAddress(T.ModuleId id) external view returns(address){return _modules[uint8(id)];}
    function activate() external onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||!modulesBound||!seeded)revert InvalidLifecycle();_assert(true);_setLife(T.Lifecycle.ACTIVE);}
    function pause() external onlyGuardian {if(lifecycle!=T.Lifecycle.ACTIVE)revert InvalidLifecycle();_setLife(T.Lifecycle.PAUSED);}
    function resume() external onlyGuardian {if(lifecycle!=T.Lifecycle.PAUSED||!modulesBound)revert InvalidLifecycle();_assert(true);_setLife(T.Lifecycle.ACTIVE);}
    function initiateShutdown(uint64 delay) external onlyGuardian {if((lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED)||delay<MIN_SHUTDOWN)revert InvalidLifecycle();shutdownAt=uint64(block.timestamp)+delay;_setLife(T.Lifecycle.SHUTDOWN_PENDING);}
    function extendShutdown(uint64 deadline) external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||deadline<=shutdownAt)revert InvalidLifecycle();shutdownAt=deadline;}
    function terminate() external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||block.timestamp<shutdownAt||activePrincipal!=0||_activeRuns.length!=0||!modulesBound)revert ShutdownNotReady();_assert(true);for(uint8 i;i<5;++i){if(_codeHash(_modules[i])!=_moduleHashes[i])revert ModuleCodeChanged();try IC2G2BTermination(_modules[i]).terminationReady() returns(bool ready){if(!ready)revert ShutdownNotReady();}catch{revert ShutdownNotReady();}}_setLife(T.Lifecycle.TERMINATED);}

    function allocateStrategyPrincipal(uint256 runId,address strategy,uint256 amount,bytes32 allocationId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE||runId==0||strategy==address(0)||_runUsed[runId]||allocationId==0||_allocationUsed[allocationId]||amount==0||amount>strategyCapital-activePrincipal||amount>accountedQuote||_activeRuns.length>=MAX_RUNS||amount*BPS>strategyCapital*MAX_POSITION_BPS||(activePrincipal+amount)*BPS>strategyCapital*MAX_TOTAL_BPS)revert InvalidAmount();
        _assert(true);_checkHash(strategyExecutor,strategyExecutorHash);if(!IC2G2BStrategyExecutor(strategyExecutor).isApprovedStrategy(strategy))revert InvalidEvidence();
        _runUsed[runId]=true;_allocationUsed[allocationId]=true;_runPrincipal[runId]=amount;_runStrategy[runId]=strategy;_runStatus[runId]=T.RunStatus.OPEN;_activeRuns.push(runId);activePrincipal+=amount;accountedQuote-=amount;
        uint256 maxLoss=amount*300/10_000;bytes32 ack=IC2G2BStrategyExecutor(strategyExecutor).openRun{value:amount}(runId,strategy,amount,maxLoss,allocationId);if(ack!=allocationId)revert InvalidEvidence();_assert(false);emit StrategyAllocated(runId,strategy,amount,allocationId);_emitAccounting();
    }
    function recordExitRequest(uint256 runId,bytes32 exitId,T.RunStatus status) external onlyModule(T.ModuleId.SETTLEMENT) {if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING)revert InvalidLifecycle();if(_runPrincipal[runId]==0||_runStatus[runId]!=T.RunStatus.OPEN||exitId==0||(status!=T.RunStatus.EXIT_REQUESTED&&status!=T.RunStatus.RETURN_PENDING&&status!=T.RunStatus.BLOCKED))revert InvalidRun();_runStatus[runId]=status;}
    function settleStrategyPrincipal(uint256 runId,bytes32 closeId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY)revert InvalidLifecycle();uint256 principal=_runPrincipal[runId];if(principal==0||closeId==0||_closeUsed[closeId])revert InvalidRun();_checkHash(strategyExecutor,strategyExecutorHash);uint256 beforeBalance=address(this).balance;(uint256 p,uint256 returned,bytes32 canonical)=IC2G2BStrategyExecutor(strategyExecutor).closeToKernel(runId,closeId);uint256 afterBalance=address(this).balance;if(p!=principal||canonical!=closeId||afterBalance<beforeBalance||afterBalance-beforeBalance!=returned)revert InvalidEvidence();_closeUsed[closeId]=true;_runPrincipal[runId]=0;activePrincipal-=principal;accountedQuote+=returned;uint256 profit;uint256 loss;if(returned>=principal){profit=returned-principal;if(profit!=0){uint256 br=profit*1500/BPS;uint256 hr=profit*1000/BPS;uint256 pr=profit*1000/BPS;strategyCapital+=profit-br-hr-pr;buybackReserve+=br;holderRewardReserve+=hr;protocolReserve+=pr;cumulativeRealizedProfit+=profit;}}else{loss=principal-returned;if(loss>strategyCapital-activePrincipal)revert AccountingInvariant();strategyCapital-=loss;cumulativeRealizedLoss+=loss;}_runStatus[runId]=T.RunStatus.SETTLED;_removeRun(runId);_assert(false);emit StrategySettled(runId,principal,returned,profit,loss,closeId);_emitAccounting();
    }
    function runPrincipal(uint256 id) external view returns(uint256){return _runPrincipal[id];} function runStrategy(uint256 id) external view returns(address){return _runStrategy[id];} function runStatus(uint256 id) external view returns(T.RunStatus){return _runStatus[id];}
    function activeRunCount() external view returns(uint256){return _activeRuns.length;} function activeRunAt(uint256 i) external view returns(uint256){return _activeRuns[i];}

    function holderDigest(T.HolderPayment memory p) public view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,address(this),p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));}
    function payHolder(T.HolderPayment calldata p,bool retry,bytes32 attemptId) external onlyModule(T.ModuleId.HOLDER) nonReentrant returns(bool){return _payHolder(p,retry,attemptId);}
    function _payHolder(T.HolderPayment calldata p,bool retry,bytes32 attemptId) private returns(bool){if(lifecycle!=T.Lifecycle.ACTIVE||p.leafId==0||p.useId==0||p.recipient==address(0)||p.asset!=address(0)||p.amount==0||p.distributionStatus!=1||p.liabilityStatus!=1||p.recoveryStatus!=0||p.expiresAt!=0&&block.timestamp>p.expiresAt||p.amount>holderRewardReserve||p.amount>accountedQuote)revert HolderUnavailable();bytes32 digest=holderDigest(p);_checkHash(distributor,distributorHash);_checkHash(liability,liabilityHash);(T.HolderPayment memory committed,bool proof)=IC2G2BHolderDistributor(distributor).paymentData(p.leafId);if(!proof||holderDigest(committed)!=digest||IC2G2BHolderDistributor(distributor).paymentDigest(p.leafId)!=digest||IC2G2BHolderLiability(liability).paymentDigest(p.leafId)!=digest)revert InvalidEvidence();bytes32 id=p.useId;if(_holderPaid[id])revert Replay();if(retry){if(attemptId==0||_holderAttempts[id][attemptId]||_failedPaymentDigest[id]!=digest||_failedRecipient[id]!=p.recipient||_failedAmount[id]!=p.amount||_failedRetryIdentity[id]!=keccak256(abi.encode(p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId)))revert Replay();_holderAttempts[id][attemptId]=true;}_assert(false);(bool ok,)=payable(p.recipient).call{value:p.amount,gas:50_000}("");if(!ok){if(!retry){bytes32 failId=keccak256(abi.encode(id,block.number,msg.sender));_holderAttempts[id][failId]=true;_failedPaymentDigest[id]=digest;_failedRecipient[id]=p.recipient;_failedAmount[id]=p.amount;_failedRetryIdentity[id]=keccak256(abi.encode(p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId));emit HolderPaymentFailed(id,failId,p.recipient,p.amount);}return false;}_checkHash(distributor,distributorHash);_checkHash(liability,liabilityHash);IC2G2BHolderDistributor(distributor).consumePayment(p.leafId,digest);IC2G2BHolderLiability(liability).consumePayment(p.leafId,digest);_holderPaid[id]=true;holderRewardReserve-=p.amount;accountedQuote-=p.amount;_assert(false);emit HolderPaid(id,p.recipient,p.amount);_emitAccounting();return true;}
    function holderPaid(bytes32 id) external view returns(bool){return _holderPaid[id];} function failedHolder(bytes32 id) external view returns(bytes32,address,uint256,bytes32){return(_failedPaymentDigest[id],_failedRecipient[id],_failedAmount[id],_failedRetryIdentity[id]);}

    function releaseBuyback(bytes32 id,uint256 amount,bytes32 quoteId) external onlyModule(T.ModuleId.BUYBACK) nonReentrant {if(lifecycle!=T.Lifecycle.ACTIVE||id==0||_buybackUsed[id]||buybackReserve<BUYBACK_MIN||amount==0||amount>BUYBACK_CAP||amount>buybackReserve*2000/BPS||amount>accountedQuote)revert InvalidAmount();if(lastBuybackAt!=0&&block.timestamp<uint256(lastBuybackAt)+BUYBACK_COOLDOWN)revert InvalidLifecycle();if(buybackPeriodStart==0||block.timestamp>=uint256(buybackPeriodStart)+BUYBACK_PERIOD){buybackPeriodStart=uint64(block.timestamp);buybackPeriodStartReserve=buybackReserve;buybackPeriodSpend=0;}if(amount>buybackPeriodStartReserve*2000/BPS||buybackPeriodSpend+amount>buybackPeriodStartReserve*4000/BPS)revert InvalidAmount();if(quoteId==0||quoteSource==address(0)||_codeHash(quoteSource)!=quoteSourceHash)revert QuotePolicyUnavailable();_buybackUsed[id]=true;lastBuybackAt=uint64(block.timestamp);buybackPeriodSpend+=amount;buybackReserve-=amount;accountedQuote-=amount;revert QuotePolicyUnavailable();}
    function recoverProtocolReserve(bytes32 id,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(id,amount,0);}
    function recoverNoRecipient(bytes32 id,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(id,amount,1);}
    function recoverExpiredHolder(bytes32 id,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(id,amount,2);}
    function _recover(bytes32 id,uint256 amount,uint8 kind) private {if(lifecycle!=T.Lifecycle.TERMINATED||id==0||amount==0||recoveryEvidence.code.length==0||_recoveryUsed[keccak256(abi.encode(kind,id))])revert RecoveryUnavailable();_checkHash(recoveryEvidence,recoveryEvidenceHash);(bool eligible,uint256 exact)=kind==0?IC2G2BRecoveryEvidence(recoveryEvidence).protocolReserveRecovery(id):kind==1?IC2G2BRecoveryEvidence(recoveryEvidence).noRecipientRecovery(id):IC2G2BRecoveryEvidence(recoveryEvidence).expiredHolderRecovery(id);uint256 bucket=kind==0?protocolReserve:holderRewardReserve;if(!eligible||exact!=amount||amount>bucket||amount>accountedQuote)revert InvalidEvidence();_checkHash(recoveryEvidence,recoveryEvidenceHash);_recoveryUsed[keccak256(abi.encode(kind,id))]=true;if(kind==0)IC2G2BRecoveryEvidence(recoveryEvidence).consumeProtocolReserve(id);else if(kind==1)IC2G2BRecoveryEvidence(recoveryEvidence).consumeNoRecipient(id);else IC2G2BRecoveryEvidence(recoveryEvidence).consumeExpiredHolder(id);if(kind==0)protocolReserve-=amount;else holderRewardReserve-=amount;accountedQuote-=amount;_send(RECOVERY_TREASURY,amount);_assert(false);emit RecoveryReleased(id,kind,amount);_emitAccounting();}

    function emergencyEnter() external nonReentrant {if(msg.sender!=emergencyAuthority||lifecycle==T.Lifecycle.TERMINATED||lifecycle==T.Lifecycle.EMERGENCY_RECOVERY)revert Unauthorized();_assert(true);uint256 n=accountedQuote-holderRewardReserve;uint256 b=address(this).balance;uint256 hb=b>n?b-n:0;if(hb>holderRewardReserve)hb=holderRewardReserve;preEmergencyHolderDeficit=holderRewardReserve-hb;unchecked{++emergencyNonce;}emergencySnapshotId=keccak256(abi.encode(block.chainid,address(this),emergencyNonce,uint8(lifecycle),b,accountedQuote,activePrincipal,holderRewardReserve,preEmergencyHolderDeficit,block.timestamp,block.number));emergencyStatus=T.ProcessingStatus.IN_PROGRESS;_setLife(T.Lifecycle.EMERGENCY_RECOVERY);emit EmergencyEntered(emergencySnapshotId,emergencyNonce,b,accountedQuote,holderRewardReserve,activePrincipal,preEmergencyHolderDeficit);}
    function emergencyTransferBNB(bytes32 scopeId,bytes32 attemptId,uint32 attemptNumber,uint256 amount,bytes32 evidence) external onlyModule(T.ModuleId.EMERGENCY) nonReentrant {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||scopeId==0||attemptId==0||attemptNumber==0||amount==0||evidence==0||amount>address(this).balance)revert InvalidAmount();address reg=_modules[5];if(reg==address(0)||_codeHash(reg)!=_moduleHashes[5])revert ModuleCodeChanged();IC2G2BRegistry(reg).beginAttempt(emergencySnapshotId,scopeId,attemptId,attemptNumber);uint256 before_=address(this).balance;_send(emergencyWallet,amount);if(before_-address(this).balance!=amount)revert InvalidEvidence();emergencyBNBOutflow+=amount;IC2G2BRegistry(reg).finishAttempt(emergencySnapshotId,scopeId,attemptId,attemptNumber,T.AttemptStatus.SUCCEEDED,evidence);emit EmergencyBNBRecovered(scopeId,attemptId,amount,evidence);}
    function setEmergencyStatus(T.ProcessingStatus s) external onlyModule(T.ModuleId.EMERGENCY){if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||s==T.ProcessingStatus.NOT_STARTED)revert InvalidLifecycle();emergencyStatus=s;}
    function _assert(bool physical) private view {if(strategyCapital+buybackReserve+protocolReserve+holderRewardReserve!=accountedQuote+activePrincipal||activePrincipal>strategyCapital||accountedQuote<holderRewardReserve||(physical&&address(this).balance<accountedQuote))revert AccountingInvariant();}
    function _removeRun(uint256 id) private {for(uint256 i;i<_activeRuns.length;++i)if(_activeRuns[i]==id){_activeRuns[i]=_activeRuns[_activeRuns.length-1];_activeRuns.pop();break;}}
    function _send(address to,uint256 amount) private {uint256 b=address(this).balance;(bool ok,)=payable(to).call{value:amount,gas:50_000}("");if(!ok||b<address(this).balance||b-address(this).balance!=amount)revert TransferFailed();}
    function _checkHash(address a,bytes32 h) private view {if(_codeHash(a)!=h)revert ExternalCodeChanged();}
    function _codeHash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
    function _setLife(T.Lifecycle l) private {T.Lifecycle old=lifecycle;lifecycle=l;emit LifecycleChanged(old,l);}
    function _emitAccounting() private {emit AccountingChanged(strategyCapital,buybackReserve,protocolReserve,holderRewardReserve,accountedQuote,activePrincipal);}
}
