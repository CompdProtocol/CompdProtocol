// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {H7RealGraphBase} from "./CompdPhase7CR2CH7ShutdownSettlement.t.sol";
import {H4HostileHolder} from "./CompdPhase7CR2CHCurrentV3.t.sol";
import {T,Kernel} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {CompdHolderModuleV3 as Holder} from "../../contracts/production/v3/phase7cr2ch/CompdHolderModuleV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
contract CompdHolderCurrentPolicySuccessorTest is H7RealGraphBase {
 function testPolicyGuardianEmergencyPreservesFixedRecipientSettlement() public {
  _settle(1.1 ether);bytes32 leaf=_nonempty(address(0xBEEF));uint256 aq=kernel.accountedQuote();
  vm.expectRevert(Kernel.Unauthorized.selector);vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();
  assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.ACTIVE));
  vm.prank(GUARDIAN);kernel.emergencyEnter();assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING));
  uint256 beforeBalance=address(0xBEEF).balance;vm.prank(address(0xC011));assertTrue(holder.pay(leaf));
  assertEq(address(0xBEEF).balance-beforeBalance,0.01 ether);(bytes32 d,,,)=kernel.failedHolder(_payment(leaf).useId);assertEq(d,bytes32(0));_checkPaid(leaf,aq);
  vm.expectRevert(Holder.InvalidPayment.selector);holder.pay(leaf);_finish();
 }
 function testPolicyPauseBlocksOrdinaryButTerminalRetrySurvivesShutdown() public {
  _settle(1.1 ether);H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_nonempty(address(r));uint256 aq=kernel.accountedQuote();
  vm.prank(GUARDIAN);kernel.pause();vm.expectRevert(Holder.InvalidPayment.selector);holder.pay(leaf);assertEq(kernel.holderRewardReserve(),0.01 ether);
  vm.prank(GUARDIAN);kernel.resume();assertFalse(holder.pay(leaf));
  vm.prank(GUARDIAN);kernel.emergencyEnter();holder.terminalize(leaf);bytes32 id=_payment(leaf).useId;
  (,uint64 began,uint64 expires,)=state.terminalStatus(leaf);assertEq(expires-began,604800);
  assertFalse(holder.retry(id));assertEq(state.outstandingHolderLiability(),0.01 ether);assertEq(kernel.accountedQuote(),aq);
  _finish();r.accept();vm.warp(expires-1);vm.prank(address(0xC011));assertTrue(holder.retry(id));_checkPaid(leaf,aq);
  vm.expectRevert(Holder.Unauthorized.selector);holder.retry(id);
 }
 function testPolicyPermissionlessPaymentCannotChangeTupleOrAcknowledgeDirectly() public {
  bytes32 leaf=_pending(address(0xBEEF),false);T.HolderPayment memory p=_payment(leaf);bytes32 digest=state.paymentDigest(leaf);uint256 aq=kernel.accountedQuote();
  vm.expectRevert(Holder.Unauthorized.selector);holder.retry(p.useId);
  vm.expectRevert(State.Unauthorized.selector);state.acknowledgePayment(leaf,digest);
  vm.expectRevert(Kernel.Unauthorized.selector);kernel.payHolder(leaf,p.useId,digest,p.recipient,p.amount,false,keccak256("attempt"));
  vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(address(holder));kernel.payHolder(leaf,p.useId,digest,address(0xBAD),p.amount,false,keccak256("attempt"));
  vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(address(holder));kernel.payHolder(leaf,p.useId,digest,p.recipient,p.amount-1,false,keccak256("attempt"));
  assertEq(state.unresolvedOrdinary(),1);assertEq(kernel.holderRewardReserve(),p.amount);
  address caller=address(0xC011);uint256 cb=caller.balance;uint256 rb=p.recipient.balance;vm.prank(caller);assertTrue(holder.pay(leaf));
  assertEq(caller.balance,cb);assertEq(p.recipient.balance-rb,p.amount);_checkPaid(leaf,aq);
  vm.expectRevert(Holder.InvalidPayment.selector);holder.pay(leaf);
 }
}
