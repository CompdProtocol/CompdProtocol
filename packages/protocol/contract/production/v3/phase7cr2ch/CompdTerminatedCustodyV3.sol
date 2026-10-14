// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

interface ITerminatedCustodyKernelV3 {
    function lifecycle() external view returns(uint8);
}
interface ITerminatedCustodyTokenV3 {
    function balanceOf(address) external view returns(uint256);
    function transfer(address,uint256) external returns(bool);
}
/// @dev Internal library, no separately deployed authority. Caller must hold its
/// own reentrancy lock. Kernel termination proves that committed runs are closed;
/// these native-only executors/buffers have no remaining accounted liabilities.
library CompdTerminatedCustodyV3 {
    address internal constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address internal constant TREASURY=0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    error RecoveryUnavailable();
    event CustodyRecovered(address indexed asset,uint256 amount);
    function check(address kernel) internal view {
        if(msg.sender!=GUARDIAN||ITerminatedCustodyKernelV3(kernel).lifecycle()!=3)revert RecoveryUnavailable();
    }
    function native(address kernel) internal returns(uint256 amount){
        check(kernel);amount=address(this).balance;if(amount==0)return 0;
        (bool ok,)=payable(TREASURY).call{value:amount,gas:50_000}("");
        if(!ok||address(this).balance!=0)revert RecoveryUnavailable();
        emit CustodyRecovered(address(0),amount);
    }
    function token(address kernel,address asset,uint256 amount) internal {
        check(kernel);if(amount==0)revert RecoveryUnavailable();
        ITerminatedCustodyTokenV3 t=ITerminatedCustodyTokenV3(asset);uint256 before_=t.balanceOf(address(this));
        if(!t.transfer(TREASURY,amount)||before_-t.balanceOf(address(this))!=amount)revert RecoveryUnavailable();
        emit CustodyRecovered(asset,amount);
    }
}
