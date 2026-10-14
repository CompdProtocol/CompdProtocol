// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BBoundModule, IC2G2BStrategyExecutorR4, IC2G2BHolderDistributor, IC2G2BHolderLiability, IC2G2BRecoveryEvidence, IC2G2BRegistry} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdStrategyExecutorV2R2} from "../../v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {C2G2BBuybackExecutorR6R2B, C2G2BBuybackConfigR6R2B} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface C2G2BBuybackModuleCommitmentR6R2B { function buybackConfigurationCommitment() external view returns(bytes32); }

interface IC2G2BTermination { function terminationReady() external view returns(bool); }
interface IC2G2BCanonicalHolder { function canonicalPayment(bytes32 leafId) external view returns(bytes32 digest,address recipient,address asset,uint256 amount,uint8 status,bool payableNow); }
interface IC2G2BHolderStateSource { function canonicalState() external view returns(address); function terminalStatus(bytes32 leafId) external view returns(bool terminal,uint64 startedAt,uint64 expiresAt,bytes32 useId); function kernel() external view returns(address); function distributor() external view returns(address); function liability() external view returns(address); function recoveryEvidence() external view returns(address); function candidateModule() external view returns(address); function recoveryWindowStart(bytes32 id,uint8 kind) external view returns(uint64); function canonicalPayment(bytes32) external view returns(bytes32,address,address,uint256,uint8,bool); function paymentWindowStart(bytes32) external view returns(uint64); }
interface IHolderWindowPaymentV3 { function paymentData(bytes32 leafId) external view returns(T.HolderPayment memory payment,bool proofValid); function paymentWindowStart(bytes32 leafId) external view returns(uint64); }
interface IHolderCandidateHelpersV3 { function kernel() external view returns(address); function state() external view returns(address); function domainSeparator() external view returns(bytes32); function computeActivationContextHash(uint64,bytes32,uint64,uint64,uint256,address) external pure returns(bytes32); function computeWindowIdentity(uint64,bytes32,uint64,uint64,uint256,address,address,address) external pure returns(bytes32,bytes32,uint64); function computeExclusionSetHash(address[15] calldata,uint32) external pure returns(bytes32); }
interface INonpayableRecoveryEvidenceV3 { function nonpayableHolderRecovery(bytes32,uint8) external view returns(bool,uint256); function consumeNonpayableHolder(bytes32,uint8) external; }
interface IRecoveryV3Authorization { function authorizeRecovery(uint8,bytes32) external view returns(bool,uint256); }

/// @notice Native-BNB custody kernel. Domain evidence/history is kept in typed modules.
contract CompdVaultKernelV3 {
    uint256 private constant BPS=10_000; uint256 public constant TREASURY_TO_STRATEGY_ALLOCATION_BPS=1_000; uint256 private constant TREASURY_ALLOCATION_DENOMINATOR=BPS/TREASURY_TO_STRATEGY_ALLOCATION_BPS; uint64 private constant MIN_SHUTDOWN=72 hours;
    uint64 public constant HOLDER_WINDOW_SECONDS=28_800;
    bytes32 public constant HOLDER_WINDOW_TYPEHASH=keccak256(bytes("CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"));
    bytes32 public constant EXCLUSION_SET_TYPEHASH=keccak256(bytes("CompdHolderRewardExclusionSet(uint32 exclusionSetVersion,address[] sortedExcludedAddresses)"));
    uint256 private constant BUYBACK_MIN=0.25 ether; uint256 private constant BUYBACK_CAP=0.50 ether;
    uint256 private constant MAX_POSITION_BPS=1_000; uint256 private constant MAX_TOTAL_BPS=3_000; uint256 private constant MAX_DESIGNED_LOSS_BPS=300; uint8 private constant MAX_RUNS=3;
    address public constant CONFIGURATION_ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address public constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address public constant RECOVERY_TREASURY=0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address public constant BUYBACK_ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address public constant AUTOMATION_EXECUTOR=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public immutable emergencyAuthority; address public immutable emergencyWallet; address public immutable eligibilityToken;
    address public immutable strategyExecutor; bytes32 public immutable strategyExecutorHash;
    address public immutable buybackExecutor; bytes32 public immutable buybackExecutorHash;
    address public immutable distributor; bytes32 public immutable distributorHash;
    address public immutable candidateModule; bytes32 public immutable candidateModuleHash;
    address public immutable liability; bytes32 public immutable liabilityHash;
    address public immutable recoveryEvidence; bytes32 public immutable recoveryEvidenceHash;
    address public immutable holderState; bytes32 public immutable holderStateHash;
    address[6] private _modules; bytes32[6] private _moduleHashes; bool public constant modulesBound=true; bool public seeded; bool public hasActivated;
    T.Lifecycle public lifecycle=T.Lifecycle.PAUSED;
    uint64 public shutdownAt; uint64 public shutdownStartedAt; uint64 public emergencyNonce; bytes32 public emergencySnapshotId;
    uint64 public activationBlock; uint64 public activationTimestamp; uint64 public firstEligibleWindowStart; bytes32 public activationBlockHash; bool public activationSealed; bool public activationSealFailed;
    uint32 public constant exclusionSetVersion=2; bytes32 public activationExclusionSetHash;
    mapping(uint64=>uint256) public holderWindowAccrued;
    uint256 public eligibleWindowHR; uint256 public partialActivationHR; uint256 public activationSealFailureHR; uint256 public shutdownTailHR; uint256 public emergencyLockedHR;
    T.ProcessingStatus public emergencyStatus; uint256 public preEmergencyHolderDeficit; uint256 public emergencyBNBOutflow;
    uint256 public strategyCapital; uint256 public nonStrategyTreasuryPrincipal; uint256 public buybackReserve; uint256 public protocolReserve;
    uint256 public holderRewardReserve; uint256 public accountedQuote; uint256 public activePrincipal;
    uint256 public cumulativeRealizedProfit; uint256 public cumulativeRealizedLoss;
    mapping(uint256=>uint256) private _runPrincipal; mapping(uint256=>uint256) public principalCredited; mapping(uint256=>uint256) public runTotalPhysicalReturn; mapping(uint256=>uint256) public runMaxDesignedLoss; mapping(uint256=>uint256) public runActualLoss; mapping(uint256=>bool) public runLossBoundBreached; bool public strategyAllocationHalted;
    mapping(uint256=>bool) private _runUsed;
    mapping(bytes32=>bool) private _allocationUsed; mapping(bytes32=>bool) private _closeUsed;
    mapping(bytes32=>bool) private _holderPaid; mapping(bytes32=>bytes32) private _failedPaymentDigest;
    mapping(bytes32=>address) private _failedRecipient; mapping(bytes32=>uint256) private _failedAmount;
    mapping(bytes32=>bytes32) private _failedRetryIdentity; mapping(bytes32=>mapping(bytes32=>bool)) private _holderAttempts;
    mapping(bytes32=>bool) private _buybackUsed; mapping(bytes32=>bool) private _recoveryUsed; mapping(bytes32=>bool) private _nonpayableRecoveryUsed;
    uint8 private _activeRunCount; bool private _entered;
    bool public buybackActivated;

    error Unauthorized(); error InvalidLifecycle(); error InvalidConfiguration(); error InvalidModule();
    error ModuleCodeChanged(); error ExternalCodeChanged(); error AccountingInvariant(); error InvalidAmount();
    error Replay(); error InvalidEvidence(); error InvalidRun(); error QuotePolicyUnavailable(); error RecoveryUnavailable();
    error ShutdownNotReady(); error EmergencyInvariantFailure(); error TransferFailed(); error HolderUnavailable();
    event LifecycleChanged(T.Lifecycle indexed beforeState,T.Lifecycle indexed afterState);
    event AccountingChanged(uint256 sc,uint256 ntp,uint256 br,uint256 pr,uint256 hr,uint256 aq,uint256 ap);
    event ModuleBound(T.ModuleId indexed id,address indexed module,bytes32 codeHash);
    event StrategyAllocated(uint256 indexed runId,address indexed strategy,uint256 principal,bytes32 allocationId);
    event StrategyRiskBudgetCommitted(uint256 indexed runId,uint256 principal,uint256 maxDesignedLoss);
    event StrategyPartialRecovery(uint256 indexed runId,bytes32 indexed attemptId,uint256 physicalBNB,uint256 principalCredited,uint256 remainingPrincipal);
    event StrategySettled(uint256 indexed runId,uint256 principal,uint256 returnedBNB,uint256 profit,uint256 loss,bytes32 closeId);
    event LOSS_BOUND_BREACH(uint256 indexed runId,uint256 principal,uint256 physicalReturnedBNB,uint256 maxDesignedLoss,uint256 actualLoss);
    event ExecutorCloseMetadataMismatch(uint256 indexed runId,bytes32 indexed closeId,uint256 reportedPrincipal,uint256 committedPrincipal,uint256 reportedReturn,uint256 physicalReturn,bytes32 reportedCloseId);
    event HolderPaid(bytes32 indexed useId,address indexed recipient,uint256 amount);
    event HolderPaymentFailed(bytes32 indexed useId,bytes32 indexed attemptId,address recipient,uint256 amount);
    event BuybackReleased(bytes32 indexed operationId,uint256 amount);
    event RecoveryReleased(bytes32 indexed sourceId,uint8 indexed sourceKind,uint256 amount);
    event EmergencyEntered(bytes32 indexed snapshotId,uint64 nonce,uint256 balance,uint256 aq,uint256 ntp,uint256 hr,uint256 ap,uint256 deficit);
    event EmergencyBNBRecovered(bytes32 indexed scopeId,bytes32 indexed attemptId,uint256 amount,bytes32 evidence);
    event ActivationCheckpointCaptured(uint64 indexed activationBlock,uint64 activationTimestamp,uint64 firstEligibleWindowStart);
    event ActivationCheckpointSealed(uint64 indexed activationBlock,bytes32 activationBlockHash,bytes32 activationContextHash);
    event ActivationCheckpointFailed(uint64 indexed activationBlock,uint256 demotedHR);
    event HolderWindowAccrued(uint64 indexed windowStart,bytes32 indexed windowId,uint256 amount,uint256 total);
    event HolderHRPartitionChanged(uint8 indexed fromPartition,uint8 indexed toPartition,uint256 amount);
    event ShutdownStarted(uint64 indexed startedAt,uint64 deadline,uint64 demotedWindow,uint256 demotedHR);

    modifier onlyAdmin(){if(msg.sender!=CONFIGURATION_ADMIN)revert Unauthorized();_;}
    modifier onlyGuardian(){if(msg.sender!=GUARDIAN)revert Unauthorized();_;}
    modifier onlyModule(T.ModuleId id){uint8 i=uint8(id);address m=_modules[i];if(!modulesBound||msg.sender!=m)revert Unauthorized();if(_codeHash(m)!=_moduleHashes[i])revert ModuleCodeChanged();_;}
    modifier nonReentrant(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}

    constructor(address emergencyAuthority_,address emergencyWallet_,address buybackExecutor_,address distributor_,address liability_,address recoveryEvidence_,address candidateModule_,address eligibilityToken_,address[6] memory modules_){
        if(emergencyAuthority_==address(0)||emergencyWallet_==address(0)||eligibilityToken_==address(0)||buybackExecutor_.code.length==0||distributor_.code.length==0||liability_.code.length==0||recoveryEvidence_.code.length==0||candidateModule_.code.length==0)revert InvalidConfiguration();
        emergencyAuthority=emergencyAuthority_;emergencyWallet=emergencyWallet_;eligibilityToken=eligibilityToken_;strategyExecutor=address(new CompdStrategyExecutorV2R2(address(this),CONFIGURATION_ADMIN,GUARDIAN));strategyExecutorHash=_codeHash(strategyExecutor);
        buybackExecutor=buybackExecutor_;buybackExecutorHash=_codeHash(buybackExecutor_);distributor=distributor_;distributorHash=_codeHash(distributor_);
        liability=liability_;liabilityHash=_codeHash(liability_);recoveryEvidence=recoveryEvidence_;recoveryEvidenceHash=_codeHash(recoveryEvidence_);candidateModule=candidateModule_;candidateModuleHash=_codeHash(candidateModule_);
        address state1=IC2G2BHolderStateSource(distributor_).canonicalState();address state2=IC2G2BHolderStateSource(liability_).canonicalState();if(state1==address(0)||state1!=state2||state1.code.length==0)revert InvalidConfiguration();
        IC2G2BHolderStateSource stateConfig=IC2G2BHolderStateSource(state1);if(stateConfig.kernel()!=address(this)||stateConfig.distributor()!=distributor_||stateConfig.liability()!=liability_||stateConfig.recoveryEvidence()!=recoveryEvidence_||stateConfig.candidateModule()!=candidateModule_)revert InvalidConfiguration();
        holderState=state1;holderStateHash=_codeHash(state1);IHolderCandidateHelpersV3 cm=IHolderCandidateHelpersV3(candidateModule_);if(cm.kernel()!=address(this)||cm.state()!=state1||cm.domainSeparator()==0)revert InvalidConfiguration();if(C2G2BBuybackExecutorR6R2B(buybackExecutor_).boundKernel()!=address(this))revert InvalidConfiguration();
        for(uint8 i;i<6;++i){address m=modules_[i];if(m==address(0)||m.code.length==0)revert InvalidModule();try IC2G2BBoundModule(m).kernel() returns(address k){if(k!=address(this))revert InvalidModule();}catch{revert InvalidModule();}try IC2G2BBoundModule(m).moduleId() returns(uint8 id){if(id!=i)revert InvalidModule();}catch{revert InvalidModule();}try IC2G2BBoundModule(m).moduleVersion() returns(uint32 v){uint32 expected=i==0?4:(i==1||i==2||i==3?3:2);if(v!=expected)revert InvalidModule();}catch{revert InvalidModule();}for(uint8 j;j<i;++j)if(modules_[j]==m)revert InvalidModule();_modules[i]=m;_moduleHashes[i]=_codeHash(m);emit ModuleBound(T.ModuleId(i),m,_moduleHashes[i]);}
    }
    receive() external payable {if(msg.sender!=strategyExecutor)revert Unauthorized();}
    /// @notice One-time bootstrap of canonical msg.value; forced/unsolicited BNB is excluded.
    function bootstrapTreasury() external payable onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||seeded||msg.value==0)revert InvalidLifecycle();seeded=true;uint256 strategyAllocation=msg.value/TREASURY_ALLOCATION_DENOMINATOR;uint256 treasuryRemainder=msg.value-strategyAllocation;strategyCapital+=strategyAllocation;nonStrategyTreasuryPrincipal+=treasuryRemainder;accountedQuote+=msg.value;_assert(true);_emitAccounting();}
    function activateBuyback(bytes32) external pure {revert QuotePolicyUnavailable();}
    function moduleAddress(T.ModuleId id) external view returns(address){return _modules[uint8(id)];}
    function activate() external onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||hasActivated||!modulesBound||!seeded||block.number>type(uint64).max||block.timestamp>type(uint64).max)revert InvalidLifecycle();_assert(true);hasActivated=true;activationBlock=uint64(block.number);activationTimestamp=uint64(block.timestamp);uint64 boundary=uint64((block.timestamp/HOLDER_WINDOW_SECONDS)*HOLDER_WINDOW_SECONDS);firstEligibleWindowStart=activationTimestamp==boundary?boundary:boundary+HOLDER_WINDOW_SECONDS;activationExclusionSetHash=_snapshotExclusionSet();emit ActivationCheckpointCaptured(activationBlock,activationTimestamp,firstEligibleWindowStart);_setLife(T.Lifecycle.ACTIVE);}
    function _snapshotExclusionSet() private view returns(bytes32){address[15] memory values;values[0]=address(this);values[1]=eligibilityToken;values[2]=strategyExecutor;values[3]=buybackExecutor;values[4]=distributor;values[5]=liability;values[6]=recoveryEvidence;values[7]=holderState;values[8]=candidateModule;for(uint256 i;i<6;++i)values[9+i]=_modules[i];_checkHash(candidateModule,candidateModuleHash);return IHolderCandidateHelpersV3(candidateModule).computeExclusionSetHash(values,exclusionSetVersion);}
    function activationContextHash() public view returns(bytes32){if(!hasActivated)return bytes32(0);_checkHash(candidateModule,candidateModuleHash);return IHolderCandidateHelpersV3(candidateModule).computeActivationContextHash(activationBlock,activationBlockHash,activationTimestamp,firstEligibleWindowStart,block.chainid,address(this));}
    function sealActivationCheckpoint() external returns(bool didSeal){if(!hasActivated||activationSealed||activationSealFailed||block.number<=activationBlock)revert InvalidLifecycle();if(block.number>uint256(activationBlock)+256){_failActivationSeal();return false;}bytes32 h=blockhash(activationBlock);if(h==bytes32(0)){_failActivationSeal();return false;}activationBlockHash=h;activationSealed=true;emit ActivationCheckpointSealed(activationBlock,h,activationContextHash());return true;}
    function failExpiredActivationSeal() external returns(bool failed){if(!hasActivated||activationSealed||activationSealFailed||block.number<=uint256(activationBlock)+256)revert InvalidLifecycle();_failActivationSeal();return true;}
    function _failActivationSeal() private {activationSealFailed=true;uint256 amount=eligibleWindowHR;if(amount!=0){activationSealFailureHR+=amount;eligibleWindowHR=0;emit HolderHRPartitionChanged(4,2,amount);}_assert(false);emit ActivationCheckpointFailed(activationBlock,amount);_emitAccounting();}
    function deriveWindow(uint64 windowStart) external view returns(bytes32 windowId,bytes32 distributionId,uint64 windowEnd,uint256 pool,bool eligible){if(!hasActivated||windowStart%HOLDER_WINDOW_SECONDS!=0||windowStart<firstEligibleWindowStart||windowStart>type(uint64).max-HOLDER_WINDOW_SECONDS)return(0,0,0,0,false);_checkHash(candidateModule,candidateModuleHash);(windowId,distributionId,windowEnd)=IHolderCandidateHelpersV3(candidateModule).computeWindowIdentity(activationBlock,activationBlockHash,activationTimestamp,windowStart,block.chainid,eligibilityToken,address(this),distributor);pool=holderWindowAccrued[windowStart];eligible=activationSealed&&!activationSealFailed&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY&&lifecycle!=T.Lifecycle.TERMINATED&&block.timestamp>=windowEnd&&pool!=0;}
    function _holderDomain() private view returns(bytes32){_checkHash(candidateModule,candidateModuleHash);return IHolderCandidateHelpersV3(candidateModule).domainSeparator();}
    function pause() external onlyGuardian {if(lifecycle!=T.Lifecycle.ACTIVE)revert InvalidLifecycle();_setLife(T.Lifecycle.PAUSED);}
    function resume() external onlyGuardian {if(lifecycle!=T.Lifecycle.PAUSED||!modulesBound||!hasActivated)revert InvalidLifecycle();_assert(true);_setLife(T.Lifecycle.ACTIVE);}
    function initiateShutdown(uint64 delay) external onlyGuardian {if((lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED)||delay<MIN_SHUTDOWN||block.timestamp>type(uint64).max-delay)revert InvalidLifecycle();shutdownStartedAt=uint64(block.timestamp);shutdownAt=shutdownStartedAt+delay;uint64 start=uint64((block.timestamp/HOLDER_WINDOW_SECONDS)*HOLDER_WINDOW_SECONDS);uint256 demoted;if(start>=firstEligibleWindowStart){demoted=holderWindowAccrued[start];if(demoted!=0){holderWindowAccrued[start]=0;eligibleWindowHR-=demoted;shutdownTailHR+=demoted;emit HolderHRPartitionChanged(4,3,demoted);}}_assert(false);emit ShutdownStarted(shutdownStartedAt,shutdownAt,start,demoted);_setLife(T.Lifecycle.SHUTDOWN_PENDING);}
    function extendShutdown(uint64 deadline) external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||deadline<=shutdownAt)revert InvalidLifecycle();shutdownAt=deadline;}
    function terminate() external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||block.timestamp<shutdownAt||activePrincipal!=0||!modulesBound)revert ShutdownNotReady();_assert(true);for(uint8 i;i<5;++i){if(_codeHash(_modules[i])!=_moduleHashes[i])revert ModuleCodeChanged();try IC2G2BTermination(_modules[i]).terminationReady() returns(bool ready){if(!ready)revert ShutdownNotReady();}catch{revert ShutdownNotReady();}}_setLife(T.Lifecycle.TERMINATED);}

    function allocateStrategyPrincipal(uint256 runId,address strategy,uint256 amount,bytes32 allocationId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE||strategyAllocationHalted||runId==0||strategy==address(0)||_runUsed[runId]||allocationId==0||_allocationUsed[allocationId]||amount==0||amount>strategyCapital-activePrincipal||amount>accountedQuote||_activeRunCount>=MAX_RUNS||amount*BPS>strategyCapital*MAX_POSITION_BPS||(activePrincipal+amount)*BPS>strategyCapital*MAX_TOTAL_BPS)revert InvalidAmount();
        _assert(true);_checkHash(strategyExecutor,strategyExecutorHash);if(!IC2G2BStrategyExecutorR4(strategyExecutor).isApprovedStrategy(strategy))revert InvalidEvidence();
        // This value is derived here from the frozen 3% of committed principal policy;
        // no module or executor-supplied value can enlarge the pre-exposure budget.
        uint256 maxLoss=amount*MAX_DESIGNED_LOSS_BPS/BPS;
        _runUsed[runId]=true;_allocationUsed[allocationId]=true;_runPrincipal[runId]=amount;runMaxDesignedLoss[runId]=maxLoss;_activeRunCount++;activePrincipal+=amount;accountedQuote-=amount;
        bytes32 positionId=IC2G2BStrategyExecutorR4(strategyExecutor).openRun{value:amount}(runId,strategy,amount,maxLoss,allocationId);if(positionId==bytes32(0))revert InvalidEvidence();_assert(false);emit StrategyAllocated(runId,strategy,amount,allocationId);emit StrategyRiskBudgetCommitted(runId,amount,maxLoss);_emitAccounting();
    }
    function requestStrategyExit(uint256 runId,bytes32 exitId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant returns(T.RunStatus){if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||_runPrincipal[runId]==0||exitId==bytes32(0))revert InvalidRun();_checkHash(strategyExecutor,strategyExecutorHash);return IC2G2BStrategyExecutorR4(strategyExecutor).requestExit(runId,exitId);}
    function collectStrategyPrincipal(uint256 runId,bytes32 attemptId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant returns(uint256 credited){if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY)revert InvalidLifecycle();uint256 principal=_runPrincipal[runId];if(principal==0||attemptId==bytes32(0))revert InvalidRun();uint256 remaining=principal-principalCredited[runId];if(remaining==0)revert InvalidRun();_checkHash(strategyExecutor,strategyExecutorHash);uint256 beforeBalance=address(this).balance;uint256 executorForwarded=IC2G2BStrategyExecutorR4(strategyExecutor).collectPartial(runId,attemptId,remaining);uint256 physical=address(this).balance-beforeBalance;if(physical>remaining||executorForwarded!=physical)revert InvalidEvidence();credited=physical;if(credited!=0){principalCredited[runId]+=credited;runTotalPhysicalReturn[runId]+=credited;activePrincipal-=credited;accountedQuote+=credited;_assert(true);emit StrategyPartialRecovery(runId,attemptId,credited,principalCredited[runId],principal-principalCredited[runId]);_emitAccounting();}}
    function settleStrategyPrincipal(uint256 runId,bytes32 closeId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY)revert InvalidLifecycle();uint256 principal=_runPrincipal[runId];if(principal==0||closeId==0||_closeUsed[closeId])revert InvalidRun();_checkHash(strategyExecutor,strategyExecutorHash);uint256 beforeBalance=address(this).balance;(uint256 reportedPrincipal,uint256 reportedReturn,bytes32 reportedCloseId)=IC2G2BStrategyExecutorR4(strategyExecutor).closeToKernel(runId,closeId);uint256 returned=address(this).balance-beforeBalance;uint256 remaining=principal-principalCredited[runId];if(reportedPrincipal!=principal||reportedCloseId!=closeId||reportedReturn!=returned)revert InvalidEvidence();uint256 totalReturned=runTotalPhysicalReturn[runId]+returned;runTotalPhysicalReturn[runId]=totalReturned;_closeUsed[closeId]=true;_runPrincipal[runId]=0;activePrincipal-=remaining;accountedQuote+=returned;uint256 profit;uint256 loss;if(totalReturned>=principal){profit=totalReturned-principal;if(profit!=0){uint256 br=profit*1500/BPS;uint256 hr=profit*1000/BPS;uint256 pr=profit*1000/BPS;strategyCapital+=profit-br-hr-pr;buybackReserve+=br;holderRewardReserve+=hr;protocolReserve+=pr;cumulativeRealizedProfit+=profit;if(hr!=0)_creditHolderHR(hr,uint64(block.timestamp));}}else{loss=principal-totalReturned;runActualLoss[runId]=loss;if(loss>strategyCapital-activePrincipal)revert AccountingInvariant();strategyCapital-=loss;cumulativeRealizedLoss+=loss;if(loss>runMaxDesignedLoss[runId]){runLossBoundBreached[runId]=true;strategyAllocationHalted=true;emit LOSS_BOUND_BREACH(runId,principal,totalReturned,runMaxDesignedLoss[runId],loss);}}_activeRunCount--;_assert(true);emit StrategySettled(runId,principal,totalReturned,profit,loss,closeId);_emitAccounting();
    }
    function _creditHolderHR(uint256 amount,uint64 creditedAt) private {if(lifecycle==T.Lifecycle.EMERGENCY_RECOVERY){emergencyLockedHR+=amount;emit HolderHRPartitionChanged(0,5,amount);return;}if(lifecycle==T.Lifecycle.SHUTDOWN_PENDING){shutdownTailHR+=amount;emit HolderHRPartitionChanged(0,3,amount);return;}if(activationSealFailed){activationSealFailureHR+=amount;emit HolderHRPartitionChanged(0,2,amount);return;}if(creditedAt<firstEligibleWindowStart){partialActivationHR+=amount;emit HolderHRPartitionChanged(0,1,amount);return;}uint64 start=uint64((uint256(creditedAt)/HOLDER_WINDOW_SECONDS)*HOLDER_WINDOW_SECONDS);_checkHash(candidateModule,candidateModuleHash);(bytes32 windowId,,)=IHolderCandidateHelpersV3(candidateModule).computeWindowIdentity(activationBlock,activationBlockHash,activationTimestamp,start,block.chainid,eligibilityToken,address(this),distributor);holderWindowAccrued[start]+=amount;eligibleWindowHR+=amount;emit HolderHRPartitionChanged(0,4,amount);emit HolderWindowAccrued(start,windowId,amount,holderWindowAccrued[start]);}
    function runPrincipal(uint256 id) external view returns(uint256){return _runPrincipal[id];} function activeRunCount() external view returns(uint256){return _activeRunCount;}

    function payHolder(bytes32 leafId,bytes32 useId,bytes32 digest,address recipient,uint256 amount,bool retry,bytes32 attemptId) external onlyModule(T.ModuleId.HOLDER) nonReentrant returns(bool){
        if(leafId==0||useId==0||digest==0||recipient==address(0)||amount==0||amount>holderRewardReserve||amount>accountedQuote)revert HolderUnavailable();
        if(_holderPaid[useId])revert Replay();_checkHash(distributor,distributorHash);_checkHash(liability,liabilityHash);_checkHash(holderState,holderStateHash);
        (uint8 s1,uint8 s2)=_verifiedPaymentStatuses(leafId,digest,recipient,amount);
        bool ordinary=lifecycle==T.Lifecycle.ACTIVE&&s1==1&&s2==1;
        bool terminal=(lifecycle==T.Lifecycle.SHUTDOWN_PENDING||lifecycle==T.Lifecycle.TERMINATED)&&retry&&s1==2&&s2==2;
        if(!ordinary&&!terminal)revert HolderUnavailable();
        if(terminal){(bool isTerminal,,uint64 expiresAt,bytes32 failedUseId)=IC2G2BHolderStateSource(holderState).terminalStatus(leafId);if(!isTerminal||failedUseId!=useId||block.timestamp>=expiresAt||_failedPaymentDigest[useId]!=digest||_failedRecipient[useId]!=recipient||_failedAmount[useId]!=amount||_failedRetryIdentity[useId]!=leafId)revert InvalidEvidence();}
        uint64 paymentWindow=_validatedPaymentWindow(leafId,recipient,amount);
        if(retry){if(attemptId==0||_holderAttempts[useId][attemptId]||_failedPaymentDigest[useId]!=digest||_failedRecipient[useId]!=recipient||_failedAmount[useId]!=amount||_failedRetryIdentity[useId]!=leafId)revert Replay();_holderAttempts[useId][attemptId]=true;}
        _assert(true);(bool ok,)=payable(recipient).call{value:amount,gas:50_000}("");
        if(!ok){if(!retry){bytes32 failId=keccak256(abi.encode(useId,block.number,msg.sender));_holderAttempts[useId][failId]=true;_failedPaymentDigest[useId]=digest;_failedRecipient[useId]=recipient;_failedAmount[useId]=amount;_failedRetryIdentity[useId]=leafId;emit HolderPaymentFailed(useId,failId,recipient,amount);}return false;}
        _checkHash(distributor,distributorHash);_checkHash(liability,liabilityHash);_checkHash(holderState,holderStateHash);IC2G2BHolderDistributor(distributor).consumePayment(leafId,digest);IC2G2BHolderLiability(liability).consumePayment(leafId,digest);_holderPaid[useId]=true;holderRewardReserve-=amount;accountedQuote-=amount;holderWindowAccrued[paymentWindow]-=amount;eligibleWindowHR-=amount;_assert(true);emit HolderPaid(useId,recipient,amount);_emitAccounting();return true;
    }
    function _verifiedPaymentStatuses(bytes32 leafId,bytes32 digest,address recipient,uint256 amount) private view returns(uint8 s1,uint8 s2){(bytes32 d,address r,address a,uint256 n,uint8 status,bool payableNow)=IC2G2BHolderStateSource(holderState).canonicalPayment(leafId);if(!payableNow||d!=digest||r!=recipient||a!=address(0)||n!=amount)revert InvalidEvidence();return(status,status);}
    function _validatedPaymentWindow(bytes32 leafId,address,uint256 amount) private view returns(uint64 start){start=IC2G2BHolderStateSource(holderState).paymentWindowStart(leafId);if(start<firstEligibleWindowStart||start>type(uint64).max-HOLDER_WINDOW_SECONDS||amount>holderWindowAccrued[start])revert InvalidEvidence();}
    function holderPaid(bytes32 id) external view returns(bool){return _holderPaid[id];} function failedHolder(bytes32 id) external view returns(bytes32,address,uint256,bytes32){return(_failedPaymentDigest[id],_failedRecipient[id],_failedAmount[id],_failedRetryIdentity[id]);}

    function releaseBuyback(bytes32 id,uint256 amount,bytes32 quoteId) external onlyModule(T.ModuleId.BUYBACK) nonReentrant {if(lifecycle!=T.Lifecycle.ACTIVE||!buybackActivated||id==0||_buybackUsed[id]||buybackReserve<BUYBACK_MIN||amount==0||amount>BUYBACK_CAP||amount>buybackReserve*2000/BPS||amount>accountedQuote||quoteId==0)revert InvalidAmount();_assert(true);_checkHash(buybackExecutor,buybackExecutorHash);if(buybackExecutor.balance!=0)revert InvalidEvidence();buybackReserve-=amount;accountedQuote-=amount;_buybackUsed[id]=true;C2G2BBuybackExecutorR6R2B(buybackExecutor).executeExactInput{value:amount}(id,quoteId);if(buybackExecutor.balance!=0)revert InvalidEvidence();_assert(true);emit BuybackReleased(id,amount);_emitAccounting();}
    /// @notice Recovery evidence is qualified by the immutable Recovery Module; Kernel rechecks category, exact source bucket, replay, solvency and destination.
    function executeRecovery(uint8 category,bytes32 id) external onlyModule(T.ModuleId.RECOVERY) nonReentrant returns(uint256 amount) {
        if(lifecycle!=T.Lifecycle.TERMINATED||id==0||category>6)revert RecoveryUnavailable();
        uint8 keyKind=category<=3?category:category-3;
        bytes32 key=keccak256(abi.encode(keyKind,id));
        if(category<=3){if(_recoveryUsed[key])revert RecoveryUnavailable();}
        else if(_nonpayableRecoveryUsed[key])revert RecoveryUnavailable();
        _checkHash(recoveryEvidence,recoveryEvidenceHash);(bool qualified,uint256 exact)=IRecoveryV3Authorization(_modules[uint8(T.ModuleId.RECOVERY)]).authorizeRecovery(category,id);if(!qualified||exact==0)revert InvalidEvidence();amount=exact;_assert(true);
        uint64 start; uint256 bucket;
        if(category==0){bucket=protocolReserve;if(amount>bucket||amount>accountedQuote)revert InvalidEvidence();recoveryEvidenceCall(id,0);protocolReserve-=amount;}
        else if(category==3){bucket=nonStrategyTreasuryPrincipal;if(amount>bucket||amount>accountedQuote)revert InvalidEvidence();recoveryEvidenceCall(id,3);nonStrategyTreasuryPrincipal-=amount;}
        else if(category==1||category==2){bucket=holderRewardReserve;start=IC2G2BHolderStateSource(holderState).recoveryWindowStart(id,category);if(amount>bucket||amount>accountedQuote||start==0||amount>holderWindowAccrued[start]||amount>eligibleWindowHR)revert InvalidEvidence();recoveryEvidenceCall(id,category);holderRewardReserve-=amount;holderWindowAccrued[start]-=amount;eligibleWindowHR-=amount;}
        else {uint8 partition=category-3;bucket=partition==1?partialActivationHR:partition==2?activationSealFailureHR:shutdownTailHR;if(amount!=bucket||amount>holderRewardReserve||amount>accountedQuote)revert InvalidEvidence();INonpayableRecoveryEvidenceV3(recoveryEvidence).consumeNonpayableHolder(id,partition);if(partition==1)partialActivationHR-=amount;else if(partition==2)activationSealFailureHR-=amount;else shutdownTailHR-=amount;holderRewardReserve-=amount;}
        if(category<=3)_recoveryUsed[key]=true;else _nonpayableRecoveryUsed[key]=true;
        accountedQuote-=amount;_send(RECOVERY_TREASURY,amount);_assert(false);emit RecoveryReleased(id,category,amount);_emitAccounting();
    }
    function recoveryEvidenceCall(bytes32 id,uint8 kind) private {
        if(kind==0)IC2G2BRecoveryEvidence(recoveryEvidence).consumeProtocolReserve(id);
        else if(kind==3)IC2G2BRecoveryEvidence(recoveryEvidence).consumeTreasuryPrincipal(id);
        else if(kind==1)IC2G2BRecoveryEvidence(recoveryEvidence).consumeNoRecipient(id);
        else IC2G2BRecoveryEvidence(recoveryEvidence).consumeExpiredHolder(id);
    }    function emergencyEnter() external nonReentrant {if(msg.sender!=emergencyAuthority||lifecycle==T.Lifecycle.TERMINATED||lifecycle==T.Lifecycle.EMERGENCY_RECOVERY)revert Unauthorized();_assert(true);uint256 n=accountedQuote-holderRewardReserve;uint256 b=address(this).balance;uint256 hb=b>n?b-n:0;if(hb>holderRewardReserve)hb=holderRewardReserve;preEmergencyHolderDeficit=holderRewardReserve-hb;unchecked{++emergencyNonce;}emergencySnapshotId=keccak256(abi.encode(block.chainid,address(this),emergencyNonce,uint8(lifecycle),b,accountedQuote,nonStrategyTreasuryPrincipal,activePrincipal,holderRewardReserve,preEmergencyHolderDeficit,block.timestamp,block.number));emergencyStatus=T.ProcessingStatus.IN_PROGRESS;_setLife(T.Lifecycle.EMERGENCY_RECOVERY);emit EmergencyEntered(emergencySnapshotId,emergencyNonce,b,accountedQuote,nonStrategyTreasuryPrincipal,holderRewardReserve,activePrincipal,preEmergencyHolderDeficit);}
    function emergencyTransferBNB(bytes32 scopeId,bytes32 attemptId,uint32 attemptNumber,uint256 amount,bytes32 evidence) external onlyModule(T.ModuleId.EMERGENCY) nonReentrant {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||scopeId==0||attemptId==0||attemptNumber==0||amount==0||evidence==0||amount>address(this).balance)revert InvalidAmount();address reg=_modules[5];if(reg==address(0)||_codeHash(reg)!=_moduleHashes[5])revert ModuleCodeChanged();IC2G2BRegistry(reg).beginAttempt(emergencySnapshotId,scopeId,attemptId,attemptNumber);uint256 before_=address(this).balance;_send(emergencyWallet,amount);if(before_-address(this).balance!=amount)revert InvalidEvidence();emergencyBNBOutflow+=amount;IC2G2BRegistry(reg).finishAttempt(emergencySnapshotId,scopeId,attemptId,attemptNumber,T.AttemptStatus.SUCCEEDED,evidence);emit EmergencyBNBRecovered(scopeId,attemptId,amount,evidence);}
    function setEmergencyStatus(T.ProcessingStatus s) external onlyModule(T.ModuleId.EMERGENCY){if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||s==T.ProcessingStatus.NOT_STARTED)revert InvalidLifecycle();emergencyStatus=s;}
    function _assert(bool physical) private view {if(strategyCapital+nonStrategyTreasuryPrincipal+buybackReserve+protocolReserve+holderRewardReserve!=accountedQuote+activePrincipal||activePrincipal>strategyCapital||accountedQuote<holderRewardReserve||holderRewardReserve!=partialActivationHR+activationSealFailureHR+shutdownTailHR+emergencyLockedHR+eligibleWindowHR||(physical&&address(this).balance<accountedQuote))revert AccountingInvariant();}
    function _send(address to,uint256 amount) private {uint256 b=address(this).balance;(bool ok,)=payable(to).call{value:amount,gas:50_000}("");if(!ok||b<address(this).balance||b-address(this).balance!=amount)revert TransferFailed();}
    function _checkHash(address a,bytes32 h) private view {if(_codeHash(a)!=h)revert ExternalCodeChanged();}
    function _codeHash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
    function _setLife(T.Lifecycle l) private {T.Lifecycle old=lifecycle;lifecycle=l;emit LifecycleChanged(old,l);}
    function _emitAccounting() private {emit AccountingChanged(strategyCapital,nonStrategyTreasuryPrincipal,buybackReserve,protocolReserve,holderRewardReserve,accountedQuote,activePrincipal);}
}

