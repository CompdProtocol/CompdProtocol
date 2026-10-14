// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {stdError} from "forge-std/StdError.sol";
import {CompdPhase7CR2CHCurrentV3Test,T,Settlement,StrategyExecutor} from "./CompdPhase7CR2CHCurrentV3.t.sol";
import {IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";

contract HReadyHostileAdapter is IC2G2BStrategyAdapterR4 {
    address public settlement;bool public failOpen;bool public failClose;bool public recurse;bool public callbackRejected;
    function configure(address s,bool o,bool c,bool r) external {settlement=s;failOpen=o;failClose=c;recurse=r;}
    function strategyIdentity() external pure returns(bytes32){return keccak256("HREADY_ADAPTER");}
    function riskConfigCommitment() external pure returns(bytes32){return keccak256("HREADY_RISK");}
    function venueDependencyCommitment() external pure returns(bytes32){return keccak256("HREADY_VENUE");}
    function open(uint256 id,bytes32,uint256,uint256) external payable returns(bytes32){require(!failOpen,"OPEN_FAIL");return bytes32(id);}
    function requestExit(bytes32,bytes32) external pure returns(T.AdapterPositionStatus){return T.AdapterPositionStatus.EXIT_REQUESTED;}
    function observe(bytes32) external pure returns(T.AdapterPositionStatus,uint256,bytes32){return(T.AdapterPositionStatus.EXIT_REQUESTED,0,0);}
    function collect(bytes32,bytes32,uint256) external pure returns(uint256,bytes32){return(0,0);}
    function close(bytes32 p,bytes32) external returns(bytes32){
        if(recurse){(bool ok,)=settlement.call(abi.encodeWithSignature("closeRun(uint256,bytes32)",uint256(p),bytes32(uint256(999))));callbackRejected=!ok;require(!ok,"REENTRY_ACCEPTED");}
        require(!failClose,"CLOSE_FAIL");(bool sent,)=msg.sender.call{value:address(this).balance}("");require(sent);return p;
    }
}

contract CompdHReadyCounterTest is CompdPhase7CR2CHCurrentV3Test {
    function _count() internal view returns(uint256){return uint256(vm.load(address(settlement),bytes32(uint256(8))));}
    function _open(uint256 id) internal {vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.startRun(id,address(adapter),1 ether,bytes32(id));}
    function _exit(uint256 id) internal {vm.prank(GUARDIAN);settlement.requestExit(id,bytes32(id+1000));}
    function _close(uint256 id) internal {vm.prank(GUARDIAN);settlement.closeRun(id,bytes32(id+2000));}
    function _model() internal view {uint256 n;for(uint256 i;i<settlement.historyLength();++i)if(settlement.run(settlement.historyAt(i)).state!=T.StrategyRunState.CLOSED)++n;assertEq(_count(),n);assertEq(settlement.terminationReady(),n==0);_assertAccounting();}
    function testCounterOpenExitBlockedAndClosed() public {
        assertTrue(settlement.terminationReady());_open(1);assertEq(_count(),1);assertFalse(settlement.terminationReady());
        vm.prank(GUARDIAN);settlement.recordBlocked(1,keccak256("blocked"));assertEq(_count(),1);assertFalse(settlement.terminationReady());
        _exit(1);assertEq(_count(),1);_close(1);assertEq(_count(),0);assertTrue(settlement.terminationReady());assertEq(settlement.historyAt(0),1);_model();
    }
    function testCounterThreeConcurrentRunsCloseOutOfOrder() public {
        _open(1);_open(2);_open(3);assertEq(_count(),3);
        vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(4,address(adapter),1 ether,bytes32(uint256(4)));assertEq(_count(),3);
        // Adapter returns its complete balance; isolate the exact principal for each close.
        _exit(2);vm.deal(address(adapter),1 ether);_close(2);assertEq(_count(),2);
        _exit(1);vm.deal(address(adapter),1 ether);_close(1);assertEq(_count(),1);
        _exit(3);vm.deal(address(adapter),1 ether);_close(3);_model();assertTrue(settlement.terminationReady());
    }
    function testCounterFailedAdmissionAndDuplicateRunRollback() public {
        vm.prank(address(0xBAD));vm.expectRevert();settlement.startRun(1,address(adapter),1 ether,bytes32(uint256(1)));assertEq(_count(),0);
        _open(1);uint256 aq=kernel.accountedQuote();vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(1,address(adapter),1 ether,bytes32(uint256(2)));assertEq(_count(),1);assertEq(kernel.accountedQuote(),aq);_model();
    }
    function testCounterRepeatedCloseAndInvalidCloseNoDecrement() public {
        _open(1);vm.prank(GUARDIAN);vm.expectRevert();settlement.closeRun(1,bytes32(uint256(1)));assertEq(_count(),1);
        _exit(1);_close(1);vm.prank(GUARDIAN);vm.expectRevert();settlement.closeRun(1,bytes32(uint256(99)));assertEq(_count(),0);_model();
    }
    function testCounterExitCollectionPauseAndShutdownRetainOutstanding() public {
        _open(1);_exit(1);settlement.collectRun(1,bytes32(uint256(333)));assertEq(_count(),1);assertFalse(settlement.terminationReady());
        vm.prank(GUARDIAN);kernel.pause();assertFalse(settlement.terminationReady());vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertEq(_count(),1);_close(1);_model();
    }
    function testCounterCheckedUnderflowRollsBackPhysicalSettlement() public {
        _open(1);_exit(1);vm.store(address(settlement),bytes32(uint256(8)),0); // Deliberately corrupt test storage, never a production path.
        uint256 balance=address(kernel).balance;vm.prank(GUARDIAN);vm.expectRevert(stdError.arithmeticError);settlement.closeRun(1,bytes32(uint256(2001)));
        assertEq(address(kernel).balance,balance);assertEq(kernel.activePrincipal(),1 ether);assertEq(uint256(settlement.run(1).state),uint256(T.StrategyRunState.EXIT_REQUESTED));
        vm.store(address(settlement),bytes32(uint256(8)),bytes32(uint256(1)));_close(1);_model();
    }
    function testCounterCheckedOverflowRollsBackAdmission() public {
        vm.store(address(settlement),bytes32(uint256(8)),bytes32(type(uint256).max)); // Deliberate storage corruption diagnostic.
        uint256 balance=address(kernel).balance;vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert(stdError.arithmeticError);settlement.startRun(1,address(adapter),1 ether,bytes32(uint256(1)));
        assertEq(address(kernel).balance,balance);assertEq(kernel.activePrincipal(),0);assertEq(settlement.historyLength(),0);assertEq(uint256(settlement.run(1).state),0);
    }
    function _hostile() internal returns(HReadyHostileAdapter h){
        h=new HReadyHostileAdapter();h.configure(address(settlement),false,false,false);vm.prank(GUARDIAN);kernel.pause();StrategyExecutor exec=StrategyExecutor(payable(kernel.strategyExecutor()));
        bytes32 ident=h.strategyIdentity();bytes32 risk=h.riskConfigCommitment();bytes32 venue=h.venueDependencyCommitment();
        vm.prank(ADMIN);exec.proposeStrategy(address(h),ident,risk,venue);vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);exec.activateStrategy(address(h));vm.prank(GUARDIAN);kernel.resume();
    }
    function testCounterHostileOpenCloseAndReentrantCloseAtomicity() public {
        HReadyHostileAdapter h=_hostile();h.configure(address(settlement),true,false,false);vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(1,address(h),1 ether,bytes32(uint256(1)));assertEq(_count(),0);assertEq(kernel.activePrincipal(),0);
        h.configure(address(settlement),false,false,false);vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.startRun(1,address(h),1 ether,bytes32(uint256(1)));_exit(1);
        h.configure(address(settlement),false,true,true);uint256 balance=address(kernel).balance;vm.prank(GUARDIAN);vm.expectRevert();settlement.closeRun(1,bytes32(uint256(2001)));assertEq(_count(),1);assertEq(address(kernel).balance,balance);assertEq(kernel.activePrincipal(),1 ether);assertFalse(h.callbackRejected());
        h.configure(address(settlement),false,false,true);_close(1);assertTrue(h.callbackRejected());assertEq(_count(),0);_model();
    }
    function testFuzzCounterSequentialRunsPreserveHistory(uint8 raw) public {uint256 n=bound(uint256(raw),1,16);for(uint256 id=1;id<=n;++id){_open(id);_model();_exit(id);_model();_close(id);_model();}assertEq(settlement.historyLength(),n);}
}

interface IHReadyCounterDriver {function stepCounter(uint8,uint8) external;}
contract HReadyCounterActions {IHReadyCounterDriver immutable driver;constructor(IHReadyCounterDriver d){driver=d;}function step(uint8 a,uint8 id) external {driver.stepCounter(a,id);}}
contract CompdHReadyCounterInvariantTest is CompdHReadyCounterTest,IHReadyCounterDriver {
    HReadyCounterActions actions;uint256 nextId;
    function setUp() public override {
        super.setUp();excludeContract(address(h6Actions));bytes4[] memory old=new bytes4[](5);old[0]=h6Actions.accept.selector;old[1]=h6Actions.shutdown.selector;old[2]=h6Actions.finalize.selector;old[3]=h6Actions.terminate.selector;old[4]=h6Actions.recover.selector;excludeSelector(FuzzSelector(address(h6Actions),old));
        actions=new HReadyCounterActions(this);targetContract(address(actions));bytes4[] memory s=new bytes4[](1);s[0]=actions.step.selector;targetSelector(FuzzSelector(address(actions),s));
    }
    function stepCounter(uint8 raw,uint8 pick) external {
        require(msg.sender==address(actions));uint8 a=raw%7;uint256 n=settlement.historyLength();uint256 id=n==0?0:settlement.historyAt(uint256(pick)%n);T.StrategyRunState st=settlement.run(id).state;T.Lifecycle life=kernel.lifecycle();
        if(a==0&&life==T.Lifecycle.ACTIVE&&_count()<3&&nextId<32){_open(++nextId);}
        else if(a==1&&st!=T.StrategyRunState.NONE&&st!=T.StrategyRunState.CLOSED&&settlement.run(id).exitId==0){_exit(id);}
        else if(a==2&&st!=T.StrategyRunState.NONE&&st!=T.StrategyRunState.CLOSED){vm.prank(GUARDIAN);settlement.recordBlocked(id,bytes32(uint256(444)));}
        else if(a==3&&st!=T.StrategyRunState.NONE&&st!=T.StrategyRunState.CLOSED&&settlement.run(id).exitId!=0){vm.deal(address(adapter),1 ether);_close(id);}
        else if(a==4&&life==T.Lifecycle.ACTIVE){vm.prank(GUARDIAN);kernel.pause();}else if(a==4&&life==T.Lifecycle.PAUSED){vm.prank(GUARDIAN);kernel.resume();}
        else if(a==5&&(life==T.Lifecycle.ACTIVE||life==T.Lifecycle.PAUSED)){vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);}
        else if(a==6&&st!=T.StrategyRunState.NONE&&st!=T.StrategyRunState.CLOSED&&settlement.run(id).exitId!=0){settlement.collectRun(id,keccak256(abi.encode(id,raw,pick,settlement.run(id).collectionAttempts)));}
        _model();
    }
    function invariantCounterExactlyMatchesNonClosedHistoryAndAccounting() public view {_model();assertFalse(kernel.buybackActivated());}
}
