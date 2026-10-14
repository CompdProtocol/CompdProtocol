// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {NativeFactoryGraph,Executor} from "./NativeFactoryGraph.sol";
import {CompdSettlementModuleV3 as Settlement} from "../../contracts/production/v3/phase7cr2ch/CompdSettlementModuleV3.sol";
import {C2G2BTypes as T,IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";

// Local deterministic lifecycle fixture. Not a trading strategy or production adapter.
contract AgentLifecycleFixture is IC2G2BStrategyAdapterR4 {
    address private executor;uint256 private principal;bytes32 private pos;bool private exiting;bool private paid;
    function strategyIdentity() external pure returns(bytes32){return keccak256("LOCAL_AGENT");}
    function riskConfigCommitment() external pure returns(bytes32){return keccak256("LOCAL_RISK");}
    function venueDependencyCommitment() external pure returns(bytes32){return keccak256("LOCAL_VENUE");}
    function open(uint256 id,bytes32 allocation,uint256 amount,uint256) external payable returns(bytes32){
        require(executor==address(0)&&msg.value==amount);executor=msg.sender;principal=amount;
        pos=keccak256(abi.encode(id,allocation));return pos;
    }
    function requestExit(bytes32 position,bytes32) external returns(T.AdapterPositionStatus){
        require(msg.sender==executor&&position==pos);exiting=true;return T.AdapterPositionStatus.RETURN_PENDING;
    }
    function observe(bytes32) external view returns(T.AdapterPositionStatus,uint256,bytes32){
        return(exiting?T.AdapterPositionStatus.RETURN_PENDING:T.AdapterPositionStatus.OPEN,paid?0:principal,bytes32(0));
    }
    function collect(bytes32 position,bytes32 attempt,uint256 maxPrincipal) external returns(uint256,bytes32){
        require(msg.sender==executor&&exiting&&position==pos&&!paid&&principal<=maxPrincipal);paid=true;
        (bool ok,)=payable(executor).call{value:principal}("");require(ok);return(principal,keccak256(abi.encode(attempt)));
    }
    function close(bytes32 position,bytes32) external returns(bytes32){
        require(msg.sender==executor&&exiting&&paid&&position==pos);
        (bool ok,)=payable(executor).call{value:address(this).balance}("");require(ok);return pos;
    }
}
contract CompdAgentLifecycleLocalTest is NativeFactoryGraph {
    Settlement private settlement;AgentLifecycleFixture private adapter;
    function setUp() public {
        createGraph(RESERVED);settlement=Settlement(kernel.moduleAddress(T.ModuleId.SETTLEMENT));
        vm.prank(ADMIN);kernel.activate();vm.prank(GUARDIAN);kernel.pause();
        adapter=new AgentLifecycleFixture();Executor exec=Executor(payable(kernel.strategyExecutor()));
        vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("LOCAL_AGENT"),keccak256("LOCAL_RISK"),keccak256("LOCAL_VENUE"));
        vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);exec.activateStrategy(address(adapter));
        vm.prank(GUARDIAN);kernel.resume();
    }
    function _open() private {vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.startRun(501,address(adapter),1 ether,keccak256("LOCAL_ALLOCATION"));}
    function testCycleCollectThenSettleConservesBootstrapAndProfitAllocation() public {
        _open();assertEq(kernel.activePrincipal(),1 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);
        vm.warp(block.timestamp+8 hours);vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.requestExit(501,keccak256("LOCAL_EXIT"));
        vm.deal(address(adapter),1.1 ether);settlement.collectRun(501,keccak256("LOCAL_ATTEMPT"));
        assertEq(kernel.principalCredited(501),1 ether);assertEq(kernel.activePrincipal(),0);
        vm.prank(kernel.AUTOMATION_EXECUTOR());settlement.closeRun(501,keccak256("LOCAL_CLOSE"));
        assertEq(kernel.strategyCapital(),10.065 ether);assertEq(kernel.buybackReserve(),.015 ether);
        assertEq(kernel.holderRewardReserve(),.01 ether);assertEq(kernel.protocolReserve(),.01 ether);
        assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.accountedQuote(),100.1 ether);
        assertEq(address(kernel).balance,100.1 ether);assertEq(uint8(settlement.run(501).state),6);
    }
    function testPausedKernelRejectsNewAgentEntry() public {
        vm.prank(GUARDIAN);kernel.pause();vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();
        settlement.startRun(501,address(adapter),1 ether,keccak256("LOCAL_ALLOCATION"));assertEq(kernel.activePrincipal(),0);
    }
    function testUnauthorizedAndOversizedEntryRemainRejected() public {
        vm.expectRevert();settlement.startRun(501,address(adapter),1 ether,keccak256("LOCAL_ALLOCATION"));
        vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(501,address(adapter),1.01 ether,keccak256("LOCAL_ALLOCATION"));
        assertEq(kernel.accountedQuote(),100 ether);assertEq(kernel.activePrincipal(),0);
    }
    function testDuplicateAllocationAndPrematureCloseRollback() public {
        _open();vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.startRun(501,address(adapter),1 ether,keccak256("LOCAL_ALLOCATION"));
        vm.prank(kernel.AUTOMATION_EXECUTOR());vm.expectRevert();settlement.closeRun(501,keccak256("LOCAL_CLOSE"));
        assertEq(kernel.activePrincipal(),1 ether);assertEq(kernel.cumulativeRealizedProfit(),0);
    }
}
