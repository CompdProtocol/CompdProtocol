// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdHolderCandidateTypesV3 as H} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateTypesV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdHolderDistributorV3 as Distributor} from "../../contracts/production/v3/phase7cr2ch/CompdHolderDistributorV3.sol";
import {CompdHolderLiabilityV3 as Liability} from "../../contracts/production/v3/phase7cr2ch/CompdHolderLiabilityV3.sol";
import {CompdRecoveryEvidenceV3 as Evidence} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryEvidenceV3.sol";

/// @dev Deterministic local header vectors, NOT BNB Chain headers/finality qualification.
/// Header = keccak256(abi.encode(chainId, number, timestamp, parentHash)).
/// Activation is inside UTC window 10. Windows 11 and 12 each accrue 1 ether HR.
contract H3CanonicalKernelFixture {
    address public constant eligibilityToken = address(0x70C0);
    uint64 public constant activationBlock = 1000;
    uint64 public constant activationTimestamp = 288_123;
    uint64 public constant firstEligibleWindowStart = 316_800;
    uint32 public constant exclusionSetVersion = 2;
    bool public activationSealed = true;
    bool public activationSealFailed;
    T.Lifecycle public lifecycle = T.Lifecycle.ACTIVE;
    uint256 public holderRewardReserve = 2 ether;
    uint256 public eligibleWindowHR = 2 ether;
    uint256 public protocolReserve;
    uint256 public nonStrategyTreasuryPrincipal;
    uint64 public shutdownAt;
    bytes32 public activationBlockHash;
    bytes32 public activationExclusionSetHash;
    Candidate public candidate;
    mapping(uint64 => uint256) public holderWindowAccrued;
    mapping(bytes32 => bool) public holderPaid;
    struct Failure {bytes32 digest; address recipient; uint256 amount; bytes32 leaf;}
    mapping(bytes32 => Failure) private failures;

    constructor() {
        activationBlockHash = header(activationBlock, activationTimestamp, bytes32(0));
        holderWindowAccrued[firstEligibleWindowStart] = 1 ether;
        holderWindowAccrued[firstEligibleWindowStart + 28_800] = 1 ether;
    }
    function header(uint256 number, uint64 timestamp, bytes32 parent) public view returns(bytes32) {
        return keccak256(abi.encode(block.chainid, number, timestamp, parent));
    }
    function bind(Candidate c, address s, address d, address l, address e) external {
        require(address(candidate) == address(0)); candidate = c;
        address[15] memory exclusions;
        exclusions[0] = address(this); exclusions[1] = eligibilityToken;
        exclusions[2] = address(c); exclusions[3] = s; exclusions[4] = d;
        exclusions[5] = l; exclusions[6] = e;
        activationExclusionSetHash = c.computeExclusionSetHash(exclusions, exclusionSetVersion);
    }
    function activationContextHash() external view returns(bytes32) {
        return candidate.computeActivationContextHash(activationBlock, activationBlockHash, activationTimestamp, firstEligibleWindowStart, block.chainid, address(this));
    }
    function deriveWindow(uint64 start) external view returns(bytes32 wid, bytes32 did, uint64 end, uint256 pool, bool eligible) {
        if(start % 28_800 != 0 || start < firstEligibleWindowStart || start > type(uint64).max - 28_800) return(0,0,0,0,false);
        (wid,did,end) = candidate.computeWindowIdentity(activationBlock,activationBlockHash,activationTimestamp,start,block.chainid,eligibilityToken,address(this),candidate.distributor());
        pool = holderWindowAccrued[start];
        eligible = activationSealed && !activationSealFailed && lifecycle != T.Lifecycle.EMERGENCY_RECOVERY && lifecycle != T.Lifecycle.TERMINATED && block.timestamp >= end && pool != 0;
    }
    function setLifecycle(T.Lifecycle value) external {lifecycle = value;}
    function setSeal(bool sealed_, bool failed_) external {activationSealed = sealed_; activationSealFailed = failed_;}
    function setPool(uint64 start,uint256 amount) external {
        uint256 old=holderWindowAccrued[start];holderWindowAccrued[start]=amount;
        holderRewardReserve=holderRewardReserve-old+amount;eligibleWindowHR=eligibleWindowHR-old+amount;
    }
    function recordFailure(T.HolderPayment calldata p, bytes32 digest) external {failures[p.useId] = Failure(digest,p.recipient,p.amount,p.leafId);}
    function failedHolder(bytes32 id) external view returns(bytes32,address,uint256,bytes32) {Failure memory f = failures[id]; return(f.digest,f.recipient,f.amount,f.leaf);}
}

/// @dev Reproducible local replay of a one-holder, weight=1, exact integer payout.
contract H3OneHolderReplay {
    function replay(uint256 pool) external pure returns(uint256 weight,uint256 quotient,uint256 remainder,uint256 payout) {return(1,pool,0,pool);}
}

interface IH4ReservationDriver {
    function stepReserve(uint8,bool) external;
    function stepCorrect(uint8) external;
    function stepFinalize(uint8) external;
    function stepContradict(uint8) external;
}

contract H4ReservationActions {
    IH4ReservationDriver immutable driver;
    constructor(IH4ReservationDriver d){driver=d;}
    function reserve(uint8 slot,bool empty) external {driver.stepReserve(slot,empty);}
    function correct(uint8 slot) external {driver.stepCorrect(slot);}
    function finalize(uint8 slot) external {driver.stepFinalize(slot);}
    function contradict(uint8 slot) external {driver.stepContradict(slot);}
}

contract CompdPhase7CR2CHCanonicalStateTest is Test {
    address constant FINALIZER = address(0xF1A1);
    address constant RECIPIENT = address(0xBEEF);
    uint64 constant START = 316_800;
    uint64 constant END = START + 28_800;
    H3CanonicalKernelFixture kernel;
    Candidate candidate;
    State state;
    Distributor distributor;
    Liability liability;
    Evidence evidence;
    H3OneHolderReplay replay;
    H4ReservationActions actions;
    uint8[4] owners;
    uint32[4] versions;
    bool[4] finalized;
    bool handlerInitialized;

    function setUp() public {
        vm.chainId(31337); vm.roll(1114); vm.warp(END + 37);
        kernel = new H3CanonicalKernelFixture();
        uint256 nonce = vm.getNonce(address(this));
        address predictedState = vm.computeCreateAddress(address(this),nonce+1);
        address predictedDistributor = vm.computeCreateAddress(address(this),nonce+2);
        address predictedLiability = vm.computeCreateAddress(address(this),nonce+3);
        address predictedEvidence = vm.computeCreateAddress(address(this),nonce+4);
        candidate = new Candidate(address(kernel),predictedState,predictedDistributor,FINALIZER,kernel.eligibilityToken());
        state = new State(address(kernel),predictedDistributor,predictedLiability,predictedEvidence,FINALIZER,address(candidate),kernel.eligibilityToken(),address(candidate).codehash);
        distributor = new Distributor(address(kernel),address(state),address(candidate),FINALIZER);
        liability = new Liability(address(kernel),address(state));
        evidence = new Evidence(address(kernel),address(state));
        assertEq(address(state),predictedState); assertEq(address(distributor),predictedDistributor);
        assertEq(address(liability),predictedLiability); assertEq(address(evidence),predictedEvidence);
        kernel.bind(candidate,address(state),address(distributor),address(liability),address(evidence));
        replay = new H3OneHolderReplay();
        actions=new H4ReservationActions(IH4ReservationDriver(address(this)));
        bytes4[] memory selectors=new bytes4[](4);
        selectors[0]=actions.reserve.selector;selectors[1]=actions.correct.selector;
        selectors[2]=actions.finalize.selector;selectors[3]=actions.contradict.selector;
        targetSelector(FuzzSelector(address(actions),selectors));targetContract(address(actions));
    }

    function _vector(uint32 version) internal view returns(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l) {
        (bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible) = kernel.deriveWindow(START); require(eligible);
        e.snapshotBlock=1100; e.snapshotBlockHash=kernel.header(1100,end-3,kernel.activationBlockHash());
        e.sourceStartBlock=kernel.activationBlock(); e.closeBlock=1101;
        e.closeBlockHash=kernel.header(1101,end,e.snapshotBlockHash);
        e.finalityBlock=1113; e.finalityBlockHash=kernel.header(1113,end+36,e.closeBlockHash);
        e.exclusionSetVersion=kernel.exclusionSetVersion(); e.exclusionSetHash=kernel.activationExclusionSetHash();
        e.replayCodeHash=address(replay).codehash;
        uint16[] memory indices=new uint16[](1); address[] memory recipients=new address[](1); recipients[0]=RECIPIENT;
        uint256[] memory weights=new uint256[](1); uint256[] memory quotients=new uint256[](1);
        uint256[] memory remainders=new uint256[](1); uint256[] memory payouts=new uint256[](1);
        (weights[0],quotients[0],remainders[0],payouts[0])=replay.replay(pool);
        e.entriesHash=keccak256(abi.encode(keccak256("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"),indices,recipients,weights,quotients,remainders,payouts));
        e.manifestHash=keccak256(abi.encode(block.chainid,address(kernel),wid,did,e.sourceStartBlock,e.snapshotBlockHash,e.closeBlockHash,e.finalityBlockHash,e.entriesHash,e.exclusionSetHash,e.replayCodeHash));
        c.distributionId=did; c.windowId=wid; c.windowStart=START; c.windowEnd=end;
        c.windowPool=pool; c.payableTotal=pool; c.recipientCount=1; c.algorithmVersion=1; c.version=version;
        c.datasetHash=_dataset(c,e);
        l=H.Leaf(candidate.domainSeparator(),did,version,wid,START,end,address(0),pool,pool,0,RECIPIENT,pool,c.datasetHash,1);
        c.root=_leafHash(l);
    }
    function _dataset(H.Candidate memory c,H.CandidateEvidence memory e) internal view returns(bytes32) {
        return keccak256(abi.encode(candidate.DATASET_TYPEHASH(),candidate.domainSeparator(),c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion,e.exclusionSetVersion,e.exclusionSetHash,uint256(kernel.activationBlock()),kernel.activationBlockHash(),kernel.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash));
    }
    function _commitment(H.Candidate memory c,H.CandidateEvidence memory e,bytes32 prior,bytes32 reason) internal view returns(bytes32) {
        return keccak256(abi.encode(candidate.EVIDENCE_TYPEHASH(),candidate.domainSeparator(),c.distributionId,c.windowId,c.version,c.datasetHash,e.manifestHash,e.entriesHash,kernel.activationContextHash(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,c.algorithmVersion,e.replayCodeHash,c.root,c.recipientCount,c.windowPool,prior,reason));
    }
    function _leafHash(H.Leaf memory l) internal view returns(bytes32) {
        return keccak256(abi.encode(candidate.LEAF_TYPEHASH(),l.domainSeparator,l.distributionId,l.commitmentVersion,l.windowId,l.windowStart,l.windowEnd,l.rewardAsset,l.windowPool,l.finalizedTotalPayable,l.recipientIndex,l.recipient,l.amount,l.datasetHash,l.algorithmVersion));
    }
    function _submit(H.Candidate memory c,H.CandidateEvidence memory e) internal {vm.prank(FINALIZER);distributor.submitCandidate(c,e);}
    function _finalize() internal returns(bytes32 leafId) {
        (H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(1);_submit(c,e);
        vm.prank(FINALIZER);leafId=distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
    }
    function _emptyVector() internal view returns(H.EmptyEvidence memory x) {
        (,H.CandidateEvidence memory e,)=_vector(1);
        x=H.EmptyEvidence(e.manifestHash,candidate.EMPTY_ENTRIES(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash);
        // Separate, complete zero-row local manifest. Entries are the frozen EMPTY_ENTRIES identity.
        x.manifestHash=keccak256(abi.encode(block.chainid,address(kernel),START,END,x.entriesHash,x.snapshotBlockHash,x.closeBlockHash,x.finalityBlockHash,x.exclusionSetHash,x.replayCodeHash));
    }
    function _emptySubmit(H.EmptyEvidence memory e) internal {vm.prank(FINALIZER);distributor.submitEmptyCandidate(START,1,e);}
    function _digest(T.HolderPayment memory p) internal view returns(bytes32) {
        return keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,address(kernel),p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));
    }

    function testCanonicalWindowExcludesPartialActivationAndUsesExactUTCWindow() public view {
        assertEq(kernel.firstEligibleWindowStart(),(kernel.activationTimestamp()/28_800+1)*28_800);
        (bytes32 partialId,,,,bool ok)=kernel.deriveWindow(288_000);assertEq(partialId,0);assertFalse(ok);
        (bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible)=kernel.deriveWindow(START);
        assertTrue(eligible);assertEq(end-START,28_800);assertEq(pool,1 ether);
        (bytes32 expectedWid,bytes32 expectedDid,)=candidate.computeWindowIdentity(kernel.activationBlock(),kernel.activationBlockHash(),kernel.activationTimestamp(),START,block.chainid,kernel.eligibilityToken(),address(kernel),address(distributor));
        assertEq(wid,expectedWid);assertEq(did,expectedDid);
    }
    function testAcceptedVectorAndReviewBoundary() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(1);_submit(c,e);
        assertEq(candidate.candidateEvidenceCommitment(c.distributionId,1),_commitment(c,e,0,0));
        assertEq(candidate.pendingCandidateReserve(),c.windowPool);assertEq(state.outstandingHolderLiability(),0);
        vm.prank(FINALIZER);distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.warp(block.timestamp+1799);vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(c.distributionId,1);
        vm.warp(block.timestamp+1);distributor.finalizeCandidate(c.distributionId,1);
        assertEq(state.outstandingHolderLiability(),1 ether);assertEq(state.unresolvedOrdinary(),1);
        assertEq(state.finalizedIdentity(c.windowId),_commitment(c,e,0,0));assertEq(candidate.openReviewCount(),0);
        vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(c.distributionId,1);
    }
    function testExactR2DigestAndRealDistributorLiabilityAcknowledgements() public {
        bytes32 leaf=_finalize();(T.HolderPayment memory p,bool proof)=state.paymentData(leaf);assertTrue(proof);
        bytes32 d=_digest(p);assertEq(state.paymentDigest(leaf),d);
        (bytes32 d1,address r,address asset,uint256 amount,uint8 status,bool payableNow)=state.canonicalPayment(leaf);
        assertEq(d1,d);assertEq(r,RECIPIENT);assertEq(asset,address(0));assertEq(amount,1 ether);assertEq(status,1);assertTrue(payableNow);
        vm.prank(address(kernel));distributor.consumePayment(leaf,d);
        (uint8 mask,bool complete)=state.consumption(leaf);assertEq(mask,1);assertFalse(complete);
        (,,,,,bool afterFirst)=state.canonicalPayment(leaf);assertFalse(afterFirst);
        vm.prank(address(kernel));liability.consumePayment(leaf,d);
        (mask,complete)=state.consumption(leaf);assertEq(mask,3);assertTrue(complete);
        assertEq(state.outstandingHolderLiability(),0);assertEq(state.unresolvedOrdinary(),0);
    }
    function testWrongAndDuplicateAcknowledgementsReject() public {
        bytes32 leaf=_finalize();bytes32 digest=state.paymentDigest(leaf);
        vm.expectRevert(State.Unauthorized.selector);state.acknowledgePayment(leaf,digest);
        vm.expectRevert(State.InvalidPayment.selector);vm.prank(address(distributor));state.acknowledgePayment(leaf,bytes32(uint256(digest)^1));
        vm.prank(address(kernel));distributor.consumePayment(leaf,digest);
        vm.expectRevert(State.Unauthorized.selector);vm.prank(address(kernel));distributor.consumePayment(leaf,digest);
        vm.prank(address(kernel));liability.consumePayment(leaf,digest);
        vm.expectRevert(State.InvalidPayment.selector);vm.prank(address(kernel));liability.consumePayment(leaf,digest);
    }
    function testTerminalRequiresExactKernelFailureAndGraceCannotReset() public {
        bytes32 leaf=_finalize();(T.HolderPayment memory p,)=state.paymentData(leaf);bytes32 d=state.paymentDigest(leaf);
        vm.expectRevert(State.InvalidTransition.selector);state.terminalize(leaf);
        kernel.setLifecycle(T.Lifecycle.SHUTDOWN_PENDING);
        vm.expectRevert(State.InvalidPayment.selector);state.terminalize(leaf);
        kernel.recordFailure(p,d);state.terminalize(leaf);
        (bool terminal,uint64 started,uint64 expires,bytes32 useId)=state.terminalStatus(leaf);
        assertTrue(terminal);assertEq(useId,p.useId);assertEq(expires,started+604_800);
        assertEq(state.paymentDigest(leaf),d);assertEq(state.outstandingHolderLiability(),p.amount);
        assertEq(state.unresolvedOrdinary(),0);assertEq(state.terminalOutstanding(),1);
        vm.warp(block.timestamp+1);vm.expectRevert(State.InvalidTransition.selector);state.terminalize(leaf);
        (,uint64 unchanged,,)=state.terminalStatus(leaf);assertEq(unchanged,started);
        // Window 12 has uncommitted HR; reconciliation must remain false, not fabricated true.
        assertFalse(state.recoveryReconciliationComplete());
    }
    function testTerminalExpiryBoundaryAndOneShotRecovery() public {
        bytes32 leaf=_finalize();(T.HolderPayment memory p,)=state.paymentData(leaf);
        kernel.setLifecycle(T.Lifecycle.SHUTDOWN_PENDING);kernel.recordFailure(p,state.paymentDigest(leaf));state.terminalize(leaf);
        (,,uint64 expires,)=state.terminalStatus(leaf);bytes32 id=state.expiredHolderRecoveryId(leaf);
        vm.warp(expires-1);(,,,,,bool payableBefore)=state.canonicalPayment(leaf);assertTrue(payableBefore);
        vm.warp(expires);(,,,,,bool payableAt)=state.canonicalPayment(leaf);assertFalse(payableAt);
        (bool eligible,)=evidence.expiredHolderRecovery(id);assertFalse(eligible);
        kernel.setLifecycle(T.Lifecycle.TERMINATED);(eligible,)=evidence.expiredHolderRecovery(id);assertTrue(eligible);
        vm.prank(address(kernel));evidence.consumeExpiredHolder(id);
        (eligible,)=evidence.expiredHolderRecovery(id);assertFalse(eligible);
        assertEq(state.outstandingHolderLiability(),0);assertEq(state.terminalOutstanding(),0);
        vm.expectRevert(State.InvalidTransition.selector);vm.prank(address(kernel));evidence.consumeExpiredHolder(id);
    }
    function testCorrectionPreservesHistoryResetsReviewAndStaleVersionCannotFinalize() public {
        (H.Candidate memory old,H.CandidateEvidence memory e,)=_vector(1);_submit(old,e);
        bytes32 prior=candidate.candidateEvidenceCommitment(old.distributionId,1);vm.warp(block.timestamp+100);
        (H.Candidate memory next,H.CandidateEvidence memory e2,H.Leaf memory leaf)=_vector(2);
        bytes32 reason=keccak256(abi.encode("LOCAL_REPLAY_RECOMMIT_VERSION",uint32(2)));
        vm.prank(FINALIZER);distributor.correctCandidate(next,e2,reason);
        assertEq(candidate.candidateEvidenceCommitment(old.distributionId,1),prior);
        assertEq(candidate.candidateEvidenceCommitment(next.distributionId,2),_commitment(next,e2,prior,reason));
        assertEq(candidate.candidate(next.distributionId,2).executableAfter,block.timestamp+1800);
        vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(old.distributionId,1);
        vm.prank(FINALIZER);distributor.materializeLeaf(next.distributionId,2,leaf,new bytes32[](0));
        vm.warp(block.timestamp+1799);vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeCandidate(next.distributionId,2);
        vm.warp(block.timestamp+1);distributor.finalizeCandidate(next.distributionId,2);
        assertEq(state.finalizedIdentity(next.windowId),candidate.candidateEvidenceCommitment(next.distributionId,2));
        vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.correctCandidate(next,e2,reason);
    }
    function testInvalidCorrectionVersionAndMissingReasonReject() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);_submit(c,e);c.version=3;
        vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.correctCandidate(c,e,keccak256("reason"));
        c.version=2;vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.correctCandidate(c,e,0);
    }
    function testUnauthorizedFinalizerAndDuplicateCandidateReject() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);
        vm.expectRevert(Distributor.Unauthorized.selector);distributor.submitCandidate(c,e);
        _submit(c,e);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
    }
    function testFinalizerCannotOverrideKernelWindowPoolOrIdentity() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);
        c.windowPool+=1;vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
        c.windowPool-=1;c.windowId=bytes32(uint256(c.windowId)^1);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
        (c,e,)=_vector(1);c.distributionId=bytes32(uint256(c.distributionId)^1);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
    }
    function testCandidateRequiresClosedWindowAndSealedActivation() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);
        vm.warp(END);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
        vm.warp(END+1);kernel.setSeal(false,false);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
        kernel.setSeal(false,true);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
    }
    function testFuzzMissingOrInconsistentEvidenceFailsClosed(uint8 mutation) public {
        mutation=uint8(bound(mutation,0,15));(H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);
        if(mutation==0)e.manifestHash=0;else if(mutation==1)e.entriesHash=0;else if(mutation==2)e.snapshotBlockHash=0;
        else if(mutation==3)e.closeBlockHash=0;else if(mutation==4)e.finalityBlockHash=0;else if(mutation==5)e.replayCodeHash=0;
        else if(mutation==6)e.exclusionSetHash=bytes32(uint256(e.exclusionSetHash)^1);else if(mutation==7)++e.exclusionSetVersion;
        else if(mutation==8)++e.sourceStartBlock;else if(mutation==9)e.snapshotBlock=kernel.activationBlock()-1;
        else if(mutation==10)e.closeBlock=e.snapshotBlock;else if(mutation==11)e.finalityBlock=e.closeBlock-1;
        else if(mutation==12)e.entriesHash=bytes32(uint256(e.entriesHash)^1);else if(mutation==13)++e.finalityBlock;
        else if(mutation==14)e.finalityBlockHash=bytes32(uint256(e.finalityBlockHash)^1);else c.datasetHash=bytes32(uint256(c.datasetHash)^1);
        vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);
    }
    function testCommittedManifestMutationChangesIdentityAndWrongStateHandoffRejects() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(1);
        bytes32 wrongCommitment=_commitment(c,e,0,0);e.manifestHash=keccak256(abi.encode(e.manifestHash,"alternate-local-manifest"));
        assertNotEq(_commitment(c,e,0,0),wrongCommitment);_submit(c,e);
        vm.prank(FINALIZER);distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));
        vm.warp(block.timestamp+1800);distributor.finalizeCandidate(c.distributionId,1);
        vm.expectRevert(State.InvalidCandidate.selector);vm.prank(address(candidate));state.registerFinalizedDistribution(c.distributionId,1,wrongCommitment);
    }
    function testEmptyCandidateUsesActualModuleStateHandoffAndOneShotRecovery() public {
        H.EmptyEvidence memory e=_emptyVector();_emptySubmit(e);(bytes32 wid,,,,)=kernel.deriveWindow(START);
        vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeEmptyCandidate(wid);
        vm.warp(block.timestamp+1800);distributor.finalizeEmptyCandidate(wid);
        assertEq(state.outstandingHolderLiability(),1 ether);assertEq(candidate.openReviewCount(),0);
        bytes32 id=state.emptyRecoveryId(wid);assertNotEq(id,0);
        (bool eligible,)=evidence.noRecipientRecovery(id);assertFalse(eligible);
        kernel.setLifecycle(T.Lifecycle.TERMINATED);(eligible,)=evidence.noRecipientRecovery(id);assertTrue(eligible);
        vm.prank(address(kernel));evidence.consumeNoRecipient(id);(eligible,)=evidence.noRecipientRecovery(id);assertFalse(eligible);
        vm.expectRevert(State.Replay.selector);vm.prank(address(kernel));evidence.consumeNoRecipient(id);
    }
    function testEmptyMissingMalformedEvidenceAndDuplicateReject() public {
        H.EmptyEvidence memory e=_emptyVector();e.manifestHash=0;vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(e);
        e=_emptyVector();e.entriesHash=0;vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(e);
        e=_emptyVector();e.closeBlock=e.snapshotBlock;vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(e);
        e=_emptyVector();_emptySubmit(e);vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(e);
    }
    function testNoDuplicateWindowReservationAcrossNonemptyAndEmptyPaths() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);_submit(c,e);
        // Two genuine accrued windows exist, but the same window must not be reserved twice.
        H.EmptyEvidence memory empty=_emptyVector();
        vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(empty);
    }

    function _vectorFor(uint64 start,uint32 version) internal view returns(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l) {
        (c,e,l)=_vector(version);
        (c.windowId,c.distributionId,c.windowEnd,c.windowPool,)=kernel.deriveWindow(start);
        c.windowStart=start;c.payableTotal=c.windowPool;
        e.snapshotBlock=1100+(start-START)/28_800*100;
        e.snapshotBlockHash=kernel.header(e.snapshotBlock,c.windowEnd-3,kernel.activationBlockHash());
        e.closeBlock=e.snapshotBlock+1;e.closeBlockHash=kernel.header(e.closeBlock,c.windowEnd,e.snapshotBlockHash);
        e.finalityBlock=e.closeBlock+12;e.finalityBlockHash=kernel.header(e.finalityBlock,c.windowEnd+36,e.closeBlockHash);
        uint16[] memory indices=new uint16[](1);address[] memory recipients=new address[](1);recipients[0]=RECIPIENT;
        uint256[] memory w=new uint256[](1);uint256[] memory q=new uint256[](1);uint256[] memory r=new uint256[](1);uint256[] memory p=new uint256[](1);
        (w[0],q[0],r[0],p[0])=replay.replay(c.windowPool);
        e.entriesHash=keccak256(abi.encode(keccak256("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"),indices,recipients,w,q,r,p));
        e.manifestHash=keccak256(abi.encode(block.chainid,address(kernel),c.windowId,c.distributionId,e.sourceStartBlock,e.snapshotBlockHash,e.closeBlockHash,e.finalityBlockHash,e.entriesHash,e.exclusionSetHash,e.replayCodeHash));
        c.datasetHash=_dataset(c,e);
        l=H.Leaf(candidate.domainSeparator(),c.distributionId,version,c.windowId,start,c.windowEnd,address(0),c.windowPool,c.windowPool,0,RECIPIENT,c.windowPool,c.datasetHash,1);
        c.root=_leafHash(l);
    }
    function _emptyFor(uint64 start) internal view returns(H.EmptyEvidence memory x) {
        (,H.CandidateEvidence memory e,)=_vectorFor(start,1);
        x=H.EmptyEvidence(e.manifestHash,candidate.EMPTY_ENTRIES(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash);
        x.manifestHash=keccak256(abi.encode(block.chainid,address(kernel),start,start+28_800,x.entriesHash,x.snapshotBlockHash,x.closeBlockHash,x.finalityBlockHash,x.exclusionSetHash,x.replayCodeHash));
    }
    function _submitEmptyFor(uint64 start) internal {H.EmptyEvidence memory e=_emptyFor(start);vm.prank(FINALIZER);distributor.submitEmptyCandidate(start,1,e);}
    function _snapshot(uint64 start) internal view returns(bytes32) {
        (bytes32 wid,bytes32 did,,,)=kernel.deriveWindow(start);uint32 v=candidate.currentVersion(wid);
        bytes32 normal;
        if(v!=0)normal=keccak256(abi.encode(candidate.candidate(did,v),candidate.candidateEvidence(did,v),candidate.candidateEvidenceCommitment(did,v)));
        bytes32 candidateSnapshot=keccak256(abi.encode(normal,candidate.emptyRecord(wid),candidate.emptyEvidence(wid),v,candidate.pendingCandidateReserve(),candidate.openReviewCount(),candidate.reconciliationDigest()));
        bytes32 stateSnapshot=keccak256(abi.encode(state.outstandingHolderLiability(),state.unresolvedOrdinary(),state.terminalOutstanding(),state.reconciliationDigest(),state.finalizedIdentity(wid),state.emptyRecoveryId(wid)));
        return keccak256(abi.encode(candidateSnapshot,stateSnapshot,kernel.holderRewardReserve(),kernel.eligibleWindowHR(),kernel.holderWindowAccrued(start)));
    }
    function _rejectOpposite(uint64 start,bool emptyOwned) internal {
        bytes32 before_=_snapshot(start);
        if(emptyOwned){(H.Candidate memory c,H.CandidateEvidence memory e,)=_vectorFor(start,1);vm.expectRevert(Candidate.InvalidCandidate.selector);_submit(c,e);}
        else{H.EmptyEvidence memory e=_emptyFor(start);vm.expectRevert(Candidate.InvalidCandidate.selector);vm.prank(FINALIZER);distributor.submitEmptyCandidate(start,1,e);}
        assertEq(_snapshot(start),before_,"rejected cross-path submission changed state");
    }
    function testH4EmptyThenNonemptyRejectsWithCompleteRollback() public {_emptySubmit(_emptyVector());_rejectOpposite(START,true);}
    function testH4NonemptyThenEmptyRejectsWithCompleteRollback() public {(H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);_submit(c,e);_rejectOpposite(START,false);}
    function testH4NonemptyAEmptyBSucceeds() public {
        vm.roll(1214);vm.warp(END+28_800+37);(H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);_submit(c,e);_submitEmptyFor(START+28_800);
        assertEq(candidate.pendingCandidateReserve(),2 ether);assertEq(candidate.openReviewCount(),2);
    }
    function testH4EmptyANonemptyBSucceeds() public {
        vm.roll(1214);vm.warp(END+28_800+37);_emptySubmit(_emptyVector());(H.Candidate memory c,H.CandidateEvidence memory e,)=_vectorFor(START+28_800,1);_submit(c,e);
        assertEq(candidate.pendingCandidateReserve(),2 ether);assertEq(candidate.openReviewCount(),2);
    }
    function testH4FinalizedNonemptyCannotBecomeEmpty() public {_finalize();_rejectOpposite(START,false);}
    function testH4FinalizedEmptyCannotBecomeNonempty() public {
        _emptySubmit(_emptyVector());(bytes32 wid,,,,)=kernel.deriveWindow(START);vm.warp(block.timestamp+1800);distributor.finalizeEmptyCandidate(wid);_rejectOpposite(START,true);
    }
    function testFuzzH4CrossPathDistinctWindowsPoolsOrderAndCorrections(uint8 a,uint8 b,uint96 rawPool,bool emptyFirst,uint8 rawVersion) public {
        a=uint8(bound(a,0,3));b=uint8(bound(b,0,3));if(a==b)b=(b+1)%4;
        uint64 startA=START+uint64(a)*28_800;uint64 startB=START+uint64(b)*28_800;
        uint256 pool=bound(rawPool,1,10 ether);kernel.setPool(startA,pool);kernel.setPool(startB,pool);
        vm.roll(1414);vm.warp(END+3*28_800+37);
        uint64 normalStart=emptyFirst?startB:startA;uint64 emptyStart=emptyFirst?startA:startB;
        if(emptyFirst)_submitEmptyFor(emptyStart);
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vectorFor(normalStart,1);_submit(c,e);
        if(!emptyFirst)_submitEmptyFor(emptyStart);
        _rejectOpposite(normalStart,false);_rejectOpposite(emptyStart,true);
        uint32 last=uint32(bound(rawVersion,1,4));
        for(uint32 v=2;v<=last;v++){(c,e,)=_vectorFor(normalStart,v);vm.prank(FINALIZER);distributor.correctCandidate(c,e,keccak256(abi.encode("LOCAL_SEQUENTIAL_CORRECTION",v)));}
        assertEq(candidate.pendingCandidateReserve(),pool*2);assertEq(state.outstandingHolderLiability(),0);
    }
    function _h5Exact(bytes32 wid,H.EmptyEvidence memory expected) internal {
        bytes32 before_=_snapshot(candidate.emptyRecord(wid).windowStart);
        vm.record();H.EmptyEvidence memory actual=candidate.emptyEvidence(wid);
        (,bytes32[] memory writes)=vm.accesses(address(candidate));assertEq(writes.length,0);
        assertEq(keccak256(abi.encode(actual)),keccak256(abi.encode(expected)),"exact canonical evidence readback");
        assertEq(_snapshot(candidate.emptyRecord(wid).windowStart),before_,"readback mutated reservation or accounting");
    }
    function testH5EvidenceBeforeAndAfterFinalizationPreservesDelayAndIdentity() public {
        H.EmptyEvidence memory e=_emptyVector();_emptySubmit(e);(bytes32 wid,,,,)=kernel.deriveWindow(START);
        Candidate.EmptyRecord memory accepted=candidate.emptyRecord(wid);_h5Exact(wid,e);
        vm.warp(accepted.acceptedAt+1799);vm.expectRevert(Candidate.InvalidCandidate.selector);distributor.finalizeEmptyCandidate(wid);
        _h5Exact(wid,e);vm.warp(accepted.acceptedAt+1800);distributor.finalizeEmptyCandidate(wid);
        bytes32 recoveryId=state.emptyRecoveryId(wid);assertTrue(recoveryId!=0);_h5Exact(wid,e);
        assertEq(state.emptyRecoveryId(wid),recoveryId);assertEq(candidate.emptyRecord(wid).commitment,accepted.commitment);
        _rejectOpposite(START,true);
    }
    function testH5UnknownIncorrectUnrelatedAndRawStorageKeysReturnZero() public {
        _emptySubmit(_emptyVector());(bytes32 wid,bytes32 did,,,)=kernel.deriveWindow(START);
        bytes32[5] memory unknown=[bytes32(0),keccak256("UNKNOWN_WINDOW"),bytes32(uint256(wid)^1),did,keccak256(abi.encode(START))];
        H.EmptyEvidence memory zero;bytes32 before_=_snapshot(START);
        for(uint256 i;i<unknown.length;i++)assertEq(keccak256(abi.encode(candidate.emptyEvidence(unknown[i]))),keccak256(abi.encode(zero)));
        assertEq(_snapshot(START),before_);
    }
    function testH5DistinctWindowsKeepDifferentEvidence() public {
        vm.roll(1214);vm.warp(END+28_800+37);H.EmptyEvidence memory a=_emptyFor(START);H.EmptyEvidence memory b=_emptyFor(START+28_800);
        _emptySubmit(a);vm.prank(FINALIZER);distributor.submitEmptyCandidate(START+28_800,1,b);
        (bytes32 wa,,,,)=kernel.deriveWindow(START);(bytes32 wb,,,,)=kernel.deriveWindow(START+28_800);
        assertTrue(keccak256(abi.encode(a))!=keccak256(abi.encode(b)));_h5Exact(wa,a);_h5Exact(wb,b);
        vm.warp(block.timestamp+1800);distributor.finalizeEmptyCandidate(wa);distributor.finalizeEmptyCandidate(wb);_h5Exact(wa,a);_h5Exact(wb,b);
    }
    function testH5DuplicateAndContradictorySubmissionCannotOverwriteEvidence() public {
        H.EmptyEvidence memory e=_emptyVector();_emptySubmit(e);(bytes32 wid,,,,)=kernel.deriveWindow(START);bytes32 before_=_snapshot(START);
        H.EmptyEvidence memory changed=abi.decode(abi.encode(e),(H.EmptyEvidence));changed.manifestHash=keccak256("ATTEMPTED_OVERWRITE");
        vm.expectRevert(Candidate.InvalidCandidate.selector);_emptySubmit(changed);assertEq(_snapshot(START),before_);_rejectOpposite(START,true);_h5Exact(wid,e);
    }
    function testH5NonemptyEvidenceCannotLeakIntoEmptyGetter() public {
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vector(1);_submit(c,e);H.EmptyEvidence memory zero;
        assertEq(keccak256(abi.encode(candidate.emptyEvidence(c.windowId))),keccak256(abi.encode(zero)));_rejectOpposite(START,false);
    }
    function testFuzzH5CanonicalWindowKeyResolution(uint8 rawSlot,uint96 rawPool,bytes32 salt,bool finalize) public {
        uint64 start=START+uint64(rawSlot%4)*28_800;kernel.setPool(start,bound(rawPool,1,10 ether));vm.roll(1414);vm.warp(END+3*28_800+37);
        H.EmptyEvidence memory e=_emptyFor(start);e.manifestHash=keccak256(abi.encode("H5_FUZZ_MANIFEST",start,salt));
        vm.prank(FINALIZER);distributor.submitEmptyCandidate(start,1,e);(bytes32 wid,,,,)=kernel.deriveWindow(start);_h5Exact(wid,e);
        if(finalize){vm.warp(block.timestamp+1800);distributor.finalizeEmptyCandidate(wid);_h5Exact(wid,e);}
        _rejectOpposite(start,true);
    }
    function _handlerStart(uint8 raw) internal returns(uint64 start,uint8 slot) {
        require(msg.sender==address(actions));slot=raw%4;
        if(!handlerInitialized){handlerInitialized=true;kernel.setPool(START+2*28_800,1 ether);kernel.setPool(START+3*28_800,1 ether);}
        uint256 minimum=END+3*28_800+37;if(block.timestamp<minimum)vm.warp(minimum);
        if(block.number<1414)vm.roll(1414);
        start=START+uint64(slot)*28_800;
    }
    function stepReserve(uint8 raw,bool empty) external {
        (uint64 start,uint8 slot)=_handlerStart(raw);
        if(owners[slot]!=0){_rejectOpposite(start,owners[slot]==2);return;}
        if(empty)_submitEmptyFor(start);else{(H.Candidate memory c,H.CandidateEvidence memory e,)=_vectorFor(start,1);_submit(c,e);}
        owners[slot]=empty?2:1;versions[slot]=1;
    }
    function stepCorrect(uint8 raw) external {
        (uint64 start,uint8 slot)=_handlerStart(raw);if(owners[slot]!=1||finalized[slot]||versions[slot]>=4)return;
        (bytes32 wid,bytes32 did,,,)=kernel.deriveWindow(start);if(block.timestamp>=candidate.candidate(did,versions[slot]).executableAfter)return;
        bytes32 prior=candidate.candidateEvidenceCommitment(did,versions[slot]);uint32 v=versions[slot]+1;
        (H.Candidate memory c,H.CandidateEvidence memory e,)=_vectorFor(start,v);vm.prank(FINALIZER);distributor.correctCandidate(c,e,keccak256(abi.encode("STATEFUL_CORRECTION",wid,v)));
        assertEq(candidate.candidateEvidenceCommitment(did,v-1),prior);versions[slot]=v;
    }
    function stepFinalize(uint8 raw) external {
        (uint64 start,uint8 slot)=_handlerStart(raw);if(owners[slot]==0||finalized[slot])return;
        if(owners[slot]==2){(bytes32 wid,,,,)=kernel.deriveWindow(start);uint64 ready=candidate.emptyRecord(wid).acceptedAt+1800;if(block.timestamp<ready)vm.warp(ready);distributor.finalizeEmptyCandidate(wid);}
        else{(H.Candidate memory c,,H.Leaf memory l)=_vectorFor(start,versions[slot]);uint64 ready=candidate.candidate(c.distributionId,c.version).executableAfter;
            if(block.timestamp>=ready)return; // Materialization is allowed only during the existing review interval.
            vm.prank(FINALIZER);distributor.materializeLeaf(c.distributionId,c.version,l,new bytes32[](0));vm.warp(ready);distributor.finalizeCandidate(c.distributionId,c.version);}
        finalized[slot]=true;
    }
    function stepContradict(uint8 raw) external {(uint64 start,uint8 slot)=_handlerStart(raw);if(owners[slot]!=0)_rejectOpposite(start,owners[slot]==2);}
    function invariantH4WindowOwnershipAndReserveConservation() public view {
        uint256 reserved;
        for(uint8 i;i<4;i++){
            uint64 start=START+uint64(i)*28_800;(bytes32 wid,bytes32 did,,,)=kernel.deriveWindow(start);
            uint32 version=candidate.currentVersion(wid);Candidate.EmptyRecord memory empty=candidate.emptyRecord(wid);
            assertFalse(version!=0&&empty.version!=0,"contradictory path ownership");
            assertFalse(state.finalizedIdentity(wid)!=0&&state.emptyRecoveryId(wid)!=0,"contradictory finalized identity");
            if(owners[i]!=0)reserved+=kernel.holderWindowAccrued(start);
            if(owners[i]==1){assertEq(version,versions[i]);assertEq(empty.version,0);assertEq(candidate.candidate(did,version).finalized,finalized[i]);}
            if(owners[i]==2){assertEq(version,0);assertEq(empty.version,1);assertEq(empty.finalized,finalized[i]);}
        }
        assertEq(candidate.pendingCandidateReserve()+state.outstandingHolderLiability(),reserved);
        assertLe(reserved,kernel.holderRewardReserve());assertEq(kernel.holderRewardReserve(),kernel.eligibleWindowHR());
    }
}
