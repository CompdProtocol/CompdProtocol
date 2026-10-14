// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase,CompdHReadySealFailureQualificationTest,HReadyRejectNative,HReadyRecoveryCallbackNative} from "./CompdHReadyLocalQualification.t.sol";
import {T,StrategyExecutor} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {CompdHolderCandidateTypesV3 as H} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateTypesV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";

contract HReadyGuardianReceiverCallback {
    address immutable recovery;bytes32 immutable id;
    constructor(address r,bytes32 i){recovery=r;id=i;}
    receive() external payable {(bool ok,)=recovery.call(abi.encodeWithSignature("recoverProtocol(bytes32)",id));require(!ok,"authorized callback must reject");}
}

contract CompdHReadyRemainingSealFailureTest is CompdHReadySealFailureQualificationTest {
    function testRemainingSealFailureAuthorizationFaultsRollbackAndOriginalEvidenceSucceeds() public {
        _settle();vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 id=_id(2);bytes32 key=keccak256(abi.encode(uint8(2),id));uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;bytes memory input=abi.encodeWithSignature("authorizeRecovery(uint8,bytes32)",uint8(5),id);
        for(uint256 field;field<6;++field){bytes32 wrong=keccak256(abi.encode(field==0?keccak256("bad"):keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),field==1?block.chainid+1:block.chainid,field==2?address(0xBAD):address(kernel),field==3?uint8(3):uint8(2),field==4?kernel.shutdownAt()+1:kernel.shutdownAt(),field==5?uint256(0.01 ether)+1:uint256(0.01 ether)));assertTrue(wrong!=id);assertFalse(_callFailure(wrong));}
        for(uint256 f;f<4;++f){if(f==0)vm.mockCall(address(recovery),input,abi.encode(false,uint256(0.01 ether)));if(f==1)vm.mockCall(address(recovery),input,abi.encode(true,uint256(0)));if(f==2)vm.mockCall(address(recovery),input,abi.encode(true,aq+1));if(f==3)vm.mockCallRevert(address(recovery),input,hex"deadbeef");
            assertFalse(_callFailure(id));assertFalse(recovery.processed(key));assertEq(kernel.accountedQuote(),aq);assertEq(kernel.activationSealFailureHR(),0.01 ether);assertEq(address(kernel).balance,physical);vm.clearMockedCalls();
        }
        assertTrue(_callFailure(id));assertEq(kernel.activationSealFailureHR(),0);assertFalse(_callFailure(id));_partitions();
    }
}

/// Negative fault injection changes peer responses, never creates a positive liability.
contract CompdHReadyRemainingRecoveryTest is CompdHReadyQualificationBase {
    function testRemainingExpiredRecoveryWrongLeafUseDigestWindowRecipientAmountAndDomain() public {
        _settle(1.1 ether);HReadyRejectNative rejector=new HReadyRejectNative();bytes32 leaf=_nonempty(address(rejector));vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertFalse(holder.pay(leaf));
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);(,,uint64 expires,)=state.terminalStatus(leaf);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();vm.warp(expires);bytes32 original=state.expiredHolderRecoveryId(leaf);(T.HolderPayment memory p,)=state.paymentData(leaf);(bytes32 digest,,,,,)=state.canonicalPayment(leaf);
        for(uint256 field;field<12;++field){bytes32 changedDigest=digest;
            if(field>=9){(T.HolderPayment memory bad,)=state.paymentData(leaf);if(field==9)bad.windowId=keccak256("wrong window");if(field==10)bad.recipient=address(0xBAD);if(field==11)bad.amount+=1;
                changedDigest=keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,address(kernel),bad.windowId,bad.distributionId,bad.version,bad.index,bad.root,bad.lineage,bad.leafId,bad.recipient,bad.asset,bad.amount,bad.distributionStatus,bad.liabilityStatus,bad.finalizedAt,bad.expiresAt,bad.recoveryStatus,bad.useId));
            }
            bytes32 wrong=keccak256(abi.encode(field==0?keccak256("bad"):keccak256("COMPD_RECOVERY_ID_V3"),field==1?block.chainid+1:block.chainid,field==2?address(0xBAD):address(kernel),field==3?uint8(1):uint8(2),field==4?address(0xBAD):address(state),field==5?keccak256("bad"):keccak256("EXPIRED_HOLDER"),field==6?keccak256("bad leaf"):leaf,field==7?keccak256("bad use"):p.useId,field==8?keccak256("bad digest"):changedDigest));
            assertTrue(wrong!=original);assertFalse(_route(2,wrong,GUARDIAN));assertFalse(recovery.processed(_key(2,wrong)));_assertAccounting();
        }
        assertTrue(_route(2,original,GUARDIAN));_assertAccounting();
    }
    function testRemainingEmptyRecoveryWrongWindowVersionCommitmentAmountAndDomain() public {
        _settle(1.1 ether);(bytes32 wid,)=_empty();_shutdownAndTerminate();Candidate.EmptyRecord memory e=candidate.emptyRecord(wid);bytes32 original=state.emptyRecoveryId(wid);
        for(uint256 field;field<10;++field){bytes32 id=keccak256(abi.encode(field==0?keccak256("bad"):keccak256("COMPD_RECOVERY_ID_V3"),field==1?block.chainid+1:block.chainid,field==2?address(0xBAD):address(kernel),field==3?uint8(2):uint8(1),field==4?address(0xBAD):address(state),field==5?keccak256("bad"):keccak256("NO_RECIPIENT"),field==6?keccak256("bad window"):wid,field==7?e.version+1:e.version,field==8?keccak256("bad commitment"):e.commitment,field==9?e.amount+1:e.amount));
            assertTrue(id!=original);assertFalse(_route(1,id,GUARDIAN));assertFalse(recovery.processed(_key(1,id)));_assertAccounting();
        }
        assertTrue(_route(1,original,GUARDIAN));assertFalse(_route(1,original,GUARDIAN));_assertAccounting();
    }
    function testRemainingShutdownTailWrongPartitionDeadlineAmountAndDomain() public {
        (bytes32 original,uint256 amount)=_prepareQualificationRecovery(6);
        for(uint256 field;field<6;++field){bytes32 id=keccak256(abi.encode(field==0?keccak256("bad"):keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),field==1?block.chainid+1:block.chainid,field==2?address(0xBAD):address(kernel),field==3?uint8(2):uint8(3),field==4?kernel.shutdownAt()+1:kernel.shutdownAt(),field==5?amount+1:amount));assertTrue(id!=original);assertFalse(_route(6,id,GUARDIAN));assertFalse(recovery.processed(_key(6,id)));_assertAccounting();}
        assertTrue(_route(6,original,GUARDIAN));_assertAccounting();
    }
    function testRemainingRecoveryAuthorizationFaultsRollbackFiveReachableCategories() public {
        uint8[5] memory kinds=[uint8(0),1,2,3,6];
        for(uint256 i;i<kinds.length;++i){uint256 snap=vm.snapshotState();uint8 kind=kinds[i];(bytes32 id,uint256 amount)=_prepareQualificationRecovery(kind);
            uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;
            bytes memory input=abi.encodeWithSignature("authorizeRecovery(uint8,bytes32)",kind,id);
            for(uint256 f;f<4;++f){
                if(f==0)vm.mockCall(address(recovery),input,abi.encode(false,amount));
                if(f==1)vm.mockCall(address(recovery),input,abi.encode(true,uint256(0)));
                if(f==2)vm.mockCall(address(recovery),input,abi.encode(true,aq+1));
                if(f==3)vm.mockCallRevert(address(recovery),input,abi.encodePacked(bytes4(keccak256("LOCAL_FAULT()"))));
                assertFalse(_route(kind,id,GUARDIAN));assertFalse(recovery.processed(_key(kind,id)));assertEq(kernel.accountedQuote(),aq);assertEq(address(kernel).balance,physical);vm.clearMockedCalls();
            }
            assertTrue(_route(kind,id,GUARDIAN));assertEq(kernel.accountedQuote(),aq-amount);assertFalse(_route(kind,id,GUARDIAN));_assertAccounting();assertTrue(vm.revertToState(snap));
        }
    }
    function testRemainingRecoveryChangedEvidenceCodeFailsClosedFiveCategories() public {
        uint8[5] memory kinds=[uint8(0),1,2,3,6];
        for(uint256 i;i<kinds.length;++i){uint256 snap=vm.snapshotState();uint8 kind=kinds[i];(bytes32 id,)=_prepareQualificationRecovery(kind);uint256 aq=kernel.accountedQuote();
            vm.etch(kernel.recoveryEvidence(),hex"00");assertFalse(_route(kind,id,GUARDIAN));assertFalse(recovery.processed(_key(kind,id)));assertEq(kernel.accountedQuote(),aq);assertTrue(vm.revertToState(snap));
        }
    }
    function testRemainingBucketRecoveryRejectsEveryWrongTupleComponent() public {
        _terminatedProfit();
        for(uint8 kind;kind<4;kind+=3){uint256 amount=kind==0?kernel.protocolReserve():kernel.nonStrategyTreasuryPrincipal();bytes32 label=kind==0?keccak256("PROTOCOL_RESERVE"):keccak256("TREASURY_PRINCIPAL");
            for(uint256 field;field<8;++field){bytes32 id=keccak256(abi.encode(field==0?keccak256("BAD_DOMAIN"):keccak256("COMPD_RECOVERY_ID_V3"),field==1?block.chainid+1:block.chainid,field==2?address(0xBAD):address(kernel),field==3?uint8(7):kind,field==4?address(0xBAD):address(state),field==5?kernel.shutdownAt()+1:kernel.shutdownAt(),field==6?keccak256("BAD_BUCKET"):label,field==7?amount+1:amount));
                assertFalse(_route(kind,id,GUARDIAN));assertFalse(recovery.processed(_key(kind,id)));_assertAccounting();
            }
        }
    }
    function testRemainingRecoveryConsumedEvidenceCannotCrossCategoryOrDepletedBucket() public {
        _terminatedProfit();bytes32 id=state.bucketRecoveryId(0);assertTrue(_route(0,id,GUARDIAN));
        for(uint8 kind;kind<7;++kind)assertFalse(_route(kind,id,GUARDIAN));
        bytes32 depleted=state.bucketRecoveryId(0);assertFalse(_route(0,depleted,GUARDIAN));assertEq(kernel.protocolReserve(),0);_assertAccounting();
    }
}

contract CompdHReadyRemainingHolderTest is CompdHReadyQualificationBase {
    function testRemainingAuthorizedGuardianReceiverCannotRecoverInsideTerminalHolderRetry() public {
        _settle(1.1 ether);HReadyRejectNative rejector=new HReadyRejectNative();vm.etch(GUARDIAN,address(rejector).code);bytes32 leaf=_nonempty(GUARDIAN);
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertFalse(holder.pay(leaf));(T.HolderPayment memory p,)=state.paymentData(leaf);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);holder.terminalize(leaf);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();bytes32 id=state.bucketRecoveryId(0);
        HReadyGuardianReceiverCallback callback=new HReadyGuardianReceiverCallback(address(recovery),id);vm.etch(GUARDIAN,address(callback).code);assertTrue(recovery.terminationReady());assertFalse(recovery.processed(_key(0,id)));
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertTrue(holder.retry(p.useId));assertFalse(recovery.processed(_key(0,id)));assertEq(kernel.protocolReserve(),0.01 ether);_assertAccounting();
        assertTrue(_route(0,id,GUARDIAN));_assertAccounting();
    }
    function testRemainingHolderChangedPeerPinsRollbackAndAllowRestoredPayment() public {
        _settle(1.1 ether);bytes32 leaf=_nonempty(address(0xBEEF));address[3] memory peers=[address(distributor),kernel.liability(),address(state)];
        for(uint256 i;i<peers.length;++i){uint256 snap=vm.snapshotState();uint256 aq=kernel.accountedQuote();vm.etch(peers[i],hex"00");
            vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);(bool ok,)=address(holder).call(abi.encodeWithSignature("pay(bytes32)",leaf));assertFalse(ok);assertEq(kernel.accountedQuote(),aq);assertTrue(vm.revertToState(snap));
        }
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertTrue(holder.pay(leaf));_assertAccounting();
    }
    function testRemainingHolderCanonicalWrongTupleAndPeerDisagreementRollback() public {
        _settle(1.1 ether);bytes32 leaf=_nonempty(address(0xBEEF));uint256 aq=kernel.accountedQuote();(T.HolderPayment memory p,)=state.paymentData(leaf);
        for(uint256 f;f<5;++f){(T.HolderPayment memory bad,)=state.paymentData(leaf);
            if(f==0)bad.recipient=address(0xBAD);if(f==1)bad.asset=address(0xBAD);if(f==2)bad.amount+=1;if(f==3)bad.windowId=keccak256("wrong window");if(f==4)bad.useId=keccak256("wrong use");
            vm.mockCall(address(distributor),abi.encodeWithSignature("paymentData(bytes32)",leaf),abi.encode(bad,true));
            vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);(bool ok,)=address(holder).call(abi.encodeWithSignature("pay(bytes32)",leaf));assertFalse(ok);assertEq(kernel.accountedQuote(),aq);(uint8 mask,bool consumed)=state.consumption(leaf);assertEq(mask,0);assertFalse(consumed);vm.clearMockedCalls();
        }
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertTrue(holder.pay(leaf));_assertAccounting();
    }
    function testRemainingHolderCandidateCannotReplayAcrossChainDomain() public {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory l)=_vector(address(0xBEEF));uint256 aq=kernel.accountedQuote();vm.chainId(31338);
        vm.prank(FINALIZER);(bool ok,)=address(distributor).call(abi.encodeCall(distributor.submitCandidate,(c,e)));assertFalse(ok);assertEq(kernel.accountedQuote(),aq);vm.chainId(31337);
        vm.prank(FINALIZER);distributor.submitCandidate(c,e);vm.prank(FINALIZER);bytes32 leaf=distributor.materializeLeaf(c.distributionId,1,l,new bytes32[](0));vm.warp(vm.getBlockTimestamp()+1800);distributor.finalizeCandidate(c.distributionId,1);
        vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);assertTrue(holder.pay(leaf));_assertAccounting();
    }
}

contract CompdHReadyRemainingStrategyTest is CompdHReadyQualificationBase {
    function testRemainingStrategyTinyPrincipalRoundsLossBudgetDownAndLatchesOneWeiLoss() public {
        _openQualification(901,1);vm.prank(GUARDIAN);settlement.requestExit(901,keccak256("tiny exit"));vm.deal(address(adapter),0);
        vm.prank(GUARDIAN);settlement.closeRun(901,keccak256("tiny close"));assertTrue(kernel.runLossBoundBreached(901));assertTrue(kernel.strategyAllocationHalted());_assertAccounting();
    }
    function testRemainingStrategyChangedAdapterDuringOpenCloseRollsBackWithoutClosingCounter() public {
        _openQualification(902,1 ether);vm.prank(GUARDIAN);settlement.requestExit(902,keccak256("exit"));uint256 snap=vm.snapshotState();vm.etch(address(adapter),hex"00");
        vm.prank(GUARDIAN);(bool ok,)=address(settlement).call(abi.encodeWithSignature("closeRun(uint256,bytes32)",902,keccak256("close")));assertFalse(ok);assertFalse(settlement.terminationReady());assertEq(kernel.activePrincipal(),1 ether);assertTrue(vm.revertToState(snap));
        vm.deal(address(adapter),1 ether);vm.prank(GUARDIAN);settlement.closeRun(902,keccak256("close"));assertTrue(settlement.terminationReady());_assertAccounting();
    }
}

