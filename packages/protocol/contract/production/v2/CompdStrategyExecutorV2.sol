// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types, CompdV2Errors} from "./CompdV2Types.sol";
import {ICompdEmergencyVaultV2, ICompdStrategyExecutorV2} from "./ICompdEmergencyVaultV2.sol";
import {ICompdStrategyAdapter} from "../ICompdProductionInterfaces.sol";

/// @notice Typed constructor-bound V2 strategy identity scaffold; no position operation is implemented.
contract CompdStrategyExecutorV2 is ICompdStrategyExecutorV2 {
    address public immutable override vault;
    address public immutable strategyAdapter;

    constructor(address vault_, address adapter_) {
        if (vault_.code.length == 0 || adapter_.code.length == 0) revert CompdV2Errors.InvalidImmutableConfiguration();
        try ICompdEmergencyVaultV2(vault_).lifecycle() returns (CompdV2Types.Lifecycle) { }
        catch { revert CompdV2Errors.InvalidImmutableConfiguration(); }
        vault = vault_;
        strategyAdapter = adapter_;
    }

    function emergencySweepAsset(address) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function snapshotEmergencyBalance(bytes32, address) external pure override returns (bool, uint256) {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function emergencyLifecycleCompatibility() external view override returns (bool) {
        return ICompdEmergencyVaultV2(vault).lifecycle() == CompdV2Types.Lifecycle.EMERGENCY_RECOVERY;
    }
    function emergencyExitRun(uint256) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function emergencyRunStatus(uint256) external pure override returns (CompdV2Types.EmergencyRunStatus) {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function closePosition(uint256) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function activeRunCount() external pure override returns (uint256) { revert CompdV2Errors.ImplementationDeferred(); }
    function activeRunAt(uint256) external pure override returns (uint256) { revert CompdV2Errors.ImplementationDeferred(); }
    function adapterForRun(uint256) external view override returns (address) { return strategyAdapter; }
}

/// @notice Existing typed synchronous adapter compatibility boundary, versioned for V2 review.
interface ICompdStrategyAdapterV2 is ICompdStrategyAdapter { }
