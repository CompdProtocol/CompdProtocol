// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ICompdHolderWorkflowV2 as IWorkflow} from "./ICompdHolderWorkflowV2.sol";

interface ICompdHolderWindowIdViewV2 {
    function holderWindowId(uint64 windowStart,uint64 windowEnd) external view returns (bytes32);
}

/// @notice Early size prototype of the canonical Holder pool/candidate workflow component.
/// @dev Vault-bound, no custody, and intentionally not yet wired to the production Vault.
contract CompdHolderWorkflowV2 is IWorkflow {
    bytes32 public constant override COMPONENT_TYPE_ID = keccak256("COMPD_HOLDER_WORKFLOW_V2");
    uint32 public constant override COMPONENT_VERSION = 2;
    uint64 public constant WINDOW_SECONDS = 28_800;
    uint64 public constant REVIEW_SECONDS = 1_800;
    uint16 public constant MAX_RECIPIENTS = 30;

    address public override vault;
    mapping(bytes32 => uint256) private _windowPool;
    mapping(bytes32 => uint64) private _windowStart;
    mapping(bytes32 => uint64) private _windowEnd;
    mapping(uint256 => bool) private _runUsed;
    mapping(bytes32 => bool) private _accrualUsed;
    mapping(bytes32 => DistributionRecord) private _currentDistribution;
    mapping(bytes32 => mapping(uint32 => DistributionRecord)) private _distributionVersions;
    mapping(bytes32 => EmptyWindowRecord) private _currentEmpty;
    mapping(bytes32 => mapping(uint32 => EmptyWindowRecord)) private _emptyVersions;
    mapping(bytes32 => uint256) private _noRecipientRecoveryAmount;
    mapping(bytes32 => bytes32) private _noRecipientRecoveryEvidence;
    mapping(bytes32 => bool) private _noRecipientRecovered;
    mapping(bytes32 => HistoryEntry[]) private _history;

    uint256 private _unfinalized;
    uint256 private _normalReview;
    uint256 private _emptyReview;
    uint256 private _finalizedNoRecipient;
    uint256 private _noRecipientEligible;
    uint32 private _openNormalReviews;
    uint32 private _openEmptyReviews;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyBoundVault();
        _;
    }

    constructor(address vault_) {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidWorkflowTransition();
        vault = vault_;
    }

    function accrueHolderPool(uint256 runId,bytes32 windowId,uint64 start,uint64 end,uint256 amount,uint256 expectedAfter)
        external override onlyVault
    {
        if (runId == 0 || _runUsed[runId] || amount == 0 || windowId == bytes32(0) || end <= start
            || end - start != WINDOW_SECONDS || start % WINDOW_SECONDS != 0 || end % WINDOW_SECONDS != 0
            || block.timestamp < start || block.timestamp >= end
            || ICompdHolderWindowIdViewV2(vault).holderWindowId(start,end) != windowId) {
            revert InvalidWorkflowTransition();
        }
        uint256 afterPool = _windowPool[windowId] + amount;
        if (afterPool != expectedAfter) revert WorkflowRecordMismatch();
        bytes32 accrualId = keccak256(abi.encode(address(this),vault,runId,windowId,amount));
        if (_accrualUsed[accrualId]) revert DuplicateWorkflowIdentity();
        _runUsed[runId] = true;
        _accrualUsed[accrualId] = true;
        _windowPool[windowId] = afterPool;
        _windowStart[windowId] = start;
        _windowEnd[windowId] = end;
        _unfinalized += amount;
        _append(windowId,amount,1,HistoryAction.ACCRUED);
        emit HolderPoolAccrued(runId,windowId,accrualId,amount,afterPool,uint64(block.timestamp),uint64(block.number));
    }

    function recordDistributionCandidate(DistributionCandidateInput calldata i) external override onlyVault {
        if (i.distributionId == bytes32(0) || i.version != 1 || i.windowId == bytes32(0)
            || i.rewardAsset == address(0) || i.root == bytes32(0) || i.datasetHash == bytes32(0)
            || i.commitmentHash == bytes32(0) || i.expectedEntryCount == 0 || i.expectedEntryCount > MAX_RECIPIENTS
            || i.positiveEntryCount == 0 || i.positiveEntryCount > i.expectedEntryCount
            || i.windowStart >= i.windowEnd || i.windowEnd - i.windowStart != WINDOW_SECONDS
            || i.windowStart % WINDOW_SECONDS != 0 || i.windowEnd % WINDOW_SECONDS != 0
            || block.timestamp < i.windowEnd || _currentDistribution[i.distributionId].status != DistributionStatus.NONE
            || _windowPool[i.windowId] == 0 || _windowPool[i.windowId] != i.windowPool
            || i.totalPayable != i.windowPool || _windowStart[i.windowId] != i.windowStart
            || _windowEnd[i.windowId] != i.windowEnd
            || ICompdHolderWindowIdViewV2(vault).holderWindowId(i.windowStart,i.windowEnd) != i.windowId) {
            revert InvalidWorkflowTransition();
        }
        DistributionRecord memory d = _makeDistribution(i,uint64(block.timestamp));
        _currentDistribution[i.distributionId] = d;
        _distributionVersions[i.distributionId][1] = d;
        delete _windowPool[i.windowId];
        _unfinalized -= i.windowPool;
        _normalReview += i.windowPool;
        ++_openNormalReviews;
        _append(i.distributionId,i.windowPool,1,HistoryAction.CANDIDATE_OPENED);
        emit DistributionCandidateRecorded(i.distributionId,i.windowId,1,i.windowPool,d.acceptedAt,d.executableAfter,i.root,i.datasetHash,i.commitmentHash);
    }

    function correctDistributionCandidate(DistributionCandidateInput calldata i,bytes32 reasonHash) external override onlyVault {
        DistributionRecord storage old = _currentDistribution[i.distributionId];
        if (old.status != DistributionStatus.REVIEW_PENDING || old.correctionLocked || reasonHash == bytes32(0)
            || old.currentVersion == type(uint32).max || i.version != old.currentVersion + 1
            || i.windowId != old.windowId || i.windowStart != old.windowStart || i.windowEnd != old.windowEnd
            || i.rewardAsset != old.rewardAsset || i.windowPool != old.windowPool || i.totalPayable != old.totalPayable
            || i.expectedEntryCount == 0 || i.expectedEntryCount > MAX_RECIPIENTS || i.positiveEntryCount == 0
            || i.positiveEntryCount > i.expectedEntryCount || i.root == bytes32(0) || i.datasetHash == bytes32(0)
            || i.commitmentHash == bytes32(0)) revert InvalidWorkflowTransition();
        uint32 oldVersion = old.currentVersion;
        DistributionRecord memory next = _makeDistribution(i,uint64(block.timestamp));
        next.correctionReasonHash = reasonHash;
        _currentDistribution[i.distributionId] = next;
        _distributionVersions[i.distributionId][i.version] = next;
        _append(i.distributionId,i.windowPool,i.version,HistoryAction.CANDIDATE_CORRECTED);
        emit DistributionCandidateCorrected(i.distributionId,oldVersion,i.version,reasonHash,next.acceptedAt,next.executableAfter);
    }

    function finalizeWorkflowDistribution(bytes32 id,uint32 version,uint256 amount,uint16 count) external override onlyVault {
        DistributionRecord storage d = _currentDistribution[id];
        if (d.status != DistributionStatus.REVIEW_PENDING || d.currentVersion != version
            || block.timestamp < d.executableAfter || d.totalPayable != amount || d.windowPool != amount
            || d.expectedEntryCount != count) revert InvalidWorkflowTransition();
        d.status = DistributionStatus.FINALIZED;
        _distributionVersions[id][version] = d;
        _normalReview -= amount;
        --_openNormalReviews;
        _append(id,amount,version,HistoryAction.DISTRIBUTION_FINALIZED);
        emit DistributionWorkflowFinalized(id,version,amount,count);
    }

    function recordEmptyCandidate(EmptyCandidateInput calldata i) external override onlyVault {
        if (i.windowId == bytes32(0) || i.distributionId == bytes32(0) || i.version != 1
            || i.emptyCommitment == bytes32(0) || i.manifestHash == bytes32(0) || i.snapshotBlockHash == bytes32(0)
            || i.activationContextHash == bytes32(0) || i.evidenceHash == bytes32(0) || i.correctionReasonHash != bytes32(0)
            || i.poolAmount == 0 || i.snapshotBlockNumber == 0 || i.replayVersion == 0 || i.recipientCount != 0 || !i.zeroResult
            || i.windowEnd <= i.windowStart || i.windowEnd - i.windowStart != WINDOW_SECONDS
            || i.windowStart % WINDOW_SECONDS != 0 || block.timestamp < i.windowEnd
            || _currentEmpty[i.windowId].status != EmptyStatus.NONE
            || _windowPool[i.windowId] != i.poolAmount || _windowStart[i.windowId] != i.windowStart
            || _windowEnd[i.windowId] != i.windowEnd
            || ICompdHolderWindowIdViewV2(vault).holderWindowId(i.windowStart,i.windowEnd) != i.windowId) {
            revert InvalidWorkflowTransition();
        }
        EmptyWindowRecord memory e = _makeEmpty(i,uint64(block.timestamp));
        _currentEmpty[i.windowId] = e;
        _emptyVersions[i.windowId][i.version] = e;
        delete _windowPool[i.windowId];
        _unfinalized -= i.poolAmount;
        _emptyReview += i.poolAmount;
        ++_openEmptyReviews;
        _append(i.windowId,i.poolAmount,i.version,HistoryAction.EMPTY_OPENED);
        emit EmptyCandidateRecorded(i.windowId,i.version,i.poolAmount,e.executableAfter);
    }

    function correctEmptyCandidate(EmptyCandidateInput calldata i,bytes32 reasonHash) external override onlyVault {
        EmptyWindowRecord storage old = _currentEmpty[i.windowId];
        if (old.status != EmptyStatus.REVIEW_PENDING || reasonHash == bytes32(0)
            || old.version == type(uint32).max || i.version != old.version + 1
            || i.distributionId != old.distributionId || i.windowStart != old.windowStart || i.windowEnd != old.windowEnd
            || i.poolAmount != old.poolAmount || i.emptyCommitment == bytes32(0) || i.manifestHash == bytes32(0)
            || i.snapshotBlockHash == bytes32(0) || i.activationContextHash == bytes32(0) || i.evidenceHash == bytes32(0)
            || i.correctionReasonHash != bytes32(0) || i.snapshotBlockNumber == 0 || i.replayVersion == 0
            || i.recipientCount != 0 || !i.zeroResult) {
            revert InvalidWorkflowTransition();
        }
        EmptyWindowRecord memory next = _makeEmpty(i,uint64(block.timestamp));
        next.correctionReasonHash = reasonHash;
        uint32 oldVersion = old.version;
        _emptyVersions[i.windowId][oldVersion].status = EmptyStatus.SUPERSEDED;
        _currentEmpty[i.windowId] = next;
        _emptyVersions[i.windowId][i.version] = next;
        _append(i.windowId,i.poolAmount,i.version,HistoryAction.EMPTY_CORRECTED);
        emit EmptyCandidateRecorded(i.windowId,i.version,i.poolAmount,next.executableAfter);
    }

    function finalizeEmptyCandidate(bytes32 windowId,uint32 version,uint256 exactAmount) external override onlyVault {
        EmptyWindowRecord storage e = _currentEmpty[windowId];
        if (e.status != EmptyStatus.REVIEW_PENDING || e.version != version || block.timestamp < e.executableAfter
            || e.poolAmount != exactAmount) revert InvalidWorkflowTransition();
        e.status = EmptyStatus.FINALIZED_NO_RECIPIENT;
        _emptyVersions[windowId][version] = e;
        _emptyReview -= exactAmount;
        _finalizedNoRecipient += exactAmount;
        --_openEmptyReviews;
        _append(windowId,exactAmount,version,HistoryAction.EMPTY_FINALIZED);
        emit EmptyCandidateFinalized(windowId,version,exactAmount);
    }

    function classifyNoRecipientPool(bytes32 windowId,uint256 exactAmount) external override onlyVault {
        EmptyWindowRecord storage e = _currentEmpty[windowId];
        if (e.status != EmptyStatus.FINALIZED_NO_RECIPIENT || exactAmount == 0 || e.poolAmount != exactAmount
            || _noRecipientRecoveryAmount[windowId] != 0) revert InvalidWorkflowTransition();
        e.status = EmptyStatus.RECOVERY_ELIGIBLE;
        _emptyVersions[windowId][e.version] = e;
        _finalizedNoRecipient -= exactAmount;
        _noRecipientEligible += exactAmount;
        _noRecipientRecoveryAmount[windowId] = exactAmount;
        _append(windowId,exactAmount,e.version,HistoryAction.NO_RECIPIENT_ELIGIBLE);
        emit NoRecipientRecoveryClassified(windowId,exactAmount);
    }

    function recordNoRecipientPoolRecovery(bytes32 windowId,uint256 exactAmount,bytes32 evidenceHash) external override onlyVault {
        EmptyWindowRecord storage e = _currentEmpty[windowId];
        if (e.status != EmptyStatus.RECOVERY_ELIGIBLE || _noRecipientRecovered[windowId]
            || _noRecipientRecoveryAmount[windowId] != exactAmount || exactAmount == 0 || evidenceHash == bytes32(0)) {
            revert InvalidWorkflowTransition();
        }
        _noRecipientEligible -= exactAmount;
        _noRecipientRecovered[windowId] = true;
        _noRecipientRecoveryEvidence[windowId] = evidenceHash;
        e.status = EmptyStatus.RECOVERED;
        _emptyVersions[windowId][e.version] = e;
        _append(windowId,exactAmount,e.version,HistoryAction.NO_RECIPIENT_RECOVERED);
        emit NoRecipientPoolRecovered(windowId,exactAmount,evidenceHash);
    }

    function distribution(bytes32 id) external view override returns (DistributionRecord memory) { return _currentDistribution[id]; }
    function distributionVersion(bytes32 id,uint32 version) external view override returns (DistributionRecord memory) { return _distributionVersions[id][version]; }
    function emptyWindow(bytes32 id) external view override returns (EmptyWindowRecord memory) { return _currentEmpty[id]; }
    function emptyWindowVersion(bytes32 id,uint32 version) external view override returns (EmptyWindowRecord memory) { return _emptyVersions[id][version]; }
    function noRecipientRecoveryEligible(bytes32 id) external view override returns (bool,uint256,bool,bytes32) {
        return (_noRecipientRecoveryAmount[id] != 0 && !_noRecipientRecovered[id],_noRecipientRecoveryAmount[id],_noRecipientRecovered[id],_noRecipientRecoveryEvidence[id]);
    }

    function windowPool(bytes32 id) external view override returns (uint256) { return _windowPool[id]; }
    function sourcePartitions() external view override returns (SourcePartitions memory) {
        return SourcePartitions(_unfinalized,_normalReview,_emptyReview,_finalizedNoRecipient,_noRecipientEligible,_openNormalReviews,_openEmptyReviews);
    }
    function historyCount(bytes32 id) external view override returns (uint32) { return uint32(_history[id].length); }
    function historyAt(bytes32 id,uint32 index) external view override returns (HistoryEntry memory) { return _history[id][index]; }

    function _makeDistribution(DistributionCandidateInput calldata i,uint64 acceptedAt) private pure returns (DistributionRecord memory d) {
        d = DistributionRecord(i.distributionId,i.windowId,i.windowStart,i.windowEnd,i.rewardAsset,i.version,acceptedAt,
            acceptedAt + REVIEW_SECONDS,i.windowPool,i.totalPayable,i.expectedEntryCount,i.positiveEntryCount,
            i.algorithmVersion,i.root,i.datasetHash,i.commitmentHash,bytes32(0),DistributionStatus.REVIEW_PENDING,false);
    }
    function _makeEmpty(EmptyCandidateInput calldata i,uint64 acceptedAt) private pure returns (EmptyWindowRecord memory e) {
        e = EmptyWindowRecord({
            windowId: i.windowId,
            distributionId: i.distributionId,
            windowStart: i.windowStart,
            windowEnd: i.windowEnd,
            emptyCommitment: i.emptyCommitment,
            manifestHash: i.manifestHash,
            snapshotBlockHash: i.snapshotBlockHash,
            activationContextHash: i.activationContextHash,
            evidenceHash: i.evidenceHash,
            correctionReasonHash: i.correctionReasonHash,
            poolAmount: i.poolAmount,
            snapshotBlockNumber: i.snapshotBlockNumber,
            replayVersion: i.replayVersion,
            acceptedAt: acceptedAt,
            executableAfter: acceptedAt + REVIEW_SECONDS,
            version: i.version,
            recipientCount: i.recipientCount,
            zeroResult: i.zeroResult,
            status: EmptyStatus.REVIEW_PENDING
        });
    }
    function _append(bytes32 subject,uint256 amount,uint32 version,HistoryAction action) private {
        _history[subject].push(HistoryEntry(subject,bytes32(0),uint64(block.timestamp),version,amount,action));
    }
}
