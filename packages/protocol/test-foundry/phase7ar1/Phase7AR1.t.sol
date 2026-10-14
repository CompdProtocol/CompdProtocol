// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T,IC2G2BHolderDistributor,IC2G2BHolderLiability,IC2G2BRecoveryEvidence,IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase7ar1/C2G2BTypesR1.sol";
import {CompdVaultKernelV2R1} from "../../contracts/production/v2/phase7ar1/CompdVaultKernelV2R1.sol";
import {CompdStrategyExecutorV2R1} from "../../contracts/production/v2/phase7ar1/CompdStrategyExecutorV2R1.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdRecoveryModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdRecoveryModuleV2.sol";
import {CompdBuybackPolicyModuleR1} from "../../contracts/production/v2/phase7ar1/CompdBuybackPolicyModuleR1.sol";

contract R1BuybackExecutor {
    address public boundKernel;
    constructor(address k){boundKernel=k;}
    function setKernel(address k) external {boundKernel=k;}
    function executeExactInput(bytes32,bytes32) external payable {require(msg.sender==boundKernel);revert("disabled");}
}
contract R1Distributor is IC2G2BHolderDistributor {
    function paymentData(bytes32) external pure returns(T.HolderPayment memory,bool){return(T.HolderPayment(0,0,0,0,0,0,0,address(0),address(0),0,0,0,0,0,0,0),false);}
    function paymentDigest(bytes32) external pure returns(bytes32){return 0;}
    function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(0,address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R1Liability is IC2G2BHolderLiability {
    function paymentDigest(bytes32) external pure returns(bytes32){return 0;}
    function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(0,address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R1RecoveryEvidence is IC2G2BRecoveryEvidence {
    function protocolReserveRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function noRecipientRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function expiredHolderRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function consumeProtocolReserve(bytes32) external pure {}
    function consumeNoRecipient(bytes32) external pure {}
    function consumeExpiredHolder(bytes32) external pure {}
}
contract R1Adapter is IC2G2BStrategyAdapterR4 {
    bytes32 public immutable overrideIdentity;
    bytes32 public overrideRisk;
    bytes32 public immutable overrideVenue;
    constructor(bytes32 i,bytes32 r,bytes32 v){overrideIdentity=i;overrideRisk=r;overrideVenue=v;}
    function strategyIdentity() external view returns(bytes32){return overrideIdentity;}
    function riskConfigCommitment() external view returns(bytes32){return overrideRisk;}
    function venueDependencyCommitment() external view returns(bytes32){return overrideVenue;}
    function setRisk(bytes32 r) external {overrideRisk=r;}
    function open(uint256,bytes32,uint256,uint256) external payable returns(bytes32){return keccak256(abi.encode(msg.sender,msg.value));}
    function requestExit(bytes32,bytes32) external pure returns(T.AdapterPositionStatus){return T.AdapterPositionStatus.EXIT_REQUESTED;}
    function observe(bytes32) external pure returns(T.AdapterPositionStatus,uint256,bytes32){return(T.AdapterPositionStatus.EXIT_REQUESTED,0,0);}
    function collect(bytes32,bytes32,uint256) external pure returns(uint256,bytes32){return(0,0);}
    function close(bytes32 id,bytes32) external returns(bytes32){uint256 amount=address(this).balance;if(amount!=0){(bool ok,)=msg.sender.call{value:amount}("");require(ok);}return id;}
}

abstract contract Phase7AR1Fixture is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    uint64 constant TEST_ADMISSION_DELAY=1 days;
    CompdVaultKernelV2R1 kernel;
    CompdSettlementModuleV2R4 settlement;
    CompdBuybackPolicyModuleR1 buyback;
    R1BuybackExecutor buyExecutor;
    R1Adapter adapter;

    function setUp() public virtual {}
    function _deploy(bool bind) internal {
        R1Distributor d=new R1Distributor();R1Liability l=new R1Liability();R1RecoveryEvidence r=new R1RecoveryEvidence();
        buyExecutor=new R1BuybackExecutor(address(0));
        kernel=new CompdVaultKernelV2R1(address(0xE001),address(0xE002),TEST_ADMISSION_DELAY,address(buyExecutor),address(d),address(l),address(r));
        vm.prank(address(this)); // Kernel-bound mock receives the eventual immutable Kernel identity.
        buyExecutor.setKernel(address(kernel));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));
        CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        buyback=new CompdBuybackPolicyModuleR1(address(kernel),address(0),bytes32(0));
        CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(r));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));
        address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        if(bind){vm.prank(ADMIN);kernel.bindModules(modules);}
    }
    function _bind() internal {
        // setUp deployed once without binding; reconstruct module addresses through stored refs is intentionally avoided.
        // A separate deployment helper below creates and binds for activation-focused tests.
    }
    function _readyAndBound() internal {
        _deployBound();
    }
    function _deployBound() internal {
        R1Distributor d=new R1Distributor();R1Liability l=new R1Liability();R1RecoveryEvidence r=new R1RecoveryEvidence();
        buyExecutor=new R1BuybackExecutor(address(0));
        kernel=new CompdVaultKernelV2R1(address(0xE001),address(0xE002),TEST_ADMISSION_DELAY,address(buyExecutor),address(d),address(l),address(r));
        buyExecutor.setKernel(address(kernel));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));
        CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        buyback=new CompdBuybackPolicyModuleR1(address(kernel),address(0),bytes32(0));
        CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(r));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));
        address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        vm.prank(ADMIN);kernel.bindModules(modules);
    }
    function _seedActivate() internal {vm.deal(ADMIN,10 ether);vm.prank(ADMIN);kernel.seedStrategyCapital{value:10 ether}();vm.prank(ADMIN);kernel.activate();}

}

contract Phase7AR1Test1 is Phase7AR1Fixture {
    function testExecutorAndKernelDeployWithZeroAdapters() public {_deploy(false);assertEq(CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor())).adapterCount(),0);assertFalse(CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor())).isApprovedStrategy(address(0xA11CE)));assertEq(kernel.strategyCapital(),0);}
    function testAdminCannotActivateBeforeBindings() public {_deploy(false);vm.deal(ADMIN,1 ether);vm.prank(ADMIN);kernel.seedStrategyCapital{value:1 ether}();vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertFalse(kernel.hasActivated());}
    function testGuardianCannotResumeGenesisPause() public { _readyAndBound();vm.expectRevert();vm.prank(GUARDIAN);kernel.resume();assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.PAUSED));assertFalse(kernel.hasActivated());}
    function testAdminCannotActivateBeforeSeed() public { _readyAndBound();vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertFalse(kernel.hasActivated());}
    function testFirstActivationAndOperationalPauseResumeLatch() public { _readyAndBound();_seedActivate();assertTrue(kernel.hasActivated());vm.prank(GUARDIAN);kernel.pause();vm.prank(GUARDIAN);kernel.resume();assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.ACTIVE));vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertTrue(kernel.hasActivated()); }
    function testShutdownDoesNotEraseActivationHistory() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING)); }
    function testEmergencyDoesNotEraseActivationHistoryOrReopenGenesis() public { _readyAndBound();_seedActivate();vm.prank(address(0xE001));kernel.emergencyEnter();assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.EMERGENCY_RECOVERY));vm.expectRevert();vm.prank(GUARDIAN);kernel.resume();assertTrue(kernel.hasActivated()); }
}

contract Phase7AR1Test2 is Phase7AR1Fixture {
    function testSeedCreditsOnlySCAndAQ() public { _readyAndBound();vm.deal(ADMIN,2 ether);vm.prank(ADMIN);kernel.seedStrategyCapital{value:2 ether}();assertEq(kernel.strategyCapital(),2 ether);assertEq(kernel.accountedQuote(),2 ether);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0); }
    function testDisabledBuybackDoesNotGateActivationAndCannotExecute() public { _readyAndBound();_seedActivate();assertFalse(kernel.buybackActivated());vm.expectRevert();vm.prank(AUTOMATION);buyback.attempt(keccak256("op"),keccak256("quote"));assertEq(kernel.buybackReserve(),0); }
    function testZeroAdaptersCannotAllocatePrincipal() public { _readyAndBound();_seedActivate();uint256 ap=kernel.activePrincipal();vm.expectRevert();vm.prank(address(settlement));kernel.allocateStrategyPrincipal(1,address(0xA11CE),1 ether,keccak256("allocation"));assertEq(kernel.activePrincipal(),ap);assertEq(kernel.strategyCapital(),10 ether); }
    function testFuzz_SeedPreservesPrincipalAndBuckets(uint96 raw) public { _readyAndBound();uint256 amount=bound(uint256(raw),1,100 ether);vm.deal(ADMIN,amount);vm.prank(ADMIN);kernel.seedStrategyCapital{value:amount}();assertEq(kernel.strategyCapital(),amount);assertEq(kernel.accountedQuote(),amount);assertEq(kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.strategyCapital()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal()); }
}

contract Phase7AR1Test3 is Phase7AR1Fixture {
    function testAdmissionTimelockThenTypedExecutionOnly() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));uint256 sc=kernel.strategyCapital();uint256 br=kernel.buybackReserve();uint256 pr=kernel.protocolReserve();uint256 hr=kernel.holderRewardReserve();uint256 aq=kernel.accountedQuote();uint256 ap=kernel.activePrincipal();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertEq(kernel.strategyCapital(),sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.holderRewardReserve(),hr);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.activePrincipal(),ap);vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertTrue(exec.isApprovedStrategy(address(adapter)));assertEq(kernel.strategyCapital(),sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.holderRewardReserve(),hr);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.activePrincipal(),ap);vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(10,address(adapter),1 ether,keccak256("alloc10"));assertEq(kernel.activePrincipal(),1 ether); }
    function testGuardianCanVetoProposalButCannotAdmitOrReenable() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.expectRevert();vm.prank(GUARDIAN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.prank(GUARDIAN);exec.cancelStrategyProposal(address(adapter));vm.expectRevert();vm.prank(GUARDIAN);exec.activateStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter))); }
    function testChangedAdapterCodeDuringTimelockFailsClosed() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.etch(address(adapter),hex"60006000fd");vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter))); }
    function testPostAdmissionRiskCommitmentDriftBlocksRun() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.prank(ADMIN);exec.activateStrategy(address(adapter));adapter.setRisk(keccak256("changed-risk"));vm.prank(GUARDIAN);kernel.resume();vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(24,address(adapter),1 ether,keccak256("alloc24"));assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),10 ether); }
    function testAdminCannotBypassProposalAndDuplicateAdapterAdmission() public { _readyAndBound();_seedActivate();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.pause();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));assertEq(exec.adapterCount(),1);assertTrue(exec.isApprovedStrategy(address(adapter)));}
    function testZeroCommitmentAndWrongCommitmentCannotBeAdmitted() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),bytes32(0),keccak256("venue"));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("wrong-risk"),keccak256("venue"));assertEq(exec.adapterCount(),0); }
    function testFuzz_UnadmittedAddressNeverPassesExecutionGate(address candidate) public {_deploy(false); CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));assertFalse(exec.isApprovedStrategy(candidate)); }
    function testExecutorExposesNoGenericArbitraryCall() public {_deploy(false);CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));(bool ok,)=address(exec).call(abi.encodeWithSignature("execute(address,bytes)",address(0xBEEF),hex"deadbeef"));assertFalse(ok);}
}

contract Phase7AR1Test4 is Phase7AR1Fixture {
    function testGuardianDisableBlocksNewRunButPreservesExitSettlement() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(22,address(adapter),1 ether,keccak256("alloc22"));vm.prank(AUTOMATION);settlement.requestExit(22,keccak256("exit22"));vm.prank(GUARDIAN);exec.disableStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter)));vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(23,address(adapter),1 ether,keccak256("alloc23"));vm.deal(address(adapter),1 ether);vm.prank(AUTOMATION);settlement.closeRun(22,keccak256("close22"));assertEq(kernel.activePrincipal(),0); }
    function testBuybackDisabledDoesNotBlockSettlementOrProfitAccounting() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R1Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R1 exec=CompdStrategyExecutorV2R1(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_DELAY);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(12,address(adapter),1 ether,keccak256("alloc12"));vm.prank(AUTOMATION);settlement.requestExit(12,keccak256("exit12"));vm.deal(address(adapter),1.1 ether);vm.prank(AUTOMATION);settlement.closeRun(12,keccak256("close12"));assertEq(kernel.buybackReserve(),0.015 ether);assertEq(kernel.strategyCapital(),10.065 ether);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(kernel.protocolReserve(),0.01 ether);assertFalse(kernel.buybackActivated());vm.expectRevert();vm.prank(AUTOMATION);buyback.attempt(keccak256("op"),keccak256("quote"));assertEq(kernel.buybackReserve(),0.015 ether);assertEq(kernel.activePrincipal(),0); }
}




