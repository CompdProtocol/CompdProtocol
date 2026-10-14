// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {T,Kernel,Settlement,StrategyExecutor,LifecycleAdapter} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "../phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
import {CompdHolderCandidateTypesV3 as H} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateTypesV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdHolderDistributorV3 as Distributor} from "../../contracts/production/v3/phase7cr2ch/CompdHolderDistributorV3.sol";
import {CompdHolderModuleV3 as Holder} from "../../contracts/production/v3/phase7cr2ch/CompdHolderModuleV3.sol";
import {CompdRecoveryModuleV3 as Recovery} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryModuleV3.sol";
import {CompdEmergencyModuleV3 as Emergency} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyModuleV3.sol";
import {CompdDisabledBuybackPolicyModuleV3 as Policy} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackPolicyModuleV3.sol";
import {H3OneHolderReplay} from "./CompdPhase7CR2CHCanonicalState.t.sol";

contract H4HostileHolder {
    bool public reject=true;
    function accept() external {reject=false;}
    receive() external payable {require(!reject,"local recipient rejection");}
}

interface IH6LifecycleDriver {
    function h6StepAccept() external;
    function h6StepShutdown(uint16) external;
    function h6StepFinalize(uint16,bool) external;
    function h6StepTerminate(uint16) external;
    function h6StepRecover() external;
}
contract H6LifecycleActions {
    IH6LifecycleDriver immutable driver;
    constructor(IH6LifecycleDriver d){driver=d;}
    function accept() external {driver.h6StepAccept();}
    function shutdown(uint16 d) external {driver.h6StepShutdown(d);}
    function finalize(uint16 d,bool direct) external {driver.h6StepFinalize(d,direct);}
    function terminate(uint16 d) external {driver.h6StepTerminate(d);}
    function recover() external {driver.h6StepRecover();}
}

/// @dev Current G3 integration gate. All deployment and adapter admission are local EVM fixtures.
contract CompdPhase7CR2CHCurrentV3Test is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant FINALIZER=address(0xF1A1);
    address constant EMERGENCY_AUTHORITY=address(0xA11CE);
    Kernel kernel;Settlement settlement;Candidate candidate;State state;Distributor distributor;
    Holder holder;Recovery recovery;Emergency emergency;LifecycleAdapter adapter;H3OneHolderReplay replay;
    uint64 windowStart;
    H6LifecycleActions h6Actions;
    bytes32 h6Window;
    bytes32 h6EvidenceHash;
    uint64 h6Accepted;
    bool h6Finalized;
    bool h6Recovered;

    function setUp() public virtual {
        vm.chainId(31337);vm.roll(1000);vm.warp(100 days+123);
        MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();
        address k=vm.computeCreateAddress(address(kd),1);
        address s=vm.computeCreateAddress(address(md),2);address d=vm.computeCreateAddress(address(md),3);
        address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);
        address c=md.candidate(k,s,d,FINALIZER,address(0x70C0));
        s=md.state(k,d,l,e,FINALIZER,c,address(0x70C0),c.codehash);
        d=md.distributor(k,s,c,FINALIZER);l=md.liability(k,s);e=md.evidence(k,s);
        address r=md.recovery(k,e,e.codehash);address h=md.holder(k,d,l,s);
        address probe=address(new StrategyExecutor(k,ADMIN,GUARDIAN));address executor=vm.computeCreateAddress(k,1);
        address settle=md.settlement(k,executor,probe.codehash);address policy=md.policy(k);
        address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);address bb=md.buyback(k);
        address[6] memory modules=[settle,h,policy,r,em,registry];
        bytes32[13] memory hashes=[probe.codehash,bb.codehash,d.codehash,l.codehash,e.codehash,c.codehash,s.codehash,settle.codehash,h.codehash,policy.codehash,r.codehash,em.codehash,registry.codehash];
        kernel=Kernel(payable(kd.deploy(EMERGENCY_AUTHORITY,address(0xB0B),bb,d,l,e,c,address(0x70C0),modules,hashes)));
        candidate=Candidate(c);state=State(s);distributor=Distributor(d);holder=Holder(h);recovery=Recovery(r);emergency=Emergency(em);settlement=Settlement(settle);
        replay=new H3OneHolderReplay();vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();
        vm.prank(ADMIN);kernel.activate();uint64 activation=kernel.activationBlock();
        vm.roll(uint256(activation)+1);vm.setBlockhash(activation,keccak256(abi.encode("LOCAL_G3_ACTIVATION_HEADER",activation,kernel.activationTimestamp())));
        assertTrue(kernel.sealActivationCheckpoint());vm.prank(GUARDIAN);kernel.pause();
        bytes32 ident=keccak256("LOCAL_G3_STRATEGY");bytes32 risk=keccak256("LOCAL_G3_RISK");bytes32 venue=keccak256("LOCAL_G3_VENUE");
        adapter=new LifecycleAdapter(ident,risk,venue);
        StrategyExecutor strategy=StrategyExecutor(payable(kernel.strategyExecutor()));
        vm.prank(ADMIN);strategy.proposeStrategy(address(adapter),ident,risk,venue);
        vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);strategy.activateStrategy(address(adapter));
        vm.prank(GUARDIAN);kernel.resume();windowStart=uint64((block.timestamp/28_800+1)*28_800);vm.warp(windowStart+1);
        h6Actions=new H6LifecycleActions(IH6LifecycleDriver(address(this)));
        bytes4[] memory selectors=new bytes4[](5);
        selectors[0]=h6Actions.accept.selector;selectors[1]=h6Actions.shutdown.selector;selectors[2]=h6Actions.finalize.selector;
        selectors[3]=h6Actions.terminate.selector;selectors[4]=h6Actions.recover.selector;
        targetSelector(FuzzSelector(address(h6Actions),selectors));targetContract(address(h6Actions));
    }
    function _assertAccounting() internal view {
        assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertLe(kernel.activePrincipal(),kernel.strategyCapital());assertGe(kernel.accountedQuote(),kernel.holderRewardReserve());
        assertEq(kernel.holderRewardReserve(),kernel.partialActivationHR()+kernel.activationSealFailureHR()+kernel.shutdownTailHR()+kernel.emergencyLockedHR()+kernel.eligibleWindowHR());
        assertGe(address(kernel).balance,kernel.accountedQuote());assertFalse(kernel.buybackActivated());
    }
    function _settle(uint256 returned) internal {
        vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.startRun(1,address(adapter),1 ether,keccak256("LOCAL_ALLOC_1"));
        _assertAccounting();vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.requestExit(1,keccak256("LOCAL_EXIT_1"));
        vm.deal(address(adapter),returned);vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.closeRun(1,keccak256("LOCAL_CLOSE_1"));_assertAccounting();
    }
    function _vector(address recipient) internal returns(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l) {
        uint64 start=windowStart;vm.warp(start+28_800+37);vm.roll(kernel.activationBlock()+24);
        (c.windowId,c.distributionId,c.windowEnd,c.windowPool,)=kernel.deriveWindow(start);
        c.windowStart=start;c.payableTotal=c.windowPool;c.recipientCount=1;c.algorithmVersion=1;c.version=1;
        e.sourceStartBlock=kernel.activationBlock();e.snapshotBlock=e.sourceStartBlock+10;
        e.snapshotBlockHash=keccak256(abi.encode(block.chainid,e.snapshotBlock,c.windowEnd-3,kernel.activationBlockHash()));
        e.closeBlock=e.snapshotBlock+1;e.closeBlockHash=keccak256(abi.encode(e.closeBlock,c.windowEnd,e.snapshotBlockHash));
        e.finalityBlock=e.closeBlock+12;e.finalityBlockHash=keccak256(abi.encode(e.finalityBlock,c.windowEnd+36,e.closeBlockHash));
        e.exclusionSetHash=kernel.activationExclusionSetHash();e.exclusionSetVersion=kernel.exclusionSetVersion();e.replayCodeHash=address(replay).codehash;
        uint16[] memory ix=new uint16[](1);address[] memory rs=new address[](1);rs[0]=recipient;
        uint256[] memory ws=new uint256[](1);ws[0]=1;uint256[] memory qs=new uint256[](1);qs[0]=c.windowPool;
        uint256[] memory rem=new uint256[](1);uint256[] memory pay=new uint256[](1);pay[0]=c.windowPool;
        e.entriesHash=keccak256(abi.encode(keccak256("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"),ix,rs,ws,qs,rem,pay));
        e.manifestHash=keccak256(abi.encode(block.chainid,address(kernel),c.windowId,e.sourceStartBlock,e.snapshotBlockHash,e.closeBlockHash,e.finalityBlockHash,e.entriesHash));
        c.datasetHash=keccak256(abi.encode(candidate.DATASET_TYPEHASH(),candidate.domainSeparator(),c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion,e.exclusionSetVersion,e.exclusionSetHash,uint256(kernel.activationBlock()),kernel.activationBlockHash(),kernel.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash));
        l=H.Leaf(candidate.domainSeparator(),c.distributionId,1,c.windowId,start,c.windowEnd,address(0),c.windowPool,c.windowPool,0,recipient,c.windowPool,c.datasetHash,1);
        c.root=keccak256(abi.encode(candidate.LEAF_TYPEHASH(),l.domainSeparator,l.distributionId,l.commitmentVersion,l.windowId,l.windowStart,l.windowEnd,l.rewardAsset,l.windowPool,l.finalizedTotalPayable,l.recipientIndex,l.recipient,l.amount,l.datasetHash,l.algorithmVersion));
    }
    function _nonempty(address recipient) internal returns(bytes32 leaf) {
        (H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(recipient);
        vm.prank(FINALIZER);distributor.submitCandidate(c,e);vm.prank(FINALIZER);leaf=distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
    }
    function _empty() internal returns(bytes32 wid,H.EmptyEvidence memory x) {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(address(0xBEEF));wid=c.windowId;
        x=H.EmptyEvidence(e.manifestHash,candidate.EMPTY_ENTRIES(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash);
        x.manifestHash=keccak256(abi.encode("LOCAL_ZERO_ROW_MANIFEST",c.windowId,c.windowPool,x.entriesHash,x.snapshotBlockHash,x.closeBlockHash,x.finalityBlockHash));
        vm.prank(FINALIZER);distributor.submitEmptyCandidate(c.windowStart,1,x);vm.warp(block.timestamp+1800);distributor.finalizeEmptyCandidate(wid);
    }
    function _shutdownAndTerminate() internal {vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();}
    function testCurrentStrategyPrincipalOnlyAndAccounting() public {_settle(1 ether);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);}
    function testCurrentSettlementPositiveProfitAndFourBucketPartition() public {
        _settle(1.1 ether);assertEq(kernel.strategyCapital(),10.065 ether);assertEq(kernel.buybackReserve(),0.015 ether);assertEq(kernel.protocolReserve(),0.01 ether);assertEq(kernel.eligibleWindowHR(),0.01 ether);
    }
    function testCurrentRealKernelHolderPaymentAtomicDebitAndDualAcknowledgement() public {
        _settle(1.1 ether);bytes32 leaf=_nonempty(address(0xBEEF));uint256 aq=kernel.accountedQuote();uint256 balance=address(0xBEEF).balance;
        vm.prank(kernel.AUTOMATION_EXECUTOR());assertTrue(holder.pay(leaf));
        assertEq(address(0xBEEF).balance-balance,0.01 ether);assertEq(kernel.accountedQuote(),aq-0.01 ether);assertEq(kernel.holderRewardReserve(),0);
        (uint8 mask,bool consumed)=state.consumption(leaf);assertEq(mask,3);assertTrue(consumed);_assertAccounting();
    }
    function testCurrentFailedHolderTerminalRetryPreservesReserveUntilSuccess() public {
        _settle(1.1 ether);H4HostileHolder recipient=new H4HostileHolder();bytes32 leaf=_nonempty(address(recipient));
        vm.prank(kernel.AUTOMATION_EXECUTOR());assertFalse(holder.pay(leaf));assertEq(kernel.holderRewardReserve(),0.01 ether);
        (T.HolderPayment memory p,)=state.paymentData(leaf);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);
        recipient.accept();vm.prank(kernel.AUTOMATION_EXECUTOR());assertTrue(holder.retry(p.useId));assertEq(kernel.holderRewardReserve(),0);_assertAccounting();
    }
    function testCurrentRecoveryNoRecipientFixedDestinationAndReplay() public {
        _settle(1.1 ether);(bytes32 wid,)=_empty();bytes32 id=state.emptyRecoveryId(wid);_shutdownAndTerminate();uint256 before_=kernel.RECOVERY_TREASURY().balance;
        vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.holderRewardReserve(),0);_assertAccounting();
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);
    }
    function testCurrentEmergencyEntryFixedNativeRecoveryAndDisabledBuyback() public {
        _settle(1.1 ether);vm.expectRevert(Kernel.Unauthorized.selector);kernel.emergencyEnter();
        uint256 balance=address(kernel).balance;uint256 accounted=kernel.accountedQuote();
        vm.prank(EMERGENCY_AUTHORITY);vm.expectRevert(Kernel.Unauthorized.selector);kernel.emergencyEnter();
        assertEq(address(kernel).balance,balance);assertEq(kernel.accountedQuote(),accounted);
        vm.prank(GUARDIAN);kernel.emergencyEnter();
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING));
        bytes32[] memory ids=new bytes32[](1);ids[0]=keccak256("LOCAL_NATIVE_SCOPE");uint8[] memory kinds=new uint8[](1);
        uint256 walletBefore=kernel.emergencyWallet().balance;
        vm.prank(EMERGENCY_AUTHORITY);vm.expectRevert(Emergency.InvalidState.selector);emergency.initialize(ids,kinds);
        vm.prank(EMERGENCY_AUTHORITY);vm.expectRevert(Emergency.Unauthorized.selector);
        emergency.recoverBNB(ids[0],keccak256("LOCAL_ATTEMPT"),1,1 ether,keccak256("LOCAL_RECOVERY_EVIDENCE"));
        assertEq(kernel.emergencyWallet().balance,walletBefore);assertEq(kernel.emergencyBNBOutflow(),0);
        assertEq(address(kernel).balance,balance);assertEq(kernel.accountedQuote(),accounted);
        vm.prank(GUARDIAN);vm.expectRevert(Kernel.RecoveryUnavailable.selector);kernel.recoverAllTerminatedFunds();
        uint256 protectedHR=kernel.holderRewardReserve();uint256 before_=kernel.RECOVERY_TREASURY().balance;
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.TERMINATED));
        vm.prank(GUARDIAN);assertEq(kernel.recoverAllTerminatedFunds(),balance-protectedHR);
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,balance-protectedHR);
        assertEq(kernel.emergencyWallet().balance,walletBefore);assertEq(kernel.holderRewardReserve(),protectedHR);
        assertEq(address(kernel).balance,protectedHR);assertEq(kernel.accountedQuote(),protectedHR);_assertAccounting();
        assertFalse(kernel.buybackActivated());
        vm.expectRevert(Kernel.QuotePolicyUnavailable.selector);kernel.activateBuyback(keccak256("disabled"));
    }
    function testCurrentDisabledBuybackAcrossPauseShutdownAndTermination() public {
        Policy policy=Policy(kernel.moduleAddress(T.ModuleId.BUYBACK));
        vm.prank(GUARDIAN);kernel.pause();vm.expectRevert(Kernel.QuotePolicyUnavailable.selector);kernel.activateBuyback(keccak256("disabled"));
        vm.prank(GUARDIAN);kernel.resume();_shutdownAndTerminate();assertFalse(kernel.buybackActivated());
        vm.expectRevert(Kernel.QuotePolicyUnavailable.selector);kernel.activateBuyback(keccak256("disabled"));
        vm.expectRevert();policy.attempt(keccak256("disabled"),keccak256("quote"));
    }
    function testCurrentEmptyEvidenceGetterReturnsCommittedCanonicalWindowEvidence() public {
        _settle(1.1 ether);(bytes32 wid,H.EmptyEvidence memory expected)=_empty();H.EmptyEvidence memory actual=candidate.emptyEvidence(wid);
        assertEq(keccak256(abi.encode(actual)),keccak256(abi.encode(expected)),"canonical window empty evidence cannot be recovered");
    }
    function _h5SubmitReviewedEmptyThenShutdown() internal returns(bytes32 wid) {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(address(0xBEEF));wid=c.windowId;
        H.EmptyEvidence memory x=H.EmptyEvidence(e.manifestHash,candidate.EMPTY_ENTRIES(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash);
        vm.prank(FINALIZER);distributor.submitEmptyCandidate(c.windowStart,1,x);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+1800);
        (bytes32 actual,,,uint256 pool,bool eligible)=kernel.deriveWindow(c.windowStart);
        assertEq(actual,wid);assertEq(pool,c.windowPool);assertTrue(eligible,"completed window remains canonically eligible during shutdown");
    }
    function testH5CampaignReviewedEmptyWindowCanFinalizeDuringShutdown() public {
        bytes32 wid=_h5SubmitReviewedEmptyThenShutdown();
        // Completion of an already accepted, fully reviewed closed window must remain possible.
        distributor.finalizeEmptyCandidate(wid);assertEq(candidate.openReviewCount(),0);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.TERMINATED));
    }
    function testH5CampaignNonemptyReviewCanFinalizeDuringShutdownControl() public {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(address(0xBEEF));
        vm.prank(FINALIZER);distributor.submitCandidate(c,e);vm.prank(FINALIZER);distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
        assertTrue(candidate.candidate(c.distributionId,1).finalized);assertEq(candidate.openReviewCount(),0);_assertAccounting();
    }
    function testH5CampaignEmptyShutdownDeadlockDiagnostic() public {
        bytes32 wid=_h5SubmitReviewedEmptyThenShutdown();distributor.finalizeEmptyCandidate(wid);
        assertEq(candidate.openReviewCount(),0);assertEq(candidate.pendingCandidateReserve(),0);
        assertTrue(state.emptyRecoveryId(wid)!=0);assertTrue(holder.terminationReady());
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.TERMINATED));_assertAccounting();
    }
    function _h6Accept(uint64 offset) internal returns(bytes32 wid,H.EmptyEvidence memory x) {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(address(0xBEEF));wid=c.windowId;vm.warp(block.timestamp+offset);
        x=H.EmptyEvidence(e.manifestHash,candidate.EMPTY_ENTRIES(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash);
        vm.prank(FINALIZER);distributor.submitEmptyCandidate(c.windowStart,1,x);
    }
    function _h6Snapshot(bytes32 wid) internal view returns(bytes32) {
        return keccak256(abi.encode(candidate.emptyRecord(wid),candidate.emptyEvidence(wid),candidate.pendingCandidateReserve(),candidate.openReviewCount(),candidate.reconciliationDigest(),state.emptyRecoveryId(wid),state.outstandingHolderLiability(),kernel.holderRewardReserve(),kernel.eligibleWindowHR(),kernel.accountedQuote(),address(kernel).balance));
    }
    function _h6RejectFinalize(bytes32 wid) internal {
        bytes32 before_=_h6Snapshot(wid);vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeEmptyCandidate(wid);assertEq(_h6Snapshot(wid),before_);
    }
    function testH6ActivePermissionlessFinalizationHasNoBNBTransfer() public {
        (bytes32 wid,H.EmptyEvidence memory e)=_h6Accept(0);uint64 accepted=candidate.emptyRecord(wid).acceptedAt;uint256 balance=address(kernel).balance;
        vm.warp(accepted+1800);vm.prank(address(0xCA11));candidate.finalizeEmptyCandidate(wid);
        assertEq(candidate.openReviewCount(),0);assertEq(address(kernel).balance,balance);assertEq(keccak256(abi.encode(candidate.emptyEvidence(wid))),keccak256(abi.encode(e)));_assertAccounting();
    }
    function testH6ImmediateShutdownExactReviewAndRecovery() public {
        (bytes32 wid,H.EmptyEvidence memory e)=_h6Accept(0);Candidate.EmptyRecord memory original=candidate.emptyRecord(wid);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(kernel.shutdownStartedAt(),original.acceptedAt);
        vm.warp(original.acceptedAt+1799);_h6RejectFinalize(wid);vm.warp(original.acceptedAt+1800);
        vm.prank(address(0xCA11));distributor.finalizeEmptyCandidate(wid);assertEq(candidate.openReviewCount(),0);assertEq(candidate.pendingCandidateReserve(),0);
        assertEq(candidate.emptyRecord(wid).acceptedAt,original.acceptedAt);assertEq(candidate.emptyRecord(wid).commitment,original.commitment);
        assertEq(keccak256(abi.encode(candidate.emptyEvidence(wid))),keccak256(abi.encode(e)));_h6RejectFinalize(wid);
        bytes32 id=state.emptyRecoveryId(wid);vm.expectRevert(Kernel.RecoveryUnavailable.selector);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();uint256 before_=kernel.RECOVERY_TREASURY().balance;
        vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.holderRewardReserve(),0);
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);_assertAccounting();
    }
    function testH6ShutdownCannotAcceptNewEmptyOrContradictoryCandidate() public {
        (bytes32 wid,H.EmptyEvidence memory e)=_h6Accept(0);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);bytes32 before_=_h6Snapshot(wid);
        vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.submitEmptyCandidate(windowStart,1,e);
        (H.Candidate memory c,H.CandidateEvidence memory ce,)=_vector(address(0xBEEF));vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.submitCandidate(c,ce);
        assertEq(_h6Snapshot(wid),before_);
    }
    function testH6PausedFinalizationRejectedThenActiveResumeWorks() public {
        (bytes32 wid,)=_h6Accept(0);vm.warp(block.timestamp+1800);vm.prank(GUARDIAN);kernel.pause();_h6RejectFinalize(wid);
        vm.prank(GUARDIAN);kernel.resume();distributor.finalizeEmptyCandidate(wid);assertEq(candidate.openReviewCount(),0);_assertAccounting();
    }
    function testH6EmergencyFinalizationRejectedWithoutMutation() public {
        (bytes32 wid,H.EmptyEvidence memory evidence)=_h6Accept(0);uint64 accepted=candidate.emptyRecord(wid).acceptedAt;
        bytes32 before_=_h6Snapshot(wid);
        vm.prank(EMERGENCY_AUTHORITY);vm.expectRevert(Kernel.Unauthorized.selector);kernel.emergencyEnter();
        assertEq(_h6Snapshot(wid),before_);assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.ACTIVE));
        vm.prank(GUARDIAN);kernel.emergencyEnter();assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING));
        // The alias starts shutdown, not the retired EMERGENCY_RECOVERY state.
        // Keep rejection/no-mutation coverage before review maturity and on replay;
        // necessary reviewed reconciliation must remain available during shutdown.
        vm.warp(accepted+1799);_h6RejectFinalize(wid);
        uint256 balance=address(kernel).balance;uint256 reserve=kernel.holderRewardReserve();
        vm.warp(accepted+1800);distributor.finalizeEmptyCandidate(wid);
        assertTrue(candidate.emptyRecord(wid).finalized);assertEq(candidate.emptyRecord(wid).acceptedAt,accepted);
        assertEq(candidate.openReviewCount(),0);assertEq(candidate.pendingCandidateReserve(),0);
        assertEq(keccak256(abi.encode(candidate.emptyEvidence(wid))),keccak256(abi.encode(evidence)));
        assertEq(address(kernel).balance,balance);assertEq(kernel.holderRewardReserve(),reserve);
        _h6RejectFinalize(wid);_assertAccounting();
    }
    function testH6TerminatedFinalizationAndUnknownIDsRejected() public {
        _settle(1.1 ether);(bytes32 wid,)=_empty();_shutdownAndTerminate();_h6RejectFinalize(wid);_h6RejectFinalize(keccak256("UNKNOWN_WINDOW"));_assertAccounting();
    }
    function testH6CallerCannotSubmitOrAlterAcceptedEvidence() public {
        (bytes32 wid,H.EmptyEvidence memory e)=_h6Accept(0);bytes32 before_=_h6Snapshot(wid);e.manifestHash=keccak256("UNAUTHORIZED_MUTATION");
        vm.expectRevert(Distributor.Unauthorized.selector);vm.prank(address(0xCA11));distributor.submitEmptyCandidate(windowStart,1,e);
        vm.expectRevert(Candidate.Unauthorized.selector);vm.prank(address(0xCA11));candidate.submitEmptyCandidate(windowStart,1,e);
        assertEq(_h6Snapshot(wid),before_);_h6RejectFinalize(wid);_h6RejectFinalize(keccak256("UNKNOWN_WINDOW"));
    }
    function testFuzzH6ReviewShutdownTimingAndReserveConservation(uint32 offset,uint16 shutdownWait,uint16 reviewWait,bool activeFirst) public {
        (bytes32 wid,H.EmptyEvidence memory e)=_h6Accept(uint64(offset%86400));uint64 accepted=candidate.emptyRecord(wid).acceptedAt;
        vm.warp(block.timestamp+shutdownWait%3601);
        if(!activeFirst){vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);}
        uint256 target=uint256(accepted)+reviewWait%3601;if(target>block.timestamp)vm.warp(target);
        if(block.timestamp<accepted+1800){_h6RejectFinalize(wid);vm.warp(accepted+1800);}
        distributor.finalizeEmptyCandidate(wid);_h6RejectFinalize(wid);
        if(activeFirst){vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);}
        assertEq(keccak256(abi.encode(candidate.emptyEvidence(wid))),keccak256(abi.encode(e)));assertEq(state.outstandingHolderLiability(),0.01 ether);assertEq(candidate.openReviewCount(),0);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();_assertAccounting();
    }
    function h6StepAccept() external {
        require(msg.sender==address(h6Actions));if(h6Window!=0)return;
        H.EmptyEvidence memory e;(h6Window,e)=_h6Accept(0);h6EvidenceHash=keccak256(abi.encode(e));h6Accepted=candidate.emptyRecord(h6Window).acceptedAt;
    }
    function h6StepShutdown(uint16 delay) external {
        require(msg.sender==address(h6Actions));if(h6Window==0||kernel.lifecycle()!=T.Lifecycle.ACTIVE)return;
        vm.warp(block.timestamp+delay%3601);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);
    }
    function h6StepFinalize(uint16 delay,bool direct) external {
        require(msg.sender==address(h6Actions));if(h6Window==0)return;vm.warp(block.timestamp+delay%2001);
        if(h6Finalized||block.timestamp<h6Accepted+1800||kernel.lifecycle()==T.Lifecycle.TERMINATED){_h6RejectFinalize(h6Window);return;}
        if(direct)candidate.finalizeEmptyCandidate(h6Window);else distributor.finalizeEmptyCandidate(h6Window);h6Finalized=true;
    }
    function h6StepTerminate(uint16 delay) external {
        require(msg.sender==address(h6Actions));if(h6Window==0||kernel.lifecycle()!=T.Lifecycle.SHUTDOWN_PENDING)return;
        if(delay%4==0&&h6Finalized&&block.timestamp<kernel.shutdownAt())vm.warp(kernel.shutdownAt());else vm.warp(block.timestamp+delay%10000);
        if(!h6Finalized||block.timestamp<kernel.shutdownAt()){vm.expectRevert(Kernel.ShutdownNotReady.selector);vm.prank(GUARDIAN);kernel.terminate();return;}
        vm.prank(GUARDIAN);kernel.terminate();
    }
    function h6StepRecover() external {
        require(msg.sender==address(h6Actions));if(h6Window==0||!h6Finalized)return;bytes32 id=state.emptyRecoveryId(h6Window);
        if(h6Recovered){vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);return;}
        if(kernel.lifecycle()!=T.Lifecycle.TERMINATED){vm.expectRevert(Kernel.RecoveryUnavailable.selector);vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);return;}
        vm.prank(GUARDIAN);recovery.recoverNoRecipient(id);h6Recovered=true;
    }
    function invariantH6RealKernelReviewLifecycleAndReserveConservation() public view {
        _assertAccounting();if(h6Window==0)return;
        Candidate.EmptyRecord memory record=candidate.emptyRecord(h6Window);assertEq(record.acceptedAt,h6Accepted);assertEq(keccak256(abi.encode(candidate.emptyEvidence(h6Window))),h6EvidenceHash);
        assertEq(record.finalized,h6Finalized);assertEq(candidate.openReviewCount(),h6Finalized?0:1);assertEq(candidate.pendingCandidateReserve(),h6Finalized?0:0.01 ether);
        assertEq(state.outstandingHolderLiability(),h6Finalized&&!h6Recovered?0.01 ether:0);assertEq(kernel.holderRewardReserve(),h6Recovered?0:0.01 ether);
        if(kernel.lifecycle()==T.Lifecycle.TERMINATED)assertTrue(h6Finalized);
    }
    function testH6CampaignProtocolAndTreasuryRecoveryAreTypedFixedAndOneShot() public {
        _settle(1.1 ether);_empty();_shutdownAndTerminate();
        bytes32 protocolId=state.bucketRecoveryId(0);uint256 before_=kernel.RECOVERY_TREASURY().balance;
        vm.expectRevert(Recovery.Unauthorized.selector);recovery.recoverProtocol(protocolId);
        vm.prank(GUARDIAN);recovery.recoverProtocol(protocolId);assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.protocolReserve(),0);_assertAccounting();
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverProtocol(protocolId);
        bytes32 principalId=state.bucketRecoveryId(3);before_=kernel.RECOVERY_TREASURY().balance;
        vm.prank(GUARDIAN);recovery.recoverTreasuryPrincipal(principalId);assertEq(kernel.RECOVERY_TREASURY().balance-before_,90 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),0);_assertAccounting();
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverTreasuryPrincipal(principalId);
    }
    function testH6CampaignTerminalExactExpiryAndTypedRecovery() public {
        _settle(1.1 ether);H4HostileHolder recipient=new H4HostileHolder();bytes32 leaf=_nonempty(address(recipient));
        vm.prank(kernel.AUTOMATION_EXECUTOR());assertFalse(holder.pay(leaf));(T.HolderPayment memory p,)=state.paymentData(leaf);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);
        (,uint64 began,uint64 expires,)=state.terminalStatus(leaf);assertEq(expires-began,604_800);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();bytes32 id=state.expiredHolderRecoveryId(leaf);
        vm.warp(expires-1);vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);assertEq(kernel.holderRewardReserve(),0.01 ether);
        address automation=kernel.AUTOMATION_EXECUTOR();vm.warp(expires);vm.expectRevert(Holder.InvalidPayment.selector);vm.prank(automation);holder.retry(p.useId);
        uint256 before_=kernel.RECOVERY_TREASURY().balance;vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.holderRewardReserve(),0);assertEq(state.terminalOutstanding(),0);_assertAccounting();
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);recovery.recoverExpiredLiability(id);
    }
    function _h6ReviewedNonemptyAfterShutdown() internal returns(bytes32 leaf) {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(address(0xBEEF));
        vm.prank(FINALIZER);distributor.submitCandidate(c,e);vm.prank(FINALIZER);leaf=distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
    }
    function testH6CampaignReviewedNonemptyShutdownHasAForwardSettlementPath() public {
        bytes32 leaf=_h6ReviewedNonemptyAfterShutdown();
        (,,,,,bool payableNow)=state.canonicalPayment(leaf);
        // Closure must use an existing legal payment/terminal route, never fabricate a failure.
        if(payableNow){vm.prank(kernel.AUTOMATION_EXECUTOR());assertTrue(holder.pay(leaf));}
        else holder.terminalize(leaf);
        assertEq(state.unresolvedOrdinary(),0,"accepted review trapped ordinary Holder liability");
    }
    function testH6CampaignReviewedNonemptyShutdownDeadlockDiagnostic() public {
        bytes32 leaf=_h6ReviewedNonemptyAfterShutdown();(T.HolderPayment memory p,)=state.paymentData(leaf);
        (bytes32 failure,,,)=kernel.failedHolder(p.useId);assertEq(failure,0);(,,,,,bool payableNow)=state.canonicalPayment(leaf);assertTrue(payableNow);
        vm.expectRevert(State.InvalidPayment.selector);holder.terminalize(leaf);
        assertEq(state.unresolvedOrdinary(),1);assertEq(state.outstandingHolderLiability(),0.01 ether);assertFalse(holder.terminationReady());
        vm.warp(kernel.shutdownAt());vm.expectRevert(Kernel.ShutdownNotReady.selector);vm.prank(GUARDIAN);kernel.terminate();
        vm.prank(kernel.AUTOMATION_EXECUTOR());assertTrue(holder.pay(leaf));assertEq(state.unresolvedOrdinary(),0);
        vm.prank(GUARDIAN);kernel.terminate();_assertAccounting();
    }
}
