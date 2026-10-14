// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";

interface ICompdEmergencyVaultV2 {
    function emergencyWithdrawAll() external;
    function emergencyWithdrawAsset(address asset) external;
    function emergencyRecoverModuleAsset(CompdV2Types.ModuleId moduleId, address asset) external;
    function emergencyExitRun(uint256 runId) external;
    function emergencyRetryAsset(CompdV2Types.ModuleId moduleId, address asset) external;
    function emergencyRetryRun(uint256 runId) external;
    function registerDiscoveredEmergencyAsset(address asset) external;
    function emergencyRefreshCompletion() external;

    function emergencyRecoveryState() external view returns (
        CompdV2Types.Lifecycle lifecycle_,
        CompdV2Types.EmergencyProcessingStatus status_,
        bytes32 snapshotId_,
        uint64 initiatedAt_,
        uint64 initiatedBlock_,
        address initiatedBy_
    );
    function emergencyRecoveryWallet() external view returns (address);
    function emergencyRecoveryAuthority() external view returns (address);
    function emergencyAccountingSnapshot() external view returns (CompdV2Types.EmergencySnapshot memory);
    function emergencyReconciliation() external view returns (CompdV2Types.EmergencyReconciliation memory);
    function emergencyAssetStatus(CompdV2Types.ModuleId moduleId, address asset)
        external view returns (CompdV2Types.EmergencyAssetRecord memory);
    function emergencyAttemptCount(bytes32 subjectId) external view returns (uint32);
    function emergencyAttemptAt(bytes32 subjectId, uint32 attemptNumber)
        external view returns (CompdV2Types.EmergencyAttempt memory);
    function emergencyOutflowByModuleAsset(CompdV2Types.ModuleId moduleId, address asset)
        external view returns (uint256 amountDebited, uint256 amountCredited);
    function emergencyFailureCountByModuleAsset(CompdV2Types.ModuleId moduleId, address asset)
        external view returns (uint32);
    function emergencyHolderBackingState() external view returns (CompdV2Types.EmergencyHolderBacking memory);
    function emergencyAssetCount() external view returns (uint256);
    function emergencyAssetAt(uint256 index) external view returns (address);
    function emergencyModuleAddress(CompdV2Types.ModuleId moduleId) external view returns (address);

    // Core V2 identities consumed by typed immutable module bindings.
    function lifecycle() external view returns (CompdV2Types.Lifecycle);
    function quoteToken() external view returns (address);
    function compdToken() external view returns (address);
    function RECOVERY_TREASURY() external view returns (address);

    // Typed normal V2 accounting and Holder hooks frozen from the Phase 6B specification.
    function registerFlapRevenue(uint256 amount) external payable;
    function allocateStrategyPrincipal(uint256 runId, uint256 amount) external;
    function settleStrategyPrincipal(uint256 runId, uint256 returnedAmount) external payable;
    function reserveFinalizedHolderDistribution(
        bytes32 distributionId, bytes32 windowId, uint32 commitmentVersion, uint256 totalPayable, uint16 expectedEntryCount
    ) external;
    function correctHolderDistribution(bytes32 distributionId, uint32 newVersion, uint16 expectedEntryCount) external;
    function registerHolderRewardEntry(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex,
        address recipient, uint256 amount
    ) external;
    function finalizeHolderDistribution(bytes32 distributionId, uint32 commitmentVersion) external;
    function payCommittedHolderEntry(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex,
        address recipient, address rewardAsset, uint256 amount
    ) external;
    function markHolderEntryFailed(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex,
        address recipient, address rewardAsset, uint256 amount, bytes32 revertDataHash
    ) external;
    function markManualSettlementAvailable(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId,
        uint16 recipientIndex, bytes32 evidenceHash
    ) external;
    function settleFailedHolderEntry(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex,
        address recipient, address rewardAsset, uint256 amount
    ) external;
    function openEmptyCandidate(
        bytes32 windowId, bytes32 distributionId, uint32 version, uint256 poolAmount,
        bytes32 emptyCommitment, bytes32 evidenceHash, bytes32 reasonHash
    ) external;
    function correctEmptyCandidate(
        bytes32 windowId, uint32 newVersion, bytes32 newCommitment,
        bytes32 newEvidenceHash, bytes32 reasonHash
    ) external;
    function finalizeEmptyCandidate(bytes32 windowId, uint32 version) external;
    function startTerminalHolderLiability(
        bytes32 distributionId, uint32 version, bytes32 windowId, uint16 recipientIndex
    ) external;
    function expireTerminalHolderLiability(
        bytes32 distributionId, uint32 version, bytes32 windowId, uint16 recipientIndex
    ) external;
    function recoverExpiredHolderLiability(bytes32 liabilityId) external;
    function recoverNoRecipientPool(bytes32 windowId) external;
}

interface ICompdEmergencyEventsV2 {
    event EmergencyRecoveryInitiated(
        bytes32 indexed snapshotId,
        address indexed authority,
        address indexed recoveryWallet,
        CompdV2Types.Lifecycle lifecycleBefore,
        uint64 startedAt,
        uint64 startedBlock,
        bytes32 accountingSnapshotHash,
        bytes32 activeRunInventoryHash,
        bytes32 assetManifestHash
    );
    event EmergencyModuleRecoveryAttempted(
        bytes32 indexed snapshotId,
        bytes32 indexed attemptId,
        CompdV2Types.ModuleId moduleId,
        address module,
        address asset,
        uint32 attemptNumber,
        address caller,
        uint64 timestamp,
        uint64 blockNumber,
        uint256 balanceBefore
    );
    event EmergencyAssetRecovered(
        bytes32 indexed snapshotId,
        bytes32 indexed attemptId,
        CompdV2Types.ModuleId moduleId,
        address module,
        address asset,
        uint256 amountDebited,
        uint256 amountCredited,
        address indexed recoveryWallet,
        bool verifiedDelta,
        uint64 timestamp,
        uint64 blockNumber
    );
    event EmergencyAssetRecoveryFailed(
        bytes32 indexed snapshotId,
        bytes32 indexed attemptId,
        CompdV2Types.ModuleId moduleId,
        address module,
        address asset,
        uint32 attemptNumber,
        bytes32 failureCode,
        bytes32 revertDataHash,
        uint64 timestamp,
        uint64 blockNumber
    );
    event EmergencyPositionExitRequired(
        bytes32 indexed snapshotId,
        uint256 indexed runId,
        address indexed adapter,
        bytes32 market,
        address asset,
        uint256 principal,
        uint64 requiredAt
    );
    event EmergencyPositionExitAttempted(
        bytes32 indexed snapshotId, uint256 indexed runId, bytes32 indexed attemptId,
        address adapter, uint64 timestamp, uint64 blockNumber
    );
    event EmergencyPositionExitSettled(
        bytes32 indexed snapshotId, uint256 indexed runId, bytes32 indexed attemptId,
        uint256 principal, uint256 measuredQuoteReturned, uint256 realizedProfit,
        uint256 realizedLoss, CompdV2Types.EmergencyRunStatus status, uint64 timestamp
    );
    event EmergencyPositionExitBlocked(
        bytes32 indexed snapshotId, uint256 indexed runId, bytes32 indexed attemptId,
        address adapter, bytes32 failureCode, bytes32 revertDataHash, uint64 timestamp, uint64 blockNumber
    );
    event EmergencyBackingDeficitUpdated(
        bytes32 indexed snapshotId,
        uint256 holderReserve,
        uint256 holderUnpaidTotal,
        uint256 holderBackingAvailable,
        uint256 holderBackingDeficit,
        uint256 preEmergencyDeficit,
        uint256 emergencyCausedDeficit,
        uint256 cumulativeQuoteEmergencyOutflow,
        uint64 timestamp
    );
    event EmergencyProcessingStatusChanged(
        bytes32 indexed snapshotId,
        CompdV2Types.EmergencyProcessingStatus previousStatus,
        CompdV2Types.EmergencyProcessingStatus newStatus,
        bytes32 reasonHash,
        uint64 timestamp
    );
    event EmergencyRecoveryCompleted(
        bytes32 indexed snapshotId,
        CompdV2Types.EmergencyProcessingStatus completionStatus,
        uint16 registeredModuleCount,
        uint16 registeredAssetCount,
        uint32 unresolvedRunCount,
        uint32 unresolvedAssetAttemptCount,
        uint256 unpaidHolderTotal,
        uint256 holderBackingDeficit,
        bytes32 coverageStatementHash,
        uint64 timestamp
    );
}

interface ICompdEmergencyModuleV2 {
    function vault() external view returns (address);
    function emergencySweepAsset(address asset) external;
    function snapshotEmergencyBalance(bytes32 snapshotId, address asset)
        external view returns (bool available, uint256 balance);
    function emergencyLifecycleCompatibility() external view returns (bool);
}

interface ICompdStrategyExecutorV2 is ICompdEmergencyModuleV2 {
    function emergencyExitRun(uint256 runId) external;
    function emergencyRunStatus(uint256 runId) external view returns (CompdV2Types.EmergencyRunStatus);
    function closePosition(uint256 runId) external;
    function activeRunCount() external view returns (uint256);
    function activeRunAt(uint256 index) external view returns (uint256);
    function adapterForRun(uint256 runId) external view returns (address);
}

interface ICompdBuybackExecutorV2 is ICompdEmergencyModuleV2 { }

interface ICompdThinFlapReceiverV2 is ICompdEmergencyModuleV2 {
    function recognizedPendingRevenue() external view returns (uint256);
    function unrecognizedSurplus() external view returns (uint256);
    function productionVault() external view returns (address);
    function taxToken() external view returns (address);
    function vaultQuoteToken() external view returns (address);
}

