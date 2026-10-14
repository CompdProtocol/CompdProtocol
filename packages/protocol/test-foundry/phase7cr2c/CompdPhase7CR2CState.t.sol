// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2c/CompdCanonicalHolderStateV3.sol";

contract KernelStateMock {
    address private constant TEST_COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    T.Lifecycle public lifecycle;
    uint256 public holderRewardReserve;
    mapping(bytes32=>bool) public paid;
    mapping(bytes32=>bytes32) private _digest;
    mapping(bytes32=>address) private _recipient;
    mapping(bytes32=>uint256) private _amount;
    mapping(bytes32=>bytes32) private _leaf;
    function configure(T.Lifecycle l,uint256 hr) external {lifecycle=l;holderRewardReserve=hr;}
    function setFailed(bytes32 useId,bytes32 digest,address recipient,uint256 amount,bytes32 leaf) external {_digest[useId]=digest;_recipient[useId]=recipient;_amount[useId]=amount;_leaf[useId]=leaf;}
    function setPaid(bytes32 useId,bool value) external {paid[useId]=value;}
    function holderPaid(bytes32 useId) external view returns(bool){return paid[useId];}
    function eligibilityToken() external pure returns(address){return TEST_COMPD_TOKEN;}
    function failedHolder(bytes32 useId) external view returns(bytes32,address,uint256,bytes32){return(_digest[useId],_recipient[useId],_amount[useId],_leaf[useId]);}
}

contract CompdPhase7CR2CStateTest is Test {
    address private constant DIST=address(0xD157);
    address private constant LIAB=address(0x11AB);
    address private constant EVIDENCE=address(0xE11D);
    address private constant FINALIZER=address(0xF1A1);
    address private constant RECIPIENT=address(0xBEEF);
    KernelStateMock private kernel;
    State private state;

    function setUp() public {
        vm.warp(100 days);
        kernel=new KernelStateMock();kernel.configure(T.Lifecycle.ACTIVE,10 ether);
        state=new State(address(kernel),DIST,LIAB,EVIDENCE,FINALIZER);
    }

    function testExactR2DigestVectorAndTwoPeerAcknowledgement() public {
        bytes32 leafId=_finalizeOneLeaf();
        (T.HolderPayment memory p,bool proof)=state.paymentData(leafId);assertTrue(proof);
        bytes32 expected=keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,address(kernel),p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));
        assertEq(state.paymentDigest(leafId),expected);
        (bytes32 d1,address r1,address a1,uint256 n1,uint8 status1,bool payable1)=state.canonicalPayment(leafId);
        assertEq(d1,expected);assertEq(r1,RECIPIENT);assertEq(a1,address(0));assertEq(n1,1 ether);assertEq(status1,1);assertTrue(payable1);
        vm.prank(DIST);state.acknowledgePayment(leafId,expected);
        (uint8 mask,bool complete)=state.consumption(leafId);assertEq(mask,1);assertFalse(complete);
        (, , , , ,bool afterFirst)=state.canonicalPayment(leafId);assertFalse(afterFirst);
        vm.prank(LIAB);state.acknowledgePayment(leafId,expected);
        (mask,complete)=state.consumption(leafId);assertEq(mask,3);assertTrue(complete);
        assertEq(state.outstandingHolderLiability(),0);assertEq(state.unresolvedOrdinary(),0);
    }

    function testWrongAndDuplicateAcknowledgementsReject() public {
        bytes32 leafId=_finalizeOneLeaf();bytes32 digest=state.paymentDigest(leafId);
        vm.expectRevert(State.Unauthorized.selector);vm.prank(address(0xBAD));state.acknowledgePayment(leafId,digest);
        vm.prank(DIST);state.acknowledgePayment(leafId,digest);
        vm.expectRevert(State.Unauthorized.selector);vm.prank(DIST);state.acknowledgePayment(leafId,digest);
        vm.prank(LIAB);state.acknowledgePayment(leafId,digest);
        vm.expectRevert(State.InvalidPayment.selector);vm.prank(LIAB);state.acknowledgePayment(leafId,digest);
    }

    function testTerminalizationNeedsKernelFailureAndKeepsDigestAndLiability() public {
        kernel.configure(T.Lifecycle.ACTIVE,1 ether);
        bytes32 leafId=_finalizeOneLeaf();(T.HolderPayment memory p,)=state.paymentData(leafId);bytes32 digest=state.paymentDigest(leafId);
        kernel.configure(T.Lifecycle.SHUTDOWN_PENDING,1 ether);
        vm.expectRevert(State.InvalidPayment.selector);state.terminalize(leafId);
        kernel.setFailed(p.useId,digest,p.recipient,p.amount,leafId);
        uint256 beforeOutstanding=state.outstandingHolderLiability();state.terminalize(leafId);
        (bool terminal,uint64 started,uint64 expires,bytes32 useId)=state.terminalStatus(leafId);
        assertTrue(terminal);assertEq(useId,p.useId);assertEq(started,uint64(block.timestamp));assertEq(expires,started+7_776_000);
        assertEq(state.paymentDigest(leafId),digest);assertEq(state.outstandingHolderLiability(),beforeOutstanding);
        (bytes32 d,address recipient,address asset,uint256 amount,uint8 status,bool payableNow)=state.canonicalPayment(leafId);
        assertEq(d,digest);assertEq(recipient,p.recipient);assertEq(asset,address(0));assertEq(amount,p.amount);assertEq(status,2);assertTrue(payableNow);
        assertEq(state.unresolvedOrdinary(),0);assertEq(state.terminalOutstanding(),1);assertTrue(state.recoveryReconciliationComplete());
    }

    function testStrictTerminalExpiryBoundaryAndOneShotRecovery() public {
        kernel.configure(T.Lifecycle.ACTIVE,1 ether);
        bytes32 leafId=_finalizeOneLeaf();(T.HolderPayment memory p,)=state.paymentData(leafId);bytes32 digest=state.paymentDigest(leafId);
        kernel.configure(T.Lifecycle.SHUTDOWN_PENDING,1 ether);kernel.setFailed(p.useId,digest,p.recipient,p.amount,leafId);state.terminalize(leafId);
        (,,uint64 expires,)=state.terminalStatus(leafId);
        vm.warp(expires-1);(,,,,,bool payableBefore)=state.canonicalPayment(leafId);assertTrue(payableBefore);
        vm.warp(expires);(,,,,,bool payableAt)=state.canonicalPayment(leafId);assertFalse(payableAt);
        kernel.configure(T.Lifecycle.TERMINATED,10 ether);
        bytes32 recoveryId=state.expiredHolderRecoveryId(leafId);
        (bool eligible,uint256 amount)=state.expiredHolderRecovery(recoveryId);assertTrue(eligible);assertEq(amount,1 ether);
        vm.prank(EVIDENCE);state.consumeExpiredHolder(recoveryId);
        (eligible,amount)=state.expiredHolderRecovery(recoveryId);assertFalse(eligible);assertEq(amount,0);
        assertEq(state.outstandingHolderLiability(),0);assertEq(state.terminalOutstanding(),0);
    }

    function testEmptyCandidateRequiresReviewAndExactCanonicalRecoveryId() public {
        bytes32 windowId=keccak256("empty-window");bytes32 evidence=keccak256("empty-evidence");
        vm.prank(DIST);state.submitEmptyCandidate(windowId,1,10 ether,evidence);
        vm.expectRevert(State.InvalidCandidate.selector);vm.prank(DIST);state.finalizeEmptyCandidate(windowId);
        vm.warp(block.timestamp+1_800);vm.prank(DIST);state.finalizeEmptyCandidate(windowId);
        bytes32 id=state.emptyRecoveryId(windowId);kernel.configure(T.Lifecycle.TERMINATED,10 ether);
        (bool eligible,uint256 amount)=state.noRecipientRecovery(id);assertTrue(eligible);assertEq(amount,10 ether);
        vm.prank(EVIDENCE);state.consumeNoRecipient(id);
        (eligible,amount)=state.noRecipientRecovery(id);assertFalse(eligible);assertEq(amount,0);
    }

    function _finalizeOneLeaf() private returns(bytes32 leafId) {
        bytes32 windowId=keccak256("window-1");bytes32 distributionId=keccak256(abi.encode("distribution",windowId));bytes32 dataset=keccak256("dataset");
        uint64 start=uint64(block.timestamp-3_600);uint64 end=uint64(block.timestamp-1_800);
        State.Leaf memory leaf=State.Leaf(state.domainSeparator(),distributionId,1,windowId,start,end,address(0),1 ether,1 ether,0,RECIPIENT,1 ether,dataset,1);
        bytes32 typeHash=state.LEAF_TYPEHASH();leafId=keccak256(abi.encode(typeHash,leaf.domainSeparator,leaf.distributionId,leaf.commitmentVersion,leaf.windowId,leaf.windowStart,leaf.windowEnd,leaf.rewardAsset,leaf.windowPool,leaf.finalizedTotalPayable,leaf.recipientIndex,leaf.recipient,leaf.amount,leaf.datasetHash,leaf.algorithmVersion));
        State.Candidate memory c=State.Candidate(distributionId,windowId,start,end,address(0),1 ether,1 ether,1,leafId,dataset,1,1,0,0,false,false,false,0,0);
        vm.prank(DIST);state.submitCandidate(c);
        vm.prank(DIST);state.materializeLeaf(distributionId,1,leaf,new bytes32[](0));
        vm.warp(block.timestamp+1_800);vm.prank(DIST);state.finalizeCandidate(distributionId,1);
    }
}
