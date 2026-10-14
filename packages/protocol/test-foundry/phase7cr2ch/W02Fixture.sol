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
contract W02Fixture is Test {
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
}
