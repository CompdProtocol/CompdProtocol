// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CompdHolderWorkflowV2} from "../contracts/production/v2/CompdHolderWorkflowV2.sol";
import {CompdHolderLiabilityV2} from "../contracts/production/v2/CompdHolderLiabilityV2.sol";
import {ICompdHolderWorkflowV2 as IWorkflow} from "../contracts/production/v2/ICompdHolderWorkflowV2.sol";
import {ICompdHolderLiabilityV2 as ILiability} from "../contracts/production/v2/ICompdHolderLiabilityV2.sol";
import {CompdV2Types} from "../contracts/production/v2/CompdV2Types.sol";

contract HolderSplitVaultHarness {
    CompdV2Types.Lifecycle public lifecycle = CompdV2Types.Lifecycle.PAUSED;
    function holderWindowId(uint64 start,uint64 end) external pure returns (bytes32) {
        return keccak256(abi.encode(start,end));
    }
    function setLifecycle(CompdV2Types.Lifecycle next) external { lifecycle = next; }
    function accrue(CompdHolderWorkflowV2 workflow,uint256 runId,bytes32 windowId,uint64 start,uint64 end,uint256 amount,uint256 expectedAfter) external {
        workflow.accrueHolderPool(runId,windowId,start,end,amount,expectedAfter);
    }
    function openCandidate(CompdHolderWorkflowV2 workflow,IWorkflow.DistributionCandidateInput calldata i) external {
        workflow.recordDistributionCandidate(i);
    }
    function openEmpty(CompdHolderWorkflowV2 workflow,IWorkflow.EmptyCandidateInput calldata i) external {
        workflow.recordEmptyCandidate(i);
    }
    function finalizeEmpty(CompdHolderWorkflowV2 workflow,bytes32 id,uint32 version,uint256 amount) external {
        workflow.finalizeEmptyCandidate(id,version,amount);
    }
    function classifyEmpty(CompdHolderWorkflowV2 workflow,bytes32 id,uint256 amount) external {
        workflow.classifyNoRecipientPool(id,amount);
    }
    function recoverEmpty(CompdHolderWorkflowV2 workflow,bytes32 id,uint256 amount,bytes32 evidence) external {
        workflow.recordNoRecipientPoolRecovery(id,amount,evidence);
    }
    function correctCandidate(CompdHolderWorkflowV2 workflow,CompdHolderLiabilityV2 liability,IWorkflow.DistributionCandidateInput calldata i,bytes32 reason) external {
        uint32 oldVersion = i.version - 1;
        workflow.correctDistributionCandidate(i,reason);
        liability.supersedeMaterializedVersion(i.distributionId,oldVersion);
    }
    function materialize(CompdHolderLiabilityV2 liability,ILiability.EntryInput calldata i) external {
        liability.registerMaterializedEntry(i);
    }
    function finalizeBoth(CompdHolderWorkflowV2 workflow,CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,uint256 amount,uint16 count) external {
        workflow.finalizeWorkflowDistribution(id,version,amount,count);
        liability.finalizeLiabilityDistribution(id,version,amount,count);
    }
    function fail(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,uint16 index,bytes32 leaf,bytes32 failure) external {
        liability.recordAutomaticPaymentFailure(id,version,index,leaf,failure);
    }
    function makeManualAvailable(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,uint16 index,bytes32 leaf,bytes32 evidence) external {
        liability.recordManualSettlementAvailable(id,version,index,leaf,evidence);
    }
    function pay(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,uint16 index,bytes32 leaf) external {
        liability.recordAutomaticPayment(id,version,index,leaf);
    }
    function manualSettle(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,uint16 index,bytes32 leaf) external {
        liability.recordManualSettlement(id,version,index,leaf);
    }
    function startTerminal(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,bytes32 window,uint16 index,bytes32 leaf) external {
        liability.startTerminalLiability(id,version,window,index,leaf);
    }
    function expire(CompdHolderLiabilityV2 liability,bytes32 id,uint32 version,bytes32 window,uint16 index,bytes32 leaf) external {
        liability.expireTerminalLiability(id,version,window,index,leaf);
    }
}

contract CompdHolderSplitPrototypeTest is Test {
    uint64 internal constant WINDOW = 28_800;
    HolderSplitVaultHarness internal vault;
    CompdHolderWorkflowV2 internal workflow;
    CompdHolderLiabilityV2 internal liability;
    bytes32 internal windowId;
    bytes32 internal distributionId = keccak256("distribution-1");
    bytes32 internal leafHash = keccak256("leaf-0");
    uint64 internal start;
    uint64 internal end;

    function setUp() public {
        vault = new HolderSplitVaultHarness();
        workflow = new CompdHolderWorkflowV2(address(vault));
        liability = new CompdHolderLiabilityV2(address(vault));
        start = uint64((block.timestamp / WINDOW + 4) * WINDOW);
        end = start + WINDOW;
        windowId = vault.holderWindowId(start,end);
        vm.warp(uint256(start) + 10);
    }

    function testAccrualIsWindowBoundAndReplayProtected() public {
        vault.accrue(workflow,1,windowId,start,end,100,100);
        IWorkflow.SourcePartitions memory p = workflow.sourcePartitions();
        assertEq(p.unfinalizedWindowPools,100);
        vm.expectRevert(IWorkflow.InvalidWorkflowTransition.selector);
        vault.accrue(workflow,1,windowId,start,end,100,200);
        vm.expectRevert(IWorkflow.WorkflowRecordMismatch.selector);
        vault.accrue(workflow,2,windowId,start,end,1,100);
        vm.expectRevert(IWorkflow.InvalidWorkflowTransition.selector);
        vault.accrue(workflow,2,keccak256("wrong canonical window"),start,end,1,101);
    }

    function testNonVaultCannotMutateEitherComponent() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IWorkflow.OnlyBoundVault.selector);
        workflow.accrueHolderPool(1,windowId,start,end,100,100);
        vm.prank(address(0xBEEF));
        vm.expectRevert(ILiability.OnlyBoundVault.selector);
        liability.registerMaterializedEntry(_entryInput(1));
    }

    function testCandidateCorrectionRestartsReviewAndSupersedesOldEntries() public {
        _accrueAndOpenCandidate();
        vault.materialize(liability,_entryInput(1));
        IWorkflow.DistributionRecord memory beforeFix = workflow.distribution(distributionId);
        uint64 firstDeadline = beforeFix.executableAfter;
        vm.warp(uint256(beforeFix.acceptedAt) + 500);
        IWorkflow.DistributionCandidateInput memory replacement = _candidate(2,keccak256("root-2"));
        vault.correctCandidate(workflow,liability,replacement,keccak256("correction"));
        IWorkflow.DistributionRecord memory afterFix = workflow.distribution(distributionId);
        assertEq(afterFix.currentVersion,2);
        assertGt(afterFix.executableAfter,firstDeadline);
        ILiability.EntryRecord memory oldEntry = liability.entry(distributionId,1,0);
        assertEq(uint256(oldEntry.status),uint256(ILiability.EntryStatus.SUPERSEDED));
        ILiability.DistributionSummary memory oldSummary = liability.distributionSummary(distributionId,1);
        assertTrue(oldSummary.superseded);
        vm.warp(afterFix.executableAfter);
        vm.expectRevert(IWorkflow.InvalidWorkflowTransition.selector);
        vault.finalizeBoth(workflow,liability,distributionId,1,100,1);
    }

    function testCorrectionWithoutMaterializedEntriesIsAllowed() public {
        _accrueAndOpenCandidate();
        IWorkflow.DistributionCandidateInput memory replacement = _candidate(2,keccak256("root-2"));
        vault.correctCandidate(workflow,liability,replacement,keccak256("correction"));
        IWorkflow.DistributionRecord memory corrected = workflow.distribution(distributionId);
        ILiability.DistributionSummary memory superseded = liability.distributionSummary(distributionId,1);
        assertEq(corrected.currentVersion,2);
        assertTrue(superseded.superseded);
        assertEq(superseded.materializedCount,0);
    }

    function testFinalizationMovesReviewToLiabilityAtomically() public {
        _accrueAndOpenCandidate();
        vault.materialize(liability,_entryInput(1));
        ILiability.EntryRecord memory exactEntry = liability.entry(distributionId,1,0);
        assertEq(exactEntry.leafHash,leafHash);
        assertEq(exactEntry.recipient,address(0xA11CE));
        assertEq(exactEntry.rewardAsset,address(0x1234));
        assertEq(exactEntry.amount,100);
        assertEq(uint256(exactEntry.status),uint256(ILiability.EntryStatus.MATERIALIZED_PENDING_FINALIZATION));
        IWorkflow.DistributionRecord memory d = workflow.distribution(distributionId);
        vm.warp(d.executableAfter);
        vault.finalizeBoth(workflow,liability,distributionId,1,100,1);
        IWorkflow.SourcePartitions memory wp = workflow.sourcePartitions();
        ILiability.SourcePartitions memory lp = liability.sourcePartitions();
        assertEq(wp.normalReviewPools,0);
        assertEq(lp.finalizedUnpaidLiabilities,100);
        assertEq(wp.unfinalizedWindowPools + wp.normalReviewPools + wp.emptyReviewPools + wp.finalizedNoRecipientPools
            + wp.noRecipientRecoveryEligible + lp.finalizedUnpaidLiabilities + lp.expiredLiabilityRecoveryEligible,100);
    }

    function testFinalizationFailureRollsBackWorkflowPartition() public {
        _accrueAndOpenCandidate();
        IWorkflow.DistributionRecord memory d = workflow.distribution(distributionId);
        vm.warp(d.executableAfter);
        vm.expectRevert(ILiability.InvalidLiabilityTransition.selector);
        vault.finalizeBoth(workflow,liability,distributionId,1,100,1);
        IWorkflow.DistributionRecord memory afterAttempt = workflow.distribution(distributionId);
        IWorkflow.SourcePartitions memory p = workflow.sourcePartitions();
        assertEq(uint256(afterAttempt.status),uint256(IWorkflow.DistributionStatus.REVIEW_PENDING));
        assertEq(p.normalReviewPools,100);
    }

    function testNoRecipientPathStaysInWorkflowAndRecoversOnce() public {
        vault.accrue(workflow,1,windowId,start,end,100,100);
        vm.warp(uint256(end)+1);
        IWorkflow.EmptyCandidateInput memory empty = IWorkflow.EmptyCandidateInput({
            windowId:windowId,
            distributionId:distributionId,
            windowStart:start,
            windowEnd:end,
            emptyCommitment:keccak256("empty"),
            manifestHash:keccak256("manifest"),
            snapshotBlockHash:keccak256("snapshot block"),
            activationContextHash:keccak256("activation"),
            evidenceHash:keccak256("empty evidence"),
            correctionReasonHash:bytes32(0),
            poolAmount:100,
            snapshotBlockNumber:123,
            replayVersion:1,
            version:1,
            recipientCount:0,
            zeroResult:true
        });
        vault.openEmpty(workflow,empty);
        IWorkflow.EmptyWindowRecord memory pending = workflow.emptyWindow(windowId);
        vm.warp(pending.executableAfter);
        vault.finalizeEmpty(workflow,windowId,1,100);
        vault.classifyEmpty(workflow,windowId,100);
        IWorkflow.SourcePartitions memory p = workflow.sourcePartitions();
        assertEq(p.finalizedNoRecipientPools,0);
        assertEq(p.noRecipientRecoveryEligible,100);
        vault.recoverEmpty(workflow,windowId,100,keccak256("exact transfer evidence"));
        (bool eligible,uint256 amount,bool recovered,bytes32 evidence) = workflow.noRecipientRecoveryEligible(windowId);
        assertFalse(eligible);
        assertEq(amount,100);
        assertTrue(recovered);
        assertEq(evidence,keccak256("exact transfer evidence"));
        p = workflow.sourcePartitions();
        assertEq(p.noRecipientRecoveryEligible,0);
        vm.expectRevert(IWorkflow.InvalidWorkflowTransition.selector);
        vault.recoverEmpty(workflow,windowId,100,keccak256("replay"));
    }

    function testAutomaticPaymentConsumesOnlyExactFinalizedEntry() public {
        _accrueAndOpenCandidate();
        vault.materialize(liability,_entryInput(1));
        IWorkflow.DistributionRecord memory d = workflow.distribution(distributionId);
        vm.warp(d.executableAfter);
        vault.finalizeBoth(workflow,liability,distributionId,1,100,1);
        vault.pay(liability,distributionId,1,0,leafHash);
        ILiability.SourcePartitions memory p = liability.sourcePartitions();
        assertEq(p.finalizedUnpaidLiabilities,0);
        ILiability.EntryRecord memory e = liability.entry(distributionId,1,0);
        assertEq(uint256(e.status),uint256(ILiability.EntryStatus.PAID));
        vm.expectRevert(ILiability.InvalidLiabilityTransition.selector);
        vault.pay(liability,distributionId,1,0,leafHash);
    }

    function testAutomaticFailureTerminalGraceAndRecoveryAreExact() public {
        _accrueAndOpenCandidate();
        vault.materialize(liability,_entryInput(1));
        IWorkflow.DistributionRecord memory d = workflow.distribution(distributionId);
        vm.warp(d.executableAfter);
        vault.finalizeBoth(workflow,liability,distributionId,1,100,1);
        vault.fail(liability,distributionId,1,0,leafHash,keccak256("token failure"));
        vault.makeManualAvailable(liability,distributionId,1,0,leafHash,keccak256("manual proof"));
        vault.setLifecycle(CompdV2Types.Lifecycle.TERMINATED);
        vault.startTerminal(liability,distributionId,1,windowId,0,leafHash);
        ILiability.EntryRecord memory e = liability.entry(distributionId,1,0);
        uint64 fixedExpiry = e.terminalExpiresAt;
        vm.expectRevert(ILiability.InvalidLiabilityTransition.selector);
        vault.startTerminal(liability,distributionId,1,windowId,0,leafHash);
        vm.warp(uint256(fixedExpiry) - 1);
        vm.expectRevert(ILiability.InvalidLiabilityTransition.selector);
        vault.expire(liability,distributionId,1,windowId,0,leafHash);
        vm.warp(fixedExpiry);
        vault.expire(liability,distributionId,1,windowId,0,leafHash);
        ILiability.SourcePartitions memory p = liability.sourcePartitions();
        assertEq(p.finalizedUnpaidLiabilities,0);
        assertEq(p.expiredLiabilityRecoveryEligible,100);
        e = liability.entry(distributionId,1,0);
        assertEq(e.terminalStartedAt + 90 days,e.terminalExpiresAt);
    }

    function _accrueAndOpenCandidate() internal {
        vault.accrue(workflow,1,windowId,start,end,100,100);
        vm.warp(uint256(end)+1);
        vault.openCandidate(workflow,_candidate(1,keccak256("root-1")));
    }
    function _candidate(uint32 version,bytes32 root) internal view returns (IWorkflow.DistributionCandidateInput memory i) {
        i = IWorkflow.DistributionCandidateInput(distributionId,windowId,start,end,address(0x1234),version,100,100,1,1,1,
            root,keccak256("dataset"),keccak256(abi.encode(root,version)));
    }
    function _entryInput(uint32 version) internal view returns (ILiability.EntryInput memory i) {
        i = ILiability.EntryInput(distributionId,version,windowId,0,leafHash,address(0xA11CE),address(0x1234),100);
    }
}
