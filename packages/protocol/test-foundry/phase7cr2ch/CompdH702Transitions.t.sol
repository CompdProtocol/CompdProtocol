// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdPhase7CR2CH7PartitionRecoveryTest,Kernel,T,Evidence} from "./CompdPhase7CR2CH7PartitionRecovery.t.sol";
interface IH702Driver {function step(uint8,uint16) external;}
contract H702Actions {IH702Driver immutable driver;constructor(IH702Driver d){driver=d;}function step(uint8 action,uint16 dt) external {driver.step(action,dt);}}
contract CompdH702TransitionTest is CompdPhase7CR2CH7PartitionRecoveryTest {
    function _next(uint256 id) internal {address a=kernel.AUTOMATION_EXECUTOR();vm.prank(a);settlement.startRun(id,address(adapter),1 ether,bytes32(id));vm.prank(a);settlement.requestExit(id,bytes32(id+1000));vm.deal(address(adapter),1.1 ether);vm.prank(a);settlement.closeRun(id,bytes32(id+2000));}
    function _exactId(uint8 p,uint256 amount) internal view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),block.chainid,address(kernel),p,kernel.shutdownAt(),amount));}
    function testH702MultipleHistoricalWindowsNeverBecomeEligibleAgain() public {
        _settle();uint64 first=uint64(block.timestamp/28800*28800);vm.warp(block.timestamp+28800);_next(2);vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();
        assertEq(kernel.activationSealFailureHR(),0.02 ether);assertEq(kernel.holderWindowAccrued(first),0.01 ether);assertEq(kernel.eligibleWindowHR(),0);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(kernel.shutdownTailHR(),0);_partitions();vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 id=_exactId(2,0.02 ether);vm.prank(GUARDIAN);recovery.recoverActivationSealFailure(id);_partitions();assertEq(kernel.holderRewardReserve(),0);(,,,,bool eligible)=kernel.deriveWindow(first);assertFalse(eligible);
    }
    function testH702ProfitAfterFailureRoutesOnlyToFailureBucket() public {_settle();vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();_next(2);assertEq(kernel.activationSealFailureHR(),0.02 ether);assertEq(kernel.eligibleWindowHR(),0);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(kernel.shutdownTailHR(),0);_partitions();}
    function testH702CloseAfterShutdownKeepsFailureAndTailDistinct() public {
        _settle();vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();address a=kernel.AUTOMATION_EXECUTOR();vm.prank(a);settlement.startRun(2,address(adapter),1 ether,bytes32(uint256(2)));
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.prank(a);settlement.requestExit(2,bytes32(uint256(1002)));vm.deal(address(adapter),1.1 ether);vm.prank(a);settlement.closeRun(2,bytes32(uint256(2002)));
        assertEq(kernel.activationSealFailureHR(),0.01 ether);assertEq(kernel.shutdownTailHR(),0.01 ether);_partitions();vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 failure=_exactId(2,0.01 ether);bytes32 tail=_exactId(3,0.01 ether);vm.prank(GUARDIAN);recovery.recoverActivationSealFailure(failure);assertEq(kernel.holderRewardReserve(),0.01 ether);vm.prank(GUARDIAN);recovery.recoverShutdownTail(tail);_partitions();assertEq(kernel.holderRewardReserve(),0);
    }
    function testH702ZeroFailureAndExact256SuccessfulSeal() public {uint64 a=kernel.activationBlock();vm.roll(a+256);vm.expectRevert(Kernel.InvalidLifecycle.selector);kernel.failExpiredActivationSeal();vm.setBlockhash(a,keccak256("H702_BOUNDARY"));assertTrue(kernel.sealActivationCheckpoint());_settle();_validateAndRecover(3);_partitions();}
    function testH702ZeroAccrualFailureCanShutdownAndTerminate() public {vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();_partitions();assertEq(kernel.holderRewardReserve(),0);}
}
contract CompdH702StatefulTest is CompdPhase7CR2CH7PartitionRecoveryTest,IH702Driver {
    H702Actions actions;uint256 runs;uint256 recovered;
    function setUp() public override {super.setUp();actions=new H702Actions(this);targetContract(address(actions));bytes4[] memory s=new bytes4[](1);s[0]=actions.step.selector;targetSelector(FuzzSelector(address(actions),s));}
    function step(uint8 action,uint16 dt) external {
        require(msg.sender==address(actions));uint8 x=action%7;T.Lifecycle life=kernel.lifecycle();
        if(x==0&&life==T.Lifecycle.ACTIVE&&runs<8){++runs;address a=kernel.AUTOMATION_EXECUTOR();vm.prank(a);settlement.startRun(runs,address(adapter),1 ether,bytes32(runs));vm.prank(a);settlement.requestExit(runs,bytes32(runs+1000));vm.deal(address(adapter),1.1 ether);vm.prank(a);settlement.closeRun(runs,bytes32(runs+2000));}
        else if(x==1){vm.warp(block.timestamp+dt);}
        else if(x==2&&!kernel.activationSealFailed()){vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();}
        else if(x==3&&(life==T.Lifecycle.ACTIVE||life==T.Lifecycle.PAUSED)){vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);}
        else if(x==4&&life==T.Lifecycle.SHUTDOWN_PENDING){vm.warp(kernel.shutdownAt()>block.timestamp?kernel.shutdownAt():block.timestamp);if(state.recoveryReconciliationComplete()){vm.prank(GUARDIAN);kernel.terminate();}}
        else if(x==5&&life==T.Lifecycle.TERMINATED){uint256 amount=kernel.activationSealFailureHR();uint8 p=2;if(amount==0){amount=kernel.shutdownTailHR();p=3;}if(amount!=0){bytes32 id=keccak256(abi.encode(keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),block.chainid,address(kernel),p,kernel.shutdownAt(),amount));vm.prank(GUARDIAN);if(p==2)recovery.recoverActivationSealFailure(id);else recovery.recoverShutdownTail(id);recovered+=amount;}}
        else if(x==6&&life==T.Lifecycle.ACTIVE){vm.prank(GUARDIAN);kernel.pause();}else if(x==6&&life==T.Lifecycle.PAUSED){vm.prank(GUARDIAN);kernel.resume();}
    }
    function invariantH702PartitionConservationAndRecoveryNoDoubleDebit() public view {_partitions();assertEq(kernel.holderRewardReserve()+recovered,runs*0.01 ether);assertEq(kernel.activePrincipal(),0);assertGe(address(kernel).balance,kernel.accountedQuote());if(kernel.activationSealFailed())assertEq(kernel.eligibleWindowHR(),0);assertFalse(kernel.buybackActivated());}
}
