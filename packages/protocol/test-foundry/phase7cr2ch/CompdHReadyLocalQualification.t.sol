// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdPhase7CR2CHCurrentV3Test} from "./CompdPhase7CR2CHCurrentV3.t.sol";
import {T,Kernel,StrategyExecutor,LifecycleAdapter} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {CompdPhase7CR2CH7PartitionRecoveryTest} from "./CompdPhase7CR2CH7PartitionRecovery.t.sol";

contract HReadyRejectNative {receive() external payable {revert("LOCAL_REJECT");}}
contract HReadyLargeReturnNative {receive() external payable {assembly {return(0,0x10000)}}}
contract HReadyRecoveryCallbackNative {
    address immutable recovery;bytes4 immutable selector;bytes32 immutable id;bool public rejected;
    constructor(address r,bytes4 s,bytes32 i){recovery=r;selector=s;id=i;}
    receive() external payable {(bool ok,)=recovery.call(abi.encodeWithSelector(selector,id));require(!ok,"callback must be rejected");rejected=true;}
}

contract CompdHReadySealFailureQualificationTest is CompdPhase7CR2CH7PartitionRecoveryTest {
    function _callFailure(bytes32 id) internal returns(bool ok) {vm.prank(GUARDIAN);(ok,)=address(recovery).call(abi.encodeWithSignature("recoverActivationSealFailure(bytes32)",id));}
    function testQualificationSealFailureRecoveryHostileReceiverAndRollbackMatrix() public {
        _settle();vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 id=_id(2);bytes32 key=keccak256(abi.encode(uint8(2),id));uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;
        vm.prank(GUARDIAN);(bool direct,)=address(kernel).call(abi.encodeWithSignature("executeRecovery(uint8,bytes32)",uint8(5),id));assertFalse(direct);
        vm.prank(GUARDIAN);(bool wrong,)=address(recovery).call(abi.encodeWithSignature("recoverShutdownTail(bytes32)",id));assertFalse(wrong);
        vm.deal(address(kernel),aq-1);assertFalse(_callFailure(id));assertFalse(recovery.processed(key));assertEq(kernel.accountedQuote(),aq);vm.deal(address(kernel),physical);
        uint256 snapshot=vm.snapshotState();HReadyRejectNative rejector=new HReadyRejectNative();vm.etch(kernel.RECOVERY_TREASURY(),address(rejector).code);
        assertFalse(_callFailure(id));assertFalse(recovery.processed(key));assertEq(kernel.accountedQuote(),aq);assertEq(address(kernel).balance,physical);assertEq(kernel.activationSealFailureHR(),0.01 ether);assertTrue(vm.revertToState(snapshot));
        snapshot=vm.snapshotState();HReadyRecoveryCallbackNative callback=new HReadyRecoveryCallbackNative(address(recovery),bytes4(keccak256("recoverActivationSealFailure(bytes32)")),id);vm.etch(kernel.RECOVERY_TREASURY(),address(callback).code);
        assertTrue(_callFailure(id));assertTrue(HReadyRecoveryCallbackNative(payable(kernel.RECOVERY_TREASURY())).rejected());assertEq(kernel.accountedQuote(),aq-0.01 ether);_partitions();assertTrue(vm.revertToState(snapshot));
        snapshot=vm.snapshotState();HReadyLargeReturnNative bomb=new HReadyLargeReturnNative();vm.etch(kernel.RECOVERY_TREASURY(),address(bomb).code);assertTrue(_callFailure(id));assertEq(kernel.accountedQuote(),aq-0.01 ether);_partitions();assertTrue(vm.revertToState(snapshot));
        uint256 before_=kernel.RECOVERY_TREASURY().balance;vm.deal(address(kernel),physical+2 ether);assertTrue(_callFailure(id));assertEq(kernel.RECOVERY_TREASURY().balance-before_,0.01 ether);assertEq(kernel.activationSealFailureHR(),0);assertEq(address(kernel).balance-kernel.accountedQuote(),2 ether);assertFalse(_callFailure(id));_partitions();
    }
}

/// @dev Local qualification only. No production or test size limit is changed.
abstract contract CompdHReadyQualificationBase is CompdPhase7CR2CHCurrentV3Test {
    function _route(uint8 category,bytes32 id,address caller) internal returns(bool ok) {
        bytes4[7] memory selectors=[bytes4(keccak256("recoverProtocol(bytes32)")),bytes4(keccak256("recoverNoRecipient(bytes32)")),bytes4(keccak256("recoverExpiredLiability(bytes32)")),bytes4(keccak256("recoverTreasuryPrincipal(bytes32)")),bytes4(keccak256("recoverPartialActivation(bytes32)")),bytes4(keccak256("recoverActivationSealFailure(bytes32)")),bytes4(keccak256("recoverShutdownTail(bytes32)"))];
        vm.prank(caller);(ok,)=address(recovery).call(abi.encodeWithSelector(selectors[category],id));
    }
    function _key(uint8 category,bytes32 id) internal pure returns(bytes32) {return keccak256(abi.encode(category<=3?category:category-3,id));}
    function _terminatedProfit() internal {_settle(1.1 ether);_empty();_shutdownAndTerminate();}
    function _emergencyScope() internal returns(bytes32 scope) {
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();scope=keccak256("LOCAL_QUALIFICATION_NATIVE_SCOPE");
        bytes32[] memory ids=new bytes32[](1);ids[0]=scope;uint8[] memory kinds=new uint8[](1);
        vm.prank(EMERGENCY_AUTHORITY);emergency.initialize(ids,kinds);
    }
    function _openQualification(uint256 id,uint256 amount) internal {
        // Frozen Automation identity avoids a getter call consuming expectRevert in negative cases.
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);settlement.startRun(id,address(adapter),amount,keccak256(abi.encode("LOCAL_QUALIFICATION_ALLOC",id)));
    }
    function _boundedQualificationLoss(uint256 id) internal {
        uint256 amount=kernel.strategyCapital()/10;uint256 loss=amount*300/10000;_openQualification(id,amount);
        vm.prank(GUARDIAN);settlement.requestExit(id,keccak256(abi.encode("bounded exit",id)));vm.deal(address(adapter),amount-loss);
        vm.prank(GUARDIAN);settlement.closeRun(id,keccak256(abi.encode("bounded close",id)));assertFalse(kernel.runLossBoundBreached(id));_assertAccounting();
    }
    function _prepareQualificationRecovery(uint8 category) internal returns(bytes32 id,uint256 amount) {
        _settle(1.1 ether);
        if(category==2){HReadyRejectNative recipient=new HReadyRejectNative();bytes32 leaf=_nonempty(address(recipient));
            vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertFalse(holder.pay(leaf));
            vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);
            (,,uint64 expires,)=state.terminalStatus(leaf);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();vm.warp(expires);
            return(state.expiredHolderRecoveryId(leaf),0.01 ether);
        }
        if(category==6){_shutdownAndTerminate();id=keccak256(abi.encode(keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),block.chainid,address(kernel),uint8(3),kernel.shutdownAt(),uint256(0.01 ether)));return(id,0.01 ether);}
        (bytes32 window,)=_empty();_shutdownAndTerminate();
        if(category==1)return(state.emptyRecoveryId(window),0.01 ether);
        return(state.bucketRecoveryId(category),category==0?kernel.protocolReserve():kernel.nonStrategyTreasuryPrincipal());
    }
}

contract CompdHReadyRecoveryQualificationTest is CompdHReadyQualificationBase {
    function testQualificationAllSevenRecoveryRoutesRejectUnauthorizedZeroAndActiveWithRollback() public {
        for(uint8 category;category<7;++category){bytes32 id=keccak256(abi.encode("LOCAL_BAD_ID",category));
            assertFalse(_route(category,id,address(0xBAD)));assertFalse(_route(category,0,GUARDIAN));assertFalse(_route(category,id,GUARDIAN));
            assertFalse(recovery.processed(_key(category,id)));_assertAccounting();
        }
    }
    function testQualificationAllSevenRecoveryRoutesRejectWrongEvidenceAfterTermination() public {
        _shutdownAndTerminate();uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;
        for(uint8 category;category<7;++category){bytes32 id=keccak256(abi.encode("LOCAL_WRONG_TERMINAL_ID",category));assertFalse(_route(category,id,GUARDIAN));assertFalse(recovery.processed(_key(category,id)));}
        assertEq(kernel.accountedQuote(),aq);assertEq(address(kernel).balance,physical);_assertAccounting();
    }
    function testQualificationProtocolAndTreasuryRecoveryConserveBucketsAndForcedSurplus() public {
        _terminatedProfit();uint256 surplus=3 ether;vm.deal(address(kernel),address(kernel).balance+surplus);
        uint256 before_=kernel.RECOVERY_TREASURY().balance;uint256 aq=kernel.accountedQuote();uint256 pr=kernel.protocolReserve();uint256 ntp=kernel.nonStrategyTreasuryPrincipal();
        bytes32 protocolId=state.bucketRecoveryId(0);bytes32 treasuryId=state.bucketRecoveryId(3);
        assertFalse(_route(3,protocolId,GUARDIAN));assertFalse(_route(0,treasuryId,GUARDIAN));
        assertTrue(_route(0,protocolId,GUARDIAN));assertTrue(_route(3,treasuryId,GUARDIAN));
        assertEq(kernel.RECOVERY_TREASURY().balance-before_,pr+ntp);assertEq(kernel.accountedQuote(),aq-pr-ntp);assertEq(kernel.protocolReserve(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),0);
        assertEq(address(kernel).balance-kernel.accountedQuote(),surplus);assertFalse(_route(0,protocolId,GUARDIAN));assertFalse(_route(3,treasuryId,GUARDIAN));_assertAccounting();
    }
    function testQualificationRejectedTreasuryRollsBackRecoveryConsumptionAndAccounting() public {
        _terminatedProfit();bytes32 id=state.bucketRecoveryId(0);uint256 aq=kernel.accountedQuote();uint256 pr=kernel.protocolReserve();uint256 physical=address(kernel).balance;
        HReadyRejectNative rejector=new HReadyRejectNative();vm.etch(kernel.RECOVERY_TREASURY(),address(rejector).code);
        assertFalse(_route(0,id,GUARDIAN));assertFalse(recovery.processed(_key(0,id)));assertEq(state.bucketRecoveryId(0),id);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.protocolReserve(),pr);assertEq(address(kernel).balance,physical);
        vm.etch(kernel.RECOVERY_TREASURY(),hex"");assertTrue(_route(0,id,GUARDIAN));_assertAccounting();
    }
    function testQualificationPhysicalInsolvencyRejectsRecoveryAndRollsBack() public {
        _terminatedProfit();bytes32 id=state.bucketRecoveryId(0);uint256 aq=kernel.accountedQuote();uint256 pr=kernel.protocolReserve();vm.deal(address(kernel),aq-1);
        assertFalse(_route(0,id,GUARDIAN));assertFalse(recovery.processed(_key(0,id)));assertEq(kernel.accountedQuote(),aq);assertEq(kernel.protocolReserve(),pr);
        vm.deal(address(kernel),aq);assertTrue(_route(0,id,GUARDIAN));_assertAccounting();
    }
    function testQualificationFiveReachableRecoveryCategoriesHostileReceiverAndRollbackMatrix() public {
        uint8[5] memory categories=[uint8(0),1,2,3,6];
        for(uint256 i;i<categories.length;++i){uint256 baseline=vm.snapshotState();uint8 category=categories[i];(bytes32 id,uint256 amount)=_prepareQualificationRecovery(category);
            assertGt(amount,0);uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;
            assertFalse(_route(category,id,address(0xBAD)));assertFalse(_route(category,0,GUARDIAN));assertFalse(_route(category,bytes32(uint256(id)^1),GUARDIAN));assertFalse(_route(uint8((category+1)%7),id,GUARDIAN));
            vm.prank(GUARDIAN);(bool direct,)=address(kernel).call(abi.encodeWithSignature("executeRecovery(uint8,bytes32)",category,id));assertFalse(direct);
            vm.deal(address(kernel),aq-1);assertFalse(_route(category,id,GUARDIAN));assertFalse(recovery.processed(_key(category,id)));assertEq(kernel.accountedQuote(),aq);vm.deal(address(kernel),physical);
            uint256 hostileSnapshot=vm.snapshotState();HReadyRejectNative rejector=new HReadyRejectNative();vm.etch(kernel.RECOVERY_TREASURY(),address(rejector).code);
            assertFalse(_route(category,id,GUARDIAN));assertFalse(recovery.processed(_key(category,id)));assertEq(kernel.accountedQuote(),aq);assertEq(address(kernel).balance,physical);assertTrue(vm.revertToState(hostileSnapshot));
            bytes4 selector=category==0?bytes4(keccak256("recoverProtocol(bytes32)")):category==1?bytes4(keccak256("recoverNoRecipient(bytes32)")):category==2?bytes4(keccak256("recoverExpiredLiability(bytes32)")):category==3?bytes4(keccak256("recoverTreasuryPrincipal(bytes32)")):bytes4(keccak256("recoverShutdownTail(bytes32)"));
            uint256 callbackSnapshot=vm.snapshotState();HReadyRecoveryCallbackNative callback=new HReadyRecoveryCallbackNative(address(recovery),selector,id);vm.etch(kernel.RECOVERY_TREASURY(),address(callback).code);
            assertTrue(_route(category,id,GUARDIAN));assertTrue(HReadyRecoveryCallbackNative(payable(kernel.RECOVERY_TREASURY())).rejected());assertEq(kernel.accountedQuote(),aq-amount);_assertAccounting();assertTrue(vm.revertToState(callbackSnapshot));
            uint256 bombSnapshot=vm.snapshotState();HReadyLargeReturnNative bomb=new HReadyLargeReturnNative();vm.etch(kernel.RECOVERY_TREASURY(),address(bomb).code);assertTrue(_route(category,id,GUARDIAN));assertEq(kernel.accountedQuote(),aq-amount);_assertAccounting();assertTrue(vm.revertToState(bombSnapshot));
            uint256 before_=kernel.RECOVERY_TREASURY().balance;vm.deal(address(kernel),physical+2 ether);assertTrue(_route(category,id,GUARDIAN));assertEq(kernel.RECOVERY_TREASURY().balance-before_,amount);assertEq(kernel.accountedQuote(),aq-amount);assertEq(address(kernel).balance-kernel.accountedQuote(),2 ether);assertFalse(_route(category,id,GUARDIAN));_assertAccounting();
            assertTrue(vm.revertToState(baseline));
        }
    }
}

contract CompdHReadyEmergencyQualificationTest is CompdHReadyQualificationBase {
    function testQualificationEmergencyRecipientRevertRollsBackAttemptAndOutflow() public {
        bytes32 scope=_emergencyScope();bytes32 attempt=keccak256("LOCAL_EMERGENCY_RETRY");uint256 before_=address(kernel).balance;
        HReadyRejectNative rejector=new HReadyRejectNative();vm.etch(kernel.emergencyWallet(),address(rejector).code);
        vm.expectRevert(Kernel.TransferFailed.selector);vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,attempt,1,1 ether,keccak256("proof"));
        assertEq(address(kernel).balance,before_);assertEq(kernel.emergencyBNBOutflow(),0);
        vm.etch(kernel.emergencyWallet(),hex"");vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,attempt,1,1 ether,keccak256("proof"));
        assertEq(address(kernel).balance,before_-1 ether);assertEq(kernel.emergencyBNBOutflow(),1 ether);
        assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.COMPLETE_WITHIN_REGISTERED_SCOPE));
        vm.expectRevert();vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,attempt,1,1 ether,keccak256("proof"));
    }
    function testQualificationEmergencyInvalidScopeAmountAuthorityAndNoExit() public {
        bytes32 scope=_emergencyScope();uint256 before_=address(kernel).balance;
        vm.expectRevert();emergency.recoverBNB(scope,keccak256("attempt"),1,1 ether,keccak256("proof"));
        vm.expectRevert();vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(keccak256("unknown"),keccak256("attempt"),1,1 ether,keccak256("proof"));
        vm.expectRevert();vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,keccak256("attempt"),1,before_+1,keccak256("proof"));
        vm.expectRevert();vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,keccak256("attempt"),1,0,keccak256("proof"));
        vm.expectRevert();vm.prank(GUARDIAN);kernel.resume();vm.expectRevert();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);
        assertEq(address(kernel).balance,before_);assertEq(uint256(kernel.lifecycle()),uint256(T.Lifecycle.EMERGENCY_RECOVERY));
    }
    function testQualificationEmergencyLedgerRemainsHistoricalAndOrdinaryRecoveryBlocked() public {
        _settle(1.1 ether);_emergencyScope();uint256 aq=kernel.accountedQuote();uint256 hr=kernel.holderRewardReserve();
        for(uint8 category;category<7;++category)assertFalse(_route(category,keccak256(abi.encode(category)),GUARDIAN));
        assertEq(kernel.accountedQuote(),aq);assertEq(kernel.holderRewardReserve(),hr);_assertAccounting();
        vm.expectRevert();vm.prank(ADMIN);kernel.activateBuyback(keccak256("disabled"));
    }
    function testQualificationEmergencyWorkflowStatusAndLateDiscoveryAreScopeOnly() public {
        bytes32 scope=_emergencyScope();bytes32 attempt=keccak256("workflow attempt");bytes32 evidence=keccak256("workflow evidence");
        assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.IN_PROGRESS));
        vm.prank(EMERGENCY_AUTHORITY);emergency.beginWorkflowAttempt(scope,attempt,1);
        vm.prank(EMERGENCY_AUTHORITY);emergency.finishWorkflowAttempt(scope,attempt,1,T.AttemptStatus.BLOCKED,evidence);
        assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.COMPLETE_WITH_UNRESOLVED));
        vm.prank(EMERGENCY_AUTHORITY);emergency.resolve(scope,evidence);assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.COMPLETE_WITHIN_REGISTERED_SCOPE));
        bytes32 late=keccak256("late scope");vm.prank(EMERGENCY_AUTHORITY);emergency.discover(late,uint8(T.ScopeKind.MODULE),evidence);
        assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.IN_PROGRESS));
        vm.expectRevert();vm.prank(EMERGENCY_AUTHORITY);emergency.discover(late,uint8(T.ScopeKind.MODULE),evidence);
        assertEq(kernel.emergencyBNBOutflow(),0);assertEq(uint256(kernel.lifecycle()),uint256(T.Lifecycle.EMERGENCY_RECOVERY));
    }
    function testQualificationEmergencySettlementLocksNewProfitHRAndBlocksNewAllocation() public {
        _openQualification(1,1 ether);vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();
        vm.prank(GUARDIAN);settlement.requestExit(1,keccak256("emergency exit"));vm.deal(address(adapter),1.1 ether);
        vm.prank(GUARDIAN);settlement.closeRun(1,keccak256("emergency close"));
        assertEq(kernel.emergencyLockedHR(),0.01 ether);assertEq(kernel.eligibleWindowHR(),0);assertEq(kernel.holderRewardReserve(),0.01 ether);
        assertEq(kernel.cumulativeRealizedProfit(),0.1 ether);assertTrue(settlement.terminationReady());_assertAccounting();
        vm.expectRevert();_openQualification(2,0.1 ether);
    }
}

contract CompdHReadyStrategyQualificationTest is CompdHReadyQualificationBase {
    function testQualificationStrategyPositionCapAndThreeRunAggregateBoundary() public {
        vm.expectRevert();_openQualification(1,1 ether+1);assertEq(settlement.historyLength(),0);
        for(uint256 id=1;id<=3;++id)_openQualification(id,1 ether);
        assertEq(kernel.activeRunCount(),3);assertEq(kernel.activePrincipal(),3 ether);
        vm.expectRevert();_openQualification(4,1 wei);assertEq(settlement.historyLength(),3);assertFalse(settlement.terminationReady());_assertAccounting();
    }
    function testQualificationStrategyDesignedLossExactBoundaryAndPrincipalSeparation() public {
        _settle(0.97 ether);assertEq(kernel.runMaxDesignedLoss(1),0.03 ether);assertEq(kernel.runActualLoss(1),0.03 ether);
        assertFalse(kernel.runLossBoundBreached(1));assertFalse(kernel.strategyAllocationHalted());assertFalse(settlement.riskLatched());
        assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertTrue(settlement.terminationReady());
    }
    function testQualificationStrategyLossBreachLatchesAndBlocksFurtherAdmission() public {
        _settle(0.97 ether-1);assertTrue(kernel.runLossBoundBreached(1));assertTrue(kernel.strategyAllocationHalted());assertTrue(settlement.riskLatched());
        vm.expectRevert();_openQualification(2,0.5 ether);assertEq(settlement.historyLength(),1);_assertAccounting();
    }
    function testQualificationStrategyLargeLossTripsDailyAndDrawdownBoundary() public {
        _settle(0);assertEq(kernel.cumulativeRealizedLoss(),1 ether);assertEq(kernel.strategyCapital(),9 ether);assertTrue(settlement.riskLatched());
        // Loss-bound halt also applies: this real graph case does not isolate the breaker from that guard.
        assertTrue(kernel.strategyAllocationHalted());assertEq(kernel.cumulativeRealizedProfit(),0);_assertAccounting();
    }
    function testQualificationDailyBreakerIsolatedFromDesignedLossAndDrawdown() public {
        for(uint256 id=1;id<=30&&!settlement.riskLatched();++id)_boundedQualificationLoss(id);
        assertTrue(settlement.riskLatched());assertFalse(kernel.strategyAllocationHalted());assertGe(kernel.cumulativeRealizedLoss(),0.5 ether);assertLt(kernel.cumulativeRealizedLoss(),1 ether);
        (,,uint256 dayCapital,uint256 lossStart,uint256 peak)=settlement.riskState();
        assertGe((kernel.cumulativeRealizedLoss()-lossStart)*10000,dayCapital*500);assertLt((peak-kernel.strategyCapital())*10000,peak*1000);assertTrue(settlement.terminationReady());
        vm.expectRevert();_openQualification(100,0.1 ether);
    }
    function testQualificationDrawdownBreakerIsolatedFromDailyAndDesignedLoss() public {
        for(uint256 id=1;id<=50&&!settlement.riskLatched();++id){vm.warp(vm.getBlockTimestamp()+1 days);_boundedQualificationLoss(id);}
        assertTrue(settlement.riskLatched());assertFalse(kernel.strategyAllocationHalted());
        (,,uint256 dayCapital,uint256 lossStart,uint256 peak)=settlement.riskState();
        assertLt((kernel.cumulativeRealizedLoss()-lossStart)*10000,dayCapital*500);assertGe((peak-kernel.strategyCapital())*10000,peak*1000);assertTrue(settlement.terminationReady());
        vm.expectRevert();_openQualification(100,0.1 ether);
    }
    function testQualificationStrategyAdmissionTimelockAndChangedAdapterPin() public {
        StrategyExecutor executor=StrategyExecutor(payable(kernel.strategyExecutor()));
        LifecycleAdapter fresh=new LifecycleAdapter(keccak256("new identity"),keccak256("new risk"),keccak256("new venue"));
        vm.prank(GUARDIAN);kernel.pause();vm.prank(ADMIN);executor.proposeStrategy(address(fresh),keccak256("new identity"),keccak256("new risk"),keccak256("new venue"));
        vm.expectRevert();vm.prank(ADMIN);executor.activateStrategy(address(fresh));vm.warp(block.timestamp+24 hours);
        vm.prank(ADMIN);executor.activateStrategy(address(fresh));assertTrue(executor.isApprovedStrategy(address(fresh)));
        vm.prank(GUARDIAN);kernel.resume();vm.etch(address(adapter),hex"00");vm.expectRevert();_openQualification(1,1 ether);assertEq(settlement.historyLength(),0);_assertAccounting();
    }
}
