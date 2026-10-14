// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {W02Fixture,T} from "./W02Fixture.sol";
import {CompdNativeFeeReceiverV3 as Receiver} from "../../contracts/production/v3/phase7cr2ch/CompdNativeFeeReceiverV3.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";

contract NativeIngressTarget {
    Receiver public receiver;
    bool public reject;
    bool public probeReentry;
    bool public nestedSucceeded;
    uint256 public credited;
    uint256 public returnSize;
    constructor(){receiver=new Receiver(address(this),0x7b7Af51136574c91A12988989c0a08E98aE97777);}
    function configure(bool r,bool reentry,uint256 size) external {reject=r;probeReentry=reentry;returnSize=size;}
    function creditNativeRevenue() external payable {
        require(msg.sender==address(receiver));require(!reject,"TARGET_REJECT");
        if(probeReentry){(nestedSucceeded,)=address(receiver).call(abi.encodeCall(receiver.forwardPending,()));}
        credited+=msg.value;
        uint256 size=returnSize;if(size!=0)assembly {return(0,size)}
    }
}
contract ForceNative {
    constructor(address payable target) payable {selfdestruct(target);}
}
contract CompdNativeFeeReceiverUnitTest is Test {
    NativeIngressTarget target;Receiver receiver;
    function setUp() public {target=new NativeIngressTarget();receiver=target.receiver();vm.deal(address(this),100 ether);}
    function deposit(uint256 amount,uint256 gasBudget) internal {(bool ok,)=address(receiver).call{value:amount,gas:gasBudget}("");assertTrue(ok);}
    function testReceiveColdStipendAndZeroWakeNoExternalCall() public {
        target.configure(true,false,0);deposit(1 ether,2300);deposit(0,2300);
        assertEq(receiver.pendingBNB(),1 ether);assertEq(target.credited(),0);assertEq(receiver.totalForwarded(),0);
    }
    function testForwardFailureThenRetryConservesAndDoesNotDoubleCredit() public {
        deposit(2 ether,2300);target.configure(true,false,0);assertFalse(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),2 ether);assertEq(receiver.totalForwarded(),0);assertEq(address(target).balance,0);
        target.configure(false,false,0);vm.prank(address(0xBEEF));assertTrue(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),0);assertEq(target.credited(),2 ether);assertEq(receiver.totalForwarded(),2 ether);
        assertEq(address(target).balance,2 ether);assertFalse(receiver.forwardPending());assertEq(target.credited(),2 ether);
    }
    function testReentrancyCannotCreditTwice() public {
        deposit(1 ether,2300);target.configure(false,true,0);assertTrue(receiver.forwardPending());
        assertFalse(target.nestedSucceeded());assertEq(target.credited(),1 ether);assertEq(receiver.totalForwarded(),1 ether);
    }
    function testLargeReturnDataDoesNotNeedCopy() public {
        deposit(1 ether,2300);target.configure(false,false,65536);assertTrue(receiver.forwardPending());
        assertEq(target.credited(),1 ether);assertEq(receiver.pendingBNB(),0);
    }
    function testForcedNativeBalanceIsNotLostOrFalselyAttributed() public {
        new ForceNative{value:1 ether}(payable(address(receiver)));assertEq(receiver.pendingBNB(),1 ether);
        assertTrue(receiver.forwardPending());assertEq(target.credited(),1 ether);
    }
    function testNoArbitraryWithdrawalOrFallback() public {
        deposit(1 ether,2300);(bool ok,)=address(receiver).call(abi.encodeWithSignature("withdraw(address,uint256)",address(this),1 ether));
        assertFalse(ok);assertEq(receiver.pendingBNB(),1 ether);
    }
    function testFuzzRepeatedReceiveFailureAndRetry(uint96 a,uint96 b) public {
        uint256 first=bound(a,1,10 ether);uint256 second=bound(b,0,10 ether);
        deposit(first,2300);target.configure(true,false,0);assertFalse(receiver.forwardPending());deposit(second,2300);
        assertEq(receiver.pendingBNB(),first+second);target.configure(false,false,0);assertTrue(receiver.forwardPending());
        assertEq(target.credited(),first+second);assertEq(receiver.totalForwarded(),first+second);assertEq(receiver.pendingBNB(),0);
    }
}
contract CompdNativeFeeKernelIntegrationTest is W02Fixture {
    Receiver receiver;
    function setUp() public override {super.setUp();receiver=Receiver(payable(kernel.nativeFeeReceiver()));vm.deal(address(this),100 ether);}
    function deposit(uint256 amount) internal {(bool ok,)=address(receiver).call{value:amount,gas:2300}("");assertTrue(ok);}
    function testKernelCreatedPinnedNativeReceiverAndRuntimeLimits() public view {
        assertEq(receiver.kernel(),address(kernel));assertEq(receiver.taxToken(),kernel.eligibilityToken());
        assertEq(address(receiver).codehash,kernel.nativeFeeReceiverHash());assertEq(receiver.vaultQuoteToken(),address(0));assertEq(receiver.vaultSpecVersion(),"v3");
        assertLe(address(kernel).code.length,24576);assertLe(address(receiver).code.length,24576);
    }
    function testExactRevenue351550SeparateFromBootstrap() public {
        deposit(10 ether);vm.prank(address(0xBEEF));assertTrue(receiver.forwardPending());
        assertEq(kernel.strategyCapital(),13.5 ether);assertEq(kernel.buybackReserve(),1.5 ether);assertEq(kernel.protocolReserve(),5 ether);
        assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.holderRewardReserve(),0);
        assertEq(kernel.accountedQuote(),110 ether);assertEq(address(kernel).balance,110 ether);assertEq(receiver.pendingBNB(),0);_assertAccounting();
    }
    function testProfit65151010UnchangedAfterProtocolRevenue() public {
        deposit(10 ether);assertTrue(receiver.forwardPending());_settle(1.1 ether);
        assertEq(kernel.strategyCapital(),13.565 ether);assertEq(kernel.buybackReserve(),1.515 ether);
        assertEq(kernel.protocolReserve(),5.01 ether);assertEq(kernel.holderRewardReserve(),0.01 ether);
        assertEq(kernel.cumulativeRealizedProfit(),0.1 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);_assertAccounting();
    }
    function testUnauthorizedIngressAndPlainTransferRevert() public {
        vm.expectRevert(Kernel.Unauthorized.selector);kernel.creditNativeRevenue{value:1 ether}();
        (bool ok,)=address(kernel).call{value:1 ether}("");assertFalse(ok);assertEq(kernel.accountedQuote(),100 ether);_assertAccounting();
    }
    function testReceiverCodeChangeFailsClosedAndRetainsFunds() public {
        deposit(1 ether);vm.etch(address(receiver),hex"00");vm.expectRevert(Kernel.ExternalCodeChanged.selector);
        vm.prank(address(receiver));kernel.creditNativeRevenue{value:1 ether}();assertEq(address(receiver).balance,1 ether);assertEq(kernel.accountedQuote(),100 ether);
    }
    function testShutdownForwardFailureRetainsAllPending() public {
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);deposit(1 ether);assertFalse(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),1 ether);assertEq(receiver.totalForwarded(),0);assertEq(kernel.accountedQuote(),100 ether);_assertAccounting();
    }
    function testEmergencyForwardFailureRetainsAllPending() public {
        vm.prank(GUARDIAN);kernel.emergencyEnter();deposit(1 ether);assertFalse(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),1 ether);assertEq(kernel.accountedQuote(),100 ether);_assertAccounting();
    }
    function testPausedIngressAndZeroPendingNoop() public {
        vm.prank(GUARDIAN);kernel.pause();assertFalse(receiver.forwardPending());deposit(1 ether);assertTrue(receiver.forwardPending());
        assertEq(kernel.strategyCapital(),10.35 ether);assertEq(kernel.buybackReserve(),0.15 ether);assertEq(kernel.protocolReserve(),0.5 ether);_assertAccounting();
    }
    function testFuzzExactRoundingAndConservation(uint96 raw) public {
        uint256 amount=bound(raw,1,10 ether);deposit(amount);assertTrue(receiver.forwardPending());
        uint256 sc=amount*3500/10000;uint256 br=amount*1500/10000;uint256 pr=amount-sc-br;
        assertEq(kernel.strategyCapital(),10 ether+sc);assertEq(kernel.buybackReserve(),br);assertEq(kernel.protocolReserve(),pr);
        assertEq(kernel.holderRewardReserve(),0);assertEq(kernel.accountedQuote(),100 ether+amount);assertEq(address(kernel).balance,100 ether+amount);_assertAccounting();
    }
    /// @dev Explicit physical-solvency fault injection, followed by restoring custody.
    function testRealKernelSolvencyFailureRetryIsAtomic() public {
        vm.deal(address(kernel),99 ether);deposit(1 ether);assertFalse(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),1 ether);assertEq(receiver.totalForwarded(),0);
        assertEq(kernel.accountedQuote(),100 ether);assertEq(kernel.strategyCapital(),10 ether);
        assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),0);assertEq(address(kernel).balance,99 ether);
        vm.deal(address(kernel),100 ether);assertTrue(receiver.forwardPending());
        assertEq(receiver.pendingBNB(),0);assertEq(receiver.totalForwarded(),1 ether);assertEq(kernel.accountedQuote(),101 ether);
        assertEq(kernel.strategyCapital(),10.35 ether);assertEq(kernel.buybackReserve(),0.15 ether);assertEq(kernel.protocolReserve(),0.5 ether);
        assertFalse(receiver.forwardPending());_assertAccounting();
    }
    function testConstrainedForwardGasPreservesCustodyAndRetry() public {
        deposit(1 ether);(bool ok,bytes memory result)=address(receiver).call{gas:30000}(abi.encodeCall(receiver.forwardPending,()));
        if(ok)assertFalse(abi.decode(result,(bool)));
        assertEq(receiver.pendingBNB(),1 ether);assertEq(receiver.totalForwarded(),0);assertEq(kernel.accountedQuote(),100 ether);
        assertTrue(receiver.forwardPending());assertEq(receiver.pendingBNB(),0);assertEq(kernel.accountedQuote(),101 ether);_assertAccounting();
    }
    function testRepeatedTinyDepositsDustToProtocolNoDoubleCredit() public {
        for(uint256 i;i<4;++i){deposit(1);assertTrue(receiver.forwardPending());assertFalse(receiver.forwardPending());}
        assertEq(kernel.strategyCapital(),10 ether);assertEq(kernel.buybackReserve(),0);assertEq(kernel.protocolReserve(),4);
        assertEq(receiver.totalForwarded(),4);assertEq(kernel.accountedQuote(),100 ether+4);_assertAccounting();
    }
}
