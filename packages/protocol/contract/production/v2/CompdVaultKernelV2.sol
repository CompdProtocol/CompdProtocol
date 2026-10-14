// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdVaultKernelV2Types as T, ICompdKernelBoundModuleV2, ICompdKernelStrategyExecutorV2, ICompdKernelHolderDistributorV2, ICompdKernelHolderLiabilityV2, ICompdKernelBuybackQuoteV2, ICompdKernelBuybackExecutorV2, ICompdKernelRecoveryEvidenceV2, ICompdKernelEmergencyRegistryV2} from "./CompdVaultKernelV2Types.sol";

/// @notice BNB-native V2 custody/accounting kernel with typed, immutable module capabilities.
/// @dev Separate from the legacy decomposed V2 vault. No proxy, delegatecall or generic call surface.
contract CompdVaultKernelV2 {
    uint256 private constant BPS = 10_000;
    uint256 private constant BUYBACK_MINIMUM = 0.25 ether;
    uint256 private constant BUYBACK_MAXIMUM = 0.50 ether;
    uint64 private constant BUYBACK_COOLDOWN = 6 hours;
    uint64 private constant BUYBACK_WINDOW = 24 hours;
    uint64 private constant SHUTDOWN_MINIMUM = 72 hours;
    address public constant CONFIGURATION_ADMIN = 0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address public constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address public constant RECOVERY_TREASURY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address public constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address public constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;

    error Unauthorized(); error InvalidLifecycle(); error InvalidConfiguration(); error InvalidModule();
    error ModuleCodeChanged(); error AccountingInvariant(); error InvalidAmount(); error Replay();
    error InvalidRun(); error InvalidEvidence(); error HolderEvidenceMismatch(); error HolderUnavailable();
    error IntegrationUnavailable(); error QuotePolicyUnavailable(); error RecoveryUnavailable();
    error ShutdownNotReady(); error EmergencyInvariantFailure(); error UnsupportedEmergencyAsset();

    T.Lifecycle public lifecycle = T.Lifecycle.PAUSED;
    address public immutable emergencyAuthority;
    address public immutable emergencyWallet;
    address public immutable strategyExecutor;
    bytes32 public immutable strategyExecutorCodeHash;
    address public immutable buybackExecutor;
    bytes32 public immutable buybackExecutorCodeHash;
    address public immutable holderDistributor;
    address public immutable holderLiability;
    address public immutable buybackQuoteSource;
    address public immutable recoveryEvidenceSource;

    address[6] public modules;
    bytes32[6] public moduleCodeHashes;
    bool public modulesBound;
    bool public seeded;
    uint64 public shutdownStartedAt;
    uint64 public shutdownAt;
    uint64 public lastBuybackAt;
    uint64 public buybackPeriodStart;
    uint256 public buybackPeriodStartReserve;
    uint256 public buybackPeriodSpend;
    uint64 public emergencyNonce;
    bytes32 public emergencySnapshotId;
    T.EmergencyProcessingStatus public emergencyStatus;
    uint256 public preEmergencyHolderDeficit;

    uint256 public strategyCapital;
    uint256 public buybackReserve;
    uint256 public protocolReserve;
    uint256 public holderRewardReserve;
    uint256 public accountedQuote;
    uint256 public activePrincipal;
    uint256 public cumulativeRealizedProfit;
    uint256 public cumulativeRealizedLoss;

    mapping(uint256 => T.Run) public runs;
    mapping(uint256 => bool) public runIdUsed;
    mapping(bytes32 => bool) public allocationIdUsed;
    mapping(bytes32 => bool) public closeIdUsed;
    mapping(bytes32 => bool) public paidLeaf;
    mapping(bytes32 => mapping(bytes32 => bool)) public holderAttemptUsed;
    mapping(bytes32 => T.HolderLeaf) private _failedHolderLeaf;
    mapping(bytes32 => bool) private _hasFailedHolderLeaf;
    mapping(bytes32 => bool) public recoverySourceUsed;
    mapping(bytes32 => bool) public buybackOperationUsed;
    uint256[] private _activeRunIds;

    event LifecycleChanged(T.Lifecycle indexed previous,T.Lifecycle indexed current);
    event AccountingChanged(uint256 strategyCapital,uint256 buybackReserve,uint256 protocolReserve,uint256 holderRewardReserve,uint256 accountedQuote,uint256 activePrincipal);
    event ModuleBound(T.ModuleId indexed id,address indexed module,bytes32 codeHash);
    event StrategyAllocated(uint256 indexed runId,uint256 principal,bytes32 allocationEvidenceId);
    event StrategyExitRequested(uint256 indexed runId,bytes32 indexed exitRequestId,T.RunStatus status);
    event StrategySettled(uint256 indexed runId,uint256 principal,uint256 returnedBNB,uint256 profit,uint256 loss,bytes32 closeEvidenceId);
    event HolderPaymentFailed(bytes32 indexed leafIdentity,bytes32 indexed attemptId,uint8 failureCode);
    event HolderPaid(bytes32 indexed leafIdentity,address indexed recipient,uint256 amount);
    event BuybackExecuted(bytes32 indexed operationId,uint256 amount,bytes32 burnEvidenceId);
    event EmergencyEntered(bytes32 indexed snapshotId,uint64 nonce,uint256 physicalBNB,uint256 accountedQuote,uint256 holderReserve,uint256 preDeficit);

    modifier onlyAdmin(){if(msg.sender!=CONFIGURATION_ADMIN)revert Unauthorized();_;}
    modifier onlyGuardian(){if(msg.sender!=GUARDIAN)revert Unauthorized();_;}
    modifier onlyModule(T.ModuleId id){address m=modules[uint8(id)];if(!modulesBound||msg.sender!=m)revert Unauthorized();if(_codeHash(m)!=moduleCodeHashes[uint8(id)])revert ModuleCodeChanged();_;}
    modifier nonReentrant(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}
    bool private _entered;

    constructor(address emergencyAuthority_,address emergencyWallet_,address strategyExecutor_,address buybackExecutor_,address holderDistributor_,address holderLiability_,address quoteSource_,address recoveryEvidenceSource_){
        if(emergencyAuthority_==address(0)||emergencyWallet_==address(0)||strategyExecutor_.code.length==0||buybackExecutor_.code.length==0||holderDistributor_.code.length==0||holderLiability_.code.length==0)revert InvalidConfiguration();
        emergencyAuthority=emergencyAuthority_;emergencyWallet=emergencyWallet_;strategyExecutor=strategyExecutor_;strategyExecutorCodeHash=_codeHash(strategyExecutor_);buybackExecutor=buybackExecutor_;buybackExecutorCodeHash=_codeHash(buybackExecutor_);holderDistributor=holderDistributor_;holderLiability=holderLiability_;buybackQuoteSource=quoteSource_;recoveryEvidenceSource=recoveryEvidenceSource_;
    }

    receive() external payable {if(msg.sender!=strategyExecutor)revert Unauthorized();}

    function seedStrategyCapital() external payable onlyAdmin {
        if(lifecycle!=T.Lifecycle.PAUSED||seeded||msg.value==0)revert InvalidLifecycle();
        seeded=true;strategyCapital+=msg.value;accountedQuote+=msg.value;_assertAccounting();_emitAccounting();
    }

    function bindModules(address settlement,address holder,address buyback,address recovery,address emergency,address registry) external onlyAdmin {
        if(lifecycle!=T.Lifecycle.PAUSED||modulesBound)revert InvalidLifecycle();
        address[6] memory list=[settlement,holder,buyback,recovery,emergency,registry];
        for(uint8 i;i<6;++i){address m=list[i];if(m==address(0)||m.code.length==0)revert InvalidModule();try ICompdKernelBoundModuleV2(m).kernel() returns(address k){if(k!=address(this))revert InvalidModule();}catch{revert InvalidModule();}try ICompdKernelBoundModuleV2(m).moduleId() returns(T.ModuleId id){if(uint8(id)!=i)revert InvalidModule();}catch{revert InvalidModule();}try ICompdKernelBoundModuleV2(m).moduleVersion() returns(uint32 v){if(v!=2)revert InvalidModule();}catch{revert InvalidModule();}for(uint8 j;j<i;++j)if(list[j]==m)revert InvalidModule();modules[i]=m;moduleCodeHashes[i]=_codeHash(m);emit ModuleBound(T.ModuleId(i),m,moduleCodeHashes[i]);}
        modulesBound=true;
    }

    function activate() external onlyAdmin {if(lifecycle!=T.Lifecycle.PAUSED||!modulesBound||!seeded)revert InvalidLifecycle();_assertAccounting();_setLifecycle(T.Lifecycle.ACTIVE);}
    function pause() external onlyGuardian {if(lifecycle!=T.Lifecycle.ACTIVE)revert InvalidLifecycle();_setLifecycle(T.Lifecycle.PAUSED);}
    function resume() external onlyGuardian {if(lifecycle!=T.Lifecycle.PAUSED||!modulesBound)revert InvalidLifecycle();_assertAccounting();_setLifecycle(T.Lifecycle.ACTIVE);}
    function initiateShutdown(uint64 delay) external onlyGuardian {if((lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED)||delay<SHUTDOWN_MINIMUM)revert InvalidLifecycle();shutdownStartedAt=uint64(block.timestamp);shutdownAt=uint64(block.timestamp)+delay;_setLifecycle(T.Lifecycle.SHUTDOWN_PENDING);}
    function extendShutdown(uint64 newDeadline) external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||newDeadline<=shutdownAt)revert InvalidLifecycle();shutdownAt=newDeadline;}
    function terminate() external onlyGuardian {if(lifecycle!=T.Lifecycle.SHUTDOWN_PENDING||block.timestamp<shutdownAt||activePrincipal!=0||holderRewardReserve!=0)revert ShutdownNotReady();_assertAccounting();_setLifecycle(T.Lifecycle.TERMINATED);}

    function allocateStrategy(uint256 runId,uint256 amount,bytes32 allocationEvidenceId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE||runId==0||runIdUsed[runId]||amount==0||amount>strategyCapital-activePrincipal||allocationEvidenceId==bytes32(0)||allocationIdUsed[allocationEvidenceId]||accountedQuote<amount)revert InvalidAmount();
        _assertAccounting();runIdUsed[runId]=true;allocationIdUsed[allocationEvidenceId]=true;activePrincipal+=amount;accountedQuote-=amount;runs[runId]=T.Run(address(0),amount,uint64(block.timestamp),allocationEvidenceId,bytes32(0),0,T.RunStatus.OPEN);_activeRunIds.push(runId);
        bytes32 canonical=ICompdKernelStrategyExecutorV2(strategyExecutor).openRun{value:amount}(runId,amount,allocationEvidenceId);if(canonical!=allocationEvidenceId)revert InvalidEvidence();_assertAccounting();emit StrategyAllocated(runId,amount,allocationEvidenceId);_emitAccounting();
    }

    function requestStrategyExit(uint256 runId,bytes32 exitRequestId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        T.Run storage r=runs[runId];if((lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING)||r.status!=T.RunStatus.OPEN||exitRequestId==bytes32(0))revert InvalidRun();T.RunStatus status=ICompdKernelStrategyExecutorV2(strategyExecutor).requestExit(runId,exitRequestId);if(status!=T.RunStatus.EXIT_REQUESTED&&status!=T.RunStatus.RETURN_PENDING&&status!=T.RunStatus.BLOCKED)revert InvalidEvidence();r.status=status;emit StrategyExitRequested(runId,exitRequestId,status);
    }

    function settleStrategy(uint256 runId,bytes32 closeEvidenceId) external onlyModule(T.ModuleId.SETTLEMENT) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE&&lifecycle!=T.Lifecycle.PAUSED&&lifecycle!=T.Lifecycle.SHUTDOWN_PENDING&&lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY)revert InvalidLifecycle();T.Run storage r=runs[runId];if((r.status!=T.RunStatus.OPEN&&r.status!=T.RunStatus.EXIT_REQUESTED&&r.status!=T.RunStatus.RETURN_PENDING)||closeEvidenceId==bytes32(0)||closeIdUsed[closeEvidenceId])revert InvalidRun();uint256 beforeBalance=address(this).balance;(uint256 principal,uint256 returnedBNB,bytes32 canonical)=ICompdKernelStrategyExecutorV2(strategyExecutor).closeToKernel(runId,closeEvidenceId);uint256 afterBalance=address(this).balance;if(principal!=r.principal||canonical!=closeEvidenceId||afterBalance<beforeBalance||afterBalance-beforeBalance!=returnedBNB)revert InvalidEvidence();if(principal>activePrincipal)revert AccountingInvariant();closeIdUsed[closeEvidenceId]=true;activePrincipal-=principal;accountedQuote+=returnedBNB;uint256 profit;uint256 loss;if(returnedBNB>=principal){profit=returnedBNB-principal;if(profit!=0){uint256 compound=profit*6500/BPS;uint256 buyback=profit*1500/BPS;uint256 holder=profit*1000/BPS;uint256 protocol=profit*1000/BPS;strategyCapital+=profit-(buyback+holder+protocol);buybackReserve+=buyback;holderRewardReserve+=holder;protocolReserve+=protocol;cumulativeRealizedProfit+=profit;}}else{loss=principal-returnedBNB;if(loss>strategyCapital-activePrincipal)revert AccountingInvariant();strategyCapital-=loss;cumulativeRealizedLoss+=loss;}r.closeEvidenceId=closeEvidenceId;r.returnedBNB=returnedBNB;r.status=T.RunStatus.SETTLED;_removeActiveRun(runId);_assertAccounting();emit StrategySettled(runId,principal,returnedBNB,profit,loss,closeEvidenceId);_emitAccounting();
    }

    function payHolder(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external onlyModule(T.ModuleId.HOLDER) nonReentrant returns(bool paid){T.HolderLeaf memory leaf=ICompdKernelHolderDistributorV2(holderDistributor).verifyFinalizedLeaf(distributionId,version,index,leafIdentity);return _payHolder(leaf,bytes32(0));}
    function retryHolderPayment(bytes32 leafIdentity,bytes32 retryAttemptId) external onlyModule(T.ModuleId.HOLDER) nonReentrant returns(bool paid){if(!_hasFailedHolderLeaf[leafIdentity]||retryAttemptId==bytes32(0)||holderAttemptUsed[leafIdentity][retryAttemptId])revert HolderUnavailable();holderAttemptUsed[leafIdentity][retryAttemptId]=true;T.HolderLeaf memory previous=_failedHolderLeaf[leafIdentity];T.HolderLeaf memory leaf=ICompdKernelHolderDistributorV2(holderDistributor).verifyFinalizedLeaf(previous.distributionId,previous.version,previous.index,leafIdentity);return _payHolder(leaf,retryAttemptId);}
    function _payHolder(T.HolderLeaf memory leaf,bytes32 attemptId) private returns(bool paid){if(leaf.leafIdentity==bytes32(0)||leaf.amount==0||leaf.asset!=address(0)||leaf.distributionStatus!=1||leaf.liabilityStatus!=2||!leaf.proofValid||(leaf.expiresAt!=0&&block.timestamp>leaf.expiresAt)||paidLeaf[leaf.leafIdentity])revert HolderUnavailable();T.HolderLeaf memory liability=ICompdKernelHolderLiabilityV2(holderLiability).liability(leaf.distributionId,leaf.version,leaf.index,leaf.leafIdentity);if(!_sameHolderLeaf(leaf,liability)||leaf.amount>holderRewardReserve||accountedQuote<leaf.amount||address(this).balance<accountedQuote)revert HolderEvidenceMismatch();_assertAccounting();(bool ok,)=payable(leaf.recipient).call{value:leaf.amount,gas:50_000}("");if(!ok){bytes32 aid=attemptId==bytes32(0)?keccak256(abi.encode(leaf.leafIdentity,block.number,msg.sender)):attemptId;if(holderAttemptUsed[leaf.leafIdentity][aid])revert Replay();holderAttemptUsed[leaf.leafIdentity][aid]=true;_failedHolderLeaf[leaf.leafIdentity]=leaf;_hasFailedHolderLeaf[leaf.leafIdentity]=true;emit HolderPaymentFailed(leaf.leafIdentity,aid,1);return false;}ICompdKernelHolderDistributorV2(holderDistributor).markPaid(leaf.distributionId,leaf.version,leaf.index,leaf.leafIdentity);ICompdKernelHolderLiabilityV2(holderLiability).markPaid(leaf.distributionId,leaf.version,leaf.index,leaf.leafIdentity);paidLeaf[leaf.leafIdentity]=true;holderRewardReserve-=leaf.amount;accountedQuote-=leaf.amount;_assertAccounting();emit HolderPaid(leaf.leafIdentity,leaf.recipient,leaf.amount);_emitAccounting();return true;}
    function _sameHolderLeaf(T.HolderLeaf memory a,T.HolderLeaf memory b) private pure returns(bool){return a.distributionId==b.distributionId&&a.version==b.version&&a.index==b.index&&a.root==b.root&&a.parentCommitment==b.parentCommitment&&a.leafIdentity==b.leafIdentity&&a.recipient==b.recipient&&a.asset==b.asset&&a.amount==b.amount&&a.distributionStatus==b.distributionStatus&&a.liabilityStatus==b.liabilityStatus&&a.finalizedAt==b.finalizedAt&&a.expiresAt==b.expiresAt;}

    function releaseBuyback(bytes32 operationId,uint256 amount,bytes32 quoteEvidenceId) external onlyModule(T.ModuleId.BUYBACK) nonReentrant {
        if(lifecycle!=T.Lifecycle.ACTIVE)revert InvalidLifecycle();if(buybackQuoteSource==address(0))revert QuotePolicyUnavailable();(bool canonical,bool fresh,uint256 quotedOut,,bytes32 routeId)=ICompdKernelBuybackQuoteV2(buybackQuoteSource).quoteEvidence(quoteEvidenceId);if(!canonical||!fresh||quotedOut==0||routeId==bytes32(0))revert QuotePolicyUnavailable();if(operationId==bytes32(0)||buybackOperationUsed[operationId]||amount==0||buybackReserve<BUYBACK_MINIMUM||amount>BUYBACK_MAXIMUM||amount>buybackReserve*2000/BPS||amount>accountedQuote||(lastBuybackAt!=0&&block.timestamp<uint256(lastBuybackAt)+BUYBACK_COOLDOWN))revert InvalidAmount();if(buybackPeriodStart==0||block.timestamp>=uint256(buybackPeriodStart)+BUYBACK_WINDOW){buybackPeriodStart=uint64(block.timestamp);buybackPeriodStartReserve=buybackReserve;buybackPeriodSpend=0;}if(amount>buybackPeriodStartReserve*2000/BPS||buybackPeriodSpend+amount>buybackPeriodStartReserve*4000/BPS)revert InvalidAmount();_assertAccounting();buybackOperationUsed[operationId]=true;buybackPeriodSpend+=amount;lastBuybackAt=uint64(block.timestamp);buybackReserve-=amount;accountedQuote-=amount;(uint256 spent,uint256 received,uint256 burned,bytes32 burnId)=ICompdKernelBuybackExecutorV2(buybackExecutor).executeBuyback{value:amount}(operationId,quoteEvidenceId);if(spent!=amount||received==0||burned!=received||burnId==bytes32(0))revert InvalidEvidence();_assertAccounting();emit BuybackExecuted(operationId,amount,burnId);_emitAccounting();
    }

    function recordFlapRevenue(uint256,bytes32) external pure {revert IntegrationUnavailable();}
    function recoverProtocolReserve(bytes32 eligibilityId,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(eligibilityId,amount,0);}
    function recoverNoRecipient(bytes32 distributionId,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(distributionId,amount,1);}
    function recoverExpiredHolder(bytes32 leafIdentity,uint256 amount) external onlyModule(T.ModuleId.RECOVERY) nonReentrant {_recover(leafIdentity,amount,2);}
    function _recover(bytes32 id,uint256 amount,uint8 kind) private {if(lifecycle!=T.Lifecycle.TERMINATED||recoveryEvidenceSource==address(0))revert RecoveryUnavailable();if(id==bytes32(0)||amount==0||recoverySourceUsed[keccak256(abi.encode(kind,id))])revert Replay();(bool eligible,uint256 exactAmount)=kind==0?ICompdKernelRecoveryEvidenceV2(recoveryEvidenceSource).protocolRecovery(id):kind==1?ICompdKernelRecoveryEvidenceV2(recoveryEvidenceSource).noRecipientRecovery(id):ICompdKernelRecoveryEvidenceV2(recoveryEvidenceSource).expiredHolderRecovery(id);if(!eligible||exactAmount!=amount)revert RecoveryUnavailable();uint256 bucket=kind==0?protocolReserve:holderRewardReserve;if(amount>bucket||amount>accountedQuote)revert InvalidAmount();recoverySourceUsed[keccak256(abi.encode(kind,id))]=true;ICompdKernelRecoveryEvidenceV2(recoveryEvidenceSource).consume(id);if(kind==0)protocolReserve-=amount;else holderRewardReserve-=amount;accountedQuote-=amount;_sendFixed(RECOVERY_TREASURY,amount);_assertAccounting();_emitAccounting();}

    function emergencyEnter() external nonReentrant {if(msg.sender!=emergencyAuthority||lifecycle==T.Lifecycle.TERMINATED||lifecycle==T.Lifecycle.EMERGENCY_RECOVERY||!modulesBound)revert Unauthorized();_assertAccounting();if(activePrincipal>strategyCapital||accountedQuote<holderRewardReserve||address(this).balance<accountedQuote)revert EmergencyInvariantFailure();uint256 vb=address(this).balance;uint256 n=accountedQuote-holderRewardReserve;uint256 avail=vb>n?vb-n:0;if(avail>holderRewardReserve)avail=holderRewardReserve;preEmergencyHolderDeficit=holderRewardReserve-avail;++emergencyNonce;emergencySnapshotId=keccak256(abi.encode(block.chainid,address(this),emergencyNonce,block.timestamp,block.number,uint8(lifecycle),vb,accountedQuote,activePrincipal,holderRewardReserve));uint256[] memory ids=_activeRunIds;uint256[] memory principals=new uint256[](ids.length);for(uint256 i;i<ids.length;++i)principals[i]=runs[ids[i]].principal;ICompdKernelEmergencyRegistryV2(modules[5]).initializeSnapshot(emergencySnapshotId,ids,principals);emergencyStatus=T.EmergencyProcessingStatus.OPEN;_setLifecycle(T.Lifecycle.EMERGENCY_RECOVERY);emit EmergencyEntered(emergencySnapshotId,emergencyNonce,vb,accountedQuote,holderRewardReserve,preEmergencyHolderDeficit);}
    function requestEmergencyAssetRecovery(bytes32 snapshotId,uint8 assetKind,bytes32 assetId,uint256 amount,bytes32 evidenceId) external onlyModule(T.ModuleId.EMERGENCY) {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||snapshotId!=emergencySnapshotId||assetId==bytes32(0)||amount==0||evidenceId==bytes32(0)||assetKind!=0)revert UnsupportedEmergencyAsset();revert IntegrationUnavailable();}
    function processEmergencyModule(bytes32 snapshotId,uint8 moduleId,bytes32 actionId,bytes32 evidenceId) external onlyModule(T.ModuleId.EMERGENCY) {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||snapshotId!=emergencySnapshotId||moduleId>uint8(T.ModuleId.REGISTRY)||actionId==bytes32(0)||evidenceId==bytes32(0))revert InvalidEvidence();ICompdKernelEmergencyRegistryV2(modules[5]).beginAttempt(snapshotId,T.ScopeKind.MODULE,bytes32(uint256(moduleId)),1);ICompdKernelEmergencyRegistryV2(modules[5]).recordAttemptResult(snapshotId,T.ScopeKind.MODULE,bytes32(uint256(moduleId)),1,T.AttemptStatus.PENDING,evidenceId);emergencyStatus=T.EmergencyProcessingStatus.PENDING;}
    function reconcileEmergencyRun(uint256 runId,bytes32 closeEvidenceId,bytes32 attemptId) external onlyModule(T.ModuleId.EMERGENCY) {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||runs[runId].status==T.RunStatus.NONE||attemptId==bytes32(0))revert InvalidRun();ICompdKernelEmergencyRegistryV2(modules[5]).beginAttempt(emergencySnapshotId,T.ScopeKind.RUN,bytes32(runId),uint64(1));ICompdKernelEmergencyRegistryV2(modules[5]).recordAttemptResult(emergencySnapshotId,T.ScopeKind.RUN,bytes32(runId),1,T.AttemptStatus.PENDING,closeEvidenceId);emergencyStatus=T.EmergencyProcessingStatus.PENDING;}
    function retryEmergencyAttempt(bytes32 snapshotId,uint8 scopeKind,bytes32 subjectId,uint64 priorAttempt) external onlyModule(T.ModuleId.EMERGENCY) {if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||snapshotId!=emergencySnapshotId||scopeKind>uint8(T.ScopeKind.REVENUE)||subjectId==bytes32(0)||priorAttempt==0)revert InvalidEvidence();ICompdKernelEmergencyRegistryV2(modules[5]).beginAttempt(snapshotId,T.ScopeKind(scopeKind),subjectId,priorAttempt+1);emergencyStatus=T.EmergencyProcessingStatus.PROCESSING;}
    function refreshEmergencyCompletion(bytes32 snapshotId) external onlyModule(T.ModuleId.EMERGENCY) returns(T.EmergencyProcessingStatus status){if(lifecycle!=T.Lifecycle.EMERGENCY_RECOVERY||snapshotId!=emergencySnapshotId)revert InvalidEvidence();(,,,,uint256 unresolved,uint256 pending,bool initialized,bool complete)=ICompdKernelEmergencyRegistryV2(modules[5]).scopeSummary(snapshotId);_assertAccounting();if(!initialized||complete||unresolved!=0||pending!=0||activePrincipal!=0||holderRewardReserve!=0){emergencyStatus=unresolved!=0?T.EmergencyProcessingStatus.BLOCKED:T.EmergencyProcessingStatus.PENDING;return emergencyStatus;}emergencyStatus=T.EmergencyProcessingStatus.COMPLETE;return emergencyStatus;}

    function _sendFixed(address to,uint256 amount) private {uint256 before_=address(this).balance;(bool ok,)=payable(to).call{value:amount,gas:50_000}("");if(!ok||before_<address(this).balance||before_-address(this).balance!=amount)revert InvalidAmount();}
    function _assertAccounting() private view {if(strategyCapital+buybackReserve+protocolReserve+holderRewardReserve!=accountedQuote+activePrincipal||activePrincipal>strategyCapital||accountedQuote<holderRewardReserve||address(this).balance<accountedQuote)revert AccountingInvariant();}
    function _emitAccounting() private {emit AccountingChanged(strategyCapital,buybackReserve,protocolReserve,holderRewardReserve,accountedQuote,activePrincipal);}
    function _setLifecycle(T.Lifecycle next) private {T.Lifecycle old=lifecycle;lifecycle=next;emit LifecycleChanged(old,next);}
    function _codeHash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
    function _removeActiveRun(uint256 runId) private {for(uint256 i;i<_activeRunIds.length;++i)if(_activeRunIds[i]==runId){_activeRunIds[i]=_activeRunIds[_activeRunIds.length-1];_activeRunIds.pop();break;}}
    function activeRunCount() external view returns(uint256){return _activeRunIds.length;}
    function activeRunAt(uint256 index) external view returns(uint256){return _activeRunIds[index];}
}

