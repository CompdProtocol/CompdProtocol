// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {NativeFactoryGraph,FixtureNativeFactory,Factory,Binding} from "./NativeFactoryGraph.sol";
import {IVaultFactoryValidationV2} from "../../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../../src/flap/IPortal.sol";

contract FixtureTaxToken {
    address public taxProcessor;
    function setProcessor(address p) external {taxProcessor=p;}
}
contract FixtureProcessor {
    address public immutable taxToken;address public marketAddress;bool public reject;bool public reenter;bool public nestedSucceeded;uint256 public calls;address public factory;
    constructor(address token,address r){taxToken=token;marketAddress=r;}
    function configure(bool r,bool re,address f) external {reject=r;reenter=re;factory=f;}
    function changeMarket(address r) external {marketAddress=r;}
    function dispatch() external {
        require(!reject,"DISPATCH_REJECT");++calls;
        if(reenter)(nestedSucceeded,)=factory.call(abi.encodeWithSignature("processFees()"));
        uint256 amount=address(this).balance;if(amount!=0){(bool ok,)=marketAddress.call{value:amount}("");require(ok);}
    }
}
contract CompdNativeFactoryLocalTest is NativeFactoryGraph {
    FixtureNativeFactory factory;FixtureTaxToken token;FixtureProcessor processor;
    address constant LOCAL_PORTAL=0x00003877386745d059d92fa39159595BdaBF0000;
    function setUp() public {vm.chainId(31337);token=new FixtureTaxToken();createGraph(address(token));factory=new FixtureNativeFactory(address(kernel));processor=new FixtureProcessor(address(token),address(receiver));token.setProcessor(address(processor));vm.deal(address(this),10 ether);}
    function bind() internal {vm.prank(LOCAL_PORTAL);assertEq(factory.newVault(address(token),address(0),address(this),""),address(receiver));}
    function testProductionFactoryRequiresReservedCA() public {
        vm.expectRevert(Binding.InvalidBinding.selector);new Factory(address(kernel));
        createGraph(RESERVED);Factory production=new Factory(address(kernel));assertEq(production.taxToken(),RESERVED);assertEq(production.COMPD_TOKEN(),RESERVED);
    }
    function testNewVaultRejectsUnauthorizedCall() public {vm.expectRevert();factory.newVault(address(token),address(0),address(this),"");assertFalse(factory.bound());}
    function testWrongTokenQuoteAndCustomDataFailClosed() public {
        vm.expectRevert(Binding.InvalidLaunch.selector);vm.prank(LOCAL_PORTAL);factory.newVault(address(0xBAD),address(0),address(this),"");
        vm.expectRevert(Binding.InvalidLaunch.selector);vm.prank(LOCAL_PORTAL);factory.newVault(address(token),address(1),address(this),"");
        vm.expectRevert(Binding.InvalidLaunch.selector);vm.prank(LOCAL_PORTAL);factory.newVault(address(token),address(0),address(this),hex"01");assertFalse(factory.bound());
    }
    function testBindingIsExistingReceiverAndOneShot() public {bind();assertTrue(factory.bound());assertEq(factory.kernel(),address(kernel));assertEq(factory.receiverHash(),address(receiver).codehash);vm.expectRevert(Binding.InvalidLaunch.selector);vm.prank(LOCAL_PORTAL);factory.newVault(address(token),address(0),address(this),"");}
    function testNativeOnlyAndNormalizedTaxValidation() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)));assertFalse(factory.isQuoteTokenSupported(address(1)));assertEq(factory.factorySpecVersion(),"v2.3");
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d=IVaultFactoryValidationV2.LaunchValidationDataV1(IPortalTypes.TokenVersion.TOKEN_TAXED_V3,address(0),200,200,10000,0,0,0,address(0),0);
        (bool ok,)=factory.onBeforeLaunch(abi.encode(d));assertTrue(ok);d.buyTaxRate=500;(ok,)=factory.onBeforeLaunch(abi.encode(d));assertFalse(ok);d.buyTaxRate=200;d.quoteToken=address(1);(ok,)=factory.onBeforeLaunch(abi.encode(d));assertFalse(ok);d.quoteToken=address(0);d.dividendBps=1;(ok,)=factory.onBeforeLaunch(abi.encode(d));assertFalse(ok);
    }
    function testPermissionlessTickDispatchesAndForwardsExactAllocation() public {
        bind();vm.deal(address(processor),1 ether);vm.prank(address(0xBEEF));(bool d,bool f)=factory.processFees();assertTrue(d);assertTrue(f);checkAllocation(1 ether);
        assertEq(receiver.pendingBNB(),0);assertEq(receiver.totalForwarded(),1 ether);assertEq(address(processor).balance,0);
        (d,f)=factory.processFees();assertTrue(d);assertFalse(f);checkAllocation(1 ether);
    }
    function testDispatchFailureDoesNotBlockAlreadyPendingForward() public {
        bind();vm.deal(address(receiver),1 ether);processor.configure(true,false,address(factory));(bool d,bool f)=factory.processFees();assertFalse(d);assertTrue(f);checkAllocation(1 ether);
    }
    function testKernelFailureRetainsNativeThenPermissionlessRetry() public {
        bind();vm.deal(address(processor),1 ether);vm.deal(address(kernel),99 ether);(bool d,bool f)=factory.processFees();assertTrue(d);assertFalse(f);
        assertEq(receiver.pendingBNB(),1 ether);assertEq(receiver.totalForwarded(),0);assertEq(kernel.accountedQuote(),100 ether);
        vm.deal(address(kernel),100 ether);(d,f)=factory.processFees();assertTrue(d);assertTrue(f);checkAllocation(1 ether);
        factory.processFees();checkAllocation(1 ether);assertEq(receiver.totalForwarded(),1 ether);
    }
    function testWrongProcessorBindingCannotDispatchOrStealPending() public {
        bind();vm.deal(address(processor),1 ether);processor.changeMarket(address(0xBAD));vm.expectRevert(Binding.InvalidBinding.selector);factory.processFees();assertEq(address(processor).balance,1 ether);checkAllocation(0);
    }
    function testGraphCodeChangeFailsClosed() public {bind();vm.etch(address(receiver),hex"00");vm.expectRevert(Binding.InvalidBinding.selector);factory.processFees();}
    function testReentrantProcessorCannotDoubleCredit() public {bind();processor.configure(false,true,address(factory));vm.deal(address(processor),1 ether);(bool d,bool f)=factory.processFees();assertTrue(d);assertTrue(f);assertFalse(processor.nestedSucceeded());checkAllocation(1 ether);assertEq(processor.calls(),1);}
    function testUnboundTickOnlyForwardsAnonymousPending() public {vm.deal(address(receiver),1 ether);(bool d,bool f)=factory.processFees();assertFalse(d);assertTrue(f);checkAllocation(1 ether);assertEq(processor.calls(),0);}
}
