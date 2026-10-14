// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

library C2G2BTypes {
    enum Lifecycle { ACTIVE, PAUSED, SHUTDOWN_PENDING, TERMINATED, EMERGENCY_RECOVERY }
    enum ModuleId { SETTLEMENT, HOLDER, BUYBACK, RECOVERY, EMERGENCY, REGISTRY }
    enum RunStatus { NONE, OPEN, EXIT_REQUESTED, RETURN_PENDING, SETTLED, BLOCKED }
    enum ProcessingStatus { NOT_STARTED, IN_PROGRESS, COMPLETE_WITHIN_REGISTERED_SCOPE, COMPLETE_WITH_UNRESOLVED }
    enum ScopeKind { BNB, MODULE, RUN, HOLDER_LIABILITY }
    enum ScopeStatus { OPEN, PENDING, BLOCKED, RESOLVED }
    enum AttemptStatus { STARTED, SUCCEEDED, FAILED, PENDING, BLOCKED }
    struct HolderPayment { bytes32 windowId; bytes32 distributionId; uint32 version; uint16 index; bytes32 root; bytes32 lineage; bytes32 leafId; address recipient; address asset; uint256 amount; uint8 distributionStatus; uint8 liabilityStatus; uint64 finalizedAt; uint64 expiresAt; uint8 recoveryStatus; bytes32 useId; }
    struct RunView { address strategy; uint256 principal; uint64 openedAt; bytes32 allocationId; bytes32 closeId; uint256 returnedBNB; RunStatus status; }
    struct Attempt { bytes32 id; uint32 number; uint64 timestamp; AttemptStatus status; bytes32 evidence; }
}

interface IC2G2BBoundModule { function kernel() external view returns(address); function moduleId() external pure returns(uint8); function moduleVersion() external pure returns(uint32); }
interface IC2G2BStrategyExecutor {
    function isApprovedStrategy(address strategy) external view returns(bool);
    function openRun(uint256 runId,address strategy,uint256 amount,uint256 maxDesignedLoss,bytes32 allocationId) external payable returns(bytes32);
    function requestExit(uint256 runId,bytes32 exitId) external returns(C2G2BTypes.RunStatus);
    function closeToKernel(uint256 runId,bytes32 closeId) external returns(uint256 principal,uint256 returnedBNB,bytes32 canonicalCloseId);
}
interface IC2G2BHolderDistributor {
    function paymentData(bytes32 leafId) external view returns(C2G2BTypes.HolderPayment memory payment,bool proofValid);
    function paymentDigest(bytes32 leafId) external view returns(bytes32);
    function consumePayment(bytes32 leafId,bytes32 digest) external;
}
interface IC2G2BHolderLiability {
    function paymentDigest(bytes32 leafId) external view returns(bytes32);
    function consumePayment(bytes32 leafId,bytes32 digest) external;
}
interface IC2G2BRecoveryEvidence {
    function protocolReserveRecovery(bytes32 id) external view returns(bool,uint256);
    function noRecipientRecovery(bytes32 id) external view returns(bool,uint256);
    function expiredHolderRecovery(bytes32 id) external view returns(bool,uint256);
    function consumeProtocolReserve(bytes32 id) external;
    function consumeNoRecipient(bytes32 id) external;
    function consumeExpiredHolder(bytes32 id) external;
}
interface IC2G2BBuybackQuote {
    function policyHash() external view returns(bytes32);
    function quote(bytes32 quoteId) external view returns(bytes32 route,uint256 amountOut,uint64 observedAt,uint256 referenceOut);
}
interface IC2G2BBuybackExecutor {
    function execute(bytes32 operationId,bytes32 quoteId) external payable returns(uint256 spent,uint256 received,uint256 burned,bytes32 evidenceId);
}
interface IC2G2BRegistry {
    function initialize(bytes32 snapshotId,bytes32[] calldata scopeIds,uint8[] calldata kinds) external;
    function beginAttempt(bytes32 snapshotId,bytes32 scopeId,bytes32 attemptId,uint32 number) external;
    function beginWorkflowAttempt(bytes32 snapshotId,bytes32 scopeId,bytes32 attemptId,uint32 number) external;
    function finishAttempt(bytes32 snapshotId,bytes32 scopeId,bytes32 attemptId,uint32 number,C2G2BTypes.AttemptStatus status,bytes32 evidence) external;
    function finishWorkflowAttempt(bytes32 snapshotId,bytes32 scopeId,bytes32 attemptId,uint32 number,C2G2BTypes.AttemptStatus status,bytes32 evidence) external;
    function lateDiscovery(bytes32 snapshotId,bytes32 scopeId,uint8 kind,bytes32 evidence) external;
    function resolve(bytes32 snapshotId,bytes32 scopeId,bytes32 evidence) external;
    function summary(bytes32 snapshotId) external view returns(uint256 scopes,uint256 open,uint256 pending,uint256 blocked,bool initialized);
}
interface IC2G2BKernel {
    function lifecycle() external view returns(C2G2BTypes.Lifecycle);
    function allocateStrategyPrincipal(uint256 runId,address strategy,uint256 amount,bytes32 allocationId) external;
    function recordExitRequest(uint256 runId,bytes32 exitId,C2G2BTypes.RunStatus status) external;
    function settleStrategyPrincipal(uint256 runId,bytes32 closeId) external;
    function payHolder(bytes32 leafId,bytes32 useId,bytes32 digest,address recipient,uint256 amount,bool retry,bytes32 attemptId) external returns(bool);
    function releaseBuyback(bytes32 id,uint256 amount,bytes32 quoteId) external;
    function recoverProtocolReserve(bytes32 id,uint256 amount) external;
    function recoverNoRecipient(bytes32 id,uint256 amount) external;
    function recoverExpiredHolder(bytes32 id,uint256 amount) external;
    function emergencyEnter() external;
    function emergencyTransferBNB(bytes32 scopeId,bytes32 attemptId,uint32 attemptNumber,uint256 amount,bytes32 evidence) external;
    function emergencySnapshotId() external view returns(bytes32);
    function emergencyStatus() external view returns(C2G2BTypes.ProcessingStatus);
    function setEmergencyStatus(C2G2BTypes.ProcessingStatus status) external;
    function strategyCapital() external view returns(uint256);
    function cumulativeRealizedLoss() external view returns(uint256);
    function activePrincipal() external view returns(uint256);
    function activeRunCount() external view returns(uint256);
    function activeRunAt(uint256) external view returns(uint256);
    function runPrincipal(uint256) external view returns(uint256);
    function runMaxDesignedLoss(uint256) external view returns(uint256);
    function runActualLoss(uint256) external view returns(uint256);
    function runLossBoundBreached(uint256) external view returns(bool);
    function strategyAllocationHalted() external view returns(bool);
    function runStatus(uint256) external view returns(C2G2BTypes.RunStatus);
}
