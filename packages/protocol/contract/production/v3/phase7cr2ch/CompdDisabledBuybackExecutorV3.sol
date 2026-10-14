// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdTerminatedCustodyV3 as Recovery} from "./CompdTerminatedCustodyV3.sol";

/// @notice Permanently disabled Kernel dependency. No approvals, swap, burn,
/// arbitrary-call or replacement functions are exposed. Terminated accidental
/// custody can only return to the fixed Recovery Treasury.
contract CompdDisabledBuybackExecutorV3 {
    address public immutable boundKernel;
    error Disabled();
    bool private entered;
    modifier lock(){if(entered)revert Disabled();entered=true;_;entered=false;}

    constructor(address predictedKernel_) {
        if (predictedKernel_ == address(0)) revert Disabled();
        boundKernel = predictedKernel_;
    }

    function executeExactInput(bytes32, bytes32) external payable { revert Disabled(); }
    function recoverTerminatedFunds() external lock returns(uint256){return Recovery.native(boundKernel);}
    function rescueAccidentalERC20(address token,uint256 amount) external lock {Recovery.token(boundKernel,token,amount);}
}
