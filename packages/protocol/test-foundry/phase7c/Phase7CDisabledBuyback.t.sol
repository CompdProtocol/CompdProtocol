// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CompdBuybackExecutorDisabledV1} from "../../contracts/production/v2/phase7c/CompdBuybackExecutorDisabledV1.sol";
import {CompdVaultKernelV2R2} from "../../contracts/production/v2/phase7ar2/CompdVaultKernelV2R2.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdBuybackPolicyModuleR2} from "../../contracts/production/v2/phase7ar2/CompdBuybackPolicyModuleR2.sol";
import {CompdRecoveryModuleR2} from "../../contracts/production/v2/phase7ar2/CompdRecoveryModuleR2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";

contract Phase7CDisabledBuybackTest is Test {
    address constant ADMIN = 0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;

    function testBindsImmutablyToPredictedKernelAndRejectsZero() public {
        address predictedKernel = address(0xBEEF);
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(predictedKernel);
        assertEq(executor.boundKernel(), predictedKernel);
        vm.expectRevert(CompdBuybackExecutorDisabledV1.InvalidKernel.selector);
        new CompdBuybackExecutorDisabledV1(address(0));
    }

    function testUnauthorizedCallerCannotExecute() public {
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(address(0xBEEF));
        vm.expectRevert(CompdBuybackExecutorDisabledV1.Unauthorized.selector);
        executor.executeExactInput(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function testBoundKernelCannotSpendEvenWithValueAndValueIsRolledBack() public {
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(address(this));
        vm.deal(address(this), 1 ether);
        uint256 beforeBalance = address(this).balance;
        vm.expectRevert(CompdBuybackExecutorDisabledV1.BuybackDisabled.selector);
        executor.executeExactInput{value: 0.25 ether}(bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(address(executor).balance, 0);
        assertEq(address(this).balance, beforeBalance);
    }

    function testNoGenericExecutionOrWithdrawalSelectors() public {
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(address(this));
        (bool ok,) = address(executor).call(abi.encodeWithSignature("execute(address,bytes)", address(0xCAFE), hex"deadbeef"));
        assertFalse(ok);
        (ok,) = address(executor).call(abi.encodeWithSignature("withdraw(address,uint256)", address(0xCAFE), 1));
        assertFalse(ok);
        (ok,) = address(executor).call(abi.encodeWithSignature("setKernel(address)", address(0xCAFE)));
        assertFalse(ok);
    }

    function testForcedSurplusCannotBeWithdrawnOrUsed() public {
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(address(this));
        ForceBNB force = new ForceBNB{value: 0.5 ether}();
        force.force(payable(address(executor)));
        assertEq(address(executor).balance, 0.5 ether);
        vm.expectRevert(CompdBuybackExecutorDisabledV1.BuybackDisabled.selector);
        executor.executeExactInput{value: 0}(bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(address(executor).balance, 0.5 ether);
    }

    function testPredictedKernelDeploymentAndR2ModuleBindingRehearsal() public {
        FixtureDependency distributor = new FixtureDependency();
        FixtureDependency liability = new FixtureDependency();
        FixtureRecoveryEvidence recoveryEvidence = new FixtureRecoveryEvidence();

        // Four external dependencies are created before the Kernel in the planner:
        // Distributor, Liability, Recovery Evidence, and this executor. The evidence
        // fixture always reports incomplete reconciliation, so termination stays blocked.
        address predictedKernel = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(predictedKernel);
        CompdVaultKernelV2R2 kernel = new CompdVaultKernelV2R2(
            address(0xE001), address(0xE002), address(executor), address(distributor), address(liability), address(recoveryEvidence)
        );
        assertEq(address(kernel), predictedKernel);
        assertEq(executor.boundKernel(), address(kernel));
        assertEq(kernel.buybackExecutor(), address(executor));
        assertFalse(kernel.buybackActivated());

        CompdSettlementModuleV2R4 settlement = new CompdSettlementModuleV2R4(address(kernel), kernel.strategyExecutor());
        CompdHolderModuleV2 holder = new CompdHolderModuleV2(address(kernel), address(distributor), address(liability));
        CompdBuybackPolicyModuleR2 buyback = new CompdBuybackPolicyModuleR2(address(kernel), address(0), bytes32(0));
        CompdRecoveryModuleR2 recovery = new CompdRecoveryModuleR2(address(kernel), address(recoveryEvidence));
        CompdEmergencyScopeRegistryV2 registry = new CompdEmergencyScopeRegistryV2(address(kernel));
        CompdEmergencyModuleV2 emergency = new CompdEmergencyModuleV2(address(kernel), address(registry));

        vm.prank(ADMIN);
        registry.bindEmergencyModule(address(emergency));
        address[6] memory modules = [address(settlement), address(holder), address(buyback), address(recovery), address(emergency), address(registry)];
        vm.prank(ADMIN);
        kernel.bindModules(modules);
        assertTrue(kernel.modulesBound());
        assertFalse(kernel.buybackActivated());
        assertFalse(recovery.terminationReady());
        vm.expectRevert(CompdVaultKernelV2R2.InvalidLifecycle.selector);
        vm.prank(ADMIN);
        kernel.activateBuyback(bytes32(0));
        vm.expectRevert(CompdBuybackPolicyModuleR2.Disabled.selector);
        vm.prank(AUTOMATION);
        buyback.attempt(bytes32(uint256(1)), bytes32(uint256(2)));
        assertFalse(kernel.buybackActivated());
    }

    function testR2RejectsWrongExecutorBindingWithOtherwiseCommittedModule() public {
        FixtureDependency distributor = new FixtureDependency();
        FixtureDependency liability = new FixtureDependency();
        FixtureRecoveryEvidence recoveryEvidence = new FixtureRecoveryEvidence();
        bytes32 commitment = keccak256("fixture-buyback-commitment");
        FixtureQuote quote = new FixtureQuote(commitment);
        CompdBuybackExecutorDisabledV1 executor = new CompdBuybackExecutorDisabledV1(address(0xBAD));
        CompdVaultKernelV2R2 kernel = new CompdVaultKernelV2R2(
            address(0xE001), address(0xE002), address(executor), address(distributor), address(liability), address(recoveryEvidence)
        );
        CompdSettlementModuleV2R4 settlement = new CompdSettlementModuleV2R4(address(kernel), kernel.strategyExecutor());
        CompdHolderModuleV2 holder = new CompdHolderModuleV2(address(kernel), address(distributor), address(liability));
        CompdBuybackPolicyModuleR2 buyback = new CompdBuybackPolicyModuleR2(address(kernel), address(quote), commitment);
        CompdRecoveryModuleR2 recovery = new CompdRecoveryModuleR2(address(kernel), address(recoveryEvidence));
        CompdEmergencyScopeRegistryV2 registry = new CompdEmergencyScopeRegistryV2(address(kernel));
        CompdEmergencyModuleV2 emergency = new CompdEmergencyModuleV2(address(kernel), address(registry));
        vm.prank(ADMIN);
        registry.bindEmergencyModule(address(emergency));
        address[6] memory modules = [address(settlement), address(holder), address(buyback), address(recovery), address(emergency), address(registry)];
        vm.prank(ADMIN);
        kernel.bindModules(modules);

        vm.expectRevert(CompdVaultKernelV2R2.InvalidConfiguration.selector);
        vm.prank(ADMIN);
        kernel.activateBuyback(commitment);
        assertFalse(kernel.buybackActivated());
    }
}

contract FixtureDependency {}
contract FixtureRecoveryEvidence {
    function recoveryReconciliationComplete() external pure returns (bool) { return false; }
}
contract FixtureQuote {
    bytes32 public immutable commitment;
    constructor(bytes32 commitment_) { commitment = commitment_; }
    function policyCommitment() external view returns (bytes32) { return commitment; }
    function isExecutable(bytes32, uint256) external pure returns (bool) { return true; }
}

contract ForceBNB {
    constructor() payable {}
    function force(address payable target) external { selfdestruct(target); }
}
