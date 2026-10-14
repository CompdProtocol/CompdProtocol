// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";

interface ICompdHolderRewardsDistributorV2 {
    enum CandidateStatus { NONE, MATERIALIZING, REVIEW, EXECUTABLE, EXECUTABLE_LOCKED }
    struct NormalCandidate {
        bytes32 domainSeparator;
        bytes32 distributionId;
        uint32 commitmentVersion;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 finalizedTotalPayable;
        uint16 recipientCount;
        uint16 positiveEntryCount;
        bytes32 root;
        bytes32 datasetHash;
        uint32 algorithmVersion;
        bytes32 commitmentHash;
    }
    struct NormalReplacement {
        uint32 commitmentVersion;
        uint16 recipientCount;
        uint16 positiveEntryCount;
        bytes32 root;
        bytes32 datasetHash;
        uint32 algorithmVersion;
        bytes32 correctionReasonHash;
    }
    struct Leaf {
        bytes32 domainSeparator;
        bytes32 distributionId;
        uint32 commitmentVersion;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 finalizedTotalPayable;
        uint16 recipientIndex;
        address recipient;
        uint256 amount;
        bytes32 datasetHash;
        uint32 algorithmVersion;
    }
    struct EmptyCandidate {
        bytes32 windowId;
        bytes32 distributionId;
        uint64 windowStart;
        uint64 windowEnd;
        uint256 poolAmount;
        uint32 version;
        bytes32 manifestHash;
        uint32 replayVersion;
        uint256 snapshotBlockNumber;
        bytes32 snapshotBlockHash;
        bytes32 activationContextHash;
        bool zeroResult;
        bytes32 evidenceHash;
        bytes32 commitmentHash;
        bytes32 correctionReasonHash;
    }
    struct EmptyReplacement {
        uint32 version;
        bytes32 manifestHash;
        uint32 replayVersion;
        uint256 snapshotBlockNumber;
        bytes32 snapshotBlockHash;
        bytes32 activationContextHash;
        bytes32 evidenceHash;
        bytes32 commitmentHash;
        bytes32 correctionReasonHash;
    }
    struct CommitmentView {
        bytes32 domainSeparator;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 finalizedTotalPayable;
        uint16 recipientCount;
        uint16 positiveEntryCount;
        bytes32 root;
        bytes32 datasetHash;
        uint32 algorithmVersion;
        uint32 commitmentVersion;
        uint64 acceptedAt;
        uint64 executableAfter;
        uint16 verifiedLeafCount;
        uint16 materializedEntryCount;
        uint256 materializedAmount;
        CandidateStatus status;
    }
    struct EmptyCandidateView {
        bytes32 windowId;
        bytes32 distributionId;
        uint64 windowStart;
        uint64 windowEnd;
        uint256 poolAmount;
        uint32 version;
        bytes32 manifestHash;
        uint32 replayVersion;
        uint256 snapshotBlockNumber;
        bytes32 snapshotBlockHash;
        bytes32 activationContextHash;
        uint16 recipientCount;
        bool zeroResult;
        bytes32 evidenceHash;
        bytes32 commitmentHash;
        bytes32 correctionReasonHash;
        uint64 acceptedAt;
        uint64 executableAfter;
        CompdV2Types.EmptyCandidateStatus status;
    }

    function vault() external view returns (address);
    function domainSeparator() external view returns (bytes32);
    function windowId(uint64 windowStart, uint64 windowEnd) external view returns (bytes32);
    function distributionId(bytes32 windowId_) external view returns (bytes32);
    function submitCandidate(NormalCandidate calldata candidate) external;
    function correctCandidate(bytes32 distributionId_, NormalReplacement calldata replacement) external;
    function materializeLeaf(bytes32 distributionId_, Leaf calldata leaf, bytes32[] calldata proof) external;
    function finalizeCandidate(bytes32 distributionId_) external;
    function executeProof(bytes32 distributionId_, Leaf calldata leaf, bytes32[] calldata proof)
        external returns (bool paid);
    function submitEmptyCandidate(EmptyCandidate calldata candidate) external;
    function correctEmptyCandidate(bytes32 windowId_, EmptyReplacement calldata replacement) external;
    function finalizeEmptyCandidate(bytes32 windowId_) external;
    function startTerminalLiability(bytes32 distributionId_, uint16 recipientIndex) external;
    function candidate(bytes32 distributionId_) external view returns (CommitmentView memory);
    function emptyCandidate(bytes32 windowId_) external view returns (EmptyCandidateView memory);
    function rootByVersion(bytes32 distributionId_, uint32 version) external view returns (bytes32);
    function datasetHashByVersion(bytes32 distributionId_, uint32 version) external view returns (bytes32);
    function commitmentHashByVersion(bytes32 distributionId_, uint32 version) external view returns (bytes32);
    function correctionReasonHashByVersion(bytes32 distributionId_, uint32 version) external view returns (bytes32);
    function materializedLeafHash(bytes32 distributionId_, uint32 version, uint16 index) external view returns (bytes32);
    function hashLeaf(Leaf calldata leaf) external pure returns (bytes32);
    function hashPadding(bytes32 domainSeparator_, bytes32 distributionId_, uint32 version, uint16 index)
        external pure returns (bytes32);
    function hashEmptyCommitment(EmptyCandidate calldata candidate) external pure returns (bytes32);
    function hashNode(bytes32 left, bytes32 right) external pure returns (bytes32);
    function emergencyLifecycle() external view returns (CompdV2Types.Lifecycle);
    function paymentStatus(bytes32 distributionId_, uint32 version, uint16 index)
        external view returns (bool materialized, bool paid, bool failed);
}
