// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {VaultBaseV3} from "../../../../src/flap/VaultBaseV3.sol";
import {VaultUISchema} from "../../../../src/flap/IVaultSchemasV1.sol";
import {CompdTerminatedCustodyV3 as Recovery} from "./CompdTerminatedCustodyV3.sol";

interface ICompdNativeRevenueKernelV3 {
    function creditNativeRevenue() external payable;
}

/// @notice Native-only custody buffer. Its creating Kernel is its sole destination.
/// @dev Empty receive deliberately does not authenticate, account, emit or forward.
/// All native receipts (including donations/forced BNB) are pending protocol revenue;
/// this contract does not assert that a receipt originated from Flap.
contract CompdNativeFeeReceiverV3 is VaultBaseV3 {
    address public immutable kernel;
    address public immutable taxToken;
    uint256 public totalForwarded;
    bool private _entered;

    error InvalidConfiguration();
    error Reentrancy();
    event NativeRevenueForwarded(uint256 amount);
    event NativeRevenueDeferred(uint256 amount);

    constructor(address kernel_, address taxToken_) {
        if (kernel_ != msg.sender || taxToken_ == address(0)) revert InvalidConfiguration();
        kernel = kernel_;
        taxToken = taxToken_;
    }

    receive() external payable {}

    function pendingBNB() public view returns (uint256) { return address(this).balance; }
    /// @notice Late fees remain recoverable after forwarding is permanently frozen.
    function recoverTerminatedFunds() external returns(uint256 amount){
        if(_entered)revert Reentrancy();_entered=true;amount=Recovery.native(kernel);_entered=false;
    }
    function rescueAccidentalERC20(address token,uint256 amount) external {
        if(_entered)revert Reentrancy();_entered=true;Recovery.token(kernel,token,amount);_entered=false;
    }

    /// @notice Anyone can forward pending BNB to the immutable Kernel, never themselves.
    /// @dev Failure rolls back the value transfer; balance remains the retry ledger.
    /// No returndata is copied from the external call, avoiding returndata griefing.
    function forwardPending() external returns (bool forwarded) {
        if (_entered) revert Reentrancy();
        uint256 amount = address(this).balance;
        if (amount == 0) return false;
        if (kernel.code.length == 0) { emit NativeRevenueDeferred(amount); return false; }
        _entered = true;
        address destination = kernel;
        bytes memory payload = abi.encodeCall(ICompdNativeRevenueKernelV3.creditNativeRevenue, ());
        assembly ("memory-safe") {
            forwarded := call(gas(), destination, amount, add(payload, 32), mload(payload), 0, 0)
        }
        if (forwarded) {
            totalForwarded += amount;
            emit NativeRevenueForwarded(amount);
        } else {
            emit NativeRevenueDeferred(amount);
        }
        _entered = false;
    }

    function vaultQuoteToken() public pure override returns (address) { return address(0); }
    function description() public pure override returns (string memory) { return "COMPD native fee custody; permissionless forwarding to immutable V3 Kernel"; }
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "COMPD Native Fee Receiver V3";
        schema.description = "Accepts native fees; forwardPending sends all pending BNB to the fixed Kernel.";
    }
}

