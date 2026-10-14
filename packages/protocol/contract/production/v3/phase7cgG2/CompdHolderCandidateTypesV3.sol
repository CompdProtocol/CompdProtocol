// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

library CompdHolderCandidateTypesV3 {
    struct Candidate {
        bytes32 distributionId; bytes32 windowId; uint64 windowStart; uint64 windowEnd;
        address rewardAsset; uint256 windowPool; uint256 payableTotal; uint16 recipientCount;
        bytes32 root; bytes32 datasetHash; uint32 algorithmVersion; uint32 version;
        uint64 acceptedAt; uint64 executableAfter; bool empty; bool finalized;
        uint16 materializedCount; uint256 materializedTotal;
    }
    struct Leaf {
        bytes32 domainSeparator; bytes32 distributionId; uint32 commitmentVersion;
        bytes32 windowId; uint64 windowStart; uint64 windowEnd; address rewardAsset;
        uint256 windowPool; uint256 finalizedTotalPayable; uint16 recipientIndex;
        address recipient; uint256 amount; bytes32 datasetHash; uint32 algorithmVersion;
    }
    struct CandidateEvidence {
        bytes32 manifestHash; bytes32 entriesHash; uint256 snapshotBlock;
        bytes32 snapshotBlockHash; uint256 sourceStartBlock; uint256 closeBlock;
        bytes32 closeBlockHash; uint256 finalityBlock; bytes32 finalityBlockHash;
        uint32 exclusionSetVersion; bytes32 exclusionSetHash; bytes32 replayCodeHash;
    }
    struct EmptyEvidence {
        bytes32 manifestHash; bytes32 entriesHash; uint256 snapshotBlock;
        bytes32 snapshotBlockHash; uint256 sourceStartBlock; uint256 closeBlock;
        bytes32 closeBlockHash; uint256 finalityBlock; bytes32 finalityBlockHash;
        uint32 exclusionSetVersion; bytes32 exclusionSetHash; bytes32 replayCodeHash;
    }
}
