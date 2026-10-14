// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdPhase7CR2CHCurrentV3Test,H4HostileHolder} from "./CompdPhase7CR2CHCurrentV3.t.sol";
import {T,Kernel} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {CompdHolderCandidateTypesV3 as H} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateTypesV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdHolderModuleV3 as Holder} from "../../contracts/production/v3/phase7cr2ch/CompdHolderModuleV3.sol";
import {CompdHolderDistributorV3 as Distributor} from "../../contracts/production/v3/phase7cr2ch/CompdHolderDistributorV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";
import {CompdRecoveryModuleV3 as Recovery} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryModuleV3.sol";

contract H7CallbackRecipient {
    address target; bytes payload; bool public callbackRejected;
    function configure(address t,bytes calldata p) external {target=t;payload=p;}
    receive() external payable virtual { (bool ok,)=target.call(payload);require(!ok,"callback unexpectedly succeeded");callbackRejected=true; }
}
contract H7LeanCallbackRecipient is H7CallbackRecipient {
    receive() external payable override {(bool ok,)=target.call(payload);require(!ok,"callback unexpectedly succeeded");}
}
contract H7GasRejector { receive() external payable { while(true){} } }

interface IH7Driver {function h7Accept() external;function h7Shutdown() external;function h7Finalize(uint16) external;function h7Pay(bool) external;function h7Terminalize() external;function h7Retry(bool) external;function h7Advance(uint32,bool) external;function h7Terminate() external;function h7Recover() external;}
contract H7Actions {
    IH7Driver immutable d;constructor(IH7Driver x){d=x;}
    function accept() external {d.h7Accept();}function shutdown() external {d.h7Shutdown();}
    function finalize(uint16 x) external {d.h7Finalize(x);}function pay(bool x) external {d.h7Pay(x);}
    function terminalize() external {d.h7Terminalize();}function retry(bool x) external {d.h7Retry(x);}
    function advance(uint32 x,bool extend) external {d.h7Advance(x,extend);}function terminate() external {d.h7Terminate();}
    function recover() external {d.h7Recover();}
}

/// @dev Inherits the real immutable G3 graph and its regression cases; no production mocks except explicit negative tests.
abstract contract H7RealGraphBase is CompdPhase7CR2CHCurrentV3Test {
    function _accept(address recipient) internal returns(H.Candidate memory c,H.CandidateEvidence memory e,bytes32 leaf) {
        H.Leaf memory l;(c,e,l)=_vector(recipient);vm.prank(FINALIZER);distributor.submitCandidate(c,e);
        vm.prank(FINALIZER);leaf=distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));c=candidate.candidate(c.distributionId,1);
    }
    function _pending(address recipient,bool finalizedFirst) internal returns(bytes32 leaf) {
        _settle(1.1 ether);(H.Candidate memory c,,bytes32 id)=_accept(recipient);leaf=id;
        if(finalizedFirst){vm.warp(c.executableAfter);distributor.finalizeCandidate(c.distributionId,1);}
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);
        if(!finalizedFirst){vm.warp(c.executableAfter);vm.prank(address(0xC011));distributor.finalizeCandidate(c.distributionId,1);}
    }
    function _pay(bytes32 leaf) internal returns(bool){vm.prank(kernel.AUTOMATION_EXECUTOR());return holder.pay(leaf);}
    function _retry(bytes32 useId) internal returns(bool){vm.prank(kernel.AUTOMATION_EXECUTOR());return holder.retry(useId);}
    function _recoverExpired(bytes32 id) internal {vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);}
    function _payment(bytes32 leaf) internal view returns(T.HolderPayment memory p){(p,)=state.paymentData(leaf);}
    function _finish() internal {vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();_assertAccounting();}
    function _checkPaid(bytes32 leaf,uint256 beforeAQ) internal view {
        assertTrue(kernel.holderPaid(_payment(leaf).useId));(uint8 mask,bool consumed)=state.consumption(leaf);
        assertEq(mask,3);assertTrue(consumed);assertEq(state.unresolvedOrdinary(),0);assertEq(state.outstandingHolderLiability(),0);
        assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.accountedQuote(),beforeAQ-0.01 ether);_assertAccounting();
    }
    function _hashLeaf(H.Leaf memory l) internal view returns(bytes32){return keccak256(abi.encode(candidate.LEAF_TYPEHASH(),l.domainSeparator,l.distributionId,l.commitmentVersion,l.windowId,l.windowStart,l.windowEnd,l.rewardAsset,l.windowPool,l.finalizedTotalPayable,l.recipientIndex,l.recipient,l.amount,l.datasetHash,l.algorithmVersion));}
}
contract CompdPhase7CR2CH7LifecycleTest is H7RealGraphBase {
    function testH7LateFinalizationExactReviewSameTimestampAcceptance() public {
        _settle(1.1 ether);(H.Candidate memory c,,bytes32 leaf)=_accept(address(0xBEEF));bytes32 commitment=candidate.candidateEvidenceCommitment(c.distributionId,1);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(c.acceptedAt,kernel.shutdownStartedAt());
        vm.warp(c.executableAfter-1);vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(c.distributionId,1);
        vm.warp(c.executableAfter);vm.prank(address(0xC011));distributor.finalizeCandidate(c.distributionId,1);
        assertEq(candidate.candidateEvidenceCommitment(c.distributionId,1),commitment);
        uint256 aq=kernel.accountedQuote();uint256 b=address(0xBEEF).balance;assertTrue(_pay(leaf));assertEq(address(0xBEEF).balance-b,0.01 ether);_checkPaid(leaf,aq);_finish();
    }
    function testH7AlreadyFinalizedNoPriorFailureSettlesDuringShutdown() public {bytes32 leaf=_pending(address(0xBEEF),true);uint256 aq=kernel.accountedQuote();assertTrue(_pay(leaf));_checkPaid(leaf,aq);_finish();}
    function testH7OrdinarySettlementAfterDeadlineAndExtension() public {
        bytes32 leaf=_pending(address(0xBEEF),false);uint64 began=kernel.shutdownStartedAt();uint64 deadline=kernel.shutdownAt();
        vm.prank(GUARDIAN);kernel.extendShutdown(deadline+1 days);assertEq(kernel.shutdownStartedAt(),began);
        vm.expectRevert(Kernel.InvalidLifecycle.selector);vm.prank(GUARDIAN);kernel.extendShutdown(deadline);
        vm.warp(kernel.shutdownAt()+1);vm.expectRevert(Kernel.ShutdownNotReady.selector);vm.prank(GUARDIAN);kernel.terminate();
        assertTrue(_pay(leaf));vm.prank(GUARDIAN);kernel.terminate();_assertAccounting();
    }
    function testH7PhysicalFailureAfterShutdownThenTerminalRetryAfterTermination() public {
        H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_pending(address(r),false);T.HolderPayment memory p=_payment(leaf);uint256 aq=kernel.accountedQuote();
        vm.expectRevert(State.InvalidPayment.selector);holder.terminalize(leaf);assertFalse(_pay(leaf));
        (bytes32 digest,address recipient,uint256 amount,bytes32 id)=kernel.failedHolder(p.useId);
        assertEq(digest,state.paymentDigest(leaf));assertEq(recipient,address(r));assertEq(amount,p.amount);assertEq(id,leaf);
        assertEq(kernel.accountedQuote(),aq);assertEq(state.unresolvedOrdinary(),1);assertEq(state.outstandingHolderLiability(),p.amount);
        vm.prank(address(0xC011));holder.terminalize(leaf);assertEq(state.unresolvedOrdinary(),0);assertEq(state.terminalOutstanding(),1);
        (,uint64 began,uint64 expires,)=state.terminalStatus(leaf);assertEq(expires-began,604_800);
        vm.expectRevert(State.InvalidTransition.selector);holder.terminalize(leaf);_finish();r.accept();vm.prank(kernel.AUTOMATION_EXECUTOR());assertTrue(holder.retry(p.useId));
        _checkPaid(leaf,aq);assertEq(state.terminalOutstanding(),0);address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert(Holder.Unauthorized.selector);vm.prank(automation);holder.retry(p.useId);
    }
    function testH7FailureExpiryRecoveryAndRetryBoundary() public {
        H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_pending(address(r),true);T.HolderPayment memory p=_payment(leaf);
        assertFalse(_pay(leaf));holder.terminalize(leaf);(,,uint64 expires,)=state.terminalStatus(leaf);bytes32 id=state.expiredHolderRecoveryId(leaf);_finish();
        vm.warp(expires-1);vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);
        vm.prank(kernel.AUTOMATION_EXECUTOR());assertFalse(holder.retry(p.useId));(,,uint64 sameExpiry,)=state.terminalStatus(leaf);assertEq(sameExpiry,expires);
        vm.warp(expires);address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.retry(p.useId);
        uint256 b=kernel.RECOVERY_TREASURY().balance;vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);assertEq(kernel.RECOVERY_TREASURY().balance-b,p.amount);
        assertEq(state.terminalOutstanding(),0);assertEq(state.outstandingHolderLiability(),0);assertEq(kernel.holderRewardReserve(),0);
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);_assertAccounting();
    }
    function testH7GasExhaustingRecipientProducesAuthenticFailure() public {H7GasRejector r=new H7GasRejector();bytes32 leaf=_pending(address(r),false);assertFalse(_pay(leaf));assertEq(kernel.holderRewardReserve(),0.01 ether);holder.terminalize(leaf);_finish();}
    function testH7OrdinaryAndTerminalPaymentsExcludedDuringPauseAndEmergency() public {
        _settle(1.1 ether);H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_nonempty(address(r));address automation=kernel.AUTOMATION_EXECUTOR();
        vm.prank(GUARDIAN);kernel.pause();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.pay(leaf);
        vm.prank(GUARDIAN);kernel.resume();assertFalse(_pay(leaf));vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);
        bytes32 useId=_payment(leaf).useId;vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.retry(useId);_assertAccounting();
    }
    function testH7EmergencyOrdinaryPaymentCannotManufactureFailure() public {
        bytes32 leaf=_pending(address(0xBEEF),false);vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();address automation=kernel.AUTOMATION_EXECUTOR();
        vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.pay(leaf);(bytes32 d,,,)=kernel.failedHolder(_payment(leaf).useId);assertEq(d,0);_assertAccounting();
    }
    function testH7OrdinaryPaidReplayDeniedAfterTermination() public {bytes32 leaf=_pending(address(0xBEEF),false);assertTrue(_pay(leaf));_finish();address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.pay(leaf);}
}
contract CompdPhase7CR2CH7AdversarialTest is H7RealGraphBase {
    function testH7CompleteGraphRuntimeHashesAndEveryKernelPin() public view {
        assertEq(kernel.strategyExecutorHash(),kernel.strategyExecutor().codehash);assertEq(kernel.buybackExecutorHash(),kernel.buybackExecutor().codehash);
        assertEq(kernel.distributorHash(),address(distributor).codehash);assertEq(kernel.liabilityHash(),kernel.liability().codehash);
        assertEq(kernel.recoveryEvidenceHash(),kernel.recoveryEvidence().codehash);assertEq(kernel.candidateModuleHash(),address(candidate).codehash);assertEq(kernel.holderStateHash(),address(state).codehash);
        assertEq(candidate.kernel(),address(kernel));assertEq(candidate.state(),address(state));assertEq(candidate.distributor(),address(distributor));
        assertEq(state.candidateModuleCodeHash(),address(candidate).codehash);assertEq(holder.stateHash(),address(state).codehash);assertEq(holder.distributorHash(),address(distributor).codehash);assertEq(holder.liabilityHash(),kernel.liability().codehash);
        assertEq(distributor.stateCodeHash(),address(state).codehash);assertEq(distributor.candidateCodeHash(),address(candidate).codehash);
        for(uint8 i;i<6;++i){address m=kernel.moduleAddress(T.ModuleId(i));assertEq(kernel.moduleHash(i),m.codehash);}
    }
    function testH7RecordLocalConstructedRuntimeHashes() public {
        emit log_named_bytes32("Kernel",address(kernel).codehash);emit log_named_bytes32("Candidate",address(candidate).codehash);emit log_named_bytes32("State",address(state).codehash);
        emit log_named_bytes32("Distributor",address(distributor).codehash);emit log_named_bytes32("Liability",kernel.liability().codehash);emit log_named_bytes32("RecoveryEvidence",kernel.recoveryEvidence().codehash);
        emit log_named_bytes32("StrategyExecutor",kernel.strategyExecutor().codehash);emit log_named_bytes32("BuybackExecutor",kernel.buybackExecutor().codehash);
        string[6] memory names=[string("Settlement"),"Holder","BuybackPolicy","Recovery","Emergency","Registry"];
        for(uint8 i;i<6;++i)emit log_named_bytes32(names[i],kernel.moduleAddress(T.ModuleId(i)).codehash);
        emit log_named_bytes("KernelBytes",address(kernel).code);emit log_named_bytes("CandidateBytes",address(candidate).code);emit log_named_bytes("StateBytes",address(state).code);
        emit log_named_bytes("DistributorBytes",address(distributor).code);emit log_named_bytes("LiabilityBytes",kernel.liability().code);emit log_named_bytes("RecoveryEvidenceBytes",kernel.recoveryEvidence().code);
        emit log_named_bytes("StrategyExecutorBytes",kernel.strategyExecutor().code);emit log_named_bytes("BuybackExecutorBytes",kernel.buybackExecutor().code);
        for(uint8 i;i<6;++i)emit log_named_bytes(string.concat(names[i],"Bytes"),kernel.moduleAddress(T.ModuleId(i)).code);
    }
    function testH7AdmissionCorrectionAndEvidenceRemainFrozenDuringShutdown() public {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,)=_accept(address(0xBEEF));bytes32 hash=candidate.candidateEvidenceCommitment(c.distributionId,1);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.submitCandidate(c,e);
        c.version=2;vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.correctCandidate(c,e,keccak256("correction"));
        assertEq(candidate.currentVersion(c.windowId),1);assertEq(candidate.candidateEvidenceCommitment(c.distributionId,1),hash);
    }
    function testH7CallerAmountRecipientAndDirectAcknowledgementCannotBypass() public {
        bytes32 leaf=_pending(address(0xBEEF),false);T.HolderPayment memory p=_payment(leaf);bytes32 digest=state.paymentDigest(leaf);
        vm.expectRevert(Holder.Unauthorized.selector);holder.pay(leaf);vm.expectRevert(Holder.Unauthorized.selector);holder.retry(p.useId);
        vm.expectRevert(State.Unauthorized.selector);state.acknowledgePayment(leaf,digest);
        vm.expectRevert(Kernel.Unauthorized.selector);kernel.payHolder(leaf,p.useId,digest,p.recipient,p.amount,false,keccak256("attempt"));
        vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(address(holder));kernel.payHolder(leaf,p.useId,digest,address(0xBAD),p.amount,false,keccak256("attempt"));
        vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(address(holder));kernel.payHolder(leaf,p.useId,digest,p.recipient,p.amount-1,false,keccak256("attempt"));
        assertEq(state.unresolvedOrdinary(),1);assertEq(kernel.holderRewardReserve(),p.amount);assertTrue(_pay(leaf));
        address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.pay(leaf);_assertAccounting();
    }
    function testH7SecondAcknowledgementRevertRollsBackPhysicalTransferAndFirstBit() public {
        bytes32 leaf=_pending(address(0xBEEF),false);uint256 b=address(0xBEEF).balance;uint256 aq=kernel.accountedQuote();bytes32 digest=state.paymentDigest(leaf);
        vm.mockCallRevert(kernel.liability(),abi.encodeWithSignature("consumePayment(bytes32,bytes32)",leaf,digest),abi.encodeWithSignature("Error(string)","test-only peer rejection"));
        address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert();vm.prank(automation);holder.pay(leaf);vm.clearMockedCalls();
        (uint8 mask,bool consumed)=state.consumption(leaf);assertEq(mask,0);assertFalse(consumed);assertEq(address(0xBEEF).balance,b);assertEq(kernel.accountedQuote(),aq);
        (bytes32 d,,,)=kernel.failedHolder(_payment(leaf).useId);assertEq(d,0);assertTrue(_pay(leaf));_assertAccounting();
    }
    function testH7ReentrantPaymentCallbackRejectedWithoutDoubleDebit() public {
        H7CallbackRecipient r=new H7CallbackRecipient();bytes32 leaf=_pending(address(r),false);r.configure(address(holder),abi.encodeWithSignature("pay(bytes32)",leaf));
        assertTrue(_pay(leaf));assertTrue(r.callbackRejected());assertEq(address(r).balance,0.01 ether);assertEq(kernel.holderRewardReserve(),0);_assertAccounting();
    }
    function testH7ReentrantTerminalizationCannotCreateSyntheticFailure() public {
        H7LeanCallbackRecipient r=new H7LeanCallbackRecipient();bytes32 leaf=_pending(address(r),false);r.configure(address(state),abi.encodeWithSignature("terminalize(bytes32)",leaf));
        assertTrue(_pay(leaf));assertEq(state.terminalOutstanding(),0);(bytes32 failure,,,)=kernel.failedHolder(_payment(leaf).useId);assertEq(failure,0);_assertAccounting();
    }
    function testH7GuardianRecipientCannotTerminateBeforeAtomicAcknowledgement() public {
        H7CallbackRecipient template=new H7CallbackRecipient();vm.etch(GUARDIAN,address(template).code);H7CallbackRecipient r=H7CallbackRecipient(payable(GUARDIAN));
        bytes32 leaf=_pending(GUARDIAN,false);r.configure(address(kernel),abi.encodeWithSignature("terminate()"));vm.warp(kernel.shutdownAt());
        assertTrue(_pay(leaf));assertTrue(r.callbackRejected());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING));vm.prank(GUARDIAN);kernel.terminate();_assertAccounting();
    }
    function testH7ChangedPinnedPeerFailsWithoutFailureOrDebit() public {
        bytes32 leaf=_pending(address(0xBEEF),false);vm.etch(kernel.liability(),hex"00");address automation=kernel.AUTOMATION_EXECUTOR();
        vm.expectRevert(Holder.ChangedCode.selector);vm.prank(automation);holder.pay(leaf);(bytes32 d,,,)=kernel.failedHolder(_payment(leaf).useId);assertEq(d,0);assertEq(kernel.holderRewardReserve(),0.01 ether);
    }
}
contract CompdPhase7CR2CH7MixedClaimsTest is H7RealGraphBase {
    function testH7TwoRecipientsMixedOrdinaryTerminalConserveExactPool() public {
        _settle(1.1 ether);H4HostileHolder hostile=new H4HostileHolder();(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory first)=_vector(address(0xBEEF));
        c.recipientCount=2;uint16[] memory ix=new uint16[](2);ix[1]=1;address[] memory rs=new address[](2);rs[0]=address(0xBEEF);rs[1]=address(hostile);
        uint256[] memory weights=new uint256[](2);weights[0]=3;weights[1]=2;uint256[] memory amounts=new uint256[](2);amounts[0]=0.006 ether;amounts[1]=0.004 ether;uint256[] memory rem=new uint256[](2);
        e.entriesHash=keccak256(abi.encode(keccak256("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"),ix,rs,weights,amounts,rem,amounts));
        c.datasetHash=keccak256(bytes.concat(abi.encode(candidate.DATASET_TYPEHASH(),candidate.domainSeparator(),c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion),abi.encode(e.exclusionSetVersion,e.exclusionSetHash,uint256(kernel.activationBlock()),kernel.activationBlockHash(),kernel.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash)));
        first.datasetHash=c.datasetHash;first.amount=amounts[0];H.Leaf memory second=H.Leaf(first.domainSeparator,first.distributionId,first.commitmentVersion,first.windowId,first.windowStart,first.windowEnd,first.rewardAsset,first.windowPool,first.finalizedTotalPayable,1,address(hostile),amounts[1],first.datasetHash,first.algorithmVersion);
        bytes32 left=_hashLeaf(first);bytes32 right=_hashLeaf(second);c.root=keccak256(abi.encode(candidate.NODE_TYPEHASH(),left,right));
        vm.prank(FINALIZER);distributor.submitCandidate(c,e);bytes32[] memory proof=new bytes32[](1);proof[0]=right;vm.prank(FINALIZER);bytes32 a=distributor.materializeLeaf(c.distributionId,1,first,proof);
        proof[0]=left;vm.prank(FINALIZER);bytes32 b=distributor.materializeLeaf(c.distributionId,1,second,proof);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
        assertEq(state.unresolvedOrdinary(),2);assertTrue(_pay(a));assertFalse(_pay(b));holder.terminalize(b);
        assertEq(state.unresolvedOrdinary(),0);assertEq(state.terminalOutstanding(),1);assertEq(kernel.holderRewardReserve(),0.004 ether);_finish();
        hostile.accept();assertTrue(_retry(_payment(b).useId));assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);_assertAccounting();
    }
    function testH7MultipleWindowsTerminalAndNoRecipientRemainSeparated() public {
        _settle(1.1 ether);H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_nonempty(address(r));
        windowStart+=28_800;vm.warp(windowStart+1);address automation=kernel.AUTOMATION_EXECUTOR();
        vm.prank(automation);settlement.startRun(2,address(adapter),1 ether,keccak256("H7_SECOND_ALLOC"));vm.prank(automation);settlement.requestExit(2,keccak256("H7_SECOND_EXIT"));
        vm.deal(address(adapter),1.1 ether);vm.prank(automation);settlement.closeRun(2,keccak256("H7_SECOND_CLOSE"));(bytes32 wid,)=_empty();
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertFalse(_pay(leaf));holder.terminalize(leaf);assertEq(kernel.holderRewardReserve(),0.02 ether);_finish();
        uint256 before_=kernel.RECOVERY_TREASURY().balance;bytes32 id=state.emptyRecoveryId(wid);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.holderRewardReserve(),0.01 ether);r.accept();assertTrue(_retry(_payment(leaf).useId));
        assertEq(kernel.holderRewardReserve(),0);assertEq(state.outstandingHolderLiability(),0);_assertAccounting();
    }
}
contract CompdPhase7CR2CH7PropertiesTest is H7RealGraphBase {

    H7Actions actions; H4HostileHolder modelRecipient;
    bytes32 modelLeaf;bytes32 modelDistribution;bytes32 modelCommitment;uint64 modelReview;
    bool modelFinalized;bool modelPaid;bool modelTerminal;bool modelRecovered;

    
    modifier onlyActions(){require(msg.sender==address(actions));_;}
    function setUp() public override {
        super.setUp();excludeContract(address(h6Actions));
        // Explicit inherited target selectors take precedence over contract exclusion.
        // Isolate this model; the unchanged H6 handler is exercised by the other suites.
        bytes4[] memory inheritedSelectors=new bytes4[](5);
        inheritedSelectors[0]=h6Actions.accept.selector;inheritedSelectors[1]=h6Actions.shutdown.selector;
        inheritedSelectors[2]=h6Actions.finalize.selector;inheritedSelectors[3]=h6Actions.terminate.selector;inheritedSelectors[4]=h6Actions.recover.selector;
        excludeSelector(FuzzSelector(address(h6Actions),inheritedSelectors));
        actions=new H7Actions(IH7Driver(address(this)));modelRecipient=new H4HostileHolder();
        bytes4[] memory ss=new bytes4[](9);ss[0]=actions.accept.selector;ss[1]=actions.shutdown.selector;
        ss[2]=actions.finalize.selector;ss[3]=actions.pay.selector;ss[4]=actions.terminalize.selector;
        ss[5]=actions.retry.selector;ss[6]=actions.advance.selector;ss[7]=actions.terminate.selector;ss[8]=actions.recover.selector;
        targetContract(address(actions));targetSelector(FuzzSelector(address(actions),ss));
    }
    function h7Accept() external onlyActions {if(modelLeaf!=0)return;_settle(1.1 ether);(H.Candidate memory c,,bytes32 leaf)=_accept(address(modelRecipient));modelLeaf=leaf;modelDistribution=c.distributionId;modelReview=c.executableAfter;modelCommitment=candidate.candidateEvidenceCommitment(c.distributionId,1);}
    function h7Advance(uint32 dt,bool extend) external onlyActions {if(modelLeaf==0)return;vm.warp(block.timestamp+uint256(dt)%8000001);if(extend&&kernel.lifecycle()==T.Lifecycle.SHUTDOWN_PENDING){uint64 deadline=kernel.shutdownAt()+1 days;vm.prank(GUARDIAN);kernel.extendShutdown(deadline);}}
    function h7Finalize(uint16 dt) external onlyActions {if(modelLeaf==0||modelFinalized)return;vm.warp(block.timestamp+dt%3601);if(block.timestamp<modelReview){vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(modelDistribution,1);return;}distributor.finalizeCandidate(modelDistribution,1);modelFinalized=true;}
    function h7Pay(bool accept) external onlyActions {if(!modelFinalized||modelPaid||modelTerminal||kernel.lifecycle()==T.Lifecycle.TERMINATED)return;if(accept)modelRecipient.accept();modelPaid=_pay(modelLeaf);}
    function h7Recover() external onlyActions {if(!modelTerminal||modelPaid||modelRecovered||kernel.lifecycle()!=T.Lifecycle.TERMINATED)return;(,,uint64 expires,)=state.terminalStatus(modelLeaf);if(block.timestamp<expires)return;_recoverExpired(state.expiredHolderRecoveryId(modelLeaf));modelRecovered=true;}
    function h7Retry(bool accept) external onlyActions {if(!modelTerminal||modelPaid||modelRecovered)return;(,,uint64 expires,)=state.terminalStatus(modelLeaf);if(block.timestamp>=expires)return;if(accept)modelRecipient.accept();modelPaid=_retry(_payment(modelLeaf).useId);}
    function h7Shutdown() external onlyActions {if(modelLeaf==0||kernel.lifecycle()!=T.Lifecycle.ACTIVE)return;vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);}
    function h7Terminalize() external onlyActions {if(!modelFinalized||modelPaid||modelTerminal||kernel.lifecycle()!=T.Lifecycle.SHUTDOWN_PENDING)return;(bytes32 d,,,)=kernel.failedHolder(_payment(modelLeaf).useId);if(d==0){vm.expectRevert(State.InvalidPayment.selector);holder.terminalize(modelLeaf);return;}holder.terminalize(modelLeaf);modelTerminal=true;}
    function h7Terminate() external onlyActions {if(modelLeaf==0||kernel.lifecycle()!=T.Lifecycle.SHUTDOWN_PENDING)return;if(block.timestamp<kernel.shutdownAt()||!modelFinalized||(!modelPaid&&!modelTerminal)){vm.expectRevert(Kernel.ShutdownNotReady.selector);vm.prank(GUARDIAN);kernel.terminate();return;}vm.prank(GUARDIAN);kernel.terminate();}
    function invariantH7ExactLiabilityFailureLifecycleAndReserve() public view {
        _assertAccounting();if(modelLeaf==0)return;assertEq(candidate.candidateEvidenceCommitment(modelDistribution,1),modelCommitment);
        assertEq(candidate.openReviewCount(),modelFinalized?0:1);assertEq(candidate.pendingCandidateReserve(),modelFinalized?0:0.01 ether);
        bool spent=modelPaid||modelRecovered;assertEq(kernel.holderRewardReserve(),spent?0:0.01 ether);assertEq(state.outstandingHolderLiability(),modelFinalized&&!spent?0.01 ether:0);
        assertEq(state.unresolvedOrdinary(),modelFinalized&&!modelPaid&&!modelTerminal?1:0);assertEq(state.terminalOutstanding(),modelTerminal&&!spent?1:0);
        T.HolderPayment memory p=_payment(modelLeaf);assertEq(kernel.holderPaid(p.useId),modelPaid);
        if(modelTerminal){(bytes32 d,address r,uint256 x,bytes32 leaf)=kernel.failedHolder(p.useId);assertEq(d,state.paymentDigest(modelLeaf));assertEq(r,address(modelRecipient));assertEq(x,0.01 ether);assertEq(leaf,modelLeaf);}
        if(kernel.lifecycle()==T.Lifecycle.TERMINATED){assertTrue(modelFinalized);assertTrue(modelPaid||modelTerminal);}
    }
    function testFuzzH7AdmissionShutdownReviewAndExactSettlement(uint16 wait,uint16 review,bool earlyFinalized,bool reject) public {
        H4HostileHolder r=new H4HostileHolder();if(!reject)r.accept();_settle(1.1 ether);(H.Candidate memory c,,bytes32 leaf)=_accept(address(r));
        vm.warp(block.timestamp+wait%3601);if(earlyFinalized){if(block.timestamp<c.executableAfter)vm.warp(c.executableAfter);distributor.finalizeCandidate(c.distributionId,1);}
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+review%300001);
        if(!earlyFinalized){if(block.timestamp<c.executableAfter){vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(c.distributionId,1);vm.warp(c.executableAfter);}distributor.finalizeCandidate(c.distributionId,1);}
        uint256 aq=kernel.accountedQuote();assertEq(_pay(leaf),!reject);
        if(reject){holder.terminalize(leaf);assertEq(kernel.accountedQuote(),aq);_finish();r.accept();assertTrue(_retry(_payment(leaf).useId));}
        else _finish();_checkPaid(leaf,aq);
    }
    function testFuzzH7ProfitRoundingAndHRExactness(uint96 raw,bool reject) public {
        uint256 profit=bound(uint256(raw),10,1 ether);H4HostileHolder r=new H4HostileHolder();if(!reject)r.accept();_settle(1 ether+profit);
        bytes32 leaf=_nonempty(address(r));vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);uint256 x=profit*1000/10000;uint256 aq=kernel.accountedQuote();
        assertEq(kernel.holderRewardReserve(),x);assertEq(kernel.protocolReserve(),x);assertEq(kernel.buybackReserve(),profit*1500/10000);
        assertEq(_pay(leaf),!reject);if(reject){holder.terminalize(leaf);r.accept();assertTrue(_retry(_payment(leaf).useId));}
        assertEq(kernel.accountedQuote(),aq-x);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);_assertAccounting();_finish();
    }
    function testFuzzH7TerminalExpiryNeverResets(uint32 delta,bool recovered) public {
        H4HostileHolder r=new H4HostileHolder();bytes32 leaf=_pending(address(r),false);assertFalse(_pay(leaf));holder.terminalize(leaf);(,uint64 began,uint64 expires,)=state.terminalStatus(leaf);_finish();
        bytes32 useId=_payment(leaf).useId;uint256 offset=uint256(delta)%604_802;uint256 target=uint256(began)+offset;if(target>block.timestamp)vm.warp(target);if(offset>=604_800){address automation=kernel.AUTOMATION_EXECUTOR();vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.retry(useId);}
        else{assertFalse(_retry(_payment(leaf).useId));}
        (,,uint64 same,)=state.terminalStatus(leaf);assertEq(same,expires);
        if(recovered){if(block.timestamp<expires)vm.warp(expires);_recoverExpired(state.expiredHolderRecoveryId(leaf));} _assertAccounting();
    }
}
