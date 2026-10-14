// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICompdHolderRewardsDistributor {
    enum CandidateStatus {
        NONE,
        MATERIALIZING,
        REVIEW,
        EXECUTABLE,
        EXECUTABLE_LOCKED
    }

    struct CandidateInput {
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
    }

    struct ReplacementInput {
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

    function DISTRIBUTION_FINALIZER_ROLE() external view returns (bytes32);
    function automationExecutor() external view returns (address);
    function submitCandidate(CandidateInput calldata candidate) external;
    function correctCandidate(bytes32 distributionId, ReplacementInput calldata replacement) external;
    function materializeLeaf(bytes32 distributionId, Leaf calldata leaf, bytes32[] calldata proof) external;
    function finalizeCandidate(bytes32 distributionId) external;
    function executeProof(bytes32 distributionId, Leaf calldata leaf, bytes32[] calldata proof)
        external
        returns (bool paid);
    function candidate(bytes32 distributionId) external view returns (CommitmentView memory);
    function rootByVersion(bytes32 distributionId, uint32 version) external view returns (bytes32);
    function datasetHashByVersion(bytes32 distributionId, uint32 version) external view returns (bytes32);
    function commitmentHashByVersion(bytes32 distributionId, uint32 version) external view returns (bytes32);
    function correctionReasonHashByVersion(bytes32 distributionId, uint32 version) external view returns (bytes32);
    function materializedLeafHash(bytes32 distributionId, uint32 version, uint16 index) external view returns (bytes32);
    function hashLeaf(Leaf calldata leaf) external pure returns (bytes32);
    function hashPadding(bytes32 domainSeparator, bytes32 distributionId, uint32 version, uint16 index)
        external
        pure
        returns (bytes32);
    function hashNode(bytes32 left, bytes32 right) external pure returns (bytes32);
}
