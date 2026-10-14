// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHolderEpochsTest} from "../holder-epochs/CompdHolderEpochs.t.sol";
import {T} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
contract ZeroCopyToggleReceiver {
    uint256 public length; bool public reject;
    function configure(uint256 n,bool r) external {length=n;reject=r;}
    receive() external payable {uint n=length;bool r=reject;assembly{if r{revert(0,n)}return(0,n)}}
}
contract CompdHolderZeroCopyAcceptanceTest is CompdHolderEpochsTest {
    function _cold(address r) private {vm.cool(address(kernel));vm.cool(address(holder));vm.cool(address(state));vm.cool(address(candidate));vm.cool(address(distributor));vm.cool(kernel.liability());vm.cool(r);}
    function _fund(address r) private returns(bytes32 leaf){_settle(1.1 ether);return _nonempty(r);}
    function _backed(bytes32 leaf,address r) private view {assertEq(address(r).balance,0);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(state.outstandingHolderLiability(),0.01 ether);(uint8 mask,bool used)=state.consumption(leaf);assertEq(mask,0);assertFalse(used);_assertAccounting();}
    function _paid(address r) private view {assertEq(address(r).balance,0.01 ether);assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);_assertAccounting();}
    function testZeroCopy128KiBSucceedsAtFormerGriefBudget() public {
        ZeroCopyToggleReceiver r=new ZeroCopyToggleReceiver();bytes32 leaf=_fund(address(r));r.configure(131072,false);_cold(address(r));
        (bool ok,bytes memory result)=address(holder).call{gas:400000}(abi.encodeWithSignature("pay(bytes32)",leaf));assertTrue(ok);assertTrue(abi.decode(result,(bool)));_paid(address(r));
        vm.expectRevert();holder.pay(leaf);_paid(address(r));
    }
    function testZeroCopyLargeRevertPreservesFailureProofAndRetry() public {
        ZeroCopyToggleReceiver r=new ZeroCopyToggleReceiver();bytes32 leaf=_fund(address(r));r.configure(131072,true);_cold(address(r));assertFalse(holder.pay(leaf));_backed(leaf,address(r));
        (T.HolderPayment memory p,)=state.paymentData(leaf);assertTrue(holder.hasFailure(p.useId));assertEq(p.expiresAt,0);r.configure(131072,false);_cold(address(r));assertTrue(holder.retry(p.useId));_paid(address(r));vm.expectRevert();holder.retry(p.useId);
    }
    function testZeroCopyRecipientOOGAndSevenDayTerminalRetry() public {
        ZeroCopyToggleReceiver r=new ZeroCopyToggleReceiver();bytes32 leaf=_fund(address(r));r.configure(1048576,false);_cold(address(r));assertFalse(holder.pay(leaf));_backed(leaf,address(r));
        (T.HolderPayment memory p,)=state.paymentData(leaf);assertTrue(holder.hasFailure(p.useId));vm.prank(GUARDIAN);kernel.emergencyShutdown();holder.terminalize(leaf);
        (bool terminal,uint64 began,uint64 expiry,)=state.terminalStatus(leaf);assertTrue(terminal);assertEq(expiry-began,604800);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        vm.prank(GUARDIAN);kernel.recoverAllTerminatedFunds();_backed(leaf,address(r));assertEq(address(kernel).balance,0.01 ether);r.configure(131072,false);vm.warp(expiry-1);_cold(address(r));
        (bool low,)=address(holder).call{gas:100000}(abi.encodeWithSignature("retry(bytes32)",p.useId));assertFalse(low);_backed(leaf,address(r));
        _cold(address(r));(bool ok,bytes memory result)=address(holder).call{gas:400000}(abi.encodeWithSignature("retry(bytes32)",p.useId));assertTrue(ok);assertTrue(abi.decode(result,(bool)));_paid(address(r));vm.expectRevert();holder.retry(p.useId);
    }
    function testZeroCopyInsufficientCallerGasRollsBackWithoutErasingEntitlement() public {
        ZeroCopyToggleReceiver r=new ZeroCopyToggleReceiver();bytes32 leaf=_fund(address(r));r.configure(131072,false);_cold(address(r));
        (bool low,)=address(holder).call{gas:100000}(abi.encodeWithSignature("pay(bytes32)",leaf));assertFalse(low);_backed(leaf,address(r));
        (T.HolderPayment memory p,)=state.paymentData(leaf);assertFalse(holder.hasFailure(p.useId));_cold(address(r));assertTrue(holder.pay(leaf));_paid(address(r));
    }
}
