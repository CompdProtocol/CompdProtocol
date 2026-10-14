// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T,IC2G2BHolderDistributor,IC2G2BHolderLiability,IC2G2BRecoveryEvidence} from "../../contracts/production/v2/phase6c2g2br4/C2G2BTypes.sol";
import {CompdVaultKernelV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdVaultKernelV2.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdBuybackModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdBuybackModuleV2.sol";
import {CompdRecoveryModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdRecoveryModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdStrategyExecutorV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdStrategyExecutorV2R4.sol";
import {ReferenceStrategyAdapterR4} from "./ReferenceStrategyAdapterR4.sol";

contract R4BuybackExec {}
contract R4Distributor is IC2G2BHolderDistributor {
    function paymentData(bytes32) external pure returns(T.HolderPayment memory,bool){return(T.HolderPayment(bytes32(0),bytes32(0),0,0,bytes32(0),bytes32(0),bytes32(0),address(0),address(0),0,0,0,0,0,0,bytes32(0)),false);}
    function paymentDigest(bytes32) external pure returns(bytes32){return bytes32(0);}
    function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(bytes32(0),address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(bytes32(uint256(1)),0);}
}
contract R4Liability is IC2G2BHolderLiability {
    function paymentDigest(bytes32) external pure returns(bytes32){return bytes32(0);}
    function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(bytes32(0),address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(bytes32(uint256(1)),0);}
}
contract R4Recovery is IC2G2BRecoveryEvidence {
    function protocolReserveRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function noRecipientRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function expiredHolderRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function consumeProtocolReserve(bytes32) external pure {}
    function consumeNoRecipient(bytes32) external pure {}
    function consumeExpiredHolder(bytes32) external pure {}
    function recoveryReconciliationComplete() external pure returns(bool){return true;}
}
contract R4Empty {}

contract Phase6C2G2BR4Test is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address constant EMERGENCY_AUTHORITY=address(0xE001);
    uint256 constant CAPITAL=100 ether;
    uint256 constant PRINCIPAL=10 ether;
    ReferenceStrategyAdapterR4 adapter;
    CompdVaultKernelV2R4 kernel;
    CompdSettlementModuleV2R4 settlement;
    CompdEmergencyScopeRegistryV2 registry;
    CompdEmergencyModuleV2 emergency;

    function setUp() public {
        adapter=new ReferenceStrategyAdapterR4();
        R4BuybackExec buyExec=new R4BuybackExec();R4Distributor dist=new R4Distributor();R4Liability liability=new R4Liability();R4Recovery recoveryEvidence=new R4Recovery();
        address[] memory approved=new address[](1);approved[0]=address(adapter);
        kernel=new CompdVaultKernelV2R4(EMERGENCY_AUTHORITY,address(0xE002),approved,address(buyExec),address(dist),address(liability),address(recoveryEvidence));
        registry=new CompdEmergencyScopeRegistryV2(address(kernel));emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(dist),address(liability));
        CompdBuybackModuleV2 buyback=new CompdBuybackModuleV2(address(kernel),address(0));
        CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(recoveryEvidence));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));
        address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        vm.prank(ADMIN);kernel.bindModules(modules);
        vm.deal(ADMIN,CAPITAL+1 ether);vm.prank(ADMIN);kernel.seedStrategyCapital{value:CAPITAL}();vm.prank(ADMIN);kernel.activate();
    }

    function _open(uint256 id,uint256 principal) internal {
        vm.prank(AUTOMATION);settlement.startRun(id,address(adapter),principal,keccak256(abi.encode("allocation",id)));
    }
    function _exit(uint256 id) internal {
        vm.prank(AUTOMATION);settlement.requestExit(id,keccak256(abi.encode("exit",id)));
    }
    function _collect(uint256 id,uint256 amount,uint256 attemptNo) internal returns(uint256) {
        bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);adapter.setNextCollection(pos,amount);
        return settlement.collectRun(id,keccak256(abi.encode("attempt",id,attemptNo)));
    }
    function _close(uint256 id) internal {
        bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);adapter.setTerminal(pos,true);
        vm.prank(AUTOMATION);settlement.closeRun(id,keccak256(abi.encode("close",id)));
    }
    function _completeReturn(uint256 totalReturn,uint256 id) internal {
        _open(id,PRINCIPAL);_exit(id);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);vm.deal(address(adapter),totalReturn);adapter.setCash(pos,totalReturn);_close(id);
    }
    function _assertAccounting() internal view {
        assertEq(kernel.strategyCapital()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertLe(kernel.activePrincipal(),kernel.strategyCapital());assertGe(kernel.accountedQuote(),kernel.holderRewardReserve());
    }

    function testPartial2Then3Final5ReturnsPrincipalExactly() public {
        _open(1,PRINCIPAL);_exit(1);uint256 sc=kernel.strategyCapital();uint256 aq=kernel.accountedQuote();
        assertEq(_collect(1,2 ether,1),2 ether);assertEq(kernel.principalCredited(1),2 ether);assertEq(kernel.activePrincipal(),8 ether);assertEq(kernel.accountedQuote(),aq+2 ether);assertEq(kernel.strategyCapital(),sc);_assertAccounting();
        assertEq(_collect(1,3 ether,2),3 ether);assertEq(kernel.principalCredited(1),5 ether);assertEq(kernel.activePrincipal(),5 ether);assertEq(kernel.accountedQuote(),aq+5 ether);assertEq(kernel.strategyCapital(),sc);_assertAccounting();
        _close(1);assertEq(kernel.runTotalPhysicalReturn(1),PRINCIPAL);assertEq(kernel.runActualLoss(1),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.activePrincipal(),0);assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.CLOSED));_assertAccounting();
    }
    function testPartial2FinalTerminal9Total11Profit1() public {
        _open(1,PRINCIPAL);_exit(1);_collect(1,2 ether,1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);vm.deal(address(adapter),9 ether);adapter.setCash(pos,9 ether);_close(1);
        assertEq(kernel.runTotalPhysicalReturn(1),11 ether);assertEq(kernel.cumulativeRealizedProfit(),1 ether);assertEq(kernel.strategyCapital(),100.65 ether);assertEq(kernel.buybackReserve(),0.15 ether);assertEq(kernel.holderRewardReserve(),0.1 ether);assertEq(kernel.protocolReserve(),0.1 ether);_assertAccounting();
    }
    function testPartial2FinalTerminal7Total9Loss1() public {
        _open(1,PRINCIPAL);_exit(1);_collect(1,2 ether,1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);vm.deal(address(adapter),7 ether);adapter.setCash(pos,7 ether);_close(1);
        assertEq(kernel.runTotalPhysicalReturn(1),9 ether);assertEq(kernel.runActualLoss(1),1 ether);assertEq(kernel.strategyCapital(),99 ether);assertEq(kernel.cumulativeRealizedProfit(),0);_assertAccounting();
    }
    function testLossBelowThreePercent() public {_completeReturn(9.8 ether,1);assertEq(kernel.runActualLoss(1),0.2 ether);assertFalse(kernel.runLossBoundBreached(1));assertFalse(kernel.strategyAllocationHalted());}
    function testLossExactlyThreePercent() public {_completeReturn(9.7 ether,1);assertEq(kernel.runMaxDesignedLoss(1),0.3 ether);assertEq(kernel.runActualLoss(1),0.3 ether);assertFalse(kernel.runLossBoundBreached(1));}
    function testLossOneWeiAboveThreePercentLatchesForever() public {_completeReturn(9.7 ether-1,1);assertEq(kernel.runActualLoss(1),0.3 ether+1);assertTrue(kernel.runLossBoundBreached(1));assertTrue(kernel.strategyAllocationHalted());}
    function testDeterministicReferenceTerminalZeroReturnRecordsTotalLoss() public {_completeReturn(0,1);assertEq(kernel.runTotalPhysicalReturn(1),0);assertEq(kernel.runActualLoss(1),10 ether);assertEq(kernel.strategyCapital(),90 ether);assertTrue(kernel.strategyAllocationHalted());}
    function testPartialThenTotalResidualLossReconcilesOnlyAtClose() public {
        _open(1,PRINCIPAL);_exit(1);_collect(1,2 ether,1);uint256 sc=kernel.strategyCapital();assertEq(kernel.runActualLoss(1),0);assertEq(sc,CAPITAL);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);vm.deal(address(adapter),0);adapter.setCash(pos,0);_close(1);
        assertEq(kernel.runTotalPhysicalReturn(1),2 ether);assertEq(kernel.runActualLoss(1),8 ether);assertEq(kernel.strategyCapital(),92 ether);_assertAccounting();
    }
    function testZeroAndOneWeiPartialBoundaries() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setNextCollection(pos,0);
        uint256 aq=kernel.accountedQuote();vm.prank(address(0xBEEF));assertEq(settlement.collectRun(1,keccak256("empty")),0);assertEq(kernel.activePrincipal(),PRINCIPAL);assertEq(kernel.accountedQuote(),aq);
        vm.deal(address(adapter),PRINCIPAL);adapter.setNextCollection(pos,1);assertEq(_collect(1,1,2),1);assertEq(kernel.activePrincipal(),PRINCIPAL-1);assertEq(kernel.principalCredited(1),1);_assertAccounting();
    }
    function testMultiplePartialCollectionsCannotBecomeProfit() public {
        _open(1,PRINCIPAL);_exit(1);uint256 sc=kernel.strategyCapital();_collect(1,1 ether,1);_collect(1,1 ether,2);_collect(1,1 ether,3);
        assertEq(kernel.strategyCapital(),sc);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.activePrincipal(),7 ether);_assertAccounting();
    }
    function testNonterminalExcessStaysExternalUntilFinalClose() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);vm.deal(address(adapter),PRINCIPAL+1);adapter.setCash(pos,PRINCIPAL+1);adapter.setNextCollection(pos,PRINCIPAL+1);
        assertEq(settlement.collectRun(1,keccak256("capped")),PRINCIPAL);assertEq(kernel.principalCredited(1),PRINCIPAL);assertEq(kernel.activePrincipal(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(address(adapter).balance,1);assertFalse(settlement.terminationReady());_assertAccounting();
        _close(1);assertEq(kernel.cumulativeRealizedProfit(),1);_assertAccounting();
    }
    function testAdapterReportedAmountCannotOverridePhysicalPartialDelta() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setNextCollection(pos,2 ether);adapter.setReport(pos,99 ether,true);
        assertEq(settlement.collectRun(1,keccak256("metadata")),2 ether);assertEq(kernel.principalCredited(1),2 ether);assertEq(kernel.runTotalPhysicalReturn(1),2 ether);_assertAccounting();
    }
    function testAdapterExitRevertBecomesBlockedAndSameExitCanRetry() public {
        _open(1,PRINCIPAL);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setExitFailure(pos,true);bytes32 exitId=keccak256("exit");vm.prank(AUTOMATION);settlement.requestExit(1,exitId);assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.BLOCKED));assertEq(kernel.activePrincipal(),PRINCIPAL);
        adapter.setExitFailure(pos,false);vm.prank(AUTOMATION);settlement.requestExit(1,exitId);assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.RETURN_PENDING));assertEq(kernel.activePrincipal(),PRINCIPAL);
    }
    function testAdapterCollectRevertIsBlockedNoZeroSettlement() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setCollectFailure(pos,true);
        assertEq(settlement.collectRun(1,keccak256("fail")),0);assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.BLOCKED));assertEq(kernel.principalCredited(1),0);assertEq(kernel.activePrincipal(),PRINCIPAL);assertEq(kernel.runActualLoss(1),0);_assertAccounting();
    }
    function testAdapterCloseRefusalKeepsAPAndCanRetry() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setCloseFailure(pos,true);
        vm.expectRevert();vm.prank(AUTOMATION);settlement.closeRun(1,keccak256("close"));assertEq(kernel.activePrincipal(),PRINCIPAL);assertEq(kernel.runPrincipal(1),PRINCIPAL);assertEq(kernel.runActualLoss(1),0);
        adapter.setCloseFailure(pos,false);adapter.setTerminal(pos,true);vm.prank(AUTOMATION);settlement.closeRun(1,keccak256("close"));assertEq(kernel.activePrincipal(),0);_assertAccounting();
    }
    function testRepeatedExitSameIdDoesNotCreateDuplicateClaimAndConflictRejects() public {
        _open(1,PRINCIPAL);bytes32 exitId=keccak256("exit");vm.prank(AUTOMATION);settlement.requestExit(1,exitId);vm.prank(AUTOMATION);settlement.requestExit(1,exitId);
        bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);(,,,,,,,,,,uint256 count,)=adapter.position(pos);assertEq(count,1);
        vm.expectRevert();vm.prank(AUTOMATION);settlement.requestExit(1,keccak256("conflict"));assertEq(kernel.activePrincipal(),PRINCIPAL);
    }
    function testDuplicateRunAndAllocationAreRejected() public {
        _open(1,PRINCIPAL);vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(1,address(adapter),PRINCIPAL,keccak256("other"));
        vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(2,address(adapter),PRINCIPAL,keccak256(abi.encode("allocation",1)));assertEq(kernel.activePrincipal(),PRINCIPAL);
    }
    function testDuplicateCollectionAndTerminalCloseAreRejected() public {
        _open(1,PRINCIPAL);_exit(1);_collect(1,1 ether,1);bytes32 attempt=keccak256(abi.encode("attempt",1,uint256(1)));vm.expectRevert();settlement.collectRun(1,attempt);
        _close(1);vm.expectRevert();vm.prank(AUTOMATION);settlement.closeRun(1,keccak256(abi.encode("close",uint256(1))));
    }
    function testExecutorCodehashSubstitutionFailsClosed() public {
        _open(1,PRINCIPAL);_exit(1);R4Empty empty=new R4Empty();vm.etch(kernel.strategyExecutor(),address(empty).code);
        vm.expectRevert();settlement.collectRun(1,keccak256("executor-substitution"));assertEq(kernel.activePrincipal(),PRINCIPAL);_assertAccounting();
    }
    function testGenericTargetCalldataAndArbitraryRecipientSelectorsAreAbsent() public {
        (bool executorOk,)=kernel.strategyExecutor().call(abi.encodeWithSignature("execute(address,bytes)",address(0xBEEF),hex"deadbeef"));
        (bool rescueOk,)=address(kernel).call(abi.encodeWithSignature("rescue(address,address,uint256)",address(adapter),address(0xBEEF),1));
        assertFalse(executorOk);assertFalse(rescueOk);assertEq(kernel.accountedQuote(),CAPITAL);assertEq(kernel.activePrincipal(),0);_assertAccounting();
    }
    function testEmergencyDuringBlockedRunPreservesAPAndBlocksExposure() public {
        _open(1,PRINCIPAL);_exit(1);vm.prank(GUARDIAN);settlement.recordBlocked(1,keccak256("blocked-before-emergency"));
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();assertEq(kernel.activePrincipal(),PRINCIPAL);assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.BLOCKED));
        vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(2,address(adapter),PRINCIPAL,keccak256("emergency-new-run"));_assertAccounting();
    }
    function testDuplicateAttemptIsRejectedByBothReplayLayers() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 attempt=keccak256("single-attempt");bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setNextCollection(pos,1 ether);
        settlement.collectRun(1,attempt);assertTrue(settlement.collectionAttemptUsed(1,attempt));assertTrue(CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).attemptUsed(1,attempt));
        vm.expectRevert();settlement.collectRun(1,attempt);assertEq(kernel.principalCredited(1),1 ether);_assertAccounting();
    }
    function testDistinctCollectionAttemptsCannotReuseRecoveryIdentity() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);bytes32 recoveryId=keccak256("same-recovery");
        adapter.setRecoveryId(pos,recoveryId,true);adapter.setNextCollection(pos,1 ether);settlement.collectRun(1,keccak256("attempt-a"));
        adapter.setNextCollection(pos,1 ether);assertEq(settlement.collectRun(1,keccak256("attempt-b")),0);
        assertEq(uint8(settlement.run(1).state),uint8(T.StrategyRunState.BLOCKED));assertEq(kernel.principalCredited(1),1 ether);assertEq(kernel.activePrincipal(),9 ether);_assertAccounting();
    }
    function testSettlementReentrancyAttemptIsRejectedWithoutLosingOuterCollection() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);bytes32 attempt=keccak256("outer-attempt");
        adapter.setNextCollection(pos,1 ether);adapter.configureReentry(address(settlement),abi.encodeCall(settlement.collectRun,(1,keccak256("inner-attempt"))));
        assertEq(settlement.collectRun(1,attempt),1 ether);assertTrue(adapter.reentryAttempted());assertFalse(adapter.reentrySucceeded());assertEq(kernel.principalCredited(1),1 ether);_assertAccounting();
    }
    function testBlockedCollectionCanRetryWithoutErasingAP() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setCollectFailure(pos,true);
        assertEq(settlement.collectRun(1,keccak256("first-fail")),0);assertEq(kernel.activePrincipal(),PRINCIPAL);assertEq(kernel.runActualLoss(1),0);
        adapter.setCollectFailure(pos,false);adapter.setNextCollection(pos,1 ether);assertEq(settlement.collectRun(1,keccak256("retry")),1 ether);assertEq(kernel.activePrincipal(),9 ether);assertEq(kernel.principalCredited(1),1 ether);_assertAccounting();
    }
    function testPhysicalTerminalZeroReturnCannotBeOverriddenByAdapterMetadata() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setCash(pos,0);adapter.setTerminal(pos,true);
        vm.prank(AUTOMATION);settlement.closeRun(1,keccak256("zero-physical"));assertEq(kernel.runTotalPhysicalReturn(1),0);assertEq(kernel.runActualLoss(1),PRINCIPAL);assertEq(kernel.activePrincipal(),0);_assertAccounting();
    }
    function testWrongClosedPositionAndFakeTerminalStatusCannotClose() public {
        _open(1,PRINCIPAL);_exit(1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);adapter.setObservedStatus(pos,T.AdapterPositionStatus.CLOSED);
        vm.expectRevert();vm.prank(AUTOMATION);settlement.closeRun(1,keccak256("fake-close"));assertEq(kernel.activePrincipal(),PRINCIPAL);
        adapter.forcePositionMismatch(pos,true);adapter.setTerminal(pos,true);vm.expectRevert();vm.prank(AUTOMATION);settlement.closeRun(1,keccak256("wrong-position"));assertEq(kernel.activePrincipal(),PRINCIPAL);_assertAccounting();
    }
    function testShutdownDoesNotClearBlockedUnresolvedAP() public {
        _open(1,PRINCIPAL);_exit(1);vm.prank(GUARDIAN);settlement.recordBlocked(1,keccak256("blocked"));vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.expectRevert();vm.prank(GUARDIAN);kernel.terminate();
        assertEq(kernel.activePrincipal(),PRINCIPAL);assertFalse(settlement.terminationReady());_assertAccounting();
    }
    function testEmergencyAllowsTypedCollectionAndLeavesTerminationGate() public {
        _open(1,PRINCIPAL);_exit(1);vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();assertEq(_collect(1,2 ether,1),2 ether);assertEq(kernel.activePrincipal(),8 ether);assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.EMERGENCY_RECOVERY));_assertAccounting();
    }
    function testNewAllocationBlockedAfterLossButOpenRunCanStillReconcile() public {
        _open(1,PRINCIPAL);_open(2,PRINCIPAL);_exit(1);_completeExistingLoss(1,9.6 ether);assertTrue(kernel.strategyAllocationHalted());vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(3,address(adapter),PRINCIPAL,keccak256("new"));
        _exit(2);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(2);vm.deal(address(adapter),19.4 ether);adapter.setCash(pos,9.8 ether);adapter.setTerminal(pos,true);vm.prank(AUTOMATION);settlement.closeRun(2,keccak256("close2"));assertEq(kernel.runActualLoss(2),0.2 ether);_assertAccounting();
    }
    function _completeExistingLoss(uint256 id,uint256 totalReturn) internal {bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);vm.deal(address(adapter),totalReturn+PRINCIPAL);adapter.setCash(pos,totalReturn);adapter.setTerminal(pos,true);vm.prank(AUTOMATION);settlement.closeRun(id,keccak256(abi.encode("close",id)));}
    function testAdapterCodehashSubstitutionFailsClosed() public {
        _open(1,PRINCIPAL);_exit(1);R4Empty empty=new R4Empty();vm.etch(address(adapter),address(empty).code);vm.expectRevert();settlement.collectRun(1,keccak256("substitution"));assertEq(kernel.activePrincipal(),PRINCIPAL);
    }
    function testUnsolicitedPreexistingExecutorBNBIsNotCreditedAsRecovery() public {
        _open(1,PRINCIPAL);_exit(1);CompdStrategyExecutorV2R4 exec=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor()));vm.deal(address(exec),1 ether);bytes32 pos=exec.positionId(1);adapter.setNextCollection(pos,1 ether);
        assertEq(settlement.collectRun(1,keccak256("normal")),1 ether);assertEq(kernel.principalCredited(1),1 ether);assertEq(address(exec).balance,1 ether);_assertAccounting();
    }
    function testFuzzPartialSequenceNeverCreatesProfit(uint96 a,uint96 b) public {
        uint256 first=bound(uint256(a),0,PRINCIPAL);uint256 second=bound(uint256(b),0,PRINCIPAL-first);_open(1,PRINCIPAL);_exit(1);uint256 sc=kernel.strategyCapital();
        if(first!=0)_collect(1,first,1);if(second!=0)_collect(1,second,2);assertEq(kernel.strategyCapital(),sc);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.principalCredited(1),first+second);assertEq(kernel.activePrincipal(),PRINCIPAL-first-second);_assertAccounting();
    }
    function testFuzzTerminalReturnConservesBuckets(uint96 raw) public {
        uint256 total=bound(uint256(raw),0,20 ether);_completeReturn(total,1);uint256 profit=total>PRINCIPAL?total-PRINCIPAL:0;uint256 loss=total<PRINCIPAL?PRINCIPAL-total:0;
        assertEq(kernel.cumulativeRealizedProfit(),profit);assertEq(kernel.runActualLoss(1),loss);assertEq(kernel.activePrincipal(),0);_assertAccounting();
    }
    function testRiskBudgetAndLossRemainderUseR2RulesAfterPartialRecovery() public {
        _open(1,PRINCIPAL);assertEq(kernel.runMaxDesignedLoss(1),0.3 ether);_exit(1);_collect(1,4 ether,1);bytes32 pos=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(1);vm.deal(address(adapter),5.7 ether);adapter.setCash(pos,5.7 ether);_close(1);
        assertEq(kernel.runTotalPhysicalReturn(1),9.7 ether);assertEq(kernel.runActualLoss(1),0.3 ether);assertFalse(kernel.runLossBoundBreached(1));assertEq(kernel.strategyCapital(),99.7 ether);_assertAccounting();
    }
    function testTerminationNeedsRunClosedEvenIfPartialPrincipalFullyCredited() public {
        _open(1,PRINCIPAL);_exit(1);_collect(1,PRINCIPAL,1);assertEq(kernel.activePrincipal(),0);assertFalse(settlement.terminationReady());vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.expectRevert();vm.prank(GUARDIAN);kernel.terminate();
    }
}
