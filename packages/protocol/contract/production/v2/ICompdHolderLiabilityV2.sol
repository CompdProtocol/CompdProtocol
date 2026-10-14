// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ICompdVaultBoundComponentV2} from "./ICompdVaultBoundComponentV2.sol";

interface ICompdHolderLiabilityV2 is ICompdVaultBoundComponentV2 {
    // Append prototype-only states without renumbering the Phase 6B status ordinals.
    enum EntryStatus { NONE, COMMITTED_UNPAID, FAILED_PENDING_MANUAL, TERMINAL_PENDING, TERMINAL_EXPIRED, PAID, MATERIALIZED_PENDING_FINALIZATION, SUPERSEDED, RECOVERED }
    enum ManualSettlementStatus { NONE, AVAILABLE, SETTLED }
    enum HistoryAction { MATERIALIZED, SUPERSEDED, FINALIZED, PAID, FAILED, MANUAL_AVAILABLE, MANUAL_SETTLED, TERMINAL_STARTED, TERMINAL_EXPIRED, RECOVERED }

    struct EntryInput {
        bytes32 distributionId;
        uint32 version;
        bytes32 windowId;
        uint16 index;
        bytes32 leafHash;
        address recipient;
        address rewardAsset;
        uint256 amount;
    }

    struct EntryRecord {
        bytes32 distributionId;
        uint32 version;
        bytes32 windowId;
        uint16 index;
        bytes32 leafHash;
        address recipient;
        address rewardAsset;
        uint256 amount;
        bytes32 failureHash;
        bytes32 manualEvidenceHash;
        uint64 terminalStartedAt;
        uint64 terminalExpiresAt;
        EntryStatus status;
        ManualSettlementStatus manualSettlementStatus;
    }

    struct DistributionSummary {
        uint256 materializedAmount;
        uint16 materializedCount;
        bool finalized;
        bool superseded;
    }

    struct SourcePartitions {
        uint256 finalizedUnpaidLiabilities;
        uint256 expiredLiabilityRecoveryEligible;
        uint32 pendingAutomatic;
        uint32 failedUnavailable;
        uint32 finalizedUnpaidRecords;
        uint32 terminalPendingRecords;
    }

    struct HistoryEntry {
        bytes32 liabilityId;
        bytes32 evidenceHash;
        uint64 timestamp;
        uint32 version;
        uint16 index;
        uint256 amount;
        EntryStatus priorStatus;
        EntryStatus resultingStatus;
        HistoryAction action;
    }

    error OnlyBoundVault();
    error InvalidLiabilityTransition();
    error LiabilityRecordMismatch();
    error DuplicateLiabilityIdentity();

    event HolderEntryMaterialized(bytes32 indexed distributionId,uint32 indexed version,uint16 indexed index,bytes32 leafHash,address recipient,address rewardAsset,uint256 amount);
    event MaterializedVersionSuperseded(bytes32 indexed distributionId,uint32 indexed version,uint16 entries);
    event LiabilityDistributionFinalized(bytes32 indexed distributionId,uint32 indexed version,uint256 amount,uint16 count);
    event HolderLiabilityStatusChanged(bytes32 indexed liabilityId,EntryStatus priorStatus,EntryStatus newStatus,bytes32 evidenceHash);
    event ManualSettlementAvailabilityRecorded(bytes32 indexed liabilityId,bytes32 evidenceHash);
    event TerminalLiabilityStarted(bytes32 indexed liabilityId,uint64 startedAt,uint64 expiresAt);
    event TerminalLiabilityExpired(bytes32 indexed liabilityId,uint256 amount);

    function registerMaterializedEntry(EntryInput calldata) external;
    function supersedeMaterializedVersion(bytes32,uint32) external;
    function finalizeLiabilityDistribution(bytes32,uint32,uint256,uint16) external;
    function recordAutomaticPayment(bytes32,uint32,uint16,bytes32) external;
    function recordAutomaticPaymentFailure(bytes32,uint32,uint16,bytes32,bytes32) external;
    function recordManualSettlementAvailable(bytes32,uint32,uint16,bytes32,bytes32) external;
    function recordManualSettlement(bytes32,uint32,uint16,bytes32) external;
    function startTerminalLiability(bytes32,uint32,bytes32,uint16,bytes32) external;
    function expireTerminalLiability(bytes32,uint32,bytes32,uint16,bytes32) external;
    function recordExpiredLiabilityRecovery(bytes32,bytes32) external;

    function entry(bytes32,uint32,uint16) external view returns (EntryRecord memory);
    function liabilityId(bytes32,uint32,bytes32,uint16) external pure returns (bytes32);
    function liability(bytes32) external view returns (EntryRecord memory);
    function distributionSummary(bytes32,uint32) external view returns (DistributionSummary memory);
    function sourcePartitions() external view returns (SourcePartitions memory);
    function historyCount(bytes32) external view returns (uint32);
    function historyAt(bytes32,uint32) external view returns (HistoryEntry memory);
}
