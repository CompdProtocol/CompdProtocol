// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";
import {CompdHolderDistributorV3 as Distributor} from "../../contracts/production/v3/phase7cr2ch/CompdHolderDistributorV3.sol";
import {CompdHolderLiabilityV3 as Liability} from "../../contracts/production/v3/phase7cr2ch/CompdHolderLiabilityV3.sol";
import {CompdRecoveryEvidenceV3 as RecoveryEvidence} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryEvidenceV3.sol";
import {CompdRecoveryModuleV3 as Recovery} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryModuleV3.sol";
import {CompdHolderModuleV3 as Holder} from "../../contracts/production/v3/phase7cr2ch/CompdHolderModuleV3.sol";
import {CompdSettlementModuleV3 as Settlement} from "../../contracts/production/v3/phase7cr2ch/CompdSettlementModuleV3.sol";
import {CompdDisabledBuybackPolicyModuleV3 as BuybackPolicy} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackPolicyModuleV3.sol";
import {CompdEmergencyModuleV3 as Emergency} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyModuleV3.sol";
import {CompdEmergencyScopeRegistryV3 as Registry} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyScopeRegistryV3.sol";
import {CompdDisabledBuybackExecutorV3 as BuybackExecutor} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackExecutorV3.sol";
import {CompdStrategyExecutorV2R2 as StrategyExecutor} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";

contract GraphModuleDeployer {
    function candidate(address k,address s,address d,address f,address t) external returns(address){return address(new Candidate(k,s,d,f,t));}
    function state(address k,address d,address l,address e,address f,address c,address t,bytes32 ch) external returns(address){return address(new State(k,d,l,e,f,c,t,ch));}
    function distributor(address k,address s,address c,address f) external returns(address){return address(new Distributor(k,s,c,f));}
    function liability(address k,address s) external returns(address){return address(new Liability(k,s));}
    function evidence(address k,address s) external returns(address){return address(new RecoveryEvidence(k,s));}
    function recovery(address k,address e,bytes32 h) external returns(address){return address(new Recovery(k,e,h));}
    function holder(address k,address d,address l,address s) external returns(address){return address(new Holder(k,d,l,s));}
    function settlement(address k,address e,bytes32 h) external returns(address){return address(new Settlement(k,e,h));}
    function buybackPolicy(address k) external returns(address){return address(new BuybackPolicy(k));}
    function emergency(address k,address r) external returns(address){return address(new Emergency(k,r));}
    function registry(address k,address e) external returns(address){return address(new Registry(k,e));}
    function buybackExecutor(address k) external returns(address){return address(new BuybackExecutor(k));}
}

contract GraphKernelDeployer {
    function deploy(address emergencyAuthority,address emergencyWallet,address buyback,address distributor,address liability,address evidence,address candidate,address token,address[6] memory modules,bytes32[13] memory hashes) external returns(address){return address(new Kernel(emergencyAuthority,emergencyWallet,buyback,distributor,liability,evidence,candidate,token,modules,hashes));}
}

contract Phase7CR2CIGraphTest is Test {
    address private constant FINALIZER = address(0xF1A1);
    address private constant TOKEN = address(0x70C0);
    address private constant CONFIG_ADMIN = 0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;

    function testImmutableKernelLastGraphPredictionsAndDisabledBuyback() public {
        GraphModuleDeployer md = new GraphModuleDeployer();
        GraphKernelDeployer kd = new GraphKernelDeployer();
        assertEq(vm.getNonce(address(md)),1);
        assertEq(vm.getNonce(address(kd)),1);
        address predictedKernel = vm.computeCreateAddress(address(kd), 1);
        address predictedCandidate = vm.computeCreateAddress(address(md), 1);
        address predictedState = vm.computeCreateAddress(address(md), 2);
        address predictedDistributor = vm.computeCreateAddress(address(md), 3);
        address predictedLiability = vm.computeCreateAddress(address(md), 4);
        address predictedEvidence = vm.computeCreateAddress(address(md), 5);
        address predictedRecovery = vm.computeCreateAddress(address(md), 6);
        address predictedHolder = vm.computeCreateAddress(address(md), 7);
        address predictedSettlement = vm.computeCreateAddress(address(md), 8);
        address predictedBuybackPolicy = vm.computeCreateAddress(address(md), 9);
        address predictedEmergency = vm.computeCreateAddress(address(md), 10);
        address predictedRegistry = vm.computeCreateAddress(address(md), 11);
        address predictedBuybackExecutor = vm.computeCreateAddress(address(md), 12);
        address predictedStrategyExecutor = vm.computeCreateAddress(predictedKernel, 1);

        address candidate = md.candidate(predictedKernel,predictedState,predictedDistributor,FINALIZER,TOKEN);
        assertEq(candidate,predictedCandidate);
        address state = md.state(predictedKernel,predictedDistributor,predictedLiability,predictedEvidence,FINALIZER,candidate,TOKEN,candidate.codehash);
        assertEq(state,predictedState);
        address distributor = md.distributor(predictedKernel,state,candidate,FINALIZER);
        assertEq(distributor,predictedDistributor);
        address liability = md.liability(predictedKernel,state);
        assertEq(liability,predictedLiability);
        address evidence = md.evidence(predictedKernel,state);
        assertEq(evidence,predictedEvidence);
        address recovery = md.recovery(predictedKernel,evidence,evidence.codehash);
        assertEq(recovery,predictedRecovery);
        address holder = md.holder(predictedKernel,distributor,liability,state);
        assertEq(holder,predictedHolder);

        address strategyHashProbe = address(new StrategyExecutor(predictedKernel,CONFIG_ADMIN,GUARDIAN));
        bytes32 strategyHash = strategyHashProbe.codehash;
        address settlement = md.settlement(predictedKernel,predictedStrategyExecutor,strategyHash);
        assertEq(settlement,predictedSettlement);
        address buybackPolicy = md.buybackPolicy(predictedKernel);
        assertEq(buybackPolicy,predictedBuybackPolicy);
        address emergency = md.emergency(predictedKernel,predictedRegistry);
        assertEq(emergency,predictedEmergency);
        address registry = md.registry(predictedKernel,emergency);
        assertEq(registry,predictedRegistry);
        address buybackExecutor = md.buybackExecutor(predictedKernel);
        assertEq(buybackExecutor,predictedBuybackExecutor);

        address[6] memory modules = [settlement,holder,buybackPolicy,recovery,emergency,registry];
        bytes32[13] memory hashes = [strategyHash,buybackExecutor.codehash,distributor.codehash,liability.codehash,evidence.codehash,candidate.codehash,state.codehash,settlement.codehash,holder.codehash,buybackPolicy.codehash,recovery.codehash,emergency.codehash,registry.codehash];
        address kernel = kd.deploy(address(0xA11CE),address(0xB0B),buybackExecutor,distributor,liability,evidence,candidate,TOKEN,modules,hashes);
        assertEq(kernel,predictedKernel);
        assertEq(vm.getNonce(address(md)),13);
        assertEq(vm.getNonce(address(kd)),2);
        assertEq(vm.getNonce(kernel),2);
        assertEq(Kernel(payable(kernel)).strategyExecutor(),predictedStrategyExecutor);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.SETTLEMENT),settlement);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.HOLDER),holder);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.BUYBACK),buybackPolicy);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.RECOVERY),recovery);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.EMERGENCY),emergency);
        assertEq(Kernel(payable(kernel)).moduleAddress(T.ModuleId.REGISTRY),registry);
        assertEq(Registry(registry).emergencyModule(),emergency);
        assertEq(Emergency(emergency).registry(),registry);
        assertEq(Kernel(payable(kernel)).moduleHash(5),registry.codehash);

        vm.expectRevert(BuybackExecutor.Disabled.selector);
        BuybackExecutor(payable(buybackExecutor)).executeExactInput(bytes32(uint256(1)),bytes32(uint256(2)));
        (bool rebound,) = registry.call(abi.encodeWithSignature("bindEmergencyModule(address)",address(0xBAD)));
        assertFalse(rebound);
        vm.expectRevert(Kernel.QuotePolicyUnavailable.selector);
        Kernel(payable(kernel)).activateBuyback(bytes32(uint256(1)));
    }

    function testForwardReferencedConstructorsDoNotRequireKernelCode() public {
        address futureKernel = address(0x123456);
        address futureExecutor = address(0x234567);
        address futureRegistry = address(0x345678);
        Settlement s = new Settlement(futureKernel,futureExecutor,bytes32(uint256(1)));
        Emergency e = new Emergency(futureKernel,futureRegistry);
        Registry r = new Registry(futureKernel,address(e));
        BuybackExecutor b = new BuybackExecutor(futureKernel);
        BuybackPolicy p = new BuybackPolicy(futureKernel);
        assertEq(s.kernel(),futureKernel);
        assertEq(e.kernel(),futureKernel);
        assertEq(r.kernel(),futureKernel);
        assertEq(b.boundKernel(),futureKernel);
        assertEq(p.kernel(),futureKernel);
    }

    function testKernelRejectsNonzeroButWrongExpectedStrategyExecutorHash() public {
        GraphModuleDeployer md = new GraphModuleDeployer();
        GraphKernelDeployer kd = new GraphKernelDeployer();
        address k = vm.computeCreateAddress(address(kd),1);
        address c = vm.computeCreateAddress(address(md),1);
        address s = vm.computeCreateAddress(address(md),2);
        address d = vm.computeCreateAddress(address(md),3);
        address l = vm.computeCreateAddress(address(md),4);
        address e = vm.computeCreateAddress(address(md),5);
        address r = vm.computeCreateAddress(address(md),6);
        address h = vm.computeCreateAddress(address(md),7);
        address settle = vm.computeCreateAddress(address(md),8);
        address bp = vm.computeCreateAddress(address(md),9);
        address em = vm.computeCreateAddress(address(md),10);
        address reg = vm.computeCreateAddress(address(md),11);
        address be = vm.computeCreateAddress(address(md),12);
        address candidate = md.candidate(k,s,d,FINALIZER,TOKEN);
        address state = md.state(k,d,l,e,FINALIZER,candidate,TOKEN,candidate.codehash);
        address distributor = md.distributor(k,state,candidate,FINALIZER);
        address liability = md.liability(k,state);
        address evidence = md.evidence(k,state);
        address recovery = md.recovery(k,evidence,evidence.codehash);
        address holder = md.holder(k,distributor,liability,state);
        address strategyProbe = address(new StrategyExecutor(k,CONFIG_ADMIN,GUARDIAN));
        address settlement = md.settlement(k,vm.computeCreateAddress(k,1),strategyProbe.codehash);
        address policy = md.buybackPolicy(k);
        address emergency = md.emergency(k,reg);
        address registry = md.registry(k,emergency);
        address buybackExecutor = md.buybackExecutor(k);
        assertEq(candidate,c);assertEq(state,s);assertEq(distributor,d);assertEq(liability,l);assertEq(evidence,e);
        assertEq(recovery,r);assertEq(holder,h);assertEq(settlement,settle);assertEq(policy,bp);assertEq(emergency,em);assertEq(registry,reg);assertEq(buybackExecutor,be);
        address[6] memory modules=[settlement,holder,policy,recovery,emergency,registry];
        bytes32[13] memory hashes=[bytes32(uint256(1)),buybackExecutor.codehash,distributor.codehash,liability.codehash,evidence.codehash,candidate.codehash,state.codehash,settlement.codehash,holder.codehash,policy.codehash,recovery.codehash,emergency.codehash,registry.codehash];
        vm.expectPartialRevert(Kernel.ExpectedCodeHashMismatch.selector);
        kd.deploy(address(0xA11CE),address(0xB0B),buybackExecutor,distributor,liability,evidence,candidate,TOKEN,modules,hashes);
    }

    function testKernelRejectsZeroExpectedStrategyExecutorHash() public {
        GraphModuleDeployer md = new GraphModuleDeployer();
        GraphKernelDeployer kd = new GraphKernelDeployer();
        address k = vm.computeCreateAddress(address(kd),1);
        address c = vm.computeCreateAddress(address(md),1);
        address s = vm.computeCreateAddress(address(md),2);
        address d = vm.computeCreateAddress(address(md),3);
        address l = vm.computeCreateAddress(address(md),4);
        address e = vm.computeCreateAddress(address(md),5);
        address candidate = md.candidate(k,s,d,FINALIZER,TOKEN);
        address state = md.state(k,d,l,e,FINALIZER,candidate,TOKEN,candidate.codehash);
        address distributor = md.distributor(k,state,candidate,FINALIZER);
        address liability = md.liability(k,state);
        address evidence = md.evidence(k,state);
        address recovery = md.recovery(k,evidence,evidence.codehash);
        address holder = md.holder(k,distributor,liability,state);
        address strategyProbe = address(new StrategyExecutor(k,CONFIG_ADMIN,GUARDIAN));
        address settlement = md.settlement(k,vm.computeCreateAddress(k,1),strategyProbe.codehash);
        address policy = md.buybackPolicy(k);
        address emergency = md.emergency(k,vm.computeCreateAddress(address(md),11));
        address registry = md.registry(k,emergency);
        address buybackExecutor = md.buybackExecutor(k);
        address[6] memory modules=[settlement,holder,policy,recovery,emergency,registry];
        bytes32[13] memory hashes=[bytes32(0),buybackExecutor.codehash,distributor.codehash,liability.codehash,evidence.codehash,candidate.codehash,state.codehash,settlement.codehash,holder.codehash,policy.codehash,recovery.codehash,emergency.codehash,registry.codehash];
        vm.expectRevert(Kernel.InvalidConfiguration.selector);
        kd.deploy(address(0xA11CE),address(0xB0B),buybackExecutor,distributor,liability,evidence,candidate,TOKEN,modules,hashes);
    }

}
