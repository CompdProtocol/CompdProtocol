// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";
import {ICompdEmergencyRegistryV2 as IRegistry} from "./ICompdEmergencyRegistryV2.sol";

/// @notice Vault-bound bounded emergency evidence store. It never calls or owns assets.
/// @dev The manifest candidate cap is local engineering scaffolding, not a production-frozen value.
contract CompdEmergencyRegistryV2 is IRegistry {
    bytes32 public constant override COMPONENT_TYPE_ID = keccak256("COMPD_EMERGENCY_REGISTRY_V2");
    uint32 public constant override COMPONENT_VERSION = 2;
    uint16 public constant LOCAL_MANIFEST_CAP_CANDIDATE = 16;
    address public override vault;

    struct ReconciliationRecord {
        bytes32 evidenceHash;
        bool resolved;
        uint64 timestamp;
        uint64 blockNumber;
    }

    mapping(bytes32 => SnapshotCell) private _snapshotCells;
    mapping(bytes32 => ModuleAssetEvidence) private _moduleAssets;
    mapping(bytes32 => uint32) private _attemptCounts;
    mapping(bytes32 => mapping(uint32 => AttemptRecord)) private _attempts;
    mapping(bytes32 => bool) private _attemptIdUsed;
    mapping(bytes32 => CoverageEvidence) private _coverage;
    mapping(bytes32 => ReconciliationRecord[]) private _reconciliationHistory;
    mapping(bytes32 => bool) private _assetKnown;
    bytes32[] private _assetKeys;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyBoundVault();
        _;
    }

    constructor(address vault_) {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidComponentIdentity();
        vault = vault_;
    }

    function initializeAsset(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset,
        uint256 snapshotBalance, CompdV2Types.EmergencySnapshotCellStatus snapshotStatus, bytes32 evidenceHash)
        external override onlyVault
    {
        if (snapshotId == bytes32(0) || !_validModule(moduleId) || evidenceHash == bytes32(0)) revert InvalidModuleId();
        bytes32 key = _moduleAssetKey(moduleId, asset);
        if (_moduleAssets[key].status != CompdV2Types.EmergencyAssetStatus.UNREGISTERED) revert DuplicateEvidence();
        _appendAsset(key, moduleId, asset);
        _moduleAssets[key] = ModuleAssetEvidence({
            moduleId: moduleId,
            asset: asset,
            status: snapshotStatus == CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE
                ? CompdV2Types.EmergencyAssetStatus.BLOCKED : CompdV2Types.EmergencyAssetStatus.REGISTERED,
            snapshotStatus: snapshotStatus,
            attemptCount: 0,
            discoveredAt: uint64(block.timestamp),
            discoveryEvidenceHash: evidenceHash,
            lastAttemptId: bytes32(0),
            lastFailureCode: bytes32(0),
            lastRevertDataHash: bytes32(0)
        });
        _snapshotCells[_snapshotKey(snapshotId, moduleId, asset)] = SnapshotCell({
            snapshotId: snapshotId,
            moduleId: moduleId,
            asset: asset,
            availability: snapshotStatus,
            observedBalance: snapshotBalance,
            evidenceHash: evidenceHash
        });
        emit EmergencySnapshotCellRecorded(snapshotId, moduleId, asset, snapshotStatus, snapshotBalance, evidenceHash);
    }

    function recordDiscovery(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset, bytes32 evidenceHash)
        external override onlyVault
    {
        if (snapshotId == bytes32(0) || !_validModule(moduleId) || evidenceHash == bytes32(0)) revert InvalidModuleId();
        bytes32 key = _moduleAssetKey(moduleId, asset);
        ModuleAssetEvidence storage r = _moduleAssets[key];
        if (r.status != CompdV2Types.EmergencyAssetStatus.UNREGISTERED) revert DuplicateEvidence();
        _appendAsset(key, moduleId, asset);
        r.moduleId = moduleId;
        r.asset = asset;
        r.status = CompdV2Types.EmergencyAssetStatus.DISCOVERED_AFTER_INITIATION;
        r.discoveredAt = uint64(block.timestamp);
        r.discoveryEvidenceHash = evidenceHash;
        r.snapshotStatus = CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
        SnapshotCell storage cell = _snapshotCells[_snapshotKey(snapshotId, moduleId, asset)];
        cell.snapshotId = snapshotId;
        cell.moduleId = moduleId;
        cell.asset = asset;
        cell.availability = CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
        cell.evidenceHash = evidenceHash;
        emit EmergencyAssetDiscovered(snapshotId, moduleId, asset, r.discoveredAt, evidenceHash);
    }

    function recordSnapshotCell(SnapshotCell calldata cell) external override onlyVault {
        if (cell.snapshotId == bytes32(0) || !_validModule(cell.moduleId) || cell.evidenceHash == bytes32(0)
            || !_assetKnown[_moduleAssetKey(cell.moduleId, cell.asset)]) revert DuplicateEvidence();
        bytes32 key = _snapshotKey(cell.snapshotId, cell.moduleId, cell.asset);
        SnapshotCell storage old = _snapshotCells[key];
        if (old.snapshotId != bytes32(0) && old.availability == CompdV2Types.EmergencySnapshotCellStatus.RECORDED) {
            revert DuplicateEvidence();
        }
        old.snapshotId = cell.snapshotId;
        old.moduleId = cell.moduleId;
        old.asset = cell.asset;
        old.availability = cell.availability;
        old.observedBalance = cell.observedBalance;
        old.evidenceHash = cell.evidenceHash;
        _moduleAssets[_moduleAssetKey(cell.moduleId, cell.asset)].snapshotStatus = cell.availability;
        emit EmergencySnapshotCellRecorded(cell.snapshotId, cell.moduleId, cell.asset,
            cell.availability, cell.observedBalance, cell.evidenceHash);
    }

    function beginAttempt(bytes32 subjectId, bytes32 attemptId, uint32 expectedAttemptNumber,
        CompdV2Types.ModuleId moduleId, address asset, uint256 runId, address caller,
        uint256 moduleBalanceBefore, uint256 recoveryWalletBalanceBefore) external override onlyVault
    {
        if (subjectId == bytes32(0) || attemptId == bytes32(0) || !_validModule(moduleId)
            || !_assetKnown[_moduleAssetKey(moduleId, asset)] || caller == address(0)
            || _attemptIdUsed[attemptId]) revert AttemptSequenceMismatch();
        uint32 next = _attemptCounts[subjectId] + 1;
        if (expectedAttemptNumber != next) revert AttemptSequenceMismatch();
        _attemptIdUsed[attemptId] = true;
        _attemptCounts[subjectId] = next;
        _attempts[subjectId][next] = AttemptRecord({
            subjectId: subjectId,
            attemptId: attemptId,
            attemptNumber: next,
            moduleId: moduleId,
            asset: asset,
            runId: runId,
            caller: caller,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            moduleBalanceBefore: moduleBalanceBefore,
            moduleBalanceAfter: 0,
            recoveryWalletBalanceBefore: recoveryWalletBalanceBefore,
            recoveryWalletBalanceAfter: 0,
            amountDebited: 0,
            amountCredited: 0,
            outcome: CompdV2Types.EmergencyAttemptOutcome.NONE,
            failureCode: bytes32(0),
            revertDataHash: bytes32(0),
            evidenceHash: bytes32(0)
        });
    }

    function completeAttempt(AttemptRecord calldata record) external override onlyVault {
        if (record.subjectId == bytes32(0) || record.attemptNumber == 0 || !_validModule(record.moduleId)
            || record.outcome == CompdV2Types.EmergencyAttemptOutcome.NONE || record.evidenceHash == bytes32(0)) {
            revert AttemptSequenceMismatch();
        }
        AttemptRecord storage pending = _attempts[record.subjectId][record.attemptNumber];
        if (pending.attemptId == bytes32(0) || pending.outcome != CompdV2Types.EmergencyAttemptOutcome.NONE
            || pending.attemptId != record.attemptId || pending.moduleId != record.moduleId
            || pending.asset != record.asset || pending.runId != record.runId || pending.caller != record.caller
            || pending.timestamp != record.timestamp || pending.blockNumber != record.blockNumber
            || pending.moduleBalanceBefore != record.moduleBalanceBefore
            || pending.recoveryWalletBalanceBefore != record.recoveryWalletBalanceBefore
            || record.amountDebited > record.moduleBalanceBefore) revert AttemptSequenceMismatch();
        pending.moduleBalanceAfter = record.moduleBalanceAfter;
        pending.recoveryWalletBalanceAfter = record.recoveryWalletBalanceAfter;
        pending.amountDebited = record.amountDebited;
        pending.amountCredited = record.amountCredited;
        pending.outcome = record.outcome;
        pending.failureCode = record.failureCode;
        pending.revertDataHash = record.revertDataHash;
        pending.evidenceHash = record.evidenceHash;
        ModuleAssetEvidence storage assetRecord = _moduleAssets[_moduleAssetKey(record.moduleId, record.asset)];
        ++assetRecord.attemptCount;
        assetRecord.lastAttemptId = record.attemptId;
        assetRecord.status = _assetStatus(record.outcome);
        assetRecord.lastFailureCode = record.failureCode;
        assetRecord.lastRevertDataHash = record.revertDataHash;
        emit EmergencyAttemptRecorded(record.subjectId, record.attemptId, record.attemptNumber,
            record.moduleId, record.asset, record.runId, record.outcome, record.amountDebited,
            record.amountCredited, record.failureCode, record.revertDataHash, record.evidenceHash);
    }

    function recordUnavailableCoverage(bytes32 snapshotId, uint32 expectedCellCount, uint32 recordedCellCount,
        uint32 unavailableCellCount, uint32 unresolvedAttemptCount, bytes32 evidenceHash) external override onlyVault
    {
        if (snapshotId == bytes32(0) || evidenceHash == bytes32(0) || recordedCellCount > expectedCellCount
            || unavailableCellCount > expectedCellCount) revert DuplicateEvidence();
        CoverageEvidence storage c = _coverage[snapshotId];
        c.expectedCellCount = expectedCellCount;
        c.recordedCellCount = recordedCellCount;
        c.unavailableCellCount = unavailableCellCount;
        c.unresolvedAttemptCount = unresolvedAttemptCount;
        c.updatedAt = uint64(block.timestamp);
        c.coverageHash = keccak256(abi.encode(c.coverageHash, expectedCellCount, recordedCellCount,
            unavailableCellCount, unresolvedAttemptCount, evidenceHash, block.number));
        c.unresolvedEvidenceHash = evidenceHash;
        emit EmergencyCoverageUpdated(snapshotId, expectedCellCount, recordedCellCount,
            unavailableCellCount, unresolvedAttemptCount, c.coverageHash, evidenceHash);
    }

    function recordReconciliation(bytes32 snapshotId, bytes32 recordId, bytes32 evidenceHash, bool resolved)
        external override onlyVault
    {
        if (snapshotId == bytes32(0) || recordId == bytes32(0) || evidenceHash == bytes32(0)) revert DuplicateEvidence();
        bytes32 key = keccak256(abi.encode(snapshotId, recordId));
        _reconciliationHistory[key].push(ReconciliationRecord(evidenceHash, resolved, uint64(block.timestamp), uint64(block.number)));
        emit EmergencyReconciliationEvidenceRecorded(snapshotId, recordId, evidenceHash, resolved);
    }

    function assetCount() external view override returns (uint32) { return uint32(_assetKeys.length); }
    function assetAt(uint32 index) external view override returns (CompdV2Types.ModuleId moduleId, address asset) {
        if (index >= _assetKeys.length) revert RegistryCapacityReached();
        bytes32 key = _assetKeys[index];
        ModuleAssetEvidence storage r = _moduleAssets[key];
        return (r.moduleId, r.asset);
    }
    function moduleAssetEvidence(CompdV2Types.ModuleId moduleId, address asset) external view override returns (ModuleAssetEvidence memory) {
        return _moduleAssets[_moduleAssetKey(moduleId, asset)];
    }
    function snapshotCell(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset)
        external view override returns (SnapshotCell memory)
    { return _snapshotCells[_snapshotKey(snapshotId, moduleId, asset)]; }
    function attemptCount(bytes32 subjectId) external view override returns (uint32) { return _attemptCounts[subjectId]; }
    function attemptAt(bytes32 subjectId, uint32 attemptNumber) external view override returns (AttemptRecord memory) {
        return _attempts[subjectId][attemptNumber];
    }
    function coverage(bytes32 snapshotId) external view override returns (CoverageEvidence memory) { return _coverage[snapshotId]; }
    function reconciliationEvidence(bytes32 snapshotId, bytes32 recordId)
        external view override returns (bytes32 evidenceHash, bool resolved, bool exists)
    {
        ReconciliationRecord[] storage h = _reconciliationHistory[keccak256(abi.encode(snapshotId, recordId))];
        if (h.length == 0) return (bytes32(0), false, false);
        // The event stream is the append-only detailed history; this view returns the latest commitment.
        ReconciliationRecord storage latest = h[h.length - 1];
        evidenceHash = latest.evidenceHash;
        resolved = latest.resolved;
        exists = true;
    }

    function _appendAsset(bytes32 key, CompdV2Types.ModuleId, address) private {
        if (_assetKnown[key]) revert DuplicateEvidence();
        if (_assetKeys.length >= LOCAL_MANIFEST_CAP_CANDIDATE) revert RegistryCapacityReached();
        _assetKnown[key] = true;
        _assetKeys.push(key);
    }
    function _moduleAssetKey(CompdV2Types.ModuleId moduleId, address asset) private pure returns (bytes32) {
        return keccak256(abi.encode(moduleId, asset));
    }
    function _snapshotKey(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset) private pure returns (bytes32) {
        return keccak256(abi.encode(snapshotId, moduleId, asset));
    }
    function _validModule(CompdV2Types.ModuleId moduleId) private pure returns (bool) {
        return uint8(moduleId) <= uint8(CompdV2Types.ModuleId.THIN_FLAP_RECEIVER);
    }
    function _assetStatus(CompdV2Types.EmergencyAttemptOutcome outcome)
        private pure returns (CompdV2Types.EmergencyAssetStatus)
    {
        if (outcome == CompdV2Types.EmergencyAttemptOutcome.SUCCESS) return CompdV2Types.EmergencyAssetStatus.RECOVERED;
        if (outcome == CompdV2Types.EmergencyAttemptOutcome.NO_BALANCE) return CompdV2Types.EmergencyAssetStatus.ZERO_BALANCE;
        if (outcome == CompdV2Types.EmergencyAttemptOutcome.FAILED_RETRYABLE) return CompdV2Types.EmergencyAssetStatus.FAILED_RETRYABLE;
        if (outcome == CompdV2Types.EmergencyAttemptOutcome.UNSUPPORTED) return CompdV2Types.EmergencyAssetStatus.UNSUPPORTED;
        if (outcome == CompdV2Types.EmergencyAttemptOutcome.BLOCKED) return CompdV2Types.EmergencyAssetStatus.BLOCKED;
        return CompdV2Types.EmergencyAssetStatus.TRANSFERRED_UNVERIFIED;
    }
}
