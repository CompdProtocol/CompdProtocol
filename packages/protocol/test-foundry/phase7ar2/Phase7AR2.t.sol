// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {C2G2BTypes as T,IC2G2BHolderDistributor,IC2G2BHolderLiability,IC2G2BRecoveryEvidence,IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdVaultKernelV2R2} from "../../contracts/production/v2/phase7ar2/CompdVaultKernelV2R2.sol";
import {CompdStrategyExecutorV2R2} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdRecoveryModuleR2} from "../../contracts/production/v2/phase7ar2/CompdRecoveryModuleR2.sol";
import {CompdBuybackPolicyModuleR2} from "../../contracts/production/v2/phase7ar2/CompdBuybackPolicyModuleR2.sol";

contract R2BuybackExecutor {
    address public boundKernel;
    constructor(address k){boundKernel=k;}
    function setKernel(address k) external {boundKernel=k;}
    function executeExactInput(bytes32,bytes32) external payable {require(msg.sender==boundKernel);revert("disabled");}
}
contract ForceBNB { constructor() payable {} function force(address payable target) external { selfdestruct(target); } }
contract R2Distributor is IC2G2BHolderDistributor {
    T.HolderPayment private _payment;bytes32 private _digest;bool private _proof;
    function configure(T.HolderPayment calldata p,bytes32 digest) external {_payment=p;_digest=digest;_proof=true;}
    function paymentData(bytes32) external view returns(T.HolderPayment memory,bool){return(_payment,_proof);}
    function paymentDigest(bytes32) external view returns(bytes32){return _digest;}
    function consumePayment(bytes32,bytes32) external {_proof=false;}
    function canonicalPayment(bytes32) external view returns(bytes32,address,address,uint256,uint8,bool){return(_digest,_payment.recipient,_payment.asset,_payment.amount,_payment.distributionStatus,_proof);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R2Liability is IC2G2BHolderLiability {
    T.HolderPayment private _payment;bytes32 private _digest;bool private _valid;
    function configure(T.HolderPayment calldata p,bytes32 digest) external {_payment=p;_digest=digest;_valid=true;}
    function paymentDigest(bytes32) external view returns(bytes32){return _digest;}
    function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external view returns(bytes32,address,address,uint256,uint8,bool){return(_digest,_payment.recipient,_payment.asset,_payment.amount,_payment.liabilityStatus,_valid);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R2RecoveryEvidence is IC2G2BRecoveryEvidence {
    mapping(bytes32=>uint256) public treasuryAmount;
    mapping(bytes32=>bool) public treasuryConsumed;
    function setTreasuryAmount(bytes32 id,uint256 amount) external {treasuryAmount[id]=amount;treasuryConsumed[id]=false;}
    function protocolReserveRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function treasuryPrincipalRecovery(bytes32 id) external view returns(bool,uint256){return(!treasuryConsumed[id]&&treasuryAmount[id]!=0,treasuryAmount[id]);}
    function noRecipientRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function expiredHolderRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function consumeProtocolReserve(bytes32) external pure {}
    function consumeTreasuryPrincipal(bytes32 id) external {treasuryConsumed[id]=true;}
    function consumeNoRecipient(bytes32) external pure {}
    function consumeExpiredHolder(bytes32) external pure {}
    function recoveryReconciliationComplete() external pure returns(bool){return true;}
}
contract R2Adapter is IC2G2BStrategyAdapterR4 {
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

abstract contract Phase7AR2Fixture is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    uint64 constant TEST_ADMISSION_TIMELOCK=24 hours;
    CompdVaultKernelV2R2 kernel;
    CompdSettlementModuleV2R4 settlement;
    CompdEmergencyModuleV2 emergency;
    CompdEmergencyScopeRegistryV2 registry;
    CompdBuybackPolicyModuleR2 buyback;
    R2Distributor distributor;
    R2Liability liability;
    CompdHolderModuleV2 holder;
    R2BuybackExecutor buyExecutor;
    R2RecoveryEvidence recoveryEvidence;
    CompdRecoveryModuleR2 recovery;
    R2Adapter adapter;

    function setUp() public virtual {}
    function _deploy(bool bind) internal {
        R2Distributor d=new R2Distributor();R2Liability l=new R2Liability();R2RecoveryEvidence r=new R2RecoveryEvidence();recoveryEvidence=r;distributor=d;liability=l;
        buyExecutor=new R2BuybackExecutor(address(0));
        kernel=new CompdVaultKernelV2R2(address(0xE001),address(0xE002),address(buyExecutor),address(d),address(l),address(r));
        vm.prank(address(this)); // Kernel-bound mock receives the eventual immutable Kernel identity.
        buyExecutor.setKernel(address(kernel));
        registry=new CompdEmergencyScopeRegistryV2(address(kernel));
        emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        buyback=new CompdBuybackPolicyModuleR2(address(kernel),address(0),bytes32(0));
        recovery=new CompdRecoveryModuleR2(address(kernel),address(r));
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
        R2Distributor d=new R2Distributor();R2Liability l=new R2Liability();R2RecoveryEvidence r=new R2RecoveryEvidence();recoveryEvidence=r;distributor=d;liability=l;
        buyExecutor=new R2BuybackExecutor(address(0));
        kernel=new CompdVaultKernelV2R2(address(0xE001),address(0xE002),address(buyExecutor),address(d),address(l),address(r));
        buyExecutor.setKernel(address(kernel));
        registry=new CompdEmergencyScopeRegistryV2(address(kernel));
        emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        buyback=new CompdBuybackPolicyModuleR2(address(kernel),address(0),bytes32(0));
        recovery=new CompdRecoveryModuleR2(address(kernel),address(r));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));
        address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        vm.prank(ADMIN);kernel.bindModules(modules);
    }
    function _seedActivate() internal {vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();vm.prank(ADMIN);kernel.activate();}

}

contract Phase7AR2Test1 is Phase7AR2Fixture {
    function testExecutorAndKernelDeployWithZeroAdapters() public {_deploy(false);assertEq(CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor())).adapterCount(),0);assertFalse(CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor())).isApprovedStrategy(address(0xA11CE)));assertEq(kernel.strategyCapital(),0);}
    function testAdminCannotActivateBeforeBindings() public {_deploy(false);vm.deal(ADMIN,1 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:1 ether}();vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertFalse(kernel.hasActivated());}
    function testGuardianCannotResumeGenesisPause() public { _readyAndBound();vm.expectRevert();vm.prank(GUARDIAN);kernel.resume();assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.PAUSED));assertFalse(kernel.hasActivated());}
    function testAdminCannotActivateBeforeSeed() public { _readyAndBound();vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertFalse(kernel.hasActivated());}
    function testFirstActivationAndOperationalPauseResumeLatch() public { _readyAndBound();_seedActivate();assertTrue(kernel.hasActivated());vm.prank(GUARDIAN);kernel.pause();vm.prank(GUARDIAN);kernel.resume();assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.ACTIVE));vm.expectRevert();vm.prank(ADMIN);kernel.activate();assertTrue(kernel.hasActivated()); }
    function testShutdownDoesNotEraseActivationHistory() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.SHUTDOWN_PENDING)); }
    function testEmergencySweepPreservesLogicalTreasuryAndHolderAccounting() public { _readyAndBound();_seedActivate();uint256 beforeNtp=kernel.nonStrategyTreasuryPrincipal();uint256 beforeAQ=kernel.accountedQuote();uint256 beforeProfit=kernel.cumulativeRealizedProfit();uint256 beforeHR=kernel.holderRewardReserve();vm.prank(address(0xE001));kernel.emergencyEnter();assertTrue(kernel.hasActivated());assertEq(uint8(kernel.lifecycle()),uint8(T.Lifecycle.EMERGENCY_RECOVERY));bytes32 scope=keccak256("emergency-bnb");bytes32 attempt=keccak256("emergency-attempt");bytes32[] memory ids=new bytes32[](1);ids[0]=scope;uint8[] memory kinds=new uint8[](1);kinds[0]=uint8(T.ScopeKind.BNB);vm.prank(address(0xE001));emergency.initialize(ids,kinds);vm.prank(address(0xE001));emergency.recoverBNB(scope,attempt,1,1 ether,keccak256("verified-transfer"));assertEq(kernel.nonStrategyTreasuryPrincipal(),beforeNtp);assertEq(kernel.accountedQuote(),beforeAQ);assertEq(kernel.cumulativeRealizedProfit(),beforeProfit);assertEq(kernel.holderRewardReserve(),beforeHR);assertEq(kernel.activePrincipal(),0);assertEq(kernel.emergencyBNBOutflow(),1 ether);assertEq(address(kernel).balance,beforeAQ-1 ether);assertEq(address(0xE002).balance,1 ether);assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());vm.expectRevert();vm.prank(GUARDIAN);kernel.resume();assertTrue(kernel.hasActivated()); }
}

contract Phase7AR2Test2 is Phase7AR2Fixture {
    function testBootstrapThreeBNBPartitionsExactTenNinetyWithNoProfit() public { _readyAndBound();vm.deal(ADMIN,3 ether);vm.recordLogs();vm.prank(ADMIN);kernel.bootstrapTreasury{value:3 ether}();Vm.Log[] memory logs=vm.getRecordedLogs();assertEq(kernel.strategyCapital(),0.3 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),2.7 ether);assertEq(kernel.accountedQuote(),3 ether);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());for(uint256 i;i<logs.length;++i)assertNotEq(logs[i].topics[0],keccak256("StrategySettled(uint256,uint256,uint256,uint256,uint256,bytes32)")); }
    function testBootstrapRoundsDownAndKeepsRemainder() public { _readyAndBound();vm.deal(ADMIN,19);vm.prank(ADMIN);kernel.bootstrapTreasury{value:19}();assertEq(kernel.strategyCapital(),1);assertEq(kernel.nonStrategyTreasuryPrincipal(),18);assertEq(kernel.accountedQuote(),19); }
    function testOneWeiBootstrapKeepsDustInNonStrategyBucket() public { _readyAndBound();vm.deal(ADMIN,1);vm.prank(ADMIN);kernel.bootstrapTreasury{value:1}();assertEq(kernel.strategyCapital(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),1);assertEq(kernel.accountedQuote(),1); }
    function testBootstrapCannotRepeatOrUseZeroOrUnauthorizedCaller() public { _readyAndBound();vm.deal(ADMIN,4 ether);vm.expectRevert();vm.prank(ADMIN);kernel.bootstrapTreasury();vm.expectRevert();vm.prank(address(0xA11CE));kernel.bootstrapTreasury{value:1 ether}();vm.prank(ADMIN);kernel.bootstrapTreasury{value:1 ether}();vm.expectRevert();vm.prank(ADMIN);kernel.bootstrapTreasury{value:1 ether}();assertEq(kernel.strategyCapital(),0.1 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),0.9 ether); }
    function testSeedCreditsOnlySCAndAQ() public { _readyAndBound();vm.deal(ADMIN,2 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:2 ether}();assertEq(kernel.strategyCapital(),0.2 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),1.8 ether);assertEq(kernel.accountedQuote(),2 ether);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0); }
    function testUnaccountedForcedBNBCannotIncreaseStrategyAllocationCapacity() public { _readyAndBound();_seedActivate();ForceBNB forceSend=new ForceBNB{value:50 ether}();forceSend.force(payable(address(kernel)));uint256 strategyBefore=kernel.strategyCapital();assertEq(kernel.strategyCapital(),10 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(address(kernel).balance,kernel.accountedQuote()+50 ether);assertEq(kernel.strategyCapital(),strategyBefore);vm.expectRevert();vm.prank(address(settlement));kernel.allocateStrategyPrincipal(88,address(0xA11CE),10.01 ether,keccak256("forced-surplus"));assertEq(kernel.activePrincipal(),0); }
    function testStrategyCannotConsumeNonStrategyTreasuryPrincipal() public { _readyAndBound();_seedActivate();vm.expectRevert();vm.prank(address(settlement));kernel.allocateStrategyPrincipal(87,address(0xA11CE),0.31 ether,keccak256("non-strategy"));assertEq(kernel.strategyCapital(),10 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.activePrincipal(),0); }
    function testApprovedStrategyCannotAllocateAgainstTheNinetyPercentBucket() public { _readyAndBound();vm.deal(ADMIN,3 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:3 ether}();vm.prank(ADMIN);kernel.activate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("approved-id"),keccak256("approved-risk"),keccak256("approved-venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("approved-id"),keccak256("approved-risk"),keccak256("approved-venue"));vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();assertTrue(exec.isApprovedStrategy(address(adapter)));vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(300,address(adapter),0.31 ether,keccak256("above-sc"));vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(301,address(adapter),2.7 ether,keccak256("entire-ntp"));assertEq(kernel.strategyCapital(),0.3 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),2.7 ether);assertEq(kernel.activePrincipal(),0);assertEq(kernel.accountedQuote(),3 ether); }
    function testR2HolderPaymentLeavesTreasuryPrincipalAndIdentityIntact() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("holder-adapter"),keccak256("holder-risk"),keccak256("holder-venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("holder-adapter"),keccak256("holder-risk"),keccak256("holder-venue"));vm.warp(block.timestamp+24 hours);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(401,address(adapter),1 ether,keccak256("holder-profit-allocation"));vm.prank(AUTOMATION);settlement.requestExit(401,keccak256("holder-profit-exit"));vm.deal(address(adapter),1.1 ether);vm.prank(AUTOMATION);settlement.closeRun(401,keccak256("holder-profit-close"));assertEq(kernel.holderRewardReserve(),0.01 ether);T.HolderPayment memory p;p.windowId=keccak256("window");p.distributionId=keccak256("distribution");p.version=1;p.index=0;p.root=keccak256("root");p.lineage=keccak256("lineage");p.leafId=keccak256("leaf");p.recipient=address(0xBEEF);p.asset=address(0);p.amount=0.01 ether;p.distributionStatus=1;p.liabilityStatus=1;p.finalizedAt=uint64(block.timestamp);p.expiresAt=0;p.recoveryStatus=0;p.useId=keccak256("use");bytes32 digest=keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,address(kernel),p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));distributor.configure(p,digest);liability.configure(p,digest);uint256 recipientBefore=p.recipient.balance;vm.prank(AUTOMATION);assertTrue(holder.pay(p.leafId));assertEq(p.recipient.balance,recipientBefore+p.amount);assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.accountedQuote(),100.09 ether);assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal()); }
    function testTerminatedNormalRecoveryMovesOnlyProvenTreasuryPrincipal() public { _readyAndBound();vm.deal(ADMIN,3 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:3 ether}();bytes32 id=keccak256("treasury-principal-recovery");recoveryEvidence.setTreasuryAmount(id,0.9 ether);vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(block.timestamp+72 hours);vm.prank(GUARDIAN);kernel.terminate();vm.prank(GUARDIAN);recovery.recoverTreasuryPrincipal(id);assertEq(kernel.nonStrategyTreasuryPrincipal(),1.8 ether);assertEq(kernel.strategyCapital(),0.3 ether);assertEq(kernel.accountedQuote(),2.1 ether);assertEq(address(kernel).balance,2.1 ether);assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());vm.expectRevert();vm.prank(GUARDIAN);recovery.recoverTreasuryPrincipal(id); }
    function testDisabledBuybackDoesNotGateActivationAndCannotExecute() public { _readyAndBound();_seedActivate();assertFalse(kernel.buybackActivated());vm.expectRevert();vm.prank(AUTOMATION);buyback.attempt(keccak256("op"),keccak256("quote"));assertEq(kernel.buybackReserve(),0); }
    function testZeroAdaptersCannotAllocatePrincipal() public { _readyAndBound();_seedActivate();uint256 ap=kernel.activePrincipal();vm.expectRevert();vm.prank(address(settlement));kernel.allocateStrategyPrincipal(1,address(0xA11CE),1 ether,keccak256("allocation"));assertEq(kernel.activePrincipal(),ap);assertEq(kernel.strategyCapital(),10 ether); }
    function testFuzz_SeedPreservesPrincipalAndBuckets(uint96 raw) public { _readyAndBound();uint256 amount=bound(uint256(raw),1,100 ether);vm.deal(ADMIN,amount);vm.prank(ADMIN);kernel.bootstrapTreasury{value:amount}();uint256 allocation=amount/10;assertEq(kernel.strategyCapital(),allocation);assertEq(kernel.nonStrategyTreasuryPrincipal(),amount-allocation);assertEq(kernel.accountedQuote(),amount);assertEq(kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.strategyCapital()+kernel.nonStrategyTreasuryPrincipal()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal()); }
}

contract Phase7AR2Test3 is Phase7AR2Fixture {
    function testAdmissionTimelockThenTypedExecutionOnly() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));uint256 sc=kernel.strategyCapital();uint256 ntp=kernel.nonStrategyTreasuryPrincipal();uint256 br=kernel.buybackReserve();uint256 pr=kernel.protocolReserve();uint256 hr=kernel.holderRewardReserve();uint256 aq=kernel.accountedQuote();uint256 ap=kernel.activePrincipal();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertEq(kernel.strategyCapital(),sc);assertEq(kernel.nonStrategyTreasuryPrincipal(),ntp);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.holderRewardReserve(),hr);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.activePrincipal(),ap);vm.warp(block.timestamp+24 hours-1);vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.warp(block.timestamp+1);vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertTrue(exec.isApprovedStrategy(address(adapter)));assertEq(kernel.strategyCapital(),sc);assertEq(kernel.nonStrategyTreasuryPrincipal(),ntp);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);assertEq(kernel.holderRewardReserve(),hr);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.activePrincipal(),ap);vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(10,address(adapter),1 ether,keccak256("alloc10"));assertEq(kernel.activePrincipal(),1 ether); }
    function testGuardianCanVetoProposalButCannotAdmitOrReenable() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.expectRevert();vm.prank(GUARDIAN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.prank(GUARDIAN);exec.cancelStrategyProposal(address(adapter));vm.expectRevert();vm.prank(GUARDIAN);exec.activateStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter))); }
    function testChangedAdapterCodeDuringTimelockFailsClosed() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_TIMELOCK);vm.etch(address(adapter),hex"60006000fd");vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter))); }
    function testPostAdmissionRiskCommitmentDriftBlocksRun() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_TIMELOCK);vm.prank(ADMIN);exec.activateStrategy(address(adapter));adapter.setRisk(keccak256("changed-risk"));vm.prank(GUARDIAN);kernel.resume();vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(24,address(adapter),1 ether,keccak256("alloc24"));assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),10 ether); }
    function testAdminCannotBypassProposalAndDuplicateAdapterAdmission() public { _readyAndBound();_seedActivate();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.expectRevert();vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.pause();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_TIMELOCK);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));assertEq(exec.adapterCount(),1);assertTrue(exec.isApprovedStrategy(address(adapter)));}
    function testZeroCommitmentAndWrongCommitmentCannotBeAdmitted() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),bytes32(0),keccak256("venue"));vm.expectRevert();vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("wrong-risk"),keccak256("venue"));assertEq(exec.adapterCount(),0); }
    function testFuzz_UnadmittedAddressNeverPassesExecutionGate(address candidate) public {_deploy(false); CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));assertFalse(exec.isApprovedStrategy(candidate)); }
    function testExecutorExposesNoGenericArbitraryCall() public {_deploy(false);CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));(bool ok,)=address(exec).call(abi.encodeWithSignature("execute(address,bytes)",address(0xBEEF),hex"deadbeef"));assertFalse(ok);}
}

contract Phase7AR2Test4 is Phase7AR2Fixture {
    function testGuardianDisableBlocksNewRunButPreservesExitSettlement() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_TIMELOCK);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(22,address(adapter),1 ether,keccak256("alloc22"));vm.prank(AUTOMATION);settlement.requestExit(22,keccak256("exit22"));vm.prank(GUARDIAN);exec.disableStrategy(address(adapter));assertFalse(exec.isApprovedStrategy(address(adapter)));vm.expectRevert();vm.prank(AUTOMATION);settlement.startRun(23,address(adapter),1 ether,keccak256("alloc23"));vm.deal(address(adapter),1 ether);vm.prank(AUTOMATION);settlement.closeRun(22,keccak256("close22"));assertEq(kernel.activePrincipal(),0); }
    function testBuybackDisabledDoesNotBlockSettlementOrProfitAccounting() public { _readyAndBound();_seedActivate();vm.prank(GUARDIAN);kernel.pause();adapter=new R2Adapter(keccak256("id"),keccak256("risk"),keccak256("venue"));CompdStrategyExecutorV2R2 exec=CompdStrategyExecutorV2R2(payable(kernel.strategyExecutor()));vm.prank(ADMIN);exec.proposeStrategy(address(adapter),keccak256("id"),keccak256("risk"),keccak256("venue"));vm.warp(block.timestamp+TEST_ADMISSION_TIMELOCK);vm.prank(ADMIN);exec.activateStrategy(address(adapter));vm.prank(GUARDIAN);kernel.resume();vm.prank(AUTOMATION);settlement.startRun(12,address(adapter),1 ether,keccak256("alloc12"));vm.prank(AUTOMATION);settlement.requestExit(12,keccak256("exit12"));vm.deal(address(adapter),1.1 ether);vm.prank(AUTOMATION);settlement.closeRun(12,keccak256("close12"));assertEq(kernel.buybackReserve(),0.015 ether);assertEq(kernel.strategyCapital(),10.065 ether);assertEq(kernel.holderRewardReserve(),0.01 ether);assertEq(kernel.protocolReserve(),0.01 ether);assertFalse(kernel.buybackActivated());vm.expectRevert();vm.prank(AUTOMATION);buyback.attempt(keccak256("op"),keccak256("quote"));assertEq(kernel.buybackReserve(),0.015 ether);assertEq(kernel.activePrincipal(),0); }
}




