// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase} from "../phase7cr2ch/CompdHReadyLocalQualification.t.sol";
import {T,Kernel,StrategyExecutor} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {H4HostileHolder} from "../phase7cr2ch/CompdPhase7CR2CHCurrentV3.t.sol";
import {AccidentalTokenFixture} from "../launch-blockers/CompdAccidentalRescue.t.sol";
import {CompdNativeFeeReceiverV3 as Receiver} from "../../contracts/production/v3/phase7cr2ch/CompdNativeFeeReceiverV3.sol";
interface ICustodyRecoveryFixture {function recoverTerminatedFunds() external returns(uint256);function rescueAccidentalERC20(address,uint256) external;}
contract RecoveryRejectFixture {receive() external payable {revert();}}
contract RecoveryReentryFixture {
    address immutable kernel;
    address immutable holder;bytes32 immutable useId;
    constructor(address k,address h,bytes32 id){kernel=k;holder=h;useId=id;}
    receive() external payable {
        (bool ok,)=kernel.call(abi.encodeWithSignature("recoverAllTerminatedFunds()"));require(!ok,"reentry escaped");
        (ok,)=holder.call(abi.encodeWithSignature("retry(bytes32)",useId));require(!ok,"holder reentry escaped");
    }
}
abstract contract CompdRecoveryTestBase is CompdHReadyQualificationBase {
    function _unpaidTerminated() internal returns(H4HostileHolder r,bytes32 useId){
        _settle(1.1 ether);r=new H4HostileHolder();bytes32 leaf=_nonempty(address(r));assertFalse(holder.pay(leaf));
        (T.HolderPayment memory p,)=state.paymentData(leaf);useId=p.useId;
        vm.prank(GUARDIAN);kernel.emergencyShutdown();holder.terminalize(leaf);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(state.outstandingHolderLiability(),0.01 ether);
    }
}
contract CompdFullRecoveryTest is CompdRecoveryTestBase {
    function testTerminalGraceSevenDaysFromTerminalizeAndNoEarlierPaymentExpiry() public {
        (,bytes32 useId)=_unpaidTerminated();(,,,bytes32 leaf)=kernel.failedHolder(useId);
        (bool terminal,uint64 started,uint64 expires,bytes32 terminalUse)=state.terminalStatus(leaf);
        assertTrue(terminal);assertEq(terminalUse,useId);assertEq(state.TERMINAL_GRACE(),604_800);
        assertEq(expires,uint256(started)+604_800);assertEq(block.timestamp,uint256(started)+72 hours);
        (T.HolderPayment memory p,bool proof)=state.paymentData(leaf);assertTrue(proof);assertEq(p.expiresAt,0);
        assertEq(kernel.holderRewardReserve(),p.amount);assertEq(state.outstandingHolderLiability(),p.amount);_assertAccounting();
    }
    function testTerminalRetryLastSecondPaysOnceAndPreservesBacking() public {
        (H4HostileHolder r,bytes32 useId)=_unpaidTerminated();(,,,bytes32 leaf)=kernel.failedHolder(useId);
        (,,uint64 expires,)=state.terminalStatus(leaf);uint256 amount=kernel.holderRewardReserve();
        vm.warp(expires-1);r.accept();assertTrue(holder.retry(useId));
        assertEq(address(r).balance,amount);assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);
        vm.expectRevert();holder.retry(useId);assertEq(address(r).balance,amount);_assertAccounting();
    }
    function testTerminalExpiryNoAutomaticWithdrawalAndRecoveryOnlyTerminated() public {
        _settle(1.1 ether);H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_nonempty(address(r));
        assertFalse(holder.pay(leaf));(T.HolderPayment memory p,)=state.paymentData(leaf);
        vm.prank(GUARDIAN);kernel.emergencyShutdown();holder.terminalize(leaf);
        (,,uint64 expires,)=state.terminalStatus(leaf);bytes32 id=state.expiredHolderRecoveryId(leaf);
        uint256 balance=address(kernel).balance;uint256 treasury=kernel.RECOVERY_TREASURY().balance;
        vm.warp(expires);assertEq(address(kernel).balance,balance);assertEq(kernel.RECOVERY_TREASURY().balance,treasury);
        assertEq(kernel.holderRewardReserve(),p.amount);assertEq(state.outstandingHolderLiability(),p.amount);
        (bool eligible,uint256 amount)=state.expiredHolderRecovery(id);assertFalse(eligible);assertEq(amount,0);
        vm.prank(GUARDIAN);vm.expectRevert(Kernel.RecoveryUnavailable.selector);recovery.recoverExpiredLiability(id);
        vm.expectRevert();holder.retry(p.useId);
        vm.prank(GUARDIAN);kernel.terminate();assertEq(kernel.holderRewardReserve(),p.amount);
        vm.prank(ADMIN);vm.expectRevert();recovery.recoverExpiredLiability(id);
        vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);
        assertEq(kernel.RECOVERY_TREASURY().balance-treasury,p.amount);assertEq(state.outstandingHolderLiability(),0);
        assertEq(kernel.holderRewardReserve(),0);uint256 recoveredBalance=address(kernel).balance;
        vm.prank(GUARDIAN);vm.expectRevert();recovery.recoverExpiredLiability(id);
        assertEq(address(kernel).balance,recoveredBalance);_assertAccounting();
    }
    function testShutdownGuardianOnlyImmediateAndNoNewRisk() public {
        vm.prank(ADMIN);vm.expectRevert();kernel.emergencyShutdown();
        vm.prank(EMERGENCY_AUTHORITY);vm.expectRevert();kernel.emergencyEnter();
        vm.prank(GUARDIAN);kernel.emergencyShutdown();assertEq(uint256(kernel.lifecycle()),uint256(T.Lifecycle.SHUTDOWN_PENDING));
        assertEq(kernel.shutdownAt(),block.timestamp+72 hours);
        vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(99,address(adapter),1 ether,keccak256("bad"));
        vm.prank(GUARDIAN);vm.expectRevert();kernel.resume();
        vm.prank(kernel.nativeFeeReceiver());vm.expectRevert();kernel.creditNativeRevenue{value:1}();
        vm.prank(kernel.moduleAddress(T.ModuleId.BUYBACK));vm.expectRevert();kernel.releaseBuyback(keccak256("buy"),1,keccak256("quote"));_assertAccounting();
    }
    function testShutdownEntryAliasAndLegacyOutOfLedgerCashoutDisabled() public {
        vm.prank(GUARDIAN);kernel.emergencyEnter();assertEq(uint256(kernel.lifecycle()),2);
        uint256 b=address(kernel).balance;uint256 aq=kernel.accountedQuote();
        vm.prank(kernel.moduleAddress(T.ModuleId.EMERGENCY));vm.expectRevert();kernel.emergencyTransferBNB(keccak256("scope"),keccak256("attempt"),1,b,keccak256("proof"));
        assertEq(address(kernel).balance,b);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.emergencyBNBOutflow(),0);
    }
    function testTerminationNonzeroLiabilitiesRemainBackedAndRetryAfterFullRecovery() public {
        (H4HostileHolder r,bytes32 useId)=_unpaidTerminated();uint256 hr=kernel.holderRewardReserve();uint256 liabilityBefore=state.outstandingHolderLiability();
        uint256 free=address(kernel).balance-hr;uint256 before_=kernel.RECOVERY_TREASURY().balance;
        vm.prank(GUARDIAN);assertEq(kernel.recoverAllTerminatedFunds(),free);
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,free);assertEq(address(kernel).balance,hr);assertEq(kernel.accountedQuote(),hr);
        assertEq(kernel.holderRewardReserve(),hr);assertEq(state.outstandingHolderLiability(),liabilityBefore);
        assertEq(kernel.strategyCapital(),0);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),0);
        r.accept();assertTrue(holder.retry(useId));assertEq(address(r).balance,hr);assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);
        vm.expectRevert();holder.retry(useId);_assertAccounting();
    }
    function testRecoveryBeforeTerminationAndWrongWalletRejected() public {
        vm.prank(GUARDIAN);vm.expectRevert();kernel.recoverAllTerminatedFunds();
        vm.prank(GUARDIAN);kernel.emergencyShutdown();vm.prank(GUARDIAN);vm.expectRevert();kernel.recoverAllTerminatedFunds();
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        vm.prank(ADMIN);vm.expectRevert();kernel.recoverAllTerminatedFunds();vm.prank(kernel.BUYBACK_ADMIN());vm.expectRevert();kernel.recoverAllTerminatedFunds();
        vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();kernel.recoverAllTerminatedFunds();_assertAccounting();
    }
    function testRecoveryForcedSurplusRepeatedAndLateFundsConservation() public {
        _unpaidTerminated();uint256 hr=kernel.holderRewardReserve();uint256 aq=kernel.accountedQuote();vm.deal(address(kernel),aq+3 ether);
        vm.prank(GUARDIAN);assertEq(kernel.recoverAllTerminatedFunds(),aq-hr+3 ether);
        vm.prank(GUARDIAN);assertEq(kernel.recoverAllTerminatedFunds(),0);
        vm.deal(address(kernel),hr+2 ether);vm.prank(GUARDIAN);assertEq(kernel.recoverAllTerminatedFunds(),2 ether);
        assertEq(address(kernel).balance,hr);assertEq(kernel.accountedQuote(),hr);_assertAccounting();
    }
    function testRecoveryAfterPositionClosureOnlyAndShutdownProfitNotEligibleAccrual() public {
        _openQualification(88,1 ether);vm.prank(GUARDIAN);kernel.emergencyShutdown();
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);vm.expectRevert();kernel.terminate();
        vm.prank(GUARDIAN);settlement.requestExit(88,keccak256("exit"));vm.deal(address(adapter),1.1 ether);
        vm.prank(GUARDIAN);settlement.closeRun(88,keccak256("close"));
        assertEq(kernel.activePrincipal(),0);assertEq(kernel.eligibleWindowHR(),0);assertEq(kernel.shutdownTailHR(),0.01 ether);
        vm.prank(GUARDIAN);kernel.terminate();vm.prank(GUARDIAN);kernel.recoverAllTerminatedFunds();
        assertEq(address(kernel).balance,0.01 ether);assertEq(kernel.cumulativeRealizedProfit(),0.1 ether);_assertAccounting();
    }
    function testRecoveryCrossVaultNativeBalancesAndLateReceiverFees() public {
        _unpaidTerminated();Receiver receiver=Receiver(payable(kernel.nativeFeeReceiver()));
        address[3] memory vaults=[address(receiver),kernel.strategyExecutor(),kernel.buybackExecutor()];uint256 before_=kernel.RECOVERY_TREASURY().balance;
        for(uint256 i;i<3;++i){vm.deal(vaults[i],i+1);vm.prank(ADMIN);vm.expectRevert();ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds();vm.prank(GUARDIAN);assertEq(ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds(),i+1);vm.prank(GUARDIAN);assertEq(ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds(),0);}
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,6);
        vm.deal(address(this),1 ether);(bool accepted,)=address(receiver).call{value:1 ether}("");assertTrue(accepted);assertFalse(receiver.forwardPending());assertEq(receiver.pendingBNB(),1 ether);
        vm.prank(GUARDIAN);assertEq(receiver.recoverTerminatedFunds(),1 ether);assertEq(receiver.totalForwarded(),0);assertEq(kernel.holderRewardReserve(),0.01 ether);_assertAccounting();
    }
    function testRecoveryCrossVaultAccidentalTokensWithOutstandingHolderLiabilities() public {
        _unpaidTerminated();AccidentalTokenFixture t=new AccidentalTokenFixture();
        address[4] memory vaults=[address(kernel),kernel.nativeFeeReceiver(),kernel.strategyExecutor(),kernel.buybackExecutor()];
        for(uint256 i;i<4;++i){t.mint(vaults[i],10);vm.prank(ADMIN);vm.expectRevert();ICustodyRecoveryFixture(vaults[i]).rescueAccidentalERC20(address(t),10);vm.prank(GUARDIAN);ICustodyRecoveryFixture(vaults[i]).rescueAccidentalERC20(address(t),10);assertEq(t.balanceOf(vaults[i]),0);}
        assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),40);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(state.outstandingHolderLiability(),0.01 ether);_assertAccounting();
    }
    function testRecoveryCrossVaultBeforeTerminationBlocked() public {
        address[3] memory vaults=[kernel.nativeFeeReceiver(),kernel.strategyExecutor(),kernel.buybackExecutor()];
        for(uint256 i;i<3;++i){vm.deal(vaults[i],10);vm.prank(GUARDIAN);vm.expectRevert();ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds();assertEq(vaults[i].balance,10);}
    }
    function testRecoveryRejectedTreasuryRollsBackEntireLedger() public {
        _unpaidTerminated();uint256 aq=kernel.accountedQuote();uint256 sc=kernel.strategyCapital();uint256 br=kernel.buybackReserve();uint256 pr=kernel.protocolReserve();uint256 ntp=kernel.nonStrategyTreasuryPrincipal();
        RecoveryRejectFixture r=new RecoveryRejectFixture();vm.etch(kernel.RECOVERY_TREASURY(),address(r).code);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.recoverAllTerminatedFunds();assertEq(kernel.accountedQuote(),aq);assertEq(kernel.strategyCapital(),sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.nonStrategyTreasuryPrincipal(),ntp);_assertAccounting();
        vm.etch(kernel.RECOVERY_TREASURY(),hex"");vm.prank(GUARDIAN);kernel.recoverAllTerminatedFunds();_assertAccounting();
    }
    function testRecoveryTreasuryCallbackCannotReenterOrDrainHolders() public {
        (H4HostileHolder recipient,bytes32 useId)=_unpaidTerminated();recipient.accept();RecoveryReentryFixture r=new RecoveryReentryFixture(address(kernel),address(holder),useId);vm.etch(kernel.RECOVERY_TREASURY(),address(r).code);
        vm.prank(GUARDIAN);kernel.recoverAllTerminatedFunds();assertEq(address(kernel).balance,0.01 ether);assertEq(address(recipient).balance,0);_assertAccounting();
        assertTrue(holder.retry(useId));assertEq(address(recipient).balance,0.01 ether);_assertAccounting();
    }
    function testRecoveryPhysicalInsolvencyBlocksInsteadOfConsumingHolderBacking() public {
        _unpaidTerminated();uint256 aq=kernel.accountedQuote();vm.deal(address(kernel),aq-1);
        vm.prank(GUARDIAN);vm.expectRevert();kernel.recoverAllTerminatedFunds();assertEq(kernel.accountedQuote(),aq);assertEq(kernel.holderRewardReserve(),0.01 ether);
        vm.deal(address(kernel),aq);_assertAccounting();
    }
    function testTerminationDelayAndIrreversibleLifecycle() public {
        vm.prank(GUARDIAN);kernel.emergencyShutdown();vm.prank(GUARDIAN);vm.expectRevert();kernel.terminate();
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();vm.prank(GUARDIAN);vm.expectRevert();kernel.resume();
        vm.prank(ADMIN);vm.expectRevert();kernel.activate();vm.prank(GUARDIAN);vm.expectRevert();kernel.emergencyShutdown();_assertAccounting();
    }
}
contract CompdCrossCustodyRecoveryTest is CompdRecoveryTestBase {
    function testRecoveryCrossVaultTransferFailuresAndCanonicalTokenDoNotTouchHolderBacking() public {
        _unpaidTerminated();AccidentalTokenFixture t=new AccidentalTokenFixture();address canonical=kernel.eligibilityToken();
        AccidentalTokenFixture fixture=new AccidentalTokenFixture();vm.etch(canonical,address(fixture).code);
        address[3] memory vaults=[kernel.nativeFeeReceiver(),kernel.strategyExecutor(),kernel.buybackExecutor()];
        for(uint256 i;i<3;++i){
            t.mint(vaults[i],5);
            for(uint8 behavior=1;behavior<=4;++behavior){if(behavior==3)continue;t.configure(behavior,address(0));vm.prank(GUARDIAN);vm.expectRevert();ICustodyRecoveryFixture(vaults[i]).rescueAccidentalERC20(address(t),5);assertEq(t.balanceOf(vaults[i]),5);assertEq(t.balanceOf(kernel.RECOVERY_TREASURY()),0);}
            AccidentalTokenFixture(canonical).mint(vaults[i],5);vm.prank(GUARDIAN);ICustodyRecoveryFixture(vaults[i]).rescueAccidentalERC20(canonical,5);
        }
        assertEq(AccidentalTokenFixture(canonical).balanceOf(kernel.RECOVERY_TREASURY()),15);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(state.outstandingHolderLiability(),0.01 ether);_assertAccounting();
    }
    function testRecoveryCrossVaultRejectedNativeDestinationRetainsCustodyForRetry() public {
        _unpaidTerminated();RecoveryRejectFixture r=new RecoveryRejectFixture();vm.etch(kernel.RECOVERY_TREASURY(),address(r).code);
        address[3] memory vaults=[kernel.nativeFeeReceiver(),kernel.strategyExecutor(),kernel.buybackExecutor()];
        for(uint256 i;i<3;++i){vm.deal(vaults[i],10);vm.prank(GUARDIAN);vm.expectRevert();ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds();assertEq(vaults[i].balance,10);}
        vm.etch(kernel.RECOVERY_TREASURY(),hex"");
        for(uint256 i;i<3;++i){vm.prank(GUARDIAN);assertEq(ICustodyRecoveryFixture(vaults[i]).recoverTerminatedFunds(),10);}
        assertEq(kernel.holderRewardReserve(),0.01 ether);_assertAccounting();
    }
}
