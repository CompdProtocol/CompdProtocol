// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BBuybackExecutorR6R2B} from "../phase7ar2/C2G2BTypesR2.sol";

/// @notice Day-1 deployment dependency only. This contract has no trading route
/// and permanently rejects execution; it cannot custody or withdraw treasury funds.
contract CompdBuybackExecutorDisabledV1 is C2G2BBuybackExecutorR6R2B {
    address public immutable override boundKernel;

    error InvalidKernel();
    error Unauthorized();
    error BuybackDisabled();

    constructor(address predictedKernel_) {
        if (predictedKernel_ == address(0)) revert InvalidKernel();
        boundKernel = predictedKernel_;
    }

    function executeExactInput(bytes32, bytes32) external payable override {
        if (msg.sender != boundKernel) revert Unauthorized();
        revert BuybackDisabled();
    }
}
