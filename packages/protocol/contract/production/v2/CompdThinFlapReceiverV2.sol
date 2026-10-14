// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types, CompdV2Errors} from "./CompdV2Types.sol";
import {ICompdEmergencyVaultV2, ICompdThinFlapReceiverV2} from "./ICompdEmergencyVaultV2.sol";

/// @notice Flap ingress identity scaffold bound to the exact V2 Vault and its deploying Factory.
/// @dev Revenue recognition, quarantine and emergency sweep are intentionally deferred.
contract CompdThinFlapReceiverV2 is ICompdThinFlapReceiverV2 {
    address public immutable override productionVault;
    address public immutable override vault;
    address public immutable factory;
    address public immutable override taxToken;
    address public immutable override vaultQuoteToken;

    constructor(address vault_, address taxToken_) {
        if (vault_.code.length == 0 || taxToken_ == address(0)) revert CompdV2Errors.InvalidImmutableConfiguration();
        ICompdEmergencyVaultV2 vaultInterface = ICompdEmergencyVaultV2(vault_);
        try vaultInterface.lifecycle() returns (CompdV2Types.Lifecycle) { }
        catch { revert CompdV2Errors.InvalidImmutableConfiguration(); }
        if (taxToken_ != vaultInterface.compdToken()) revert CompdV2Errors.InvalidImmutableConfiguration();
        productionVault = vault_;
        vault = vault_;
        factory = msg.sender;
        taxToken = taxToken_;
        vaultQuoteToken = vaultInterface.quoteToken();
    }

    function emergencySweepAsset(address) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function snapshotEmergencyBalance(bytes32, address) external pure override returns (bool, uint256) {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function emergencyLifecycleCompatibility() external view override returns (bool) {
        return ICompdEmergencyVaultV2(vault).lifecycle() == CompdV2Types.Lifecycle.EMERGENCY_RECOVERY;
    }
    function recognizedPendingRevenue() external pure override returns (uint256) { return 0; }
    function unrecognizedSurplus() external pure override returns (uint256) { return 0; }
}
