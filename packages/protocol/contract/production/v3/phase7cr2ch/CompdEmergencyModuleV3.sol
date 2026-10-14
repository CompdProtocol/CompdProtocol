// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BKernel, IC2G2BRegistry} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface IEmergencyRegistryV3 {
    function initialized() external view returns (bool);
    function kernel() external view returns (address);
    function emergencyModule() external view returns (address);
    function moduleId() external view returns (uint8);
    function moduleVersion() external view returns (uint32);
}
interface IEmergencyKernelPinsV3 {
    function emergencyAuthority() external view returns (address);
    function moduleAddress(T.ModuleId) external view returns (address);
    function moduleHash(uint8) external view returns (bytes32);
}

/// @notice Immutable, forward-reference-safe emergency coordinator (slot 4/version 2).
/// Kernel remains the sole authority for lifecycle, accounting and BNB transfers.
contract CompdEmergencyModuleV3 {
    uint8 public constant MODULE_ID = 4;
    uint32 public constant MODULE_VERSION = 2;
    address public immutable kernel;
    address public immutable registry;
    bool private _entered;

    error Unauthorized();
    error InvalidState();
    error ChangedCode();
    event RegistryInitialized(bytes32 indexed snapshotId, uint256 scopes);
    event EmergencyStatus(T.ProcessingStatus status);
    event RecoveryAttempt(bytes32 indexed scopeId, bytes32 indexed attemptId, uint256 amount);

    modifier lock() {
        if (_entered) revert Unauthorized();
        _entered = true;
        _;
        _entered = false;
    }

    /// @dev Does not inspect Kernel or Registry code; both are future immutable refs.
    constructor(address predictedKernel_, address predictedRegistry_) {
        if (predictedKernel_ == address(0) || predictedRegistry_ == address(0)) revert Unauthorized();
        kernel = predictedKernel_;
        registry = predictedRegistry_;
    }

    function moduleId() external pure returns (uint8) { return MODULE_ID; }
    function moduleVersion() external pure returns (uint32) { return MODULE_VERSION; }

    function initialize(bytes32[] calldata ids, uint8[] calldata kinds) external {
        if (msg.sender != _authority()) revert Unauthorized();
        _checkGraph();
        bytes32 snap = IC2G2BKernel(kernel).emergencySnapshotId();
        if (IC2G2BKernel(kernel).lifecycle() != T.Lifecycle.EMERGENCY_RECOVERY) revert InvalidState();
        IC2G2BRegistry(registry).initialize(snap, ids, kinds);
        emit RegistryInitialized(snap, ids.length);
        _updateStatus();
    }

    function recoverBNB(bytes32 scopeId, bytes32 attemptId, uint32 number, uint256 amount, bytes32 evidence) external lock {
        if (msg.sender != _authority() || IC2G2BKernel(kernel).lifecycle() != T.Lifecycle.EMERGENCY_RECOVERY) revert Unauthorized();
        _checkGraph();
        IC2G2BKernel(kernel).emergencyTransferBNB(scopeId, attemptId, number, amount, evidence);
        emit RecoveryAttempt(scopeId, attemptId, amount);
        _updateStatus();
    }

    function beginWorkflowAttempt(bytes32 scopeId, bytes32 attemptId, uint32 number) external {
        if (msg.sender != _authority()) revert Unauthorized();
        _checkGraph();
        IC2G2BRegistry(registry).beginWorkflowAttempt(IC2G2BKernel(kernel).emergencySnapshotId(), scopeId, attemptId, number);
        _updateStatus();
    }

    function finishWorkflowAttempt(bytes32 scopeId, bytes32 attemptId, uint32 number, T.AttemptStatus status, bytes32 evidence) external {
        if (msg.sender != _authority()) revert Unauthorized();
        _checkGraph();
        IC2G2BRegistry(registry).finishWorkflowAttempt(IC2G2BKernel(kernel).emergencySnapshotId(), scopeId, attemptId, number, status, evidence);
        _updateStatus();
    }

    function discover(bytes32 scopeId, uint8 kind, bytes32 evidence) external {
        if (msg.sender != _authority()) revert Unauthorized();
        _checkGraph();
        IC2G2BRegistry(registry).lateDiscovery(IC2G2BKernel(kernel).emergencySnapshotId(), scopeId, kind, evidence);
        _updateStatus();
    }

    function resolve(bytes32 scopeId, bytes32 evidence) external {
        if (msg.sender != _authority()) revert Unauthorized();
        _checkGraph();
        IC2G2BRegistry(registry).resolve(IC2G2BKernel(kernel).emergencySnapshotId(), scopeId, evidence);
        _updateStatus();
    }

    function terminationReady() external pure returns (bool) { return true; }

    function _updateStatus() private {
        (, uint256 open, uint256 pending, uint256 blocked,) = IC2G2BRegistry(registry).summary(IC2G2BKernel(kernel).emergencySnapshotId());
        if (!IEmergencyRegistryV3(registry).initialized()) revert InvalidState();
        T.ProcessingStatus status;
        if (open == 0 && pending == 0 && blocked == 0) status = T.ProcessingStatus.COMPLETE_WITHIN_REGISTERED_SCOPE;
        else if (open == 0 && pending == 0 && blocked > 0) status = T.ProcessingStatus.COMPLETE_WITH_UNRESOLVED;
        else status = T.ProcessingStatus.IN_PROGRESS;
        IC2G2BKernel(kernel).setEmergencyStatus(status);
        emit EmergencyStatus(status);
    }

    function _authority() private view returns (address) { return IEmergencyKernelPinsV3(kernel).emergencyAuthority(); }

    function _checkGraph() private view {
        if (_hash(address(this)) != IEmergencyKernelPinsV3(kernel).moduleHash(MODULE_ID)
            || IEmergencyKernelPinsV3(kernel).moduleAddress(T.ModuleId.EMERGENCY) != address(this)
            || _hash(registry) != IEmergencyKernelPinsV3(kernel).moduleHash(5)
            || IEmergencyKernelPinsV3(kernel).moduleAddress(T.ModuleId.REGISTRY) != registry
            || IEmergencyRegistryV3(registry).kernel() != kernel
            || IEmergencyRegistryV3(registry).emergencyModule() != address(this)
            || IEmergencyRegistryV3(registry).moduleId() != 5
            || IEmergencyRegistryV3(registry).moduleVersion() != 2) revert ChangedCode();
    }

    function _hash(address a) private view returns (bytes32 h) { assembly { h := extcodehash(a) } }
}
