// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";
import {ICompdHolderAccountingV2 as IHolder} from "./ICompdHolderAccountingV2.sol";

interface ICompdHolderWindowVaultV2 {
    function holderWindowId(uint64 windowStart, uint64 windowEnd) external view returns (bytes32);
}

/// @notice Canonical detailed Holder workflow state; deliberately holds no assets.
/// @dev `vault` is constructor-set storage with no setter, keeping runtime code hash address-independent.
contract CompdHolderAccountingV2 is IHolder {
    bytes32 public constant override COMPONENT_TYPE_ID = keccak256("COMPD_HOLDER_ACCOUNTING_V2");
    uint32 public constant override COMPONENT_VERSION = 2;
    uint64 public constant WINDOW_SECONDS = 28_800;
    uint64 public constant REVIEW_SECONDS = 1_800;
    uint64 public constant TERMINAL_GRACE_SECONDS = 7_776_000;
    uint16 public constant MAX_RECIPIENTS = 30;

    address public override vault;

    mapping(bytes32 => uint256) private _windowPool;
    mapping(bytes32 => uint64) private _windowStart;
    mapping(bytes32 => uint64) private _windowEnd;
    mapping(uint256 => bool) private _runAccrued;
    mapping(bytes32 => bool) private _accrualUsed;
    mapping(bytes32 => DistributionRecord) private _distributions;
    mapping(bytes32 => mapping(uint32 => DistributionRecord)) private _distributionVersions;
    mapping(bytes32 => mapping(uint32 => mapping(uint16 => EntryRecord))) private _entries;
    mapping(bytes32 => EmptyWindowRecord) private _emptyWindows;
    mapping(bytes32 => mapping(uint32 => EmptyWindowRecord)) private _emptyVersions;
    mapping(bytes32 => EntryRecord) private _liabilities;
    mapping(bytes32 => bool) private _liabilityRecovered;
    mapping(bytes32 => uint256) private _noRecipientEligibleAmount;
    mapping(bytes32 => bytes32) private _noRecipientEvidence;
    mapping(bytes32 => bool) private _noRecipientRecovered;
    mapping(bytes32 => HolderHistoryEntry[]) private _history;

    uint256 private _unfinalized;
    uint256 private _normalReview;
    uint256 private _emptyReview;
    uint256 private _finalizedUnpaid;
    uint256 private _finalizedNoRecipient;
    uint256 private _recoveryEligible;
    uint256 private _terminalPendingSubset;
    uint256 private _terminalExpiredSubset;
    uint256 private _noRecipientEligibleSubset;
    uint32 private _openNormalReviews;
    uint32 private _openEmptyReviews;
    uint32 private _pendingAutomatic;
    uint32 private _failedUnavailable;
    uint32 private _finalizedUnpaidRecords;
    uint32 private _terminalPendingRecords;
    uint64 private _historySequence;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyBoundVault();
        _;
    }

    constructor(address vault_) {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidComponentIdentity();
        vault = vault_;
    }

    function accrueHolderPool(
        uint256 runId,
        bytes32 windowId,
        uint64 windowStart,
        uint64 windowEnd,
        uint256 amount,
        uint256 expectedWindowPoolAfter
    ) external override onlyVault {
        if (runId == 0 || amount == 0 || windowId == bytes32(0) || windowStart >= windowEnd || windowEnd - windowStart != WINDOW_SECONDS
            || windowStart % WINDOW_SECONDS != 0 || windowEnd % WINDOW_SECONDS != 0
            || block.timestamp < windowStart || block.timestamp >= windowEnd
            || ICompdHolderWindowVaultV2(vault).holderWindowId(windowStart, windowEnd) != windowId
            || _runAccrued[runId]) revert InvalidHolderTransition();
        uint256 afterPool = _windowPool[windowId] + amount;
        if (afterPool != expectedWindowPoolAfter) revert HolderRecordMismatch();
        bytes32 accrualId = keccak256(abi.encode(address(this), vault, runId, windowId, amount));
        if (_accrualUsed[accrualId]) revert DuplicateHolderIdentity();
        uint64 now64 = _timestamp();
        _accrualUsed[accrualId] = true;
        _runAccrued[runId] = true;
        _windowPool[windowId] = afterPool;
        _windowStart[windowId] = windowStart;
        _windowEnd[windowId] = windowEnd;
        _unfinalized += amount;
        emit HolderPoolAccrued(runId, windowId, accrualId, amount, afterPool, now64, uint64(block.number));
        _assertPartition();
    }

    function recordDistributionCandidate(DistributionCandidateInput calldata input) external override onlyVault {
        if (input.version != 1 || input.distributionId == bytes32(0) || input.totalPayable == 0
            || input.expectedEntryCount == 0 || input.expectedEntryCount > MAX_RECIPIENTS
            || input.root == bytes32(0) || input.datasetHash == bytes32(0) || input.commitmentHash == bytes32(0)
            || input.windowStart >= input.windowEnd || input.windowEnd - input.windowStart != WINDOW_SECONDS
            || input.windowStart % WINDOW_SECONDS != 0 || input.windowEnd % WINDOW_SECONDS != 0
            || input.rewardAsset == address(0) || block.timestamp < input.windowEnd
            || ICompdHolderWindowVaultV2(vault).holderWindowId(input.windowStart, input.windowEnd) != input.windowId
            || _windowPool[input.windowId] == 0 || _windowPool[input.windowId] != input.windowPool
            || input.totalPayable != input.windowPool || _windowStart[input.windowId] != input.windowStart
            || _windowEnd[input.windowId] != input.windowEnd) revert InvalidHolderTransition();
        DistributionRecord storage current = _distributions[input.distributionId];
        if (current.status != DistributionStatus.NONE) revert DuplicateHolderIdentity();
        uint64 acceptedAt = _timestamp();
        DistributionRecord memory record = _makeDistribution(input, acceptedAt);
        _distributions[input.distributionId] = record;
        _distributionVersions[input.distributionId][1] = record;
        _windowPool[input.windowId] = 0;
        _unfinalized -= input.windowPool;
        _normalReview += input.windowPool;
        ++_openNormalReviews;
        _append(input.distributionId, bytes32(0), bytes32(0), input.version, 0, input.windowPool,
            HistoryAction.CANDIDATE_OPENED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit DistributionCandidateRecorded(input.distributionId, input.windowId, 1, input.windowPool,
            input.totalPayable, acceptedAt, record.executableAfter, input.root, input.datasetHash, input.commitmentHash);
        _assertPartition();
    }

    function correctDistributionCandidate(DistributionCandidateInput calldata replacement, bytes32 reasonHash)
        external override onlyVault
    {
        DistributionRecord storage old = _distributions[replacement.distributionId];
        uint32 oldVersion = old.currentVersion;
        if (old.status == DistributionStatus.NONE || old.correctionLocked || reasonHash == bytes32(0)
            || oldVersion == type(uint32).max || replacement.version != oldVersion + 1
            || replacement.windowId != old.windowId || replacement.windowPool != old.windowPool
            || replacement.totalPayable != old.totalPayable || replacement.windowStart != old.windowStart
            || replacement.windowEnd != old.windowEnd || replacement.rewardAsset != old.rewardAsset
            || replacement.expectedEntryCount == 0 || replacement.expectedEntryCount > MAX_RECIPIENTS
            || replacement.root == bytes32(0) || replacement.datasetHash == bytes32(0)
            || replacement.commitmentHash == bytes32(0)) revert InvalidHolderTransition();
        if (old.status == DistributionStatus.FINALIZED) {
            _finalizedUnpaid -= old.totalPayable;
            _finalizedUnpaidRecords -= old.materializedEntryCount;
            _pendingAutomatic -= old.materializedEntryCount;
            _normalReview += old.totalPayable;
            old.status = DistributionStatus.REVIEW_PENDING;
            ++_openNormalReviews;
        }
        uint64 acceptedAt = _timestamp();
        DistributionRecord memory next = _makeDistribution(replacement, acceptedAt);
        next.correctionReasonHash = reasonHash;
        _distributions[replacement.distributionId] = next;
        _distributionVersions[replacement.distributionId][replacement.version] = next;
        _append(replacement.distributionId, bytes32(0), reasonHash, replacement.version, 0,
            replacement.windowPool, HistoryAction.CANDIDATE_CORRECTED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit DistributionCandidateCorrected(replacement.distributionId, oldVersion, replacement.version,
            old.commitmentHash, replacement.commitmentHash, reasonHash, acceptedAt, next.executableAfter);
        _assertPartition();
    }

    function registerMaterializedEntry(EntryRecord calldata entry_) external override onlyVault {
        DistributionRecord storage distribution_ = _distributions[entry_.distributionId];
        if (distribution_.status != DistributionStatus.REVIEW_PENDING || distribution_.currentVersion != entry_.version
            || distribution_.windowId != entry_.windowId || entry_.recipient == address(0)
            || entry_.rewardAsset != distribution_.rewardAsset || entry_.amount == 0 || entry_.leafHash == bytes32(0)
            || entry_.recipientIndex >= MAX_RECIPIENTS || entry_.status != EntryStatus.NONE
            || entry_.manualSettlementStatus != ManualSettlementStatus.NONE
            || _entries[entry_.distributionId][entry_.version][entry_.recipientIndex].leafHash != bytes32(0)) {
            revert InvalidHolderTransition();
        }
        distribution_.materializedAmount += entry_.amount;
        ++distribution_.materializedEntryCount;
        if (distribution_.materializedAmount > distribution_.totalPayable
            || distribution_.materializedEntryCount > distribution_.expectedEntryCount) revert HolderRecordMismatch();
        _entries[entry_.distributionId][entry_.version][entry_.recipientIndex] = entry_;
        _append(entry_.distributionId, entry_.leafHash, bytes32(0), entry_.version, entry_.recipientIndex,
            entry_.amount, HistoryAction.ENTRY_MATERIALIZED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryMaterialized(entry_.distributionId, entry_.version, entry_.recipientIndex,
            entry_.leafHash, entry_.recipient, entry_.rewardAsset, entry_.amount);
    }

    function finalizeDistribution(bytes32 distributionId_, uint32 version, uint256 exactTotal, uint16 exactCount)
        external override onlyVault
    {
        DistributionRecord storage d = _distributions[distributionId_];
        if (d.status != DistributionStatus.REVIEW_PENDING || d.currentVersion != version
            || block.timestamp < d.executableAfter || d.totalPayable != exactTotal
            || d.materializedAmount != exactTotal || d.materializedEntryCount != exactCount
            || exactCount != d.expectedEntryCount) revert InvalidHolderTransition();
        uint16 seen;
        for (uint16 i; i < MAX_RECIPIENTS; ++i) {
            EntryRecord storage e = _entries[distributionId_][version][i];
            if (e.leafHash != bytes32(0)) {
                if (e.status != EntryStatus.NONE) revert HolderRecordMismatch();
                e.status = EntryStatus.COMMITTED_UNPAID;
                ++seen;
            }
        }
        if (seen != exactCount) revert HolderRecordMismatch();
        d.status = DistributionStatus.FINALIZED;
        _distributionVersions[distributionId_][version] = d;
        _normalReview -= d.windowPool;
        _finalizedUnpaid += d.totalPayable;
        _pendingAutomatic += exactCount;
        _finalizedUnpaidRecords += exactCount;
        --_openNormalReviews;
        _append(distributionId_, bytes32(0), bytes32(0), version, 0, exactTotal,
            HistoryAction.DISTRIBUTION_FINALIZED, EntryStatus.NONE, EntryStatus.COMMITTED_UNPAID,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit DistributionFinalized(distributionId_, version, exactTotal, exactCount);
        _assertPartition();
    }

    function recordAutomaticPayment(bytes32 distributionId_, uint32 version, uint16 index, bytes32 leafHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if (e.status != EntryStatus.COMMITTED_UNPAID) revert InvalidHolderTransition();
        e.status = EntryStatus.PAID;
        _finalizedUnpaid -= e.amount;
        --_pendingAutomatic;
        --_finalizedUnpaidRecords;
        _append(distributionId_, leafHash, bytes32(0), version, index, e.amount,
            HistoryAction.PAYMENT_SUCCEEDED, EntryStatus.COMMITTED_UNPAID, EntryStatus.PAID,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryStatusChanged(distributionId_, version, index, EntryStatus.COMMITTED_UNPAID, EntryStatus.PAID, bytes32(0));
        _assertPartition();
    }

    function recordAutomaticPaymentFailure(bytes32 distributionId_, uint32 version, uint16 index, bytes32 leafHash, bytes32 revertDataHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if (e.status != EntryStatus.COMMITTED_UNPAID || revertDataHash == bytes32(0)) revert InvalidHolderTransition();
        e.status = EntryStatus.FAILED_PENDING_MANUAL;
        e.failureHash = revertDataHash;
        _distributions[distributionId_].correctionLocked = true;
        _distributionVersions[distributionId_][version].correctionLocked = true;
        --_pendingAutomatic;
        ++_failedUnavailable;
        _append(distributionId_, leafHash, revertDataHash, version, index, e.amount,
            HistoryAction.PAYMENT_FAILED, EntryStatus.COMMITTED_UNPAID, EntryStatus.FAILED_PENDING_MANUAL,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryStatusChanged(distributionId_, version, index, EntryStatus.COMMITTED_UNPAID,
            EntryStatus.FAILED_PENDING_MANUAL, revertDataHash);
    }

    function recordManualSettlementAvailable(bytes32 distributionId_, uint32 version, uint16 index, bytes32 leafHash, bytes32 evidenceHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if (e.status != EntryStatus.FAILED_PENDING_MANUAL || e.manualSettlementStatus != ManualSettlementStatus.NONE
            || evidenceHash == bytes32(0)) revert InvalidHolderTransition();
        e.manualSettlementStatus = ManualSettlementStatus.AVAILABLE;
        e.manualEvidenceHash = evidenceHash;
        --_failedUnavailable;
        _append(distributionId_, leafHash, evidenceHash, version, index, e.amount,
            HistoryAction.MANUAL_AVAILABLE, EntryStatus.FAILED_PENDING_MANUAL, EntryStatus.FAILED_PENDING_MANUAL,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit ManualSettlementAvailabilityRecorded(distributionId_, version, index, evidenceHash);
    }

    function recordManualSettlement(bytes32 distributionId_, uint32 version, uint16 index, bytes32 leafHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if ((e.status != EntryStatus.FAILED_PENDING_MANUAL && e.status != EntryStatus.TERMINAL_PENDING)
            || e.manualSettlementStatus != ManualSettlementStatus.AVAILABLE
            || (e.status == EntryStatus.TERMINAL_PENDING && block.timestamp >= e.terminalExpiresAt)) {
            revert InvalidHolderTransition();
        }
        EntryStatus beforeStatus = e.status;
        e.status = EntryStatus.PAID;
        e.manualSettlementStatus = ManualSettlementStatus.SETTLED;
        _finalizedUnpaid -= e.amount;
        --_finalizedUnpaidRecords;
        if (beforeStatus == EntryStatus.TERMINAL_PENDING) {
            --_terminalPendingRecords;
            _terminalPendingSubset -= e.amount;
        }
        _append(distributionId_, leafHash, e.manualEvidenceHash, version, index, e.amount,
            HistoryAction.MANUAL_SETTLED, beforeStatus, EntryStatus.PAID,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryStatusChanged(distributionId_, version, index, beforeStatus, EntryStatus.PAID, e.manualEvidenceHash);
        _assertPartition();
    }

    function startTerminalLiability(bytes32 distributionId_, uint32 version, bytes32 windowId, uint16 index, bytes32 leafHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if (e.windowId != windowId || e.status != EntryStatus.FAILED_PENDING_MANUAL
            || e.manualSettlementStatus != ManualSettlementStatus.AVAILABLE) revert InvalidHolderTransition();
        e.status = EntryStatus.TERMINAL_PENDING;
        e.terminalStartedAt = _timestamp();
        e.terminalExpiresAt = e.terminalStartedAt + TERMINAL_GRACE_SECONDS;
        ++_terminalPendingRecords;
        _terminalPendingSubset += e.amount;
        _append(distributionId_, leafHash, e.manualEvidenceHash, version, index, e.amount,
            HistoryAction.TERMINAL_STARTED, EntryStatus.FAILED_PENDING_MANUAL, EntryStatus.TERMINAL_PENDING,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryStatusChanged(distributionId_, version, index, EntryStatus.FAILED_PENDING_MANUAL,
            EntryStatus.TERMINAL_PENDING, e.manualEvidenceHash);
    }

    function expireTerminalLiability(bytes32 distributionId_, uint32 version, bytes32 windowId, uint16 index, bytes32 leafHash)
        external override onlyVault
    {
        EntryRecord storage e = _entryExact(distributionId_, version, index, leafHash);
        if (e.windowId != windowId || e.status != EntryStatus.TERMINAL_PENDING
            || block.timestamp < e.terminalExpiresAt) revert InvalidHolderTransition();
        e.status = EntryStatus.TERMINAL_EXPIRED;
        bytes32 id = _liabilityId(e);
        _liabilities[id] = e;
        _finalizedUnpaid -= e.amount;
        _recoveryEligible += e.amount;
        _terminalPendingSubset -= e.amount;
        _terminalExpiredSubset += e.amount;
        --_terminalPendingRecords;
        --_finalizedUnpaidRecords;
        _append(distributionId_, leafHash, id, version, index, e.amount,
            HistoryAction.TERMINAL_EXPIRED, EntryStatus.TERMINAL_PENDING, EntryStatus.TERMINAL_EXPIRED,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        emit HolderEntryStatusChanged(distributionId_, version, index, EntryStatus.TERMINAL_PENDING,
            EntryStatus.TERMINAL_EXPIRED, id);
        _assertPartition();
    }

    function recordEmptyCandidate(EmptyCandidateInput calldata input) external override onlyVault {
        if (input.version != 1 || input.windowId == bytes32(0) || input.distributionId == bytes32(0)
            || input.emptyCommitment == bytes32(0) || input.evidenceHash == bytes32(0) || input.poolAmount == 0
            || input.zeroResult != true || input.recipientCount != 0 || input.windowStart >= input.windowEnd
            || input.windowEnd - input.windowStart != WINDOW_SECONDS || input.windowStart % WINDOW_SECONDS != 0
            || input.windowEnd % WINDOW_SECONDS != 0 || block.timestamp < input.windowEnd
            || ICompdHolderWindowVaultV2(vault).holderWindowId(input.windowStart, input.windowEnd) != input.windowId
            || _emptyWindows[input.windowId].status != CompdV2Types.EmptyCandidateStatus.NONE
            || _windowPool[input.windowId] != input.poolAmount || _windowPool[input.windowId] == 0) {
            revert InvalidHolderTransition();
        }
        uint64 acceptedAt = _timestamp();
        EmptyWindowRecord memory r = _makeEmpty(input, acceptedAt);
        _emptyWindows[input.windowId] = r;
        _emptyVersions[input.windowId][input.version] = r;
        _windowPool[input.windowId] = 0;
        _unfinalized -= input.poolAmount;
        _emptyReview += input.poolAmount;
        ++_openEmptyReviews;
        _append(input.windowId, input.emptyCommitment, input.evidenceHash, input.version, 0, input.poolAmount,
            HistoryAction.EMPTY_OPENED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.NONE, r.status);
        emit EmptyWindowCandidateRecorded(input.windowId, input.distributionId, input.version,
            input.poolAmount, input.emptyCommitment, input.evidenceHash, acceptedAt, r.executableAfter);
        _assertPartition();
    }

    function correctEmptyCandidate(EmptyCandidateInput calldata replacement, bytes32 reasonHash) external override onlyVault {
        EmptyWindowRecord storage old = _emptyWindows[replacement.windowId];
        uint32 oldVersion = old.version;
        if (old.status != CompdV2Types.EmptyCandidateStatus.REVIEW_PENDING || reasonHash == bytes32(0)
            || replacement.version != oldVersion + 1 || replacement.distributionId != old.distributionId
            || replacement.windowStart != old.windowStart || replacement.windowEnd != old.windowEnd
            || replacement.poolAmount != old.poolAmount || replacement.zeroResult != true || replacement.recipientCount != 0
            || replacement.emptyCommitment == bytes32(0) || replacement.evidenceHash == bytes32(0)) revert InvalidHolderTransition();
        uint64 acceptedAt = _timestamp();
        EmptyWindowRecord memory r = _makeEmpty(replacement, acceptedAt);
        r.correctionReasonHash = reasonHash;
        _emptyWindows[replacement.windowId] = r;
        _emptyVersions[replacement.windowId][replacement.version] = r;
        _append(replacement.windowId, replacement.emptyCommitment, reasonHash, replacement.version, 0,
            replacement.poolAmount, HistoryAction.EMPTY_CORRECTED, EntryStatus.NONE, EntryStatus.NONE,
            old.status, r.status);
        emit EmptyWindowCandidateCorrected(replacement.windowId, oldVersion, replacement.version,
            replacement.emptyCommitment, replacement.evidenceHash, reasonHash, acceptedAt, r.executableAfter);
    }

    function finalizeEmptyCandidate(bytes32 windowId, uint32 version, uint256 exactPoolAmount) external override onlyVault {
        EmptyWindowRecord storage r = _emptyWindows[windowId];
        if (r.status != CompdV2Types.EmptyCandidateStatus.REVIEW_PENDING || r.version != version
            || block.timestamp < r.executableAfter || r.poolAmount != exactPoolAmount) revert InvalidHolderTransition();
        r.status = CompdV2Types.EmptyCandidateStatus.FINALIZED_NO_RECIPIENT;
        _emptyVersions[windowId][version] = r;
        _emptyReview -= exactPoolAmount;
        _finalizedNoRecipient += exactPoolAmount;
        --_openEmptyReviews;
        _append(windowId, r.emptyCommitment, r.evidenceHash, version, 0, exactPoolAmount,
            HistoryAction.EMPTY_FINALIZED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.REVIEW_PENDING, r.status);
        emit EmptyWindowFinalized(windowId, version, exactPoolAmount, r.emptyCommitment, r.evidenceHash);
        _assertPartition();
    }

    function classifyNoRecipientPool(bytes32 windowId, uint256 exactAmount) external override onlyVault {
        EmptyWindowRecord storage r = _emptyWindows[windowId];
        if (r.status != CompdV2Types.EmptyCandidateStatus.FINALIZED_NO_RECIPIENT || exactAmount == 0
            || exactAmount != r.poolAmount || _noRecipientEligibleAmount[windowId] != 0) revert InvalidHolderTransition();
        r.status = CompdV2Types.EmptyCandidateStatus.RECOVERY_ELIGIBLE;
        _emptyVersions[windowId][r.version] = r;
        _finalizedNoRecipient -= exactAmount;
        _recoveryEligible += exactAmount;
        _noRecipientEligibleSubset += exactAmount;
        _noRecipientEligibleAmount[windowId] = exactAmount;
        _noRecipientEvidence[windowId] = r.evidenceHash;
        _append(windowId, r.emptyCommitment, r.evidenceHash, r.version, 0, exactAmount,
            HistoryAction.NO_RECIPIENT_ELIGIBLE, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.FINALIZED_NO_RECIPIENT, r.status);
        emit NoRecipientPoolRecoveryClassified(windowId, exactAmount, r.evidenceHash);
        _assertPartition();
    }

    function recordNoRecipientPoolRecovery(bytes32 windowId, uint256 exactAmount, bytes32 transferEvidenceHash) external override onlyVault {
        EmptyWindowRecord storage r = _emptyWindows[windowId];
        if (r.status != CompdV2Types.EmptyCandidateStatus.RECOVERY_ELIGIBLE || exactAmount == 0
            || _noRecipientEligibleAmount[windowId] != exactAmount || _noRecipientRecovered[windowId]
            || transferEvidenceHash == bytes32(0)) revert InvalidHolderTransition();
        _noRecipientRecovered[windowId] = true;
        _noRecipientEligibleAmount[windowId] = 0;
        _noRecipientEligibleSubset -= exactAmount;
        _recoveryEligible -= exactAmount;
        r.status = CompdV2Types.EmptyCandidateStatus.RECOVERED;
        _emptyVersions[windowId][r.version] = r;
        _append(windowId, r.emptyCommitment, transferEvidenceHash, r.version, 0, exactAmount,
            HistoryAction.NO_RECIPIENT_RECOVERED, EntryStatus.NONE, EntryStatus.NONE,
            CompdV2Types.EmptyCandidateStatus.RECOVERY_ELIGIBLE, r.status);
        emit NoRecipientPoolRecovered(windowId, exactAmount, transferEvidenceHash);
        _assertPartition();
    }

    function recordExpiredLiabilityRecovery(bytes32 liabilityId_, bytes32 transferEvidenceHash) external override onlyVault {
        EntryRecord storage l = _liabilities[liabilityId_];
        if (l.status != EntryStatus.TERMINAL_EXPIRED || _liabilityRecovered[liabilityId_]
            || transferEvidenceHash == bytes32(0)) revert InvalidHolderTransition();
        _liabilityRecovered[liabilityId_] = true;
        _recoveryEligible -= l.amount;
        _terminalExpiredSubset -= l.amount;
        _append(l.distributionId, l.leafHash, transferEvidenceHash, l.version, l.recipientIndex, l.amount,
            HistoryAction.LIABILITY_RECOVERED, EntryStatus.TERMINAL_EXPIRED, EntryStatus.TERMINAL_EXPIRED,
            CompdV2Types.EmptyCandidateStatus.NONE, CompdV2Types.EmptyCandidateStatus.NONE);
        _assertPartition();
    }

    function distribution(bytes32 distributionId_) external view override returns (DistributionRecord memory) {
        return _distributions[distributionId_];
    }
    function distributionVersion(bytes32 distributionId_, uint32 version) external view override returns (DistributionRecord memory) {
        return _distributionVersions[distributionId_][version];
    }
    function entry(bytes32 distributionId_, uint32 version, uint16 index) external view override returns (EntryRecord memory) {
        return _entries[distributionId_][version][index];
    }
    function emptyWindow(bytes32 windowId) external view override returns (EmptyWindowRecord memory) { return _emptyWindows[windowId]; }
    function emptyWindowVersion(bytes32 windowId, uint32 version) external view override returns (EmptyWindowRecord memory) {
        return _emptyVersions[windowId][version];
    }
    function liabilityId(bytes32 distributionId_, uint32 version, bytes32 windowId, uint16 index)
        external pure override returns (bytes32)
    {
        return keccak256(abi.encode(distributionId_, version, windowId, index));
    }
    function liability(bytes32 liabilityId_) external view override returns (EntryRecord memory) { return _liabilities[liabilityId_]; }
    function noRecipientRecoveryEligible(bytes32 windowId) external view override returns (bool, uint256, bool, bytes32) {
        return (_noRecipientEligibleAmount[windowId] != 0, _noRecipientEligibleAmount[windowId],
            _noRecipientRecovered[windowId], _noRecipientEvidence[windowId]);
    }
    function holderPartitionTotals() external view override returns (HolderPartitionTotals memory p) {
        p = HolderPartitionTotals(_unfinalized, _normalReview, _emptyReview, _finalizedUnpaid,
            _finalizedNoRecipient, _recoveryEligible, _terminalPendingSubset, _terminalExpiredSubset,
            _noRecipientEligibleSubset);
    }
    function globalHolderBlockers() external view override returns (uint32,uint32,uint32,uint32,uint32,uint32) {
        return (_openNormalReviews, _openEmptyReviews, _pendingAutomatic, _failedUnavailable,
            _finalizedUnpaidRecords, _terminalPendingRecords);
    }
    function holderRecordCount(bytes32 subjectId) external view override returns (uint32) {
        return uint32(_history[subjectId].length);
    }
    function holderRecordAt(bytes32 subjectId, uint32 index) external view override returns (HolderHistoryEntry memory) {
        return _history[subjectId][index];
    }

    function _entryExact(bytes32 id, uint32 version, uint16 index, bytes32 leafHash)
        private view returns (EntryRecord storage e)
    {
        e = _entries[id][version][index];
        if (e.leafHash == bytes32(0) || e.leafHash != leafHash || e.version != version || e.recipientIndex != index
            || _distributions[id].currentVersion != version || _distributions[id].windowId != e.windowId) revert HolderRecordMismatch();
    }

    function _makeDistribution(DistributionCandidateInput calldata i, uint64 acceptedAt)
        private pure returns (DistributionRecord memory r)
    {
        r.distributionId = i.distributionId; r.windowId = i.windowId; r.windowStart = i.windowStart;
        r.windowEnd = i.windowEnd; r.rewardAsset = i.rewardAsset; r.currentVersion = i.version;
        r.acceptedAt = acceptedAt; r.executableAfter = acceptedAt + REVIEW_SECONDS; r.windowPool = i.windowPool;
        r.totalPayable = i.totalPayable; r.expectedEntryCount = i.expectedEntryCount;
        r.positiveEntryCount = i.positiveEntryCount; r.algorithmVersion = i.algorithmVersion;
        r.root = i.root; r.datasetHash = i.datasetHash; r.commitmentHash = i.commitmentHash;
        r.status = DistributionStatus.REVIEW_PENDING;
    }

    function _makeEmpty(EmptyCandidateInput calldata i, uint64 acceptedAt)
        private pure returns (EmptyWindowRecord memory r)
    {
        r.windowId = i.windowId; r.distributionId = i.distributionId; r.windowStart = i.windowStart;
        r.windowEnd = i.windowEnd; r.emptyCommitment = i.emptyCommitment; r.manifestHash = i.manifestHash;
        r.snapshotBlockHash = i.snapshotBlockHash; r.activationContextHash = i.activationContextHash;
        r.evidenceHash = i.evidenceHash; r.correctionReasonHash = i.correctionReasonHash;
        r.poolAmount = i.poolAmount; r.snapshotBlockNumber = i.snapshotBlockNumber; r.replayVersion = i.replayVersion;
        r.acceptedAt = acceptedAt; r.executableAfter = acceptedAt + REVIEW_SECONDS; r.version = i.version;
        r.recipientCount = i.recipientCount; r.zeroResult = i.zeroResult;
        r.status = CompdV2Types.EmptyCandidateStatus.REVIEW_PENDING;
    }

    function _append(bytes32 subject, bytes32 recordId, bytes32 evidenceHash, uint32 version, uint16 index,
        uint256 amount, HistoryAction action, EntryStatus oldEntry, EntryStatus newEntry,
        CompdV2Types.EmptyCandidateStatus oldEmpty, CompdV2Types.EmptyCandidateStatus newEmpty) private
    {
        uint64 sequence = ++_historySequence;
        _history[subject].push(HolderHistoryEntry(subject, keccak256(abi.encode(address(this), sequence, subject, recordId)),
            evidenceHash, _timestamp(), version, index, amount, action, oldEntry, newEntry, oldEmpty, newEmpty));
    }

    function _liabilityId(EntryRecord storage e) private view returns (bytes32) {
        return keccak256(abi.encode(e.distributionId, e.version, e.windowId, e.recipientIndex));
    }

    function _timestamp() private view returns (uint64 t) {
        if (block.timestamp > type(uint64).max) revert InvalidHolderTransition();
        t = uint64(block.timestamp);
    }

    function _assertPartition() private view {
        if (_unfinalized + _normalReview + _emptyReview + _finalizedUnpaid
            + _finalizedNoRecipient + _recoveryEligible != _vaultHolderReserve()) revert HolderRecordMismatch();
        if (_terminalPendingSubset > _finalizedUnpaid || _terminalExpiredSubset + _noRecipientEligibleSubset > _recoveryEligible) {
            revert HolderRecordMismatch();
        }
    }

    function _vaultHolderReserve() private view returns (uint256) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("holderRewardReserve()"));
        if (!ok || data.length != 32) revert HolderRecordMismatch();
        return abi.decode(data, (uint256));
    }
}
