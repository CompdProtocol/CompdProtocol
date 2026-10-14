// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHolderEpochsTest} from "../holder-epochs/CompdHolderEpochs.t.sol";
import {T} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
contract BudgetQualifiedRecipient {
 uint256 public length;uint256 public mode;address public holder;bytes32 public leaf;bool public blocked;
 function configure(uint256 n,uint256 m,address h,bytes32 l) external {length=n;mode=m;holder=h;leaf=l;}
 receive() external payable {
  uint256 n=length;uint256 m=mode;
  if(m==3){(bool ok,)=holder.call{gas:10000}(abi.encodeWithSignature("pay(bytes32)",leaf));require(!ok,"reentry succeeded");blocked=true;}
  assembly {if eq(m,1){revert(0,n)} if eq(m,2){invalid()} return(0,n)}
 }
}
contract CompdHolderBudgetQualifiedTest is CompdHolderEpochsTest {
 // Test-qualified per-single Holder call only; not a production executor setting.
 uint256 constant CALLER_BUDGET=1000000;
 uint256 constant MAX_MEASURED_CALL_GAS=750000;
 event BudgetEvidence(bytes32 scenario,uint256 returndataLength,uint256 mode,uint256 budget,uint256 measuredCallGas,bool callOK,bool paid);
 function cold(address r) private {vm.cool(address(kernel));vm.cool(address(holder));vm.cool(address(state));vm.cool(address(candidate));vm.cool(address(distributor));vm.cool(kernel.liability());vm.cool(r);}
 function fund(BudgetQualifiedRecipient r) private returns(bytes32 leaf,T.HolderPayment memory p) {_settle(1.1 ether);leaf=_nonempty(address(r));(p,)=state.paymentData(leaf);}
 function backed(bytes32 leaf,address r) private view {assertEq(r.balance,0);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(state.outstandingHolderLiability(),0.01 ether);(uint8 mask,bool consumed)=state.consumption(leaf);assertEq(mask,0);assertFalse(consumed);_assertAccounting();}
 function paidOnce(bytes32 leaf,T.HolderPayment memory p,address r) private {assertEq(r.balance,0.01 ether);assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);assertTrue(kernel.holderPaid(p.useId));assertFalse(holder.hasFailure(p.useId));(uint8 mask,bool consumed)=state.consumption(leaf);assertEq(mask,3);assertTrue(consumed);vm.expectRevert();holder.pay(leaf);vm.expectRevert();holder.retry(p.useId);assertEq(r.balance,0.01 ether);_assertAccounting();}
 function invoke(BudgetQualifiedRecipient r,bytes32 leaf,T.HolderPayment memory p,bool retry,bytes32 scenario) private returns(bool ok,bool paid) {
  cold(address(r));bytes memory input=retry?abi.encodeWithSignature("retry(bytes32)",p.useId):abi.encodeWithSignature("pay(bytes32)",leaf);
  uint256 beforeGas=gasleft();bytes memory data;(ok,data)=address(holder).call{gas:CALLER_BUDGET}(input);uint256 used=beforeGas-gasleft();paid=ok&&data.length==32&&abi.decode(data,(bool));
  emit BudgetEvidence(scenario,r.length(),r.mode(),CALLER_BUDGET,used,ok,paid);assertLt(used,MAX_MEASURED_CALL_GAS);
 }
 function failedThenRetry(uint256 n,uint256 m) private {
  BudgetQualifiedRecipient r=new BudgetQualifiedRecipient();(bytes32 leaf,T.HolderPayment memory p)=fund(r);r.configure(n,m,address(holder),leaf);
  (bool ok,bool paid)=invoke(r,leaf,p,false,keccak256("failed ordinary"));assertTrue(ok);assertFalse(paid);backed(leaf,address(r));assertTrue(holder.hasFailure(p.useId));
  r.configure(131072,0,address(holder),leaf);(ok,paid)=invoke(r,leaf,p,true,keccak256("funded ordinary retry"));assertTrue(ok);assertTrue(paid);paidOnce(leaf,p,address(r));
 }
 function terminalFixture() private returns(BudgetQualifiedRecipient r,bytes32 leaf,T.HolderPayment memory p,uint64 expires) {
  r=new BudgetQualifiedRecipient();(leaf,p)=fund(r);r.configure(0,2,address(holder),leaf);(bool ok,bool paid)=invoke(r,leaf,p,false,keccak256("full recipient gas failed"));assertTrue(ok);assertFalse(paid);backed(leaf,address(r));
  vm.prank(GUARDIAN);kernel.emergencyShutdown();holder.terminalize(leaf);(bool terminal,uint64 began,uint64 expiry,bytes32 use)=state.terminalStatus(leaf);assertTrue(terminal);assertEq(use,p.useId);assertEq(expiry-began,604800);expires=expiry;assertEq(p.expiresAt,0);
  vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();vm.prank(GUARDIAN);kernel.recoverAllTerminatedFunds();backed(leaf,address(r));assertEq(address(kernel).balance,0.01 ether);
 }
 function testBudgetOrdinaryAndOversizedReturnLengths() public {
  BudgetQualifiedRecipient r=new BudgetQualifiedRecipient();(bytes32 leaf,T.HolderPayment memory p)=fund(r);uint256 snapshot=vm.snapshotState();uint256[4] memory sizes=[uint256(0),32,65536,131072];
  for(uint256 i;i<sizes.length;++i){assertTrue(vm.revertToState(snapshot));r.configure(sizes[i],0,address(holder),leaf);(bool ok,bool paid)=invoke(r,leaf,p,false,keccak256("ordinary success"));assertTrue(ok);assertTrue(paid);paidOnce(leaf,p,address(r));}
 }
 function testBudgetOversizedRevertAndFundedRetry() public {failedThenRetry(131072,1);}
 function testBudgetMemoryOOGAndFundedRetry() public {failedThenRetry(1048576,0);}
 function testBudgetFullRecipientGasExhaustionAndFundedRetry() public {failedThenRetry(0,2);}
 function testBudgetReentrantRecipientCannotDoublePay() public {
  BudgetQualifiedRecipient r=new BudgetQualifiedRecipient();(bytes32 leaf,T.HolderPayment memory p)=fund(r);r.configure(0,3,address(holder),leaf);(bool ok,bool paid)=invoke(r,leaf,p,false,keccak256("reentrant recipient"));assertTrue(ok);assertTrue(paid);assertTrue(r.blocked());paidOnce(leaf,p,address(r));
 }
 function testBudgetTerminalRetryAtLastGraceSecondPreservesBacking() public {
  (BudgetQualifiedRecipient r,bytes32 leaf,T.HolderPayment memory p,uint64 expiry)=terminalFixture();vm.warp(expiry-1);r.configure(131072,0,address(holder),leaf);(bool ok,bool paid)=invoke(r,leaf,p,true,keccak256("terminal last second"));assertTrue(ok);assertTrue(paid);paidOnce(leaf,p,address(r));
 }
 function testBudgetTerminalFailedRetryThenSuccessWithinGrace() public {
  (BudgetQualifiedRecipient r,bytes32 leaf,T.HolderPayment memory p,uint64 expiry)=terminalFixture();vm.warp(expiry-2);(bool ok,bool paid)=invoke(r,leaf,p,true,keccak256("terminal full gas failure"));assertTrue(ok);assertFalse(paid);backed(leaf,address(r));assertTrue(holder.hasFailure(p.useId));r.configure(131072,0,address(holder),leaf);vm.warp(expiry-1);(ok,paid)=invoke(r,leaf,p,true,keccak256("terminal funded retry"));assertTrue(ok);assertTrue(paid);paidOnce(leaf,p,address(r));
 }
 function testBudgetExactGraceExpiryRejectsAndGuardianEvidenceRecoveryOnly() public {
  (BudgetQualifiedRecipient r,bytes32 leaf,T.HolderPayment memory p,uint64 expiry)=terminalFixture();vm.warp(expiry);r.configure(0,0,address(holder),leaf);(bool ok,)=invoke(r,leaf,p,true,keccak256("exact grace expiry"));assertFalse(ok);backed(leaf,address(r));bytes32 id=state.expiredHolderRecoveryId(leaf);uint256 beforeBalance=kernel.RECOVERY_TREASURY().balance;
  vm.prank(ADMIN);vm.expectRevert();recovery.recoverExpiredLiability(id);backed(leaf,address(r));vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);assertEq(kernel.RECOVERY_TREASURY().balance-beforeBalance,0.01 ether);assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);assertEq(address(r).balance,0);vm.prank(GUARDIAN);vm.expectRevert();recovery.recoverExpiredLiability(id);_assertAccounting();
 }
 function testBudgetUnderfundedCallerRollsBackAndLaterPaymentSucceeds() public {
  BudgetQualifiedRecipient r=new BudgetQualifiedRecipient();(bytes32 leaf,T.HolderPayment memory p)=fund(r);r.configure(131072,0,address(holder),leaf);cold(address(r));(bool low,)=address(holder).call{gas:100000}(abi.encodeWithSignature("pay(bytes32)",leaf));assertFalse(low);backed(leaf,address(r));assertFalse(holder.hasFailure(p.useId));(bool ok,bool paid)=invoke(r,leaf,p,false,keccak256("after underfunded rollback"));assertTrue(ok);assertTrue(paid);paidOnce(leaf,p,address(r));
 }
}
