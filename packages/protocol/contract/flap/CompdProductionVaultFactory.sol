// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactoryBaseV2} from "../../src/flap/VaultFactoryBaseV2.sol";
import {VaultDataSchema, FieldDescriptor} from "../../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../../src/flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {IPortalTypes} from "../../src/flap/IPortal.sol";
import {ICompdProductionVaultReceiver} from "../production/ICompdProductionInterfaces.sol";
import {CompdThinFlapReceiver} from "./CompdThinFlapReceiver.sol";

/// @notice Flap V3 v2.3+ factory for the one canonical COMPD launch.
/// @dev Flap owns tax-duration validation; its normalized pre-launch hook has no duration field.
contract CompdProductionVaultFactory is VaultFactoryBaseV2 {
    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    ICompdProductionVaultReceiver public immutable productionVault;

    error InvalidLaunch();

    event VaultCreated(address indexed taxToken, address indexed quoteToken, address indexed receiver);

    constructor(address productionVault_) {
        if (productionVault_.code.length == 0) revert InvalidLaunch();
        productionVault = ICompdProductionVaultReceiver(productionVault_);
    }

    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    function isQuoteTokenSupported(address quoteToken) external view override returns (bool) {
        if (quoteToken != productionVault.quoteToken()) return false;
        if (quoteToken == address(0)) return true;
        if (quoteToken.code.length == 0) return false;
        (bool ok, bytes memory data) = quoteToken.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length == 32;
    }

    function onBeforeLaunch(bytes calldata validationData)
        external
        view
        override
        returns (bool success, string memory reason)
    {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data =
            abi.decode(validationData, (IVaultFactoryValidationV2.LaunchValidationDataV1));
        if (data.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) {
            return (false, "COMPD requires the Flap Taxed V3 token version.");
        }
        if (data.quoteToken != productionVault.quoteToken()) {
            return (false, "Launch quote token must match the configured Production Vault quote token.");
        }
        if (data.buyTaxRate != 200 || data.sellTaxRate != 200) {
            return (false, "Buy and sell tax must each be 2%.");
        }
        if (
            data.vaultBps != 10_000 || data.deflationBps != 0 || data.dividendBps != 0 || data.lpBps != 0
                || data.dividendToken != address(0) || data.minimumShareBalance != 0
        ) {
            return (false, "Route 100% of tax revenue to the Vault; burn, dividend and LP allocations must be zero.");
        }
        return (true, "");
    }

    function onBeforeNewTokenV6WithVault(IVaultPortalTypes.NewTokenV6WithVaultParams calldata)
        external
        pure
        override
        returns (bool, string memory)
    {
        return (false, "Legacy V6 launch validation is disabled; use Flap V3 validation.");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "No custom data; the factory binds the canonical COMPD token to its configured Production Vault.";
        schema.fields = new FieldDescriptor[](0);
        schema.isArray = false;
    }

    function newVault(address taxToken, address quoteToken, address, bytes calldata vaultData)
        external
        override
        returns (address receiver)
    {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        if (
            taxToken != COMPD_TOKEN || quoteToken != productionVault.quoteToken() || vaultData.length != 0
                || !_supportsQuote(quoteToken)
        ) revert InvalidLaunch();

        CompdThinFlapReceiver deployed = new CompdThinFlapReceiver(taxToken, quoteToken, address(productionVault));
        receiver = address(deployed);
        productionVault.registerFlapReceiver(receiver);
        emit VaultCreated(taxToken, quoteToken, receiver);
    }

    function _supportsQuote(address quoteToken) private view returns (bool) {
        if (quoteToken == address(0)) return true;
        if (quoteToken.code.length == 0) return false;
        (bool ok, bytes memory data) = quoteToken.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length == 32;
    }
}
