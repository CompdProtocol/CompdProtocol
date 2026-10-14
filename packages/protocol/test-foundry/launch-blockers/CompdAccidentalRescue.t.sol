// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase} from "../phase7cr2ch/CompdHReadyLocalQualification.t.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";

contract AccidentalTokenFixture {
    mapping(address=>uint256) public balanceOf;
    uint8 public behavior;
    address public callback;
    function mint(address to,uint256 n) external {balanceOf[to]+=n;}
    function configure(uint8 b,address c) external {behavior=b;callback=c;}
    function transfer(address to,uint256 n) external returns(bool){
        if(behavior==1)return false;
        if(behavior==2)return true;
        balanceOf[msg.sender]-=n;balanceOf[to]+=n;
        if(behavior==3){(bool ok,)=callback.call(abi.encodeWithSignature("rescueAccidentalERC20(address,uint256)",address(this),n));require(!ok,"reentry escaped");}
        if(behavior==4){assembly {return(0,0)}}
        return true;
    }
}

contract CompdAccidentalRescueTest is CompdHReadyQualificationBase {
    /// @dev Ledger replay of the recorded real TSLAx fork micro trade:
    /// work/launch-blockers/fork-roundtrip.json, block 126753030.
    /// Existing local adapter fixture supplies that physical return. This is
    /// NOT a qualified xStocks adapter or end-to-end COMPD route assertion.
    function testObservedForkReturnAccountingReplayNoProfitOrHolderCredit() public {
        uint256 principal=1_000_000_000_000;uint256 returned=995_014_342_817;
        uint256 oldCapital=kernel.strategyCapital();uint256 oldAccounted=kernel.accountedQuote();
        _openQualification(4242,principal);vm.prank(GUARDIAN);settlement.requestExit(4242,keccak256("RECORDED_FORK_EXIT"));
        vm.deal(address(adapter),returned);vm.prank(GUARDIAN);settlement.closeRun(4242,keccak256("RECORDED_FORK_CLOSE"));
        assertEq(kernel.runActualLoss(4242),principal-returned);assertEq(kernel.cumulativeRealizedLoss(),principal-returned);
        assertEq(kernel.strategyCapital(),oldCapital-principal+returned);assertEq(kernel.accountedQuote(),oldAccounted-principal+returned);
        assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);
        assertEq(kernel.activePrincipal(),0);assertFalse(kernel.runLossBoundBreached(4242));assertFalse(settlement.riskLatched());_assertAccounting();
    }
    function testRescueOnlyAfterTerminationAndOnlyGuardian() public {
        AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),100);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),100);
        _shutdownAndTerminate();vm.prank(ADMIN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),100);
        vm.prank(GUARDIAN);kernel.rescueAccidentalERC20(address(t),100);
        assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),100);assertEq(t.balanceOf(address(kernel)),0);_assertAccounting();
    }
    function testRescueNeverDebitsNativeReservesOrPaysCaller() public {
        _terminatedProfit();bytes32 id=state.emptyRecoveryId(_window());
        // Unrelated foreign ERC20 rescue must not require clearing native HR.
        AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),5);
        uint256 hr=kernel.holderRewardReserve();assertGt(hr,0);uint256 physical=address(kernel).balance;uint256 aq=kernel.accountedQuote();uint256 sc=kernel.strategyCapital();uint256 br=kernel.buybackReserve();uint256 pr=kernel.protocolReserve();uint256 ntp=kernel.nonStrategyTreasuryPrincipal();
        vm.prank(GUARDIAN);kernel.rescueAccidentalERC20(address(t),5);
        assertEq(kernel.holderRewardReserve(),hr);assertEq(address(kernel).balance,physical);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.strategyCapital(),sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.nonStrategyTreasuryPrincipal(),ntp);assertEq(t.balanceOf(GUARDIAN),0);_assertAccounting();
    }
    function _window() private view returns(bytes32 w){(w,,,,)=kernel.deriveWindow(windowStart);}
    function testRescueUnaccountedCOMPDOnlyAfterTerminationNeverNativeBacking() public {
        address canonical=kernel.eligibilityToken();AccidentalTokenFixture fixture=new AccidentalTokenFixture();vm.etch(canonical,address(fixture).code);AccidentalTokenFixture(canonical).mint(address(kernel),9);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(canonical,9);
        _shutdownAndTerminate();uint256 nativeBalance=address(kernel).balance;uint256 aq=kernel.accountedQuote();
        vm.prank(GUARDIAN);kernel.rescueAccidentalERC20(canonical,9);assertEq(AccidentalTokenFixture(canonical).balanceOf(kernel.RECOVERY_TREASURY()),9);assertEq(address(kernel).balance,nativeBalance);assertEq(kernel.accountedQuote(),aq);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(0),1);_assertAccounting();
    }
    function testRescueRejectsZeroExcessAndRepeatedDepletion() public {
        _shutdownAndTerminate();AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),5);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),0);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),6);
        vm.prank(GUARDIAN);kernel.rescueAccidentalERC20(address(t),5);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),5);_assertAccounting();
    }
    function testRescueFalseAndFakeSuccessRollBack() public {
        _shutdownAndTerminate();AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),5);
        for(uint8 b=1;b<=2;++b){t.configure(b,address(0));vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),5);assertEq(t.balanceOf(address(kernel)),5);assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),0);}_assertAccounting();
    }
    function testRescueReentryCannotExtractOtherAssets() public {
        _shutdownAndTerminate();AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),5);t.configure(3,address(kernel));
        vm.prank(GUARDIAN);kernel.rescueAccidentalERC20(address(t),5);assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),5);_assertAccounting();
    }
    function testRescueNonReturningTokenRollsBackInsteadOfClaimingSuccess() public {
        _shutdownAndTerminate();AccidentalTokenFixture t=new AccidentalTokenFixture();t.mint(address(kernel),5);t.configure(4,address(0));
        vm.prank(GUARDIAN);vm.expectRevert();kernel.rescueAccidentalERC20(address(t),5);assertEq(t.balanceOf(address(kernel)),5);assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),0);_assertAccounting();
    }
}
