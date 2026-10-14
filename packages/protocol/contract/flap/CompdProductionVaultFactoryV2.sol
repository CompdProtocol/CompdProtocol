// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Errors} from "../production/v2/CompdV2Types.sol";
import {ICompdEmergencyVaultV2} from "../production/v2/ICompdEmergencyVaultV2.sol";
import {ICompdProductionVaultFactoryV2} from "../production/v2/ICompdProductionVaultFactoryV2.sol";

/// @notice V2 Factory identity scaffold. No receiver deployment or Flap launch path is implemented here.
contract CompdProductionVaultFactoryV2 is ICompdProductionVaultFactoryV2 {
    address public immutable override productionVault;
    address public immutable override compdToken;
    address public immutable override quoteToken;

    constructor(address vault_) {
        if (vault_.code.length == 0) revert CompdV2Errors.InvalidImmutableConfiguration();
        ICompdEmergencyVaultV2 vaultInterface = ICompdEmergencyVaultV2(vault_);
        productionVault = vault_;
        compdToken = vaultInterface.compdToken();
        quoteToken = vaultInterface.quoteToken();
    }
}
