// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdBuybackPolicyModuleR2} from "../../v2/phase7ar2/CompdBuybackPolicyModuleR2.sol";
import {CompdBuybackExecutorV3} from "./CompdBuybackExecutorV3.sol";
/// @notice Reuses canonical 6h cooldown / 20% current / 40% rolling cohort / 0.5 BNB caps.
contract CompdBuybackPolicyModuleV3 is CompdBuybackPolicyModuleR2 {
    constructor(address kernel_,address executor_) CompdBuybackPolicyModuleR2(kernel_,executor_,CompdBuybackExecutorV3(executor_).policyCommitment()) {
        if(CompdBuybackExecutorV3(executor_).boundKernel()!=kernel_)revert Unauthorized();
    }
    address public constant MANUAL_BUYBACK_ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    bool public constant manualOnly=true;
    /// @notice Only the existing Buyback Admin can request a bounded manual operation.
    /// Kernel custody, activation, route and exact supply-burn requirements remain unchanged.
    function _authorizeCaller() internal view override {if(msg.sender!=MANUAL_BUYBACK_ADMIN)revert Unauthorized();}
}
