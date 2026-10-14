// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T,IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";
import {CompdSettlementModuleV3 as Settlement} from "../../contracts/production/v3/phase7cr2ch/CompdSettlementModuleV3.sol";
import {CompdDisabledBuybackPolicyModuleV3 as Policy} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackPolicyModuleV3.sol";
import {CompdDisabledBuybackExecutorV3 as BuybackExecutor} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackExecutorV3.sol";
import {CompdStrategyExecutorV2R2 as StrategyExecutor} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "./Phase7CR2CIValidationMatrix.t.sol";

contract LifecycleAdapter is IC2G2BStrategyAdapterR4 {
    bytes32 immutable ident; bytes32 immutable risk; bytes32 immutable venue;
    constructor(bytes32 i,bytes32 r,bytes32 v){ident=i;risk=r;venue=v;}
    function strategyIdentity() external view returns(bytes32){return ident;}
    function riskConfigCommitment() external view returns(bytes32){return risk;}
    function venueDependencyCommitment() external view returns(bytes32){return venue;}
    function open(uint256,bytes32,uint256,uint256) external payable returns(bytes32){return keccak256(abi.encode(msg.sender,msg.value,block.number));}
    function requestExit(bytes32,bytes32) external pure returns(T.AdapterPositionStatus){return T.AdapterPositionStatus.EXIT_REQUESTED;}
    function observe(bytes32) external pure returns(T.AdapterPositionStatus,uint256,bytes32){return(T.AdapterPositionStatus.EXIT_REQUESTED,0,bytes32(0));}
    function collect(bytes32,bytes32,uint256) external pure returns(uint256,bytes32){return(0,bytes32(0));}
    function close(bytes32 position,bytes32) external returns(bytes32){uint256 amount=address(this).balance;if(amount!=0){(bool ok,)=msg.sender.call{value:amount}("");require(ok);}return position;}
}

contract Phase7CR2CISettlementLifecycleTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    Kernel kernel; Settlement settlement;

    function _deployGraph() private {
        MatrixModuleDeployer md=new MatrixModuleDeployer(); MatrixKernelDeployer kd=new MatrixKernelDeployer();
        address k=vm.computeCreateAddress(address(kd),1);
        address s=vm.computeCreateAddress(address(md),2); address d=vm.computeCreateAddress(address(md),3);
        address l=vm.computeCreateAddress(address(md),4); address e=vm.computeCreateAddress(address(md),5);
        address candidate=md.candidate(k,s,d,address(0xF1A1),address(0x70C0));
        address state=md.state(k,d,l,e,address(0xF1A1),candidate,address(0x70C0),candidate.codehash);
        address distributor=md.distributor(k,state,candidate,address(0xF1A1)); address liability=md.liability(k,state);
        address evidence=md.evidence(k,state); address recovery=md.recovery(k,evidence,evidence.codehash);
        address holder=md.holder(k,distributor,liability,state);
        address probe=address(new StrategyExecutor(k,ADMIN,GUARDIAN)); address strategy=vm.computeCreateAddress(k,1);
        address settle=md.settlement(k,strategy,probe.codehash); address policy=md.policy(k);
        address emergency=md.emergency(k,vm.computeCreateAddress(address(md),11)); address registry=md.registry(k,emergency);
        address buyback=md.buyback(k);
        address[6] memory modules=[settle,holder,policy,recovery,emergency,registry];
        bytes32[13] memory hashes=[probe.codehash,buyback.codehash,distributor.codehash,liability.codehash,evidence.codehash,candidate.codehash,state.codehash,settle.codehash,holder.codehash,policy.codehash,recovery.codehash,emergency.codehash,registry.codehash];
        kernel=Kernel(payable(kd.deploy(address(0xA11CE),address(0xB0B),buyback,distributor,liability,evidence,candidate,address(0x70C0),modules,hashes)));
        settlement=Settlement(settle);
    }

    function testTypedAllocationExitAndSettlementPreservePrincipalAndSplitOnlyRealizedProfit() public {
        _deployGraph(); vm.deal(ADMIN,100 ether); vm.prank(ADMIN); kernel.bootstrapTreasury{value:100 ether}();
        address buybackPolicy=kernel.moduleAddress(T.ModuleId.BUYBACK);
        address buybackExecutor=kernel.buybackExecutor();
        vm.prank(ADMIN); kernel.activate();
        // Disabled Buyback remains unreachable even after protocol activation.
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.ACTIVE));
        _assertBuybackDisabled(buybackPolicy,buybackExecutor);
        address emergencyModule=kernel.moduleAddress(T.ModuleId.EMERGENCY);
        vm.prank(emergencyModule);
        vm.expectRevert(Kernel.InvalidAmount.selector);
        kernel.emergencyTransferBNB(bytes32(uint256(1)),bytes32(uint256(2)),1,1,bytes32(uint256(3)));
        vm.prank(GUARDIAN); kernel.pause();
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.PAUSED));
        _assertBuybackDisabled(buybackPolicy,buybackExecutor);
        bytes32 ident=keccak256("matrix-strategy"); bytes32 risk=keccak256("matrix-risk"); bytes32 venue=keccak256("matrix-venue");
        LifecycleAdapter adapter=new LifecycleAdapter(ident,risk,venue); StrategyExecutor exec=StrategyExecutor(payable(kernel.strategyExecutor()));
        vm.prank(ADMIN); exec.proposeStrategy(address(adapter),ident,risk,venue); vm.warp(block.timestamp+24 hours);
        vm.prank(ADMIN); exec.activateStrategy(address(adapter)); vm.prank(GUARDIAN); kernel.resume();
        vm.prank(address(0xA11CE)); vm.expectRevert(); settlement.startRun(11,address(adapter),1 ether,keccak256("allocation-11"));

        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.startRun(11,address(adapter),1 ether,keccak256("allocation-11"));
        assertEq(kernel.activePrincipal(),1 ether); assertEq(kernel.cumulativeRealizedProfit(),0);
        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.requestExit(11,keccak256("exit-11")); vm.deal(address(adapter),1 ether);
        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.closeRun(11,keccak256("close-11"));
        assertEq(kernel.cumulativeRealizedProfit(),0); assertEq(kernel.buybackReserve(),0); assertEq(kernel.protocolReserve(),0); assertEq(kernel.holderRewardReserve(),0);

        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.startRun(12,address(adapter),1 ether,keccak256("allocation-12"));
        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.requestExit(12,keccak256("exit-12")); vm.deal(address(adapter),1.1 ether);
        vm.prank(kernel.AUTOMATION_EXECUTOR()); settlement.closeRun(12,keccak256("close-12"));
        assertEq(kernel.cumulativeRealizedProfit(),0.1 ether); assertEq(kernel.strategyCapital(),10 ether+0.065 ether);
        assertEq(kernel.buybackReserve(),0.015 ether); assertEq(kernel.holderRewardReserve(),0.01 ether);
        assertEq(kernel.protocolReserve(),0.01 ether); assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);
        assertEq(kernel.activePrincipal(),0); assertEq(kernel.accountedQuote(),100.1 ether);
        assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        vm.prank(GUARDIAN); kernel.initiateShutdown(72 hours);
        assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING));
        _assertBuybackDisabled(buybackPolicy,buybackExecutor);
    }

    function _assertBuybackDisabled(address policy,address executor) private {
        vm.expectRevert(Kernel.QuotePolicyUnavailable.selector); kernel.activateBuyback(bytes32(uint256(1)));
        vm.expectRevert(); Policy(policy).attempt(bytes32(uint256(1)),bytes32(uint256(2)));
        vm.expectRevert(); BuybackExecutor(payable(executor)).executeExactInput(bytes32(uint256(1)),bytes32(uint256(2)));
    }
}
