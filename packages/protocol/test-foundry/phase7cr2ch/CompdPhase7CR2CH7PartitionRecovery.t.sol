// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {T,Kernel,Settlement,StrategyExecutor,LifecycleAdapter} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "../phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
import {CompdRecoveryModuleV3 as Recovery} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryModuleV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdRecoveryEvidenceV3 as Evidence} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryEvidenceV3.sol";

/// @dev Fresh real G3 graphs exercise all three nonpayable HR categories, without storage overrides or forged liabilities.
contract CompdPhase7CR2CH7PartitionRecoveryTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    Kernel kernel;Settlement settlement;LifecycleAdapter adapter;Recovery recovery;State state;
    function setUp() public virtual {
        vm.chainId(31337);vm.roll(1000);vm.warp(100 days+123);
        MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();address k=vm.computeCreateAddress(address(kd),1);
        address s=vm.computeCreateAddress(address(md),2);address d=vm.computeCreateAddress(address(md),3);address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);
        address c=md.candidate(k,s,d,address(0xF1A1),address(0x70C0));s=md.state(k,d,l,e,address(0xF1A1),c,address(0x70C0),c.codehash);
        d=md.distributor(k,s,c,address(0xF1A1));l=md.liability(k,s);e=md.evidence(k,s);address r=md.recovery(k,e,e.codehash);address h=md.holder(k,d,l,s);
        address probe=address(new StrategyExecutor(k,ADMIN,GUARDIAN));address settle=md.settlement(k,vm.computeCreateAddress(k,1),probe.codehash);address policy=md.policy(k);
        address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);address bb=md.buyback(k);
        address[6] memory m=[settle,h,policy,r,em,registry];bytes32[13] memory hashes=[probe.codehash,bb.codehash,d.codehash,l.codehash,e.codehash,c.codehash,s.codehash,settle.codehash,h.codehash,policy.codehash,r.codehash,em.codehash,registry.codehash];
        kernel=Kernel(payable(kd.deploy(address(0xA11CE),address(0xB0B),bb,d,l,e,c,address(0x70C0),m,hashes)));settlement=Settlement(settle);recovery=Recovery(r);state=State(s);
        vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();
        vm.prank(ADMIN);kernel.activate();vm.prank(GUARDIAN);kernel.pause();
        bytes32 ident=keccak256("H7_LOCAL_STRATEGY");bytes32 risk=keccak256("H7_LOCAL_RISK");bytes32 venue=keccak256("H7_LOCAL_VENUE");adapter=new LifecycleAdapter(ident,risk,venue);
        StrategyExecutor strategy=StrategyExecutor(payable(kernel.strategyExecutor()));vm.prank(ADMIN);strategy.proposeStrategy(address(adapter),ident,risk,venue);
        vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);strategy.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();
    }
    function _seal() internal {uint64 a=kernel.activationBlock();vm.roll(a+1);vm.setBlockhash(a,keccak256("H7_LOCAL_HEADER"));assertTrue(kernel.sealActivationCheckpoint());}
    function _settle() internal {address automation=kernel.AUTOMATION_EXECUTOR();vm.prank(automation);settlement.startRun(1,address(adapter),1 ether,keccak256("H7_ALLOC"));vm.prank(automation);settlement.requestExit(1,keccak256("H7_EXIT"));vm.deal(address(adapter),1.1 ether);vm.prank(automation);settlement.closeRun(1,keccak256("H7_CLOSE"));}
    function _id(uint8 partition) internal view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),block.chainid,address(kernel),partition,kernel.shutdownAt(),uint256(0.01 ether)));}
    function _recover(uint8 p,bytes32 id) internal {if(p==1)recovery.recoverPartialActivation(id);else if(p==2)recovery.recoverActivationSealFailure(id);else recovery.recoverShutdownTail(id);}
    function _validateAndRecover(uint8 p) internal {
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);bytes32 id=_id(p);uint256 aq=kernel.accountedQuote();
        vm.expectRevert(Recovery.Unauthorized.selector);_recover(p,id);vm.expectRevert(Kernel.RecoveryUnavailable.selector);vm.prank(GUARDIAN);_recover(p,id);
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();assertTrue(state.recoveryReconciliationComplete());
        (bool ok,uint256 x)=Evidence(kernel.recoveryEvidence()).nonpayableHolderRecovery(id,p);assertTrue(ok);assertEq(x,0.01 ether);
        vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(GUARDIAN);_recover(p,bytes32(uint256(id)^1));
        uint256 b=kernel.RECOVERY_TREASURY().balance;vm.prank(GUARDIAN);_recover(p,id);assertEq(kernel.RECOVERY_TREASURY().balance-b,x);
        assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.accountedQuote(),aq-x);assertEq(kernel.activePrincipal(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);
        assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        vm.expectRevert(Recovery.Unauthorized.selector);vm.prank(GUARDIAN);_recover(p,id);assertFalse(kernel.buybackActivated());
    }
    function testH7PartialActivationZeroBalanceCannotRecover() public {
        _seal();assertGt(block.timestamp,kernel.firstEligibleWindowStart());_settle();assertEq(kernel.partialActivationHR(),0);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 id=keccak256(abi.encode(keccak256("COMPD_NONPAYABLE_HOLDER_RECOVERY_V3"),block.chainid,address(kernel),uint8(1),kernel.shutdownAt(),uint256(0)));
        (bool ok,uint256 amount)=Evidence(kernel.recoveryEvidence()).nonpayableHolderRecovery(id,1);assertFalse(ok);assertEq(amount,0);
        vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(GUARDIAN);recovery.recoverPartialActivation(id);assertEq(kernel.holderRewardReserve(),0.01 ether);
    }
    function testH7ActivationSealFailureHRRecoveryOnlyAfterTermination() public {_settle();assertEq(kernel.eligibleWindowHR(),0.01 ether);vm.roll(kernel.activationBlock()+257);assertFalse(kernel.sealActivationCheckpoint());assertEq(kernel.activationSealFailureHR(),0.01 ether);assertEq(kernel.eligibleWindowHR(),0);_validateAndRecover(2);}
    function testH7ShutdownTailHRRecoveryOnlyAfterTermination() public {_seal();_settle();assertEq(kernel.eligibleWindowHR(),0.01 ether);_validateAndRecover(3);assertEq(kernel.shutdownTailHR(),0);}
    function _partitions() internal view {assertEq(kernel.holderRewardReserve(),kernel.eligibleWindowHR()+kernel.partialActivationHR()+kernel.activationSealFailureHR()+kernel.shutdownTailHR()+kernel.emergencyLockedHR());assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());}
    function testH702RepeatFailureCannotRedemoteOrRecoverTwice() public {
        _settle();uint64 start=uint64(block.timestamp/28800*28800);vm.roll(kernel.activationBlock()+257);assertTrue(kernel.failExpiredActivationSeal());_partitions();
        vm.expectRevert(Kernel.InvalidLifecycle.selector);kernel.failExpiredActivationSeal();vm.expectRevert(Kernel.InvalidLifecycle.selector);kernel.sealActivationCheckpoint();
        assertEq(kernel.holderWindowAccrued(start),0.01 ether);(,,,,bool eligible)=kernel.deriveWindow(start);assertFalse(eligible);
        _validateAndRecover(2);_partitions();assertEq(kernel.activationSealFailureHR(),0);assertEq(kernel.shutdownTailHR(),0);
        vm.expectRevert(Kernel.InvalidLifecycle.selector);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);
    }
    function testH702ShutdownBeforeSealFailureKeepsTailSeparate() public {
        _settle();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(kernel.shutdownTailHR(),0.01 ether);assertEq(kernel.eligibleWindowHR(),0);
        vm.roll(kernel.activationBlock()+257);assertFalse(kernel.sealActivationCheckpoint());assertEq(kernel.activationSealFailureHR(),0);assertEq(kernel.shutdownTailHR(),0.01 ether);_partitions();
        vm.expectRevert(Kernel.InvalidLifecycle.selector);kernel.sealActivationCheckpoint();vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();
        bytes32 id=_id(3);vm.prank(GUARDIAN);recovery.recoverShutdownTail(id);_partitions();assertEq(kernel.holderRewardReserve(),0);
    }
    function testH702PausedBoundaryAndWrongPartitionCannotRecover() public {
        _settle();uint64 a=kernel.activationBlock();vm.roll(a+256);vm.setBlockhash(a,bytes32(0));assertFalse(kernel.sealActivationCheckpoint());vm.prank(GUARDIAN);kernel.pause();
        vm.warp((block.timestamp/28800+1)*28800);_validateAndRecover(2);_partitions();assertEq(kernel.shutdownTailHR(),0);
        bytes32 wrongId=_id(3);vm.expectRevert(Kernel.InvalidEvidence.selector);vm.prank(GUARDIAN);recovery.recoverShutdownTail(wrongId);
    }
    function testFuzzH702ShutdownDelayAfterSealFailure(uint32 offset,bool paused) public {
        _settle();vm.roll(kernel.activationBlock()+257);kernel.failExpiredActivationSeal();if(paused){vm.prank(GUARDIAN);kernel.pause();}
        vm.warp(block.timestamp+uint256(offset)%365 days);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);_partitions();assertEq(kernel.activationSealFailureHR(),0.01 ether);assertEq(kernel.shutdownTailHR(),0);assertEq(kernel.eligibleWindowHR(),0);
        vm.expectRevert(Kernel.InvalidLifecycle.selector);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);_partitions();
        vm.warp(kernel.shutdownAt());vm.prank(GUARDIAN);kernel.terminate();bytes32 id=_id(2);vm.prank(GUARDIAN);recovery.recoverActivationSealFailure(id);_partitions();assertEq(kernel.holderRewardReserve(),0);
    }
}
