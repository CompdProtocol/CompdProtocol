// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {VaultFactoryBaseV2} from "../../src/flap/VaultFactoryBaseV2.sol";
import {VaultDataSchema} from "../../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../../src/flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {IPortalTypes} from "../../src/flap/IPortal.sol";
import {CompdNativeFeeReceiverV3} from "../production/v3/phase7cr2ch/CompdNativeFeeReceiverV3.sol";

interface ICompdNativeFactoryKernelV3 {
    function nativeFeeReceiver() external view returns (address);
    function nativeFeeReceiverHash() external view returns (bytes32);
    function eligibilityToken() external view returns (address);
}
interface ICompdFlapTaxTokenV3 { function taxProcessor() external view returns (address); }
interface ICompdFlapNativeProcessorV3 {
    function taxToken() external view returns (address);
    function marketAddress() external view returns (address);
    function dispatch() external;
}

/// @dev Shared binding path. The concrete production constructor below enforces COMPD CA.
abstract contract CompdNativeFactoryBindingV3 is VaultFactoryBaseV2 {
    address public immutable kernel;
    address public immutable taxToken;
    CompdNativeFeeReceiverV3 public immutable receiver;
    bytes32 public immutable kernelHash;
    bytes32 public immutable receiverHash;
    bool public bound;
    bool private _entered;
    uint256 public constant DISPATCH_GAS = 1_000_000;

    error InvalidBinding();
    error InvalidLaunch();
    error Reentrancy();
    event VaultBound(address indexed token, address indexed receiver);
    event FeesProcessed(address indexed processor, bool dispatched, bool forwarded);

    constructor(address kernel_) {
        if (kernel_.code.length == 0) revert InvalidBinding();
        ICompdNativeFactoryKernelV3 k = ICompdNativeFactoryKernelV3(kernel_);
        address r = k.nativeFeeReceiver();
        address t = k.eligibilityToken();
        if (r.code.length == 0 || t == address(0)) revert InvalidBinding();
        CompdNativeFeeReceiverV3 candidate = CompdNativeFeeReceiverV3(payable(r));
        if (candidate.kernel() != kernel_ || candidate.taxToken() != t
            || candidate.vaultQuoteToken() != address(0) || r.codehash != k.nativeFeeReceiverHash()) revert InvalidBinding();
        kernel = kernel_; taxToken = t; receiver = candidate;
        kernelHash = kernel_.codehash; receiverHash = r.codehash;
    }

    function factorySpecVersion() public pure override returns (string memory) { return "v2.3"; }
    function isQuoteTokenSupported(address quote) external pure override returns (bool) { return quote == address(0); }
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "Native COMPD fees; returns the immutable Kernel-created receiver. No custom data.";
    }
    function onBeforeLaunch(bytes calldata encoded) external pure override returns (bool, string memory) {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d = abi.decode(encoded, (IVaultFactoryValidationV2.LaunchValidationDataV1));
        if (d.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3 || d.quoteToken != address(0)
            || d.buyTaxRate != 200 || d.sellTaxRate != 200 || d.vaultBps != 10_000
            || d.deflationBps != 0 || d.dividendBps != 0 || d.lpBps != 0
            || d.dividendToken != address(0) || d.minimumShareBalance != 0) return (false, "Requires native Taxed V3, 2% buy/sell and 100% Vault allocation.");
        return (true, "");
    }
    function onBeforeNewTokenV6WithVault(IVaultPortalTypes.NewTokenV6WithVaultParams calldata)
        external pure override returns (bool, string memory) { return (false, "Use normalized V3 validation."); }

    function newVault(address token, address quote, address, bytes calldata data) external override returns (address) {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        _checkGraph();
        if (bound || token != taxToken || quote != address(0) || data.length != 0) revert InvalidLaunch();
        bound = true;
        emit VaultBound(token, address(receiver));
        return address(receiver);
    }

    /// @notice Permissionless keeper tick: dispatch first, then retry pending forwarding.
    /// @dev No owner claim, caller reward, custody, arbitrary destination or approvals.
    /// Dispatch failure does not block previously received BNB from being forwarded.
    function processFees() external returns (bool dispatched, bool forwarded) {
        if (_entered) revert Reentrancy();
        _checkGraph();
        _entered = true;
        address processor;
        if (bound && taxToken.code.length != 0) {
            processor = ICompdFlapTaxTokenV3(taxToken).taxProcessor();
            if (processor.code.length == 0 || ICompdFlapNativeProcessorV3(processor).taxToken() != taxToken
                || ICompdFlapNativeProcessorV3(processor).marketAddress() != address(receiver)) revert InvalidBinding();
            bytes memory payload = abi.encodeCall(ICompdFlapNativeProcessorV3.dispatch, ());
            uint256 budget = DISPATCH_GAS;
            assembly ("memory-safe") {
                dispatched := call(budget, processor, 0, add(payload, 32), mload(payload), 0, 0)
            }
        }
        forwarded = receiver.forwardPending();
        _entered = false;
        emit FeesProcessed(processor, dispatched, forwarded);
    }

    function _checkGraph() private view {
        if (kernel.codehash != kernelHash || address(receiver).codehash != receiverHash) revert InvalidBinding();
    }
}

/// @notice Production factory for the reserved COMPD token; its address cannot be substituted.
contract CompdNativeVaultFactoryV3 is CompdNativeFactoryBindingV3 {
    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    constructor(address kernel_) CompdNativeFactoryBindingV3(kernel_) {
        if (taxToken != COMPD_TOKEN) revert InvalidBinding();
    }
}
