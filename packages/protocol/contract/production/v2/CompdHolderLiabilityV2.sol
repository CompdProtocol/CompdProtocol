// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ICompdHolderLiabilityV2 as ILiability} from "./ICompdHolderLiabilityV2.sol";
import {CompdV2Types} from "./CompdV2Types.sol";

interface ICompdLiabilityVaultLifecycleV2 {
    function lifecycle() external view returns (CompdV2Types.Lifecycle);
}

/// @notice Early size prototype for exact Holder entries and recipient liabilities; never holds assets.
contract CompdHolderLiabilityV2 is ILiability {
    bytes32 public constant override COMPONENT_TYPE_ID = keccak256("COMPD_HOLDER_LIABILITY_V2");
    uint32 public constant override COMPONENT_VERSION = 2;
    uint64 public constant TERMINAL_GRACE_SECONDS = 7_776_000;
    uint16 public constant MAX_RECIPIENTS = 30;

    address public override vault;
    mapping(bytes32 => EntryRecord) private _entries;
    mapping(bytes32 => DistributionSummary) private _summaries;
    mapping(bytes32 => mapping(uint16 => bytes32)) private _entryKeys;
    mapping(bytes32 => HistoryEntry[]) private _history;
    uint256 private _finalizedUnpaid;
    uint256 private _expiredRecovery;
    uint32 private _pendingAutomatic;
    uint32 private _failedUnavailable;
    uint32 private _finalizedUnpaidRecords;
    uint32 private _terminalPendingRecords;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyBoundVault();
        _;
    }

    constructor(address vault_) {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidLiabilityTransition();
        vault = vault_;
    }

    function registerMaterializedEntry(EntryInput calldata i) external override onlyVault {
        if (i.distributionId == bytes32(0) || i.version == 0 || i.windowId == bytes32(0) || i.index >= MAX_RECIPIENTS
            || i.leafHash == bytes32(0) || i.recipient == address(0) || i.rewardAsset == address(0) || i.amount == 0) {
            revert InvalidLiabilityTransition();
        }
        bytes32 id = liabilityId(i.distributionId,i.version,i.windowId,i.index);
        if (_entries[id].status != EntryStatus.NONE) revert DuplicateLiabilityIdentity();
        EntryRecord memory e = EntryRecord(i.distributionId,i.version,i.windowId,i.index,i.leafHash,i.recipient,
            i.rewardAsset,i.amount,bytes32(0),bytes32(0),0,0,EntryStatus.MATERIALIZED_PENDING_FINALIZATION,ManualSettlementStatus.NONE);
        _entries[id] = e;
        DistributionSummary storage s = _summaries[_distributionKey(i.distributionId,i.version)];
        if (s.finalized || s.superseded || s.materializedCount >= MAX_RECIPIENTS) revert InvalidLiabilityTransition();
        s.materializedAmount += i.amount;
        ++s.materializedCount;
        _entryKeys[_distributionKey(i.distributionId,i.version)][i.index] = id;
        _append(id,bytes32(0),i.version,i.index,i.amount,EntryStatus.NONE,e.status,HistoryAction.MATERIALIZED);
        emit HolderEntryMaterialized(i.distributionId,i.version,i.index,i.leafHash,i.recipient,i.rewardAsset,i.amount);
    }

    function supersedeMaterializedVersion(bytes32 distributionId,uint32 version) external override onlyVault {
        bytes32 dkey = _distributionKey(distributionId,version);
        DistributionSummary storage s = _summaries[dkey];
        if (s.finalized || s.superseded) revert InvalidLiabilityTransition();
        uint16 changed;
        for (uint16 i; i < MAX_RECIPIENTS; ++i) {
            bytes32 id = _entryKeys[dkey][i];
            if (id != bytes32(0)) {
                EntryRecord storage e = _entries[id];
                if (e.status != EntryStatus.MATERIALIZED_PENDING_FINALIZATION) revert LiabilityRecordMismatch();
                e.status = EntryStatus.SUPERSEDED;
                ++changed;
                _append(id,bytes32(0),version,i,e.amount,EntryStatus.MATERIALIZED_PENDING_FINALIZATION,e.status,HistoryAction.SUPERSEDED);
            }
        }
        if (changed != s.materializedCount) revert LiabilityRecordMismatch();
        s.superseded = true;
        emit MaterializedVersionSuperseded(distributionId,version,changed);
    }

    function finalizeLiabilityDistribution(bytes32 distributionId,uint32 version,uint256 exactAmount,uint16 exactCount)
        external override onlyVault
    {
        bytes32 dkey = _distributionKey(distributionId,version);
        DistributionSummary storage s = _summaries[dkey];
        if (distributionId == bytes32(0) || version == 0 || s.finalized || s.superseded
            || exactAmount == 0 || s.materializedAmount != exactAmount || s.materializedCount != exactCount
            || exactCount == 0 || exactCount > MAX_RECIPIENTS) revert InvalidLiabilityTransition();
        uint16 changed;
        for (uint16 i; i < MAX_RECIPIENTS; ++i) {
            bytes32 id = _entryKeys[dkey][i];
            if (id != bytes32(0)) {
                EntryRecord storage e = _entries[id];
                if (e.status != EntryStatus.MATERIALIZED_PENDING_FINALIZATION) revert LiabilityRecordMismatch();
                e.status = EntryStatus.COMMITTED_UNPAID;
                ++changed;
                _append(id,bytes32(0),version,i,e.amount,EntryStatus.MATERIALIZED_PENDING_FINALIZATION,e.status,HistoryAction.FINALIZED);
            }
        }
        if (changed != exactCount) revert LiabilityRecordMismatch();
        s.finalized = true;
        _finalizedUnpaid += exactAmount;
        _pendingAutomatic += exactCount;
        _finalizedUnpaidRecords += exactCount;
        emit LiabilityDistributionFinalized(distributionId,version,exactAmount,exactCount);
    }

    function recordAutomaticPayment(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafHash) external override onlyVault {
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.status != EntryStatus.COMMITTED_UNPAID) revert InvalidLiabilityTransition();
        e.status = EntryStatus.PAID;
        _finalizedUnpaid -= e.amount;
        --_pendingAutomatic;
        --_finalizedUnpaidRecords;
        _append(id,bytes32(0),version,index,e.amount,EntryStatus.COMMITTED_UNPAID,e.status,HistoryAction.PAID);
        emit HolderLiabilityStatusChanged(id,EntryStatus.COMMITTED_UNPAID,e.status,bytes32(0));
    }

    function recordAutomaticPaymentFailure(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafHash,bytes32 failureHash)
        external override onlyVault
    {
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.status != EntryStatus.COMMITTED_UNPAID || failureHash == bytes32(0)) revert InvalidLiabilityTransition();
        e.status = EntryStatus.FAILED_PENDING_MANUAL;
        e.failureHash = failureHash;
        --_pendingAutomatic;
        ++_failedUnavailable;
        _append(id,failureHash,version,index,e.amount,EntryStatus.COMMITTED_UNPAID,e.status,HistoryAction.FAILED);
        emit HolderLiabilityStatusChanged(id,EntryStatus.COMMITTED_UNPAID,e.status,failureHash);
    }

    function recordManualSettlementAvailable(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafHash,bytes32 evidenceHash)
        external override onlyVault
    {
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.status != EntryStatus.FAILED_PENDING_MANUAL || e.manualSettlementStatus != ManualSettlementStatus.NONE
            || evidenceHash == bytes32(0)) revert InvalidLiabilityTransition();
        e.manualSettlementStatus = ManualSettlementStatus.AVAILABLE;
        e.manualEvidenceHash = evidenceHash;
        --_failedUnavailable;
        _append(id,evidenceHash,version,index,e.amount,EntryStatus.FAILED_PENDING_MANUAL,e.status,HistoryAction.MANUAL_AVAILABLE);
        emit ManualSettlementAvailabilityRecorded(id,evidenceHash);
    }

    function recordManualSettlement(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafHash) external override onlyVault {
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.status != EntryStatus.FAILED_PENDING_MANUAL || e.manualSettlementStatus != ManualSettlementStatus.AVAILABLE) revert InvalidLiabilityTransition();
        e.status = EntryStatus.PAID;
        e.manualSettlementStatus = ManualSettlementStatus.SETTLED;
        _finalizedUnpaid -= e.amount;
        --_finalizedUnpaidRecords;
        _append(id,bytes32(0),version,index,e.amount,EntryStatus.FAILED_PENDING_MANUAL,e.status,HistoryAction.MANUAL_SETTLED);
        emit HolderLiabilityStatusChanged(id,EntryStatus.FAILED_PENDING_MANUAL,e.status,bytes32(0));
    }

    function startTerminalLiability(bytes32 distributionId,uint32 version,bytes32 windowId,uint16 index,bytes32 leafHash)
        external override onlyVault
    {
        if (ICompdLiabilityVaultLifecycleV2(vault).lifecycle() != CompdV2Types.Lifecycle.TERMINATED) revert InvalidLiabilityTransition();
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.windowId != windowId || e.status != EntryStatus.FAILED_PENDING_MANUAL
            || e.manualSettlementStatus != ManualSettlementStatus.AVAILABLE) revert InvalidLiabilityTransition();
        uint64 started = uint64(block.timestamp);
        uint64 expires = started + TERMINAL_GRACE_SECONDS;
        e.terminalStartedAt = started;
        e.terminalExpiresAt = expires;
        e.status = EntryStatus.TERMINAL_PENDING;
        ++_terminalPendingRecords;
        _append(id,bytes32(0),version,index,e.amount,EntryStatus.FAILED_PENDING_MANUAL,e.status,HistoryAction.TERMINAL_STARTED);
        emit TerminalLiabilityStarted(id,started,expires);
    }

    function expireTerminalLiability(bytes32 distributionId,uint32 version,bytes32 windowId,uint16 index,bytes32 leafHash)
        external override onlyVault
    {
        bytes32 id = _keyAt(distributionId,version,index,leafHash);
        EntryRecord storage e = _entries[id];
        if (e.windowId != windowId || e.status != EntryStatus.TERMINAL_PENDING || block.timestamp < e.terminalExpiresAt) {
            revert InvalidLiabilityTransition();
        }
        e.status = EntryStatus.TERMINAL_EXPIRED;
        --_terminalPendingRecords;
        --_finalizedUnpaidRecords;
        _finalizedUnpaid -= e.amount;
        _expiredRecovery += e.amount;
        _append(id,bytes32(0),version,index,e.amount,EntryStatus.TERMINAL_PENDING,e.status,HistoryAction.TERMINAL_EXPIRED);
        emit TerminalLiabilityExpired(id,e.amount);
    }

    function recordExpiredLiabilityRecovery(bytes32 id,bytes32 evidenceHash) external override onlyVault {
        EntryRecord storage e = _entries[id];
        if (e.status != EntryStatus.TERMINAL_EXPIRED || evidenceHash == bytes32(0)) revert InvalidLiabilityTransition();
        e.status = EntryStatus.RECOVERED;
        _expiredRecovery -= e.amount;
        _append(id,evidenceHash,e.version,e.index,e.amount,EntryStatus.TERMINAL_EXPIRED,e.status,HistoryAction.RECOVERED);
        emit HolderLiabilityStatusChanged(id,EntryStatus.TERMINAL_EXPIRED,e.status,evidenceHash);
    }

    function entry(bytes32 distributionId,uint32 version,uint16 index) external view override returns (EntryRecord memory) {
        return _entries[liabilityId(distributionId,version,_windowFor(distributionId,version,index),index)];
    }
    function liabilityId(bytes32 distributionId,uint32 version,bytes32 windowId,uint16 index) public pure override returns (bytes32) {
        return keccak256(abi.encode(distributionId,version,windowId,index));
    }
    function liability(bytes32 id) external view override returns (EntryRecord memory) { return _entries[id]; }
    function distributionSummary(bytes32 distributionId,uint32 version) external view override returns (DistributionSummary memory) {
        return _summaries[_distributionKey(distributionId,version)];
    }
    function sourcePartitions() external view override returns (SourcePartitions memory) {
        return SourcePartitions(_finalizedUnpaid,_expiredRecovery,_pendingAutomatic,_failedUnavailable,_finalizedUnpaidRecords,_terminalPendingRecords);
    }
    function historyCount(bytes32 id) external view override returns (uint32) { return uint32(_history[id].length); }
    function historyAt(bytes32 id,uint32 index) external view override returns (HistoryEntry memory) { return _history[id][index]; }

    function _keyAt(bytes32 distributionId,uint32 version,uint16 index,bytes32 leafHash) private view returns (bytes32 id) {
        bytes32 dkey = _distributionKey(distributionId,version);
        id = _entryKeys[dkey][index];
        EntryRecord storage e = _entries[id];
        if (id == bytes32(0) || e.leafHash != leafHash || e.distributionId != distributionId || e.version != version) {
            revert LiabilityRecordMismatch();
        }
    }
    function _windowFor(bytes32 distributionId,uint32 version,uint16 index) private view returns (bytes32) {
        bytes32 id = _entryKeys[_distributionKey(distributionId,version)][index];
        return _entries[id].windowId;
    }
    function _distributionKey(bytes32 distributionId,uint32 version) private pure returns (bytes32) {
        return keccak256(abi.encode(distributionId,version));
    }
    function _append(bytes32 id,bytes32 evidence,uint32 version,uint16 index,uint256 amount,EntryStatus prior,EntryStatus next,HistoryAction action) private {
        _history[id].push(HistoryEntry(id,evidence,uint64(block.timestamp),version,index,amount,prior,next,action));
    }
}
