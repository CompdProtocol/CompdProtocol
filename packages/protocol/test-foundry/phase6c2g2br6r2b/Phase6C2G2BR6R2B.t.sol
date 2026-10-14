// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T,IC2G2BHolderDistributor,IC2G2BHolderLiability,IC2G2BRecoveryEvidence} from "../../contracts/production/v2/phase6c2g2br4/C2G2BTypes.sol";
import {CompdVaultKernelV2R6R2B} from "../../contracts/production/v2/phase6c2g2br6r2b/CompdVaultKernelV2R6R2B.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdRecoveryModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdRecoveryModuleV2.sol";
import {CompdBuybackPolicyModuleR6R2B,IExactInputBuybackQuoteR6R2B} from "../../contracts/production/v2/phase6c2g2br6r2b/CompdBuybackPolicyModuleR6R2B.sol";
import {CompdStrategyExecutorV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdStrategyExecutorV2R4.sol";
import {ReferenceStrategyAdapterR4} from "../phase6c2g2br4/ReferenceStrategyAdapterR4.sol";

contract R6R2BMockCompd {
    uint256 public totalSupply=1e30;
    mapping(address=>uint256) public balanceOf;
    constructor(){balanceOf[address(0xBEEF)]=totalSupply;}
    function swapOutput(address to,uint256 amount) external {require(balanceOf[address(0xBEEF)]>=amount);balanceOf[address(0xBEEF)]-=amount;balanceOf[to]+=amount;}
    function burn(address from,uint256 amount) external {require(balanceOf[from]>=amount);balanceOf[from]-=amount;totalSupply-=amount;}
}

contract R6R2BExecutorMock {
    address public boundKernel;
    address payable public immutable sink;
    R6R2BMockCompd public immutable compd;
    address public forceTarget;
    uint8 public mode;
    error BadCaller(); error ExecutionFailed();
    constructor(address payable sink_){sink=sink_;compd=new R6R2BMockCompd();}
    function bindKernel(address k) external {require(msg.sender==0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9&&boundKernel==address(0)&&k.code.length!=0);boundKernel=k;}
    function configure(uint8 mode_,address forceTarget_) external {require(msg.sender==0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9);mode=mode_;forceTarget=forceTarget_;}
    function executeExactInput(bytes32,bytes32) external payable {
        if(msg.sender!=boundKernel)revert BadCaller();
        if(mode==1)revert ExecutionFailed();
        if(mode==2){(bool ok,)=boundKernel.call(abi.encodeWithSignature("releaseBuyback(bytes32,uint256,bytes32)",keccak256("reenter"),1,keccak256("q")));if(ok)revert ExecutionFailed();}
        (bool sent,)=sink.call{value:msg.value}("");if(!sent)revert ExecutionFailed();
        if(mode==3){ForceBNB(payable(forceTarget)).force(payable(boundKernel));}
        uint256 supplyBefore=compd.totalSupply();uint256 balanceBefore=compd.balanceOf(address(this));
        if(mode!=5)compd.swapOutput(address(this),msg.value*100); // reference physical COMPD output
        uint256 received=compd.balanceOf(address(this))-balanceBefore;if(received==0)revert ExecutionFailed();
        if(mode==7)revert ExecutionFailed(); // burn failure
        uint256 burnAmount=mode==8?received-1:received;compd.burn(address(this),burnAmount);
        if(supplyBefore-compd.totalSupply()!=received)revert ExecutionFailed();
        if(mode==4)revert ExecutionFailed(); // downstream failure after simulated swap and burn
    }
    receive() external payable {}
}

contract ForceBNB { constructor() payable {} function force(address payable to) external {selfdestruct(to);} }

contract R6R2BQuoteMock is IExactInputBuybackQuoteR6R2B {
    bytes32 public immutable override policyCommitment;
    bool public executable=true;
    constructor(bytes32 c){policyCommitment=c;}
    function setExecutable(bool v) external {executable=v;}
    function isExecutable(bytes32 q,uint256 x) external view returns(bool){return executable&&q!=bytes32(0)&&x!=0;}
}

contract R6R2BDistributor is IC2G2BHolderDistributor {
    function paymentData(bytes32) external pure returns(T.HolderPayment memory,bool){return(T.HolderPayment(bytes32(0),bytes32(0),0,0,bytes32(0),bytes32(0),bytes32(0),address(0),address(0),0,0,0,0,0,0,bytes32(0)),false);}
    function paymentDigest(bytes32) external pure returns(bytes32){return bytes32(0);} function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(bytes32(0),address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R6R2BLiability is IC2G2BHolderLiability {
    function paymentDigest(bytes32) external pure returns(bytes32){return bytes32(0);} function consumePayment(bytes32,bytes32) external pure {}
    function canonicalPayment(bytes32) external pure returns(bytes32,address,address,uint256,uint8,bool){return(bytes32(0),address(0),address(0),0,0,false);}
    function terminalReconciliation() external pure returns(bytes32,uint256){return(keccak256("empty"),0);}
}
contract R6R2BRecoveryEvidence is IC2G2BRecoveryEvidence {
    function protocolReserveRecovery(bytes32) external pure returns(bool,uint256){return(false,0);} function noRecipientRecovery(bytes32) external pure returns(bool,uint256){return(false,0);}
    function expiredHolderRecovery(bytes32) external pure returns(bool,uint256){return(false,0);} function consumeProtocolReserve(bytes32) external pure {}
    function consumeNoRecipient(bytes32) external pure {} function consumeExpiredHolder(bytes32) external pure {}
    function recoveryReconciliationComplete() external pure returns(bool){return true;}
}

contract Phase6C2G2BR6R2BTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address constant EMERGENCY_AUTHORITY=address(0xE001);
    bytes32 constant POLICY=keccak256("frozen test policy");
    ReferenceStrategyAdapterR4 adapter;
    R6R2BExecutorMock buyExecutor;
    R6R2BQuoteMock quote;
    CompdVaultKernelV2R6R2B kernel;
    CompdSettlementModuleV2R4 settlement;
    CompdBuybackPolicyModuleR6R2B buyback;

    function setUp() public virtual {
        adapter=new ReferenceStrategyAdapterR4();buyExecutor=new R6R2BExecutorMock(payable(address(0xD00D)));
        R6R2BDistributor d=new R6R2BDistributor();R6R2BLiability l=new R6R2BLiability();R6R2BRecoveryEvidence r=new R6R2BRecoveryEvidence();
        address[] memory approved=new address[](1);approved[0]=address(adapter);
        kernel=new CompdVaultKernelV2R6R2B(EMERGENCY_AUTHORITY,address(0xE002),approved,address(buyExecutor),address(d),address(l),address(r));
        vm.prank(ADMIN);buyExecutor.bindKernel(address(kernel));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());
        CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(d),address(l));
        quote=new R6R2BQuoteMock(POLICY);buyback=new CompdBuybackPolicyModuleR6R2B(address(kernel),address(quote),POLICY);
        CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(r));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));
        address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        vm.prank(ADMIN);kernel.bindModules(modules);
        vm.prank(ADMIN);kernel.activateBuyback(POLICY);
        vm.deal(ADMIN,101 ether);vm.prank(ADMIN);kernel.seedStrategyCapital{value:100 ether}();vm.prank(ADMIN);kernel.activate();
        _createBuybackReserve(10 ether,20 ether);
    }

    function _createBuybackReserve(uint256 principal,uint256 returned) internal {
        uint256 id=uint256(keccak256(abi.encode(principal,returned,block.timestamp)));
        vm.prank(AUTOMATION);settlement.startRun(id,address(adapter),principal,keccak256(abi.encode("alloc",id)));
        vm.prank(AUTOMATION);settlement.requestExit(id,keccak256(abi.encode("exit",id)));
        bytes32 position=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);
        vm.deal(address(adapter),returned);adapter.setCash(position,returned);adapter.setTerminal(position,true);
        vm.prank(AUTOMATION);settlement.closeRun(id,keccak256(abi.encode("close",id)));
    }

    function _attempt(bytes32 id) internal {vm.prank(AUTOMATION);buyback.attempt(id,keccak256("quote"));}
    function _configureExecutor(uint8 mode,address forceTarget) internal {vm.prank(ADMIN);buyExecutor.configure(mode,forceTarget);}

    function testExactInputIsTheAccountingSpendAndRingEntry() public {
        uint256 beforeReserve=kernel.buybackReserve();uint256 beforeSink=address(0xD00D).balance;
        uint256 beforeSC=kernel.strategyCapital();uint256 beforePR=kernel.protocolReserve();uint256 beforeHR=kernel.holderRewardReserve();
        _attempt(keccak256("success"));
        assertEq(kernel.buybackReserve(),beforeReserve-0.3 ether);
        assertEq(kernel.accountedQuote(),109.7 ether);
        assertEq(kernel.strategyCapital(),beforeSC);assertEq(kernel.protocolReserve(),beforePR);assertEq(kernel.holderRewardReserve(),beforeHR);
        assertEq(address(0xD00D).balance,beforeSink+0.3 ether);
        assertEq(buyback.ringCount(),1);(,uint256 spend)=buyback.spendAt(0);assertEq(spend,0.3 ether);
        assertEq(buyback.lastSuccessfulBuybackAt(),block.timestamp);
    }

    function testDownstreamFailureRollsBackExactInputAndPolicy() public {
        _configureExecutor(4,address(0));uint256 br=kernel.buybackReserve();uint256 aq=kernel.accountedQuote();uint256 sink=address(0xD00D).balance;
        vm.expectRevert();_attempt(keccak256("failed"));
        assertEq(kernel.buybackReserve(),br);assertEq(kernel.accountedQuote(),aq);assertEq(address(0xD00D).balance,sink);
        assertEq(buyback.ringCount(),0);assertEq(buyback.lastSuccessfulBuybackAt(),0);assertFalse(buyback.operationUsed(keccak256("failed")));
    }

    function testForcedBNBBeforeAndDuringExecutionDoesNotChangeX() public {
        vm.deal(address(kernel),address(kernel).balance+1 ether);
        ForceBNB forced=new ForceBNB{value:0.2 ether}();_configureExecutor(3,address(forced));
        uint256 br=kernel.buybackReserve();_attempt(keccak256("forced"));
        assertEq(kernel.buybackReserve(),br-0.3 ether);(,uint256 spend)=buyback.spendAt(0);assertEq(spend,0.3 ether);
        assertEq(address(kernel).balance,kernel.accountedQuote()+1.2 ether);
    }

    function testForcedBNBAtExecutorBeforeCallFailsClosed() public {
        vm.deal(address(buyExecutor),1);uint256 br=kernel.buybackReserve();
        vm.expectRevert();_attempt(keccak256("executor-donation"));
        assertEq(kernel.buybackReserve(),br);assertEq(buyback.ringCount(),0);
    }

    function testReserveTriggerAndExactInputHardCap() public {
        _createBuybackReserve(10 ether,30 ether); // +20 profit => +3 BNB to BR
        assertEq(kernel.buybackReserve(),4.5 ether);
        _attempt(keccak256("hard-cap"));(,uint256 amount)=buyback.spendAt(0);
        assertEq(amount,0.5 ether);assertEq(address(0xD00D).balance,0.5 ether);
    }

    function testKernelRejectsOneWeiAboveTwentyPercent() public {
        uint256 br=kernel.buybackReserve();
        vm.prank(address(buyback));vm.expectRevert();kernel.releaseBuyback(keccak256("over-20"),0.3 ether+1,keccak256("quote"));
        assertEq(kernel.buybackReserve(),br);
    }

    function testKernelRejectsOneWeiAboveAbsoluteCap() public {
        _createBuybackReserve(10 ether,30 ether);uint256 br=kernel.buybackReserve();
        vm.prank(address(buyback));vm.expectRevert();kernel.releaseBuyback(keccak256("over-50"),0.5 ether+1,keccak256("quote"));
        assertEq(kernel.buybackReserve(),br);
    }

    function testQuoteOutputAndBurnFailuresRollbackAccounting() public {
        uint256 br=kernel.buybackReserve();uint256 aq=kernel.accountedQuote();
        quote.setExecutable(false);vm.expectRevert();_attempt(keccak256("bad-quote"));
        quote.setExecutable(true);_configureExecutor(5,address(0));
        vm.expectRevert();_attempt(keccak256("no-output"));
        _configureExecutor(7,address(0));vm.expectRevert();_attempt(keccak256("burn-fails"));
        _configureExecutor(8,address(0));vm.expectRevert();_attempt(keccak256("supply-mismatch"));
        assertEq(kernel.buybackReserve(),br);assertEq(kernel.accountedQuote(),aq);assertEq(buyback.ringCount(),0);
    }

    function testShutdownPendingAndEmergencyRecoveryReject() public {
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.expectRevert();_attempt(keccak256("shutdown"));
    }

    function testTerminatedRejectsBuyback() public {
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);vm.warp(259_201);
        vm.prank(GUARDIAN);kernel.terminate();vm.expectRevert();_attempt(keccak256("terminated"));
    }

    function testEmergencyRecoveryRejectsBuyback() public {
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();vm.expectRevert();_attempt(keccak256("emergency"));
    }

    function testReentrantExecutorCannotCreateSecondRelease() public {
        _configureExecutor(2,address(0));uint256 br=kernel.buybackReserve();_attempt(keccak256("reentry"));
        assertEq(kernel.buybackReserve(),br-0.3 ether);assertEq(buyback.ringCount(),1);
    }

    function testCooldownAndRollingCohortCapUseSuccessfulXOnly() public {
        _attempt(keccak256("first"));vm.warp(21_601);_attempt(keccak256("second"));
        assertEq(buyback.ringCount(),2);assertEq(buyback.cohortReserveSnapshot(),1.5 ether);
        vm.warp(43_201);_attempt(keccak256("third-clipped"));
        assertEq(kernel.buybackReserve(),0.9 ether);assertEq(buyback.ringCount(),3);
        vm.warp(64_801);vm.expectRevert();_attempt(keccak256("fourth-over-cohort"));
        assertEq(kernel.buybackReserve(),0.9 ether);assertEq(buyback.ringCount(),3);
    }

    function testExactTrailingWindowExpiryBoundary() public {
        _attempt(keccak256("boundary-1"));vm.warp(21_601);_attempt(keccak256("boundary-2"));
        vm.warp(43_201);_attempt(keccak256("boundary-3"));
        vm.warp(86_400);vm.expectRevert();_attempt(keccak256("one-second-before-expiry"));
        assertEq(buyback.ringCount(),3);
        vm.warp(86_401);_attempt(keccak256("exact-expiry"));
        assertEq(buyback.ringCount(),3);assertEq(buyback.cohortReserveSnapshot(),1.5 ether);
        (uint64 oldest,)=buyback.spendAt(0);assertEq(oldest,21_601);
    }

    function testReserveDepositsDoNotExpandActiveCohortCap() public {
        vm.warp(1);
        _attempt(keccak256("deposit-cohort-1"));
        vm.warp(21_601);_attempt(keccak256("deposit-cohort-2"));
        assertEq(buyback.cohortReserveSnapshot(),1.5 ether);
        assertEq(kernel.buybackReserve(),0.96 ether);
        _createBuybackReserve(10 ether,30 ether); // +3 BNB enters BR after the cohort was frozen.
        assertEq(kernel.buybackReserve(),3.96 ether);
        assertEq(buyback.cohortReserveSnapshot(),1.5 ether);
        vm.warp(43_201);_attempt(keccak256("deposit-cohort-clipped"));
        assertEq(kernel.buybackReserve(),3.90 ether);
        assertEq(buyback.cohortReserveSnapshot(),1.5 ether);
        (,uint256 finalSpend)=buyback.spendAt(buyback.ringCount()-1);
        assertEq(finalSpend,0.06 ether);
    }

    function testEpochZeroSuccessStillEnforcesCooldown() public {
        vm.warp(0);_attempt(keccak256("epoch-zero-first"));
        vm.expectRevert();_attempt(keccak256("epoch-zero-immediate-second"));
        assertEq(buyback.ringCount(),1);
        vm.warp(6 hours);_attempt(keccak256("epoch-zero-cooldown-expired"));
        assertEq(buyback.ringCount(),2);
    }

    function testSuccessfulOperationCannotBeReplayed() public {
        bytes32 id=keccak256("one-operation-only");_attempt(id);
        uint256 reserve=kernel.buybackReserve();uint8 count=buyback.ringCount();uint64 at=buyback.lastSuccessfulBuybackAt();
        vm.warp(block.timestamp+6 hours);vm.expectRevert();_attempt(id);
        assertEq(kernel.buybackReserve(),reserve);assertEq(buyback.ringCount(),count);assertEq(buyback.lastSuccessfulBuybackAt(),at);
    }

    function testReserveBelowTriggerRejectsAfterFourFrozenCohorts() public {
        uint256 start=1;
        for(uint256 cohort;cohort<3;++cohort){
            vm.warp(start);_attempt(keccak256(abi.encode("trigger-first",cohort)));
            vm.warp(start+6 hours);_attempt(keccak256(abi.encode("trigger-second",cohort)));
            vm.warp(start+12 hours);_attempt(keccak256(abi.encode("trigger-third",cohort)));
            start+=36 hours+1;
        }
        vm.warp(start);_attempt(keccak256("trigger-fourth-first"));
        vm.warp(start+6 hours);_attempt(keccak256("trigger-fourth-second"));
        vm.warp(start+12 hours);
        assertLt(kernel.buybackReserve(),0.25 ether);
        uint256 reserve=kernel.buybackReserve();uint8 count=buyback.ringCount();
        vm.expectRevert();_attempt(keccak256("below-trigger"));
        assertEq(kernel.buybackReserve(),reserve);assertEq(buyback.ringCount(),count);
    }

    function testFuzz_ExactInputSpendPreservesBucketInvariant(uint96 rawProfit) public {
        uint256 profit=bound(uint256(rawProfit),1,5 ether);
        _createBuybackReserve(10 ether,10 ether+profit);
        uint256 beforeReserve=kernel.buybackReserve();
        uint256 expected=beforeReserve*2_000/10_000;if(expected>0.50 ether)expected=0.50 ether;
        _attempt(keccak256(abi.encode("fuzz-exact",rawProfit)));
        assertEq(beforeReserve-kernel.buybackReserve(),expected);
        (,uint256 recorded)=buyback.spendAt(0);assertEq(recorded,expected);
        assertEq(kernel.strategyCapital()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertGe(address(kernel).balance,kernel.accountedQuote());
    }

    function testFuzz_ForcedKernelBNBDoesNotAlterCommittedInput(uint96 rawDonation) public {
        uint256 donation=bound(uint256(rawDonation),0,5 ether);
        vm.deal(address(kernel),address(kernel).balance+donation);
        uint256 br=kernel.buybackReserve();_attempt(keccak256(abi.encode("fuzz-forced",rawDonation)));
        assertEq(br-kernel.buybackReserve(),0.3 ether);
        (,uint256 recorded)=buyback.spendAt(0);assertEq(recorded,0.3 ether);
        assertEq(address(kernel).balance,kernel.accountedQuote()+donation);
    }

    function testPreActivationQuoteConfigurationAndLifecycleFailClosed() public {
        vm.prank(GUARDIAN);kernel.pause();
        vm.expectRevert();_attempt(keccak256("paused"));
    }
}
