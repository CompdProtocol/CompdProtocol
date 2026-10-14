// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Slot 2 policy adapter. It has no quote source or execution route and
/// permanently reports an unset commitment for the Day-1 disabled configuration.
contract CompdDisabledBuybackPolicyModuleV3 {
    uint8 public constant MODULE_ID = 2;
    uint32 public constant MODULE_VERSION = 3;
    address public immutable kernel;

    error Disabled();

    constructor(address predictedKernel_) {
        if (predictedKernel_ == address(0)) revert Disabled();
        kernel = predictedKernel_;
    }

    function moduleId() external pure returns (uint8) { return MODULE_ID; }
    function moduleVersion() external pure returns (uint32) { return MODULE_VERSION; }
    function buybackConfigurationCommitment() external pure returns (bytes32) { return bytes32(0); }
    function terminationReady() external pure returns (bool) { return true; }
    function attempt(bytes32, bytes32) external pure { revert Disabled(); }
}
