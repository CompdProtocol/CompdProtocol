// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdVaultKernelV2R2} from "../../contracts/production/v2/phase7ar2/CompdVaultKernelV2R2.sol";
import {CompdStrategyExecutorV2R2} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdRecoveryModuleR2} from "../../contracts/production/v2/phase7ar2/CompdRecoveryModuleR2.sol";
import {CompdBuybackPolicyModuleR2} from "../../contracts/production/v2/phase7ar2/CompdBuybackPolicyModuleR2.sol";
import {R2BuybackExecutor,R2Distributor,R2Liability,R2RecoveryEvidence} from "./Phase7AR2.t.sol";

contract R2ZeroAdapterHandler is Test {
    CompdVaultKernelV2R2 immutable kernel;
    CompdSettlementModuleV2R4 immutable settlement;
    constructor(CompdVaultKernelV2R2 k,CompdSettlementModuleV2R4 s){kernel=k;settlement=s;}
    function attemptAllocate(address candidate,uint96 rawAmount,bytes32 salt) external {
        uint256 amount=bound(uint256(rawAmount),1,10 ether);
        vm.prank(address(settlement));
        (bool ok,)=address(kernel).call(abi.encodeCall(kernel.allocateStrategyPrincipal,(uint256(uint256(salt)),candidate,amount,keccak256(abi.encode(salt,candidate)) )));
        assertFalse(ok,"zero-adapter deployment must reject allocation");
    }
}

contract Phase7AR2InvariantTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    uint64 constant TEST_ADMISSION_TIMELOCK=24 hours;
    uint256 constant BOOTSTRAP=100 ether; uint256 constant SEED=10 ether;
    CompdVaultKernelV2R2 kernel;
    CompdSettlementModuleV2R4 settlement;
    R2ZeroAdapterHandler handler;

    function setUp() public {
        R2BuybackExecutor buyExec=new R2BuybackExecutor(address(0));R2Distributor d=new R2Distributor();R2Liability l=new R2Liability();R2RecoveryEvidence evidence=new R2RecoveryEvidence();
        kernel=new CompdVaultKernelV2R2(address(0xE001),address(0xE002),address(buyExec),address(d),address(l),address(evidence));buyExec.setKernel(address(kernel));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        CompdBuybackPolicyModuleR2 buyback=new CompdBuybackPolicyModuleR2(address(kernel),address(0),bytes32(0));CompdRecoveryModuleR2 recovery=new CompdRecoveryModuleR2(address(kernel),address(evidence));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];vm.prank(ADMIN);kernel.bindModules(modules);
        vm.deal(ADMIN,BOOTSTRAP);vm.prank(ADMIN);kernel.bootstrapTreasury{value:BOOTSTRAP}();vm.prank(ADMIN);kernel.activate();
        handler=new R2ZeroAdapterHandler(kernel,settlement);targetContract(address(handler));
    }

    function invariant_NoAdmittedAdapterMeansNoPrincipalExposure() public view {
        CompdStrategyExecutorV2R2 executor=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));
        assertEq(executor.adapterCount(),0);assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),SEED);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);
        assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.holderRewardReserve(),0);
        assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertLe(kernel.activePrincipal(),kernel.strategyCapital());assertGe(kernel.accountedQuote(),kernel.holderRewardReserve());
    }
}
