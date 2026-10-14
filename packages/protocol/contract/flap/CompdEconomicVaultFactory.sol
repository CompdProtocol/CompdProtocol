// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompdEconomicVault} from "../CompdEconomicVault.sol";
import {VaultDataSchema, FieldDescriptor} from "../../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../../src/flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactoryBaseV2} from "../../src/flap/VaultFactoryBaseV2.sol";

/// @notice Local Flap V3 factory candidate that routes 100% of tax into the economic vault.
/// @dev Product constraint (2%/2%, 100% vault) is project policy, not a universal Flap rule.
contract CompdEconomicVaultFactory is VaultFactoryBaseV2 {
    address public immutable accountingAdmin;
    event VaultCreated(address indexed taxToken, address indexed quoteToken, address indexed vault);

    constructor(address accountingAdmin_) {
        require(accountingAdmin_ != address(0), "Zero address");
        accountingAdmin = accountingAdmin_;
    }
    function factorySpecVersion() public pure override returns (string memory) { return "v2.2"; }
    function isQuoteTokenSupported(address quoteToken) external view override returns (bool) {
        if (quoteToken == address(0)) return true;
        if (quoteToken.code.length == 0) return false;
        (bool ok, bytes memory data) = quoteToken.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length == 32;
    }
    function onBeforeLaunch(bytes calldata validationData) external pure override returns (bool, string memory) {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data =
            abi.decode(validationData, (IVaultFactoryValidationV2.LaunchValidationDataV1));
        if (data.buyTaxRate != 200 || data.sellTaxRate != 200) return (false, "Buy and sell tax must each be 2%.");
        if (data.vaultBps != 10_000 || data.deflationBps != 0 || data.dividendBps != 0 || data.lpBps != 0) {
            return (false, "Route 100% of tax revenue to the Vault; burn, dividend, and LP allocations must be zero.");
        }
        return (true, "");
    }
    function onBeforeNewTokenV6WithVault(IVaultPortalTypes.NewTokenV6WithVaultParams calldata)
        external pure override returns (bool success, string memory reason)
    {
        return (false, "Legacy V6 launch validation is disabled.");
    }
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "No custom data. Accounting roles and economic splits are set once by the fixed admin after deployment.";
        schema.fields = new FieldDescriptor[](0);
        schema.isArray = false;
    }
    function newVault(address taxToken, address quoteToken, address, bytes calldata)
        external override returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), "Only Vault Portal");
        require(taxToken != address(0), "Zero address");
        require(this.isQuoteTokenSupported(quoteToken), "Unsupported quote token");
        vault = address(new CompdEconomicVault(taxToken, quoteToken, accountingAdmin));
        emit VaultCreated(taxToken, quoteToken, vault);
    }
}
