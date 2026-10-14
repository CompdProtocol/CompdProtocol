// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";
import {ICompdVaultBoundComponentV2} from "./ICompdVaultBoundComponentV2.sol";

/// @notice Bounded evidence/history only. It is never an asset custodian or transfer authority.
interface ICompdEmergencyRegistryV2 is ICompdVaultBoundComponentV2 {
    struct SnapshotCell {
        bytes32 snapshotId;
        CompdV2Types.ModuleId moduleId;
        address asset;
        CompdV2Types.EmergencySnapshotCellStatus availability;
        uint256 observedBalance;
        bytes32 evidenceHash;
    }

    struct AttemptRecord {
        bytes32 subjectId;
        bytes32 attemptId;
        uint32 attemptNumber;
        CompdV2Types.ModuleId moduleId;
        address asset;
        uint256 runId;
        address caller;
        uint64 timestamp;
        uint64 blockNumber;
        uint256 moduleBalanceBefore;
        uint256 moduleBalanceAfter;
        uint256 recoveryWalletBalanceBefore;
        uint256 recoveryWalletBalanceAfter;
        uint256 amountDebited;
        uint256 amountCredited;
        CompdV2Types.EmergencyAttemptOutcome outcome;
        bytes32 failureCode;
        bytes32 revertDataHash;
        bytes32 evidenceHash;
    }

    struct ModuleAssetEvidence {
        CompdV2Types.ModuleId moduleId;
        address asset;
        CompdV2Types.EmergencyAssetStatus status;
        CompdV2Types.EmergencySnapshotCellStatus snapshotStatus;
        uint32 attemptCount;
        uint64 discoveredAt;
        bytes32 discoveryEvidenceHash;
        bytes32 lastAttemptId;
        bytes32 lastFailureCode;
        bytes32 lastRevertDataHash;
    }

    struct CoverageEvidence {
        uint32 expectedCellCount;
        uint32 recordedCellCount;
        uint32 unavailableCellCount;
        uint32 unresolvedAttemptCount;
        uint64 updatedAt;
        bytes32 coverageHash;
        bytes32 unresolvedEvidenceHash;
    }

    error OnlyBoundVault();
    error InvalidComponentIdentity();
    error InvalidModuleId();
    error RegistryCapacityReached();
    error AttemptSequenceMismatch();
    error DuplicateEvidence();

    event EmergencySnapshotCellRecorded(bytes32 indexed snapshotId, CompdV2Types.ModuleId indexed moduleId, address indexed asset, CompdV2Types.EmergencySnapshotCellStatus availability, uint256 observedBalance, bytes32 evidenceHash);
    event EmergencyAssetDiscovered(bytes32 indexed snapshotId, CompdV2Types.ModuleId indexed moduleId, address indexed asset, uint64 discoveredAt, bytes32 evidenceHash);
    event EmergencyAttemptRecorded(bytes32 indexed subjectId, bytes32 indexed attemptId, uint32 indexed attemptNumber, CompdV2Types.ModuleId moduleId, address asset, uint256 runId, CompdV2Types.EmergencyAttemptOutcome outcome, uint256 amountDebited, uint256 amountCredited, bytes32 failureCode, bytes32 revertDataHash, bytes32 evidenceHash);
    event EmergencyCoverageUpdated(bytes32 indexed snapshotId, uint32 expectedCellCount, uint32 recordedCellCount, uint32 unavailableCellCount, uint32 unresolvedAttemptCount, bytes32 coverageHash, bytes32 unresolvedEvidenceHash);
    event EmergencyReconciliationEvidenceRecorded(bytes32 indexed snapshotId, bytes32 indexed recordId, bytes32 evidenceHash, bool resolved);

    // All mutation entry points are callable only by the immutable bound Vault.
    function initializeAsset(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset, uint256 snapshotBalance, CompdV2Types.EmergencySnapshotCellStatus snapshotStatus, bytes32 evidenceHash) external;
    function recordDiscovery(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset, bytes32 evidenceHash) external;
    function recordSnapshotCell(SnapshotCell calldata cell) external;
    function beginAttempt(bytes32 subjectId, bytes32 attemptId, uint32 expectedAttemptNumber, CompdV2Types.ModuleId moduleId, address asset, uint256 runId, address caller, uint256 moduleBalanceBefore, uint256 recoveryWalletBalanceBefore) external;
    function completeAttempt(AttemptRecord calldata record) external;
    function recordUnavailableCoverage(bytes32 snapshotId, uint32 expectedCellCount, uint32 recordedCellCount, uint32 unavailableCellCount, uint32 unresolvedAttemptCount, bytes32 evidenceHash) external;
    function recordReconciliation(bytes32 snapshotId, bytes32 recordId, bytes32 evidenceHash, bool resolved) external;

    function assetCount() external view returns (uint32);
    function assetAt(uint32 index) external view returns (CompdV2Types.ModuleId moduleId, address asset);
    function moduleAssetEvidence(CompdV2Types.ModuleId moduleId, address asset) external view returns (ModuleAssetEvidence memory);
    function snapshotCell(bytes32 snapshotId, CompdV2Types.ModuleId moduleId, address asset) external view returns (SnapshotCell memory);
    function attemptCount(bytes32 subjectId) external view returns (uint32);
    function attemptAt(bytes32 subjectId, uint32 attemptNumber) external view returns (AttemptRecord memory);
    function coverage(bytes32 snapshotId) external view returns (CoverageEvidence memory);
    function reconciliationEvidence(bytes32 snapshotId, bytes32 recordId) external view returns (bytes32 evidenceHash, bool resolved, bool exists);
}
