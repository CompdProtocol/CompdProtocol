// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";
import {ICompdVaultBoundComponentV2} from "./ICompdVaultBoundComponentV2.sol";

/// @notice Typed Holder-workflow state only. This component never holds or transfers assets.
interface ICompdHolderAccountingV2 is ICompdVaultBoundComponentV2 {
    enum DistributionStatus { NONE, REVIEW_PENDING, FINALIZED }
    enum EntryStatus { NONE, COMMITTED_UNPAID, FAILED_PENDING_MANUAL, TERMINAL_PENDING, TERMINAL_EXPIRED, PAID }
    enum ManualSettlementStatus { NONE, AVAILABLE, SETTLED }
    enum HistoryAction { NONE, CANDIDATE_OPENED, CANDIDATE_CORRECTED, ENTRY_MATERIALIZED, DISTRIBUTION_FINALIZED, PAYMENT_SUCCEEDED, PAYMENT_FAILED, MANUAL_AVAILABLE, MANUAL_SETTLED, TERMINAL_STARTED, TERMINAL_EXPIRED, EMPTY_OPENED, EMPTY_CORRECTED, EMPTY_FINALIZED, NO_RECIPIENT_ELIGIBLE, NO_RECIPIENT_RECOVERED, LIABILITY_RECOVERED }

    struct DistributionCandidateInput {
        bytes32 distributionId;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint32 version;
        uint256 windowPool;
        uint256 totalPayable;
        uint16 expectedEntryCount;
        uint16 positiveEntryCount;
        uint32 algorithmVersion;
        bytes32 root;
        bytes32 datasetHash;
        bytes32 commitmentHash;
    }

    struct EmptyCandidateInput {
        bytes32 windowId;
        bytes32 distributionId;
        uint64 windowStart;
        uint64 windowEnd;
        bytes32 emptyCommitment;
        bytes32 manifestHash;
        bytes32 snapshotBlockHash;
        bytes32 activationContextHash;
        bytes32 evidenceHash;
        bytes32 correctionReasonHash;
        uint256 poolAmount;
        uint256 snapshotBlockNumber;
        uint32 replayVersion;
        uint32 version;
        uint16 recipientCount;
        bool zeroResult;
    }

    struct DistributionRecord {
        bytes32 distributionId;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint32 currentVersion;
        uint64 acceptedAt;
        uint64 executableAfter;
        uint256 windowPool;
        uint256 totalPayable;
        uint256 materializedAmount;
        uint16 expectedEntryCount;
        uint16 positiveEntryCount;
        uint16 materializedEntryCount;
        uint32 algorithmVersion;
        bytes32 root;
        bytes32 datasetHash;
        bytes32 commitmentHash;
        bytes32 correctionReasonHash;
        DistributionStatus status;
        bool correctionLocked;
    }

    struct EntryRecord {
        bytes32 distributionId;
        bytes32 windowId;
        bytes32 leafHash;
        bytes32 failureHash;
        bytes32 manualEvidenceHash;
        address recipient;
        address rewardAsset;
        uint256 amount;
        uint64 terminalStartedAt;
        uint64 terminalExpiresAt;
        uint32 version;
        uint16 recipientIndex;
        EntryStatus status;
        ManualSettlementStatus manualSettlementStatus;
    }

    struct EmptyWindowRecord {
        bytes32 windowId;
        bytes32 distributionId;
        uint64 windowStart;
        uint64 windowEnd;
        bytes32 emptyCommitment;
        bytes32 manifestHash;
        bytes32 snapshotBlockHash;
        bytes32 activationContextHash;
        bytes32 evidenceHash;
        bytes32 correctionReasonHash;
        uint256 poolAmount;
        uint256 snapshotBlockNumber;
        uint32 replayVersion;
        uint64 acceptedAt;
        uint64 executableAfter;
        uint32 version;
        uint16 recipientCount;
        bool zeroResult;
        CompdV2Types.EmptyCandidateStatus status;
    }

    /// @dev Six mutually exclusive buckets sum to Vault.holderRewardReserve().
    /// terminalPendingSubset, terminalExpiredSubset and noRecipientEligibleSubset are diagnostics
    /// contained within other buckets and MUST NOT be added to this partition sum.
    struct HolderPartitionTotals {
        uint256 unfinalizedWindowPools;
        uint256 normalReviewPools;
        uint256 emptyReviewPools;
        uint256 finalizedUnpaidLiabilities;
        uint256 finalizedNoRecipientPools;
        uint256 recoveryEligible;
        uint256 terminalPendingSubset;
        uint256 terminalExpiredSubset;
        uint256 noRecipientEligibleSubset;
    }

    struct HolderHistoryEntry {
        bytes32 subjectId;
        bytes32 recordId;
        bytes32 evidenceHash;
        uint64 timestamp;
        uint32 version;
        uint16 recipientIndex;
        uint256 exactAmount;
        HistoryAction action;
        EntryStatus priorEntryStatus;
        EntryStatus resultingEntryStatus;
        CompdV2Types.EmptyCandidateStatus priorEmptyStatus;
        CompdV2Types.EmptyCandidateStatus resultingEmptyStatus;
    }

    error OnlyBoundVault();
    error InvalidComponentIdentity();
    error InvalidHolderTransition();
    error HolderRecordMismatch();
    error HolderHistoryLimit();
    error DuplicateHolderIdentity();

    event DistributionCandidateRecorded(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 indexed version, uint256 poolAmount, uint256 totalPayable, uint64 acceptedAt, uint64 executableAfter, bytes32 root, bytes32 datasetHash, bytes32 commitmentHash);
    event DistributionCandidateCorrected(bytes32 indexed distributionId, uint32 indexed oldVersion, uint32 indexed newVersion, bytes32 oldCommitmentHash, bytes32 newCommitmentHash, bytes32 reasonHash, uint64 acceptedAt, uint64 executableAfter);
    event HolderEntryMaterialized(bytes32 indexed distributionId, uint32 indexed version, uint16 indexed recipientIndex, bytes32 leafHash, address recipient, address rewardAsset, uint256 amount);
    event DistributionFinalized(bytes32 indexed distributionId, uint32 indexed version, uint256 totalPayable, uint16 entryCount);
    event HolderEntryStatusChanged(bytes32 indexed distributionId, uint32 indexed version, uint16 indexed recipientIndex, EntryStatus oldStatus, EntryStatus newStatus, bytes32 evidenceHash);
    event ManualSettlementAvailabilityRecorded(bytes32 indexed distributionId, uint32 indexed version, uint16 indexed recipientIndex, bytes32 evidenceHash);
    event EmptyWindowCandidateRecorded(bytes32 indexed windowId, bytes32 indexed distributionId, uint32 indexed version, uint256 poolAmount, bytes32 commitment, bytes32 evidenceHash, uint64 acceptedAt, uint64 executableAfter);
    event EmptyWindowCandidateCorrected(bytes32 indexed windowId, uint32 indexed oldVersion, uint32 indexed newVersion, bytes32 commitment, bytes32 evidenceHash, bytes32 reasonHash, uint64 acceptedAt, uint64 executableAfter);
    event EmptyWindowFinalized(bytes32 indexed windowId, uint32 indexed version, uint256 poolAmount, bytes32 commitment, bytes32 evidenceHash);
    event NoRecipientPoolRecoveryClassified(bytes32 indexed windowId, uint256 exactAmount, bytes32 evidenceHash);
    event NoRecipientPoolRecovered(bytes32 indexed windowId, uint256 exactAmount, bytes32 evidenceHash);
    event HolderPartitionChanged(bytes32 indexed operationId, bytes32 indexed recordId, bytes32 beforeHash, bytes32 afterHash);
    event HolderPoolAccrued(uint256 indexed runId, bytes32 indexed windowId, bytes32 indexed accrualId, uint256 amount, uint256 resultingWindowPool, uint64 timestamp, uint64 blockNumber);

    // Mutations are Vault-only; timestamps are sampled by the component from block.timestamp.
    function accrueHolderPool(uint256 runId, bytes32 windowId, uint64 windowStart, uint64 windowEnd, uint256 amount, uint256 expectedWindowPoolAfter) external;
    function recordDistributionCandidate(DistributionCandidateInput calldata input) external;
    function correctDistributionCandidate(DistributionCandidateInput calldata replacement, bytes32 reasonHash) external;
    function registerMaterializedEntry(EntryRecord calldata entry) external;
    function finalizeDistribution(bytes32 distributionId, uint32 version, uint256 exactTotal, uint16 exactCount) external;
    function recordAutomaticPayment(bytes32 distributionId, uint32 version, uint16 recipientIndex, bytes32 leafHash) external;
    function recordAutomaticPaymentFailure(bytes32 distributionId, uint32 version, uint16 recipientIndex, bytes32 leafHash, bytes32 revertDataHash) external;
    function recordManualSettlementAvailable(bytes32 distributionId, uint32 version, uint16 recipientIndex, bytes32 leafHash, bytes32 evidenceHash) external;
    function recordManualSettlement(bytes32 distributionId, uint32 version, uint16 recipientIndex, bytes32 leafHash) external;
    function startTerminalLiability(bytes32 distributionId, uint32 version, bytes32 windowId, uint16 recipientIndex, bytes32 leafHash) external;
    function expireTerminalLiability(bytes32 distributionId, uint32 version, bytes32 windowId, uint16 recipientIndex, bytes32 leafHash) external;
    function recordEmptyCandidate(EmptyCandidateInput calldata input) external;
    function correctEmptyCandidate(EmptyCandidateInput calldata replacement, bytes32 reasonHash) external;
    function finalizeEmptyCandidate(bytes32 windowId, uint32 version, uint256 exactPoolAmount) external;
    function classifyNoRecipientPool(bytes32 windowId, uint256 exactAmount) external;
    function recordNoRecipientPoolRecovery(bytes32 windowId, uint256 exactAmount, bytes32 transferEvidenceHash) external;
    function recordExpiredLiabilityRecovery(bytes32 liabilityId, bytes32 transferEvidenceHash) external;

    function distribution(bytes32 distributionId) external view returns (DistributionRecord memory);
    function distributionVersion(bytes32 distributionId, uint32 version) external view returns (DistributionRecord memory);
    function entry(bytes32 distributionId, uint32 version, uint16 recipientIndex) external view returns (EntryRecord memory);
    function emptyWindow(bytes32 windowId) external view returns (EmptyWindowRecord memory);
    function emptyWindowVersion(bytes32 windowId, uint32 version) external view returns (EmptyWindowRecord memory);
    function liabilityId(bytes32 distributionId, uint32 version, bytes32 windowId, uint16 recipientIndex) external pure returns (bytes32);
    function liability(bytes32 liabilityId_) external view returns (EntryRecord memory);
    function noRecipientRecoveryEligible(bytes32 windowId) external view returns (bool eligible, uint256 exactAmount, bool recovered, bytes32 evidenceHash);
    function holderPartitionTotals() external view returns (HolderPartitionTotals memory);
    function globalHolderBlockers() external view returns (uint32 openNormalReviews, uint32 openEmptyReviews, uint32 pendingAutomatic, uint32 failedUnavailable, uint32 finalizedUnpaid, uint32 terminalPending);
    function holderRecordCount(bytes32 subjectId) external view returns (uint32);
    function holderRecordAt(bytes32 subjectId, uint32 index) external view returns (HolderHistoryEntry memory);
}
