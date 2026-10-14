// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

library CompdVaultKernelV2Types {
    enum Lifecycle { ACTIVE, PAUSED, SHUTDOWN_PENDING, TERMINATED, EMERGENCY_RECOVERY }
    enum EmergencyProcessingStatus { UNINITIALIZED, OPEN, PROCESSING, PENDING, BLOCKED, RECONCILING, COMPLETE, COMPLETE_WITH_UNRESOLVED }
    enum ModuleId { SETTLEMENT, HOLDER, BUYBACK, RECOVERY, EMERGENCY, REGISTRY }
    enum RunStatus { NONE, OPEN, EXIT_REQUESTED, RETURN_PENDING, SETTLED, BLOCKED }
    enum ScopeStatus { UNKNOWN, OPEN, PENDING, BLOCKED, RESOLVED }
    enum ScopeKind { ASSET, MODULE, RUN, HOLDER_LIABILITY, BUYBACK, REVENUE }
    enum AttemptStatus { NONE, STARTED, SUCCEEDED, FAILED, PENDING, BLOCKED }
    enum Resolution { NONE, SETTLED, RECOVERED, PAID, EXPIRED }

    struct Accounting { uint256 strategyCapital; uint256 buybackReserve; uint256 protocolReserve; uint256 holderRewardReserve; uint256 accountedQuote; uint256 activePrincipal; }
    struct HolderLeaf { bytes32 distributionId; uint32 version; uint16 index; bytes32 root; bytes32 parentCommitment; bytes32 leafIdentity; address recipient; address asset; uint256 amount; uint8 distributionStatus; uint8 liabilityStatus; uint64 finalizedAt; uint64 expiresAt; bool proofValid; }
    struct Run { address asset; uint256 principal; uint64 openedAt; bytes32 allocationEvidenceId; bytes32 closeEvidenceId; uint256 returnedBNB; RunStatus status; }
}

interface ICompdKernelBoundModuleV2 {
    function kernel() external view returns (address);
    function moduleId() external pure returns (CompdVaultKernelV2Types.ModuleId);
    function moduleVersion() external pure returns (uint32);
}

interface ICompdKernelStrategyExecutorV2 {
    function openRun(uint256 runId,uint256 amount,bytes32 allocationEvidenceId) external payable returns (bytes32 canonicalAllocationId);
    function closeToKernel(uint256 runId,bytes32 closeEvidenceId) external returns (uint256 principal,uint256 returnedBNB,bytes32 canonicalCloseId);
    function requestExit(uint256 runId,bytes32 exitRequestId) external returns (CompdVaultKernelV2Types.RunStatus);
}

interface ICompdKernelHolderDistributorV2 {
    function verifyFinalizedLeaf(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external view returns (CompdVaultKernelV2Types.HolderLeaf memory leaf);
    function markPaid(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external;
}

interface ICompdKernelHolderLiabilityV2 {
    function liability(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external view returns (CompdVaultKernelV2Types.HolderLeaf memory leaf);
    function markPaid(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafIdentity) external;
}

interface ICompdKernelBuybackQuoteV2 {
    function quoteEvidence(bytes32 quoteEvidenceId) external view returns (bool canonical,bool fresh,uint256 quotedOut,uint64 observedAt,bytes32 routeId);
}

interface ICompdKernelBuybackExecutorV2 {
    function executeBuyback(bytes32 operationId,bytes32 quoteEvidenceId) external payable returns (uint256 bnbSpent,uint256 compdReceived,uint256 compdBurned,bytes32 burnEvidenceId);
}

interface ICompdKernelRecoveryEvidenceV2 {
    function protocolRecovery(bytes32 eligibilityId) external view returns (bool eligible,uint256 amount);
    function noRecipientRecovery(bytes32 finalizedDistributionId) external view returns (bool eligible,uint256 amount);
    function expiredHolderRecovery(bytes32 leafIdentity) external view returns (bool eligible,uint256 amount);
    function consume(bytes32 sourceId) external;
}

interface ICompdKernelEmergencyRegistryV2 {
    function initializeSnapshot(bytes32 snapshotId,uint256[] calldata runIds,uint256[] calldata principals) external;
    function beginAttempt(bytes32 snapshotId,CompdVaultKernelV2Types.ScopeKind kind,bytes32 subjectId,uint64 attemptNo) external;
    function recordAttemptResult(bytes32 snapshotId,CompdVaultKernelV2Types.ScopeKind kind,bytes32 subjectId,uint64 attemptNo,CompdVaultKernelV2Types.AttemptStatus status,bytes32 evidenceId) external;
    function resolveScope(bytes32 snapshotId,CompdVaultKernelV2Types.ScopeKind kind,bytes32 subjectId,CompdVaultKernelV2Types.Resolution resolution,bytes32 evidenceId) external;
    function registerLateDiscovery(bytes32 snapshotId,CompdVaultKernelV2Types.ScopeKind kind,bytes32 subjectId,bytes32 evidenceId) external;
    function scopeSummary(bytes32 snapshotId) external view returns (uint256 assets,uint256 modules,uint256 runs,uint256 liabilities,uint256 unresolved,uint256 pendingAttempts,bool initialized,bool complete);
}

