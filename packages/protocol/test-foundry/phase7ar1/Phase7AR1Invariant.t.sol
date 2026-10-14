// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar1/C2G2BTypesR1.sol";
import {CompdVaultKernelV2R1} from "../../contracts/production/v2/phase7ar1/CompdVaultKernelV2R1.sol";
import {CompdStrategyExecutorV2R1} from "../../contracts/production/v2/phase7ar1/CompdStrategyExecutorV2R1.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdRecoveryModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdRecoveryModuleV2.sol";
import {CompdBuybackPolicyModuleR1} from "../../contracts/production/v2/phase7ar1/CompdBuybackPolicyModuleR1.sol";
import {R1BuybackExecutor,R1Distributor,R1Liability,R1RecoveryEvidence} from "./Phase7AR1.t.sol";

contract R1ZeroAdapterHandler is Test {
    CompdVaultKernelV2R1 immutable kernel;
    CompdSettlementModuleV2R4 immutable settlement;
    constructor(CompdVaultKernelV2R1 k,CompdSettlementModuleV2R4 s){kernel=k;settlement=s;}
    function attemptAllocate(address candidate,uint96 rawAmount,bytes32 salt) external {
        uint256 amount=bound(uint256(rawAmount),1,10 ether);
        vm.prank(address(settlement));
        (bool ok,)=address(kernel).call(abi.encodeCall(kernel.allocateStrategyPrincipal,(uint256(uint256(salt)),candidate,amount,keccak256(abi.encode(salt,candidate)) )));
        assertFalse(ok,"zero-adapter deployment must reject allocation");
    }
}

contract Phase7AR1InvariantTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    uint64 constant TEST_DELAY=1 days;
    uint256 constant SEED=10 ether;
    CompdVaultKernelV2R1 kernel;
    CompdSettlementModuleV2R4 settlement;
    R1ZeroAdapterHandler handler;

    function setUp() public {
        R1BuybackExecutor buyExec=new R1BuybackExecutor(address(0));R1Distributor d=new R1Distributor();R1Liability l=new R1Liability();R1RecoveryEvidence evidence=new R1RecoveryEvidence();
        kernel=new CompdVaultKernelV2R1(address(0xE001),address(0xE002),TEST_DELAY,address(buyExec),address(d),address(l),address(evidence));buyExec.setKernel(address(kernel));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        CompdBuybackPolicyModuleR1 buyback=new CompdBuybackPolicyModuleR1(address(kernel),address(0),bytes32(0));CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(evidence));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];vm.prank(ADMIN);kernel.bindModules(modules);
        vm.deal(ADMIN,SEED);vm.prank(ADMIN);kernel.seedStrategyCapital{value:SEED}();vm.prank(ADMIN);kernel.activate();
        handler=new R1ZeroAdapterHandler(kernel,settlement);targetContract(address(handler));
    }

    function invariant_NoAdmittedAdapterMeansNoPrincipalExposure() public view {
        CompdStrategyExecutorV2R1 executor=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));
        assertEq(executor.adapterCount(),0);assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),SEED);
        assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.holderRewardReserve(),0);
        assertEq(kernel.strategyCapital()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertLe(kernel.activePrincipal(),kernel.strategyCapital());assertGe(kernel.accountedQuote(),kernel.holderRewardReserve());
    }
}
