// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ICompdVaultBoundComponentV2} from "./ICompdVaultBoundComponentV2.sol";

interface ICompdHolderWorkflowV2 is ICompdVaultBoundComponentV2 {
    enum DistributionStatus { NONE, REVIEW_PENDING, FINALIZED }
    // Preserve frozen CompdV2Types.EmptyCandidateStatus ordinals, including SUPERSEDED.
    enum EmptyStatus { NONE, REVIEW_PENDING, FINALIZED_NO_RECIPIENT, SUPERSEDED, RECOVERY_ELIGIBLE, RECOVERED }
    enum HistoryAction { ACCRUED, CANDIDATE_OPENED, CANDIDATE_CORRECTED, DISTRIBUTION_FINALIZED, EMPTY_OPENED, EMPTY_CORRECTED, EMPTY_FINALIZED, NO_RECIPIENT_ELIGIBLE, NO_RECIPIENT_RECOVERED }

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
        uint16 expectedEntryCount;
        uint16 positiveEntryCount;
        uint32 algorithmVersion;
        bytes32 root;
        bytes32 datasetHash;
        bytes32 commitmentHash;
        bytes32 correctionReasonHash;
        DistributionStatus status;
        bool correctionLocked;
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
        EmptyStatus status;
    }

    struct SourcePartitions {
        uint256 unfinalizedWindowPools;
        uint256 normalReviewPools;
        uint256 emptyReviewPools;
        uint256 finalizedNoRecipientPools;
        uint256 noRecipientRecoveryEligible;
        uint32 openNormalReviews;
        uint32 openEmptyReviews;
    }

    struct HistoryEntry {
        bytes32 subjectId;
        bytes32 evidenceHash;
        uint64 timestamp;
        uint32 version;
        uint256 amount;
        HistoryAction action;
    }

    error OnlyBoundVault();
    error InvalidWorkflowTransition();
    error WorkflowRecordMismatch();
    error DuplicateWorkflowIdentity();

    event HolderPoolAccrued(uint256 indexed runId, bytes32 indexed windowId, bytes32 indexed accrualId, uint256 amount, uint256 resultingWindowPool, uint64 timestamp, uint64 blockNumber);
    event DistributionCandidateRecorded(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 indexed version, uint256 poolAmount, uint64 acceptedAt, uint64 executableAfter, bytes32 root, bytes32 datasetHash, bytes32 commitmentHash);
    event DistributionCandidateCorrected(bytes32 indexed distributionId, uint32 indexed oldVersion, uint32 indexed newVersion, bytes32 reasonHash, uint64 acceptedAt, uint64 executableAfter);
    event DistributionWorkflowFinalized(bytes32 indexed distributionId, uint32 indexed version, uint256 amount, uint16 entryCount);
    event EmptyCandidateRecorded(bytes32 indexed windowId, uint32 indexed version, uint256 poolAmount, uint64 executableAfter);
    event EmptyCandidateFinalized(bytes32 indexed windowId, uint32 indexed version, uint256 poolAmount);
    event NoRecipientRecoveryClassified(bytes32 indexed windowId, uint256 exactAmount);
    event NoRecipientPoolRecovered(bytes32 indexed windowId, uint256 exactAmount, bytes32 evidenceHash);

    function accrueHolderPool(uint256,bytes32,uint64,uint64,uint256,uint256) external;
    function recordDistributionCandidate(DistributionCandidateInput calldata) external;
    function correctDistributionCandidate(DistributionCandidateInput calldata,bytes32) external;
    function finalizeWorkflowDistribution(bytes32,uint32,uint256,uint16) external;
    function recordEmptyCandidate(EmptyCandidateInput calldata) external;
    function correctEmptyCandidate(EmptyCandidateInput calldata,bytes32) external;
    function finalizeEmptyCandidate(bytes32,uint32,uint256) external;
    function classifyNoRecipientPool(bytes32,uint256) external;
    function recordNoRecipientPoolRecovery(bytes32,uint256,bytes32) external;

    function distribution(bytes32) external view returns (DistributionRecord memory);
    function distributionVersion(bytes32,uint32) external view returns (DistributionRecord memory);
    function emptyWindow(bytes32) external view returns (EmptyWindowRecord memory);
    function emptyWindowVersion(bytes32,uint32) external view returns (EmptyWindowRecord memory);
    function noRecipientRecoveryEligible(bytes32) external view returns (bool,uint256,bool,bytes32);
    /// @notice Current canonical unfinalized pool for a window. The Vault uses this
    ///         to derive the post-accrual expectation without keeping a duplicate ledger.
    function windowPool(bytes32) external view returns (uint256);
    function sourcePartitions() external view returns (SourcePartitions memory);
    function historyCount(bytes32) external view returns (uint32);
    function historyAt(bytes32,uint32) external view returns (HistoryEntry memory);
}
