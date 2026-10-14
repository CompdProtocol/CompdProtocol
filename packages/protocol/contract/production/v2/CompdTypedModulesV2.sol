// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdVaultKernelV2Types as T,ICompdKernelBoundModuleV2} from "./CompdVaultKernelV2Types.sol";

interface ICompdKernelCapabilitiesV2 {
    function allocateStrategy(uint256,uint256,bytes32) external;
    function requestStrategyExit(uint256,bytes32) external;
    function settleStrategy(uint256,bytes32) external;
    function recordFlapRevenue(uint256,bytes32) external;
    function payHolder(bytes32,uint32,uint16,bytes32) external returns(bool);
    function retryHolderPayment(bytes32,bytes32) external returns(bool);
    function releaseBuyback(bytes32,uint256,bytes32) external;
    function recoverProtocolReserve(bytes32,uint256) external;
    function recoverNoRecipient(bytes32,uint256) external;
    function recoverExpiredHolder(bytes32,uint256) external;
    function requestEmergencyAssetRecovery(bytes32,uint8,bytes32,uint256,bytes32) external;
    function processEmergencyModule(bytes32,uint8,bytes32,bytes32) external;
    function reconcileEmergencyRun(uint256,bytes32,bytes32) external;
    function retryEmergencyAttempt(bytes32,uint8,bytes32,uint64) external;
    function refreshEmergencyCompletion(bytes32) external returns(T.EmergencyProcessingStatus);
}

abstract contract CompdTypedModuleBaseV2 is ICompdKernelBoundModuleV2 {
    address public immutable override kernel;
    error Unauthorized();
    constructor(address kernel_){if(kernel_==address(0)||kernel_.code.length==0)revert Unauthorized();kernel=kernel_;}
    function moduleVersion() external pure override returns(uint32){return 2;}
}

contract CompdSettlementModuleV2 is CompdTypedModuleBaseV2 {
    constructor(address k) CompdTypedModuleBaseV2(k){}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.SETTLEMENT;}
    function allocateStrategy(uint256 runId,uint256 amount,bytes32 allocationEvidenceId) external {ICompdKernelCapabilitiesV2(kernel).allocateStrategy(runId,amount,allocationEvidenceId);}
    function requestExit(uint256 runId,bytes32 exitRequestId) external {ICompdKernelCapabilitiesV2(kernel).requestStrategyExit(runId,exitRequestId);}
    function settleStrategy(uint256 runId,bytes32 closeEvidenceId) external {ICompdKernelCapabilitiesV2(kernel).settleStrategy(runId,closeEvidenceId);}
    function recordFlapRevenue(uint256 amount,bytes32 payoutEvidenceId) external {ICompdKernelCapabilitiesV2(kernel).recordFlapRevenue(amount,payoutEvidenceId);}
}

contract CompdHolderModuleV2 is CompdTypedModuleBaseV2 {
    constructor(address k) CompdTypedModuleBaseV2(k){}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.HOLDER;}
    function payHolder(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external returns(bool){return ICompdKernelCapabilitiesV2(kernel).payHolder(distributionId,version,index,leafIdentity);}
    function retryHolderPayment(bytes32 leafIdentity,bytes32 retryAttemptId) external returns(bool){return ICompdKernelCapabilitiesV2(kernel).retryHolderPayment(leafIdentity,retryAttemptId);}
}

contract CompdBuybackModuleV2 is CompdTypedModuleBaseV2 {
    address public constant BUYBACK_ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address public constant AUTOMATION_EXECUTOR=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    constructor(address k) CompdTypedModuleBaseV2(k){}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.BUYBACK;}
    function execute(bytes32 operationId,uint256 amount,bytes32 quoteEvidenceId) external {if(msg.sender!=BUYBACK_ADMIN&&msg.sender!=AUTOMATION_EXECUTOR)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).releaseBuyback(operationId,amount,quoteEvidenceId);}
}

contract CompdRecoveryModuleV2 is CompdTypedModuleBaseV2 {
    address public constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    constructor(address k) CompdTypedModuleBaseV2(k){}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.RECOVERY;}
    function recoverProtocolReserve(bytes32 id,uint256 amount) external {if(msg.sender!=GUARDIAN)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).recoverProtocolReserve(id,amount);}
    function recoverNoRecipient(bytes32 id,uint256 amount) external {if(msg.sender!=GUARDIAN)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).recoverNoRecipient(id,amount);}
    function recoverExpiredHolder(bytes32 id,uint256 amount) external {if(msg.sender!=GUARDIAN)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).recoverExpiredHolder(id,amount);}
}

contract CompdEmergencyModuleV2 is CompdTypedModuleBaseV2 {
    address public immutable emergencyAuthority;
    constructor(address k,address authority) CompdTypedModuleBaseV2(k){if(authority==address(0))revert Unauthorized();emergencyAuthority=authority;}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.EMERGENCY;}
    function recoverEmergencyAsset(bytes32 snapshotId,uint8 assetKind,bytes32 assetId,uint256 amount,bytes32 evidenceId) external {if(msg.sender!=emergencyAuthority)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).requestEmergencyAssetRecovery(snapshotId,assetKind,assetId,amount,evidenceId);}
    function processModule(bytes32 snapshotId,uint8 moduleId_,bytes32 actionId,bytes32 evidenceId) external {if(msg.sender!=emergencyAuthority)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).processEmergencyModule(snapshotId,moduleId_,actionId,evidenceId);}
    function reconcileRun(uint256 runId,bytes32 closeEvidenceId,bytes32 attemptId) external {if(msg.sender!=emergencyAuthority)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).reconcileEmergencyRun(runId,closeEvidenceId,attemptId);}
    function retry(bytes32 snapshotId,uint8 scopeKind,bytes32 subjectId,uint64 priorAttempt) external {if(msg.sender!=emergencyAuthority)revert Unauthorized();ICompdKernelCapabilitiesV2(kernel).retryEmergencyAttempt(snapshotId,scopeKind,subjectId,priorAttempt);}
    function refresh(bytes32 snapshotId) external returns(T.EmergencyProcessingStatus){if(msg.sender!=emergencyAuthority)revert Unauthorized();return ICompdKernelCapabilitiesV2(kernel).refreshEmergencyCompletion(snapshotId);}
}

/// @notice Snapshot-bound append-only capability Registry for the new typed Kernel graph.
contract CompdEmergencyScopeRegistryV2 is CompdTypedModuleBaseV2 {
    address public immutable emergencyModule;
    mapping(bytes32=>bool) public initialized;
    mapping(bytes32=>bool) public complete;
    mapping(bytes32=>uint256) public assetCount;
    mapping(bytes32=>uint256) public moduleCount;
    mapping(bytes32=>uint256) public runCount;
    mapping(bytes32=>uint256) public liabilityCount;
    mapping(bytes32=>uint256) public unresolvedCount;
    mapping(bytes32=>uint256) public pendingCount;
    mapping(bytes32=>mapping(T.ScopeKind=>mapping(bytes32=>T.ScopeStatus))) public scopes;
    mapping(bytes32=>mapping(T.ScopeKind=>mapping(bytes32=>uint64))) public attempts;
    mapping(bytes32=>mapping(T.ScopeKind=>mapping(bytes32=>mapping(uint64=>T.AttemptStatus)))) public attemptStatus;
    mapping(bytes32=>mapping(T.ScopeKind=>mapping(bytes32=>bool))) public everRegistered;
    mapping(bytes32=>mapping(T.ScopeKind=>mapping(bytes32=>T.Resolution))) public resolutions;
    mapping(bytes32=>mapping(uint256=>uint256)) public snapshotRunPrincipal;
    event ScopeRegistered(bytes32 indexed snapshotId,T.ScopeKind indexed kind,bytes32 indexed subjectId);
    event AttemptRecorded(bytes32 indexed snapshotId,T.ScopeKind indexed kind,bytes32 indexed subjectId,uint64 attemptNo,T.AttemptStatus status,bytes32 evidenceId);
    event ScopeResolved(bytes32 indexed snapshotId,T.ScopeKind indexed kind,bytes32 indexed subjectId,T.Resolution resolution,bytes32 evidenceId);

    constructor(address kernel_,address emergencyModule_) CompdTypedModuleBaseV2(kernel_){if(emergencyModule_==address(0)||emergencyModule_.code.length==0)revert Unauthorized();emergencyModule=emergencyModule_;}
    function moduleId() external pure override returns(T.ModuleId){return T.ModuleId.REGISTRY;}
    modifier onlyController(){if(msg.sender!=kernel&&msg.sender!=emergencyModule)revert Unauthorized();_;}
    function initializeSnapshot(bytes32 snapshotId,uint256[] calldata runIds,uint256[] calldata principals) external onlyController {if(msg.sender!=kernel||snapshotId==bytes32(0)||initialized[snapshotId]||runIds.length!=principals.length)revert Unauthorized();initialized[snapshotId]=true;assetCount[snapshotId]=1;moduleCount[snapshotId]=6;unresolvedCount[snapshotId]=1;bytes32 accountingId=keccak256("ACCOUNTING_RECONCILIATION");everRegistered[snapshotId][T.ScopeKind.ASSET][accountingId]=true;scopes[snapshotId][T.ScopeKind.ASSET][accountingId]=T.ScopeStatus.OPEN;for(uint256 i;i<runIds.length;++i){bytes32 id=bytes32(runIds[i]);if(id==bytes32(0)||everRegistered[snapshotId][T.ScopeKind.RUN][id])revert Unauthorized();everRegistered[snapshotId][T.ScopeKind.RUN][id]=true;scopes[snapshotId][T.ScopeKind.RUN][id]=T.ScopeStatus.OPEN;snapshotRunPrincipal[snapshotId][runIds[i]]=principals[i];++runCount[snapshotId];++unresolvedCount[snapshotId];emit ScopeRegistered(snapshotId,T.ScopeKind.RUN,id);}emit ScopeRegistered(snapshotId,T.ScopeKind.ASSET,accountingId);}
    function beginAttempt(bytes32 snapshotId,T.ScopeKind kind,bytes32 subjectId,uint64 attemptNo) external onlyController {if(!initialized[snapshotId]||!everRegistered[snapshotId][kind][subjectId]||attemptNo!=attempts[snapshotId][kind][subjectId]+1)revert Unauthorized();attempts[snapshotId][kind][subjectId]=attemptNo;attemptStatus[snapshotId][kind][subjectId][attemptNo]=T.AttemptStatus.STARTED;scopes[snapshotId][kind][subjectId]=T.ScopeStatus.PENDING;++pendingCount[snapshotId];complete[snapshotId]=false;emit AttemptRecorded(snapshotId,kind,subjectId,attemptNo,T.AttemptStatus.STARTED,bytes32(0));}
    function recordAttemptResult(bytes32 snapshotId,T.ScopeKind kind,bytes32 subjectId,uint64 attemptNo,T.AttemptStatus status,bytes32 evidenceId) external onlyController {if(attemptStatus[snapshotId][kind][subjectId][attemptNo]!=T.AttemptStatus.STARTED||status==T.AttemptStatus.NONE||status==T.AttemptStatus.STARTED)revert Unauthorized();attemptStatus[snapshotId][kind][subjectId][attemptNo]=status;--pendingCount[snapshotId];if(status==T.AttemptStatus.FAILED||status==T.AttemptStatus.BLOCKED)scopes[snapshotId][kind][subjectId]=T.ScopeStatus.BLOCKED;else if(status==T.AttemptStatus.PENDING)scopes[snapshotId][kind][subjectId]=T.ScopeStatus.PENDING;else if(status==T.AttemptStatus.SUCCEEDED)scopes[snapshotId][kind][subjectId]=T.ScopeStatus.RESOLVED;emit AttemptRecorded(snapshotId,kind,subjectId,attemptNo,status,evidenceId);}
    function resolveScope(bytes32 snapshotId,T.ScopeKind kind,bytes32 subjectId,T.Resolution resolution,bytes32 evidenceId) external onlyController {if(!initialized[snapshotId]||!everRegistered[snapshotId][kind][subjectId]||scopes[snapshotId][kind][subjectId]==T.ScopeStatus.RESOLVED||resolution==T.Resolution.NONE||evidenceId==bytes32(0))revert Unauthorized();resolutions[snapshotId][kind][subjectId]=resolution;scopes[snapshotId][kind][subjectId]=T.ScopeStatus.RESOLVED;--unresolvedCount[snapshotId];emit ScopeResolved(snapshotId,kind,subjectId,resolution,evidenceId);}
    function registerLateDiscovery(bytes32 snapshotId,T.ScopeKind kind,bytes32 subjectId,bytes32 evidenceId) external onlyController {if(!initialized[snapshotId]||subjectId==bytes32(0)||evidenceId==bytes32(0)||everRegistered[snapshotId][kind][subjectId])revert Unauthorized();everRegistered[snapshotId][kind][subjectId]=true;scopes[snapshotId][kind][subjectId]=T.ScopeStatus.OPEN;++unresolvedCount[snapshotId];if(kind==T.ScopeKind.ASSET)++assetCount[snapshotId];else if(kind==T.ScopeKind.MODULE)++moduleCount[snapshotId];else if(kind==T.ScopeKind.RUN)++runCount[snapshotId];else if(kind==T.ScopeKind.HOLDER_LIABILITY)++liabilityCount[snapshotId];complete[snapshotId]=false;emit ScopeRegistered(snapshotId,kind,subjectId);}
    function scopeSummary(bytes32 snapshotId) external view returns(uint256 assets,uint256 modules_,uint256 runs_,uint256 liabilities,uint256 unresolved,uint256 pendingAttempts,bool initialized_,bool complete_){assets=assetCount[snapshotId];modules_=moduleCount[snapshotId];runs_=runCount[snapshotId];liabilities=liabilityCount[snapshotId];unresolved=unresolvedCount[snapshotId];pendingAttempts=pendingCount[snapshotId];initialized_=initialized[snapshotId];complete_=complete[snapshotId];}
    function refreshCompletion(bytes32 snapshotId) external onlyController returns(bool){if(!initialized[snapshotId]||assetCount[snapshotId]==0||moduleCount[snapshotId]==0||unresolvedCount[snapshotId]!=0||pendingCount[snapshotId]!=0)return false;complete[snapshotId]=true;return true;}
}

