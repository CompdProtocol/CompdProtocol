// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types, CompdV2Errors} from "./CompdV2Types.sol";
import {ICompdEmergencyVaultV2, ICompdBuybackExecutorV2} from "./ICompdEmergencyVaultV2.sol";

/// @notice Fresh V2 buyback identity scaffold; router, reserve and burn behavior are deferred.
contract CompdBuybackExecutorV2 is ICompdBuybackExecutorV2 {
    address public immutable override vault;

    constructor(address vault_) {
        if (vault_.code.length == 0) revert CompdV2Errors.InvalidImmutableConfiguration();
        try ICompdEmergencyVaultV2(vault_).lifecycle() returns (CompdV2Types.Lifecycle) { }
        catch { revert CompdV2Errors.InvalidImmutableConfiguration(); }
        vault = vault_;
    }

    function emergencySweepAsset(address) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function snapshotEmergencyBalance(bytes32, address) external pure override returns (bool, uint256) {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function emergencyLifecycleCompatibility() external view override returns (bool) {
        return ICompdEmergencyVaultV2(vault).lifecycle() == CompdV2Types.Lifecycle.EMERGENCY_RECOVERY;
    }
}
