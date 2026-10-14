// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "../phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";
import {CompdStrategyExecutorV2R2 as Executor} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {CompdNativeFeeReceiverV3 as Receiver} from "../../contracts/production/v3/phase7cr2ch/CompdNativeFeeReceiverV3.sol";
import {CompdNativeFactoryBindingV3 as Binding,CompdNativeVaultFactoryV3 as Factory} from "../../contracts/flap/CompdNativeVaultFactoryV3.sol";

// Alternate-token constructor exists only in the disposable fixture. Production Factory
// always enforces reserved COMPD CA; shared binding/authentication code is unmodified.
contract FixtureNativeFactory is Binding {constructor(address k) Binding(k){}}
contract NativeFactoryGraph is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant RESERVED=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    Kernel kernel;Receiver receiver;
    function createGraph(address token) internal {
        MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();
        address k=vm.computeCreateAddress(address(kd),1);address st=vm.computeCreateAddress(address(md),2);
        address d=vm.computeCreateAddress(address(md),3);address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);
        address c=md.candidate(k,st,d,address(0xF1A1),token);st=md.state(k,d,l,e,address(0xF1A1),c,token,c.codehash);
        d=md.distributor(k,st,c,address(0xF1A1));l=md.liability(k,st);e=md.evidence(k,st);
        address r=md.recovery(k,e,e.codehash);address h=md.holder(k,d,l,st);
        address probe=address(new Executor(k,ADMIN,GUARDIAN));address executor=vm.computeCreateAddress(k,1);
        address settle=md.settlement(k,executor,probe.codehash);address policy=md.policy(k);
        address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);address bb=md.buyback(k);
        address[6] memory modules=[settle,h,policy,r,em,registry];
        bytes32[13] memory hashes=[probe.codehash,bb.codehash,d.codehash,l.codehash,e.codehash,c.codehash,st.codehash,settle.codehash,h.codehash,policy.codehash,r.codehash,em.codehash,registry.codehash];
        kernel=Kernel(payable(kd.deploy(address(0xA11CE),address(0xB0B),bb,d,l,e,c,token,modules,hashes)));
        receiver=Receiver(payable(kernel.nativeFeeReceiver()));vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();
    }
    function checkAllocation(uint256 fee) internal view {
        uint256 sc=fee*3500/10000;uint256 br=fee*1500/10000;
        assertEq(kernel.strategyCapital(),10 ether+sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),fee-sc-br);
        assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.holderRewardReserve(),0);
        assertEq(kernel.accountedQuote(),100 ether+fee);assertEq(address(kernel).balance,100 ether+fee);
        assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve(),kernel.accountedQuote());
    }
}
