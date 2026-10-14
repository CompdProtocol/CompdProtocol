// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {NativeFactoryGraph,FixtureNativeFactory} from "./NativeFactoryGraph.sol";
import {FlapBSCFixture} from "./reference/test/FlapBSCFixture.sol";
import {IPortal} from "./reference/src/flap/IPortal.sol";
import {IVaultPortal,IVaultPortalTypes} from "./reference/src/flap/IVaultPortal.sol";
import {ITaxProcessor} from "./reference/src/flap/ITaxProcessor.sol";
import {IFlapTaxTokenV3} from "./reference/src/flap/IFlapTaxTokenV3.sol";

contract CompdNativeFactoryForkTest is NativeFactoryGraph,FlapBSCFixture {
    bytes32 salt;address predicted;FixtureNativeFactory factory;
    event ForkFeeObservation(address token,address processor,address receiver,uint256 pending,uint256 credited,bool dispatched,bool forwarded);
    function setUp() public {
        uint256 pinned=vm.envUint("BSC_FORK_BLOCK");vm.createSelectFork(vm.envString("BSC_RPC_URL"),pinned);
        assertEq(block.chainid,56);assertEq(block.number,pinned);portal=IPortal(PORTAL);vaultPortal=IVaultPortal(VAULT_PORTAL);
        while(true){
            salt=_findVanitySalt(VanityType.VANITY_7777,TOKEN_IMPL_TAXED_V3,PORTAL);predicted=_predictAddress(TOKEN_IMPL_TAXED_V3,salt,PORTAL);
            if(predicted.code.length!=0)continue;
            (bool ok,bytes memory result)=address(portal).staticcall(abi.encodeWithSignature("getTokenV8Safe(address)",predicted));
            if(ok){if(abi.decode(result,(uint256))==0)break;}
            else if(keccak256(result)==keccak256(abi.encodeWithSignature("TokenNotFound(address)",predicted)))break;
            else assembly {revert(add(result,32),mload(result))}
        }
        createGraph(predicted);factory=new FixtureNativeFactory(address(kernel));vm.deal(address(this),10 ether);
    }
    function params() internal view returns(IVaultPortalTypes.NewTokenV6WithVaultParams memory p){
        p=_buildV3TaxTokenParams("COMPD LOCAL FORK ONLY","CFORK",salt,address(factory),"");p.buyTaxRate=200;p.sellTaxRate=200;
    }
    function launchAndBuy() internal returns(ITaxProcessor processor,uint256 fee){
        address token=vaultPortal.newTokenV6WithVault(params());assertEq(token,predicted);assertTrue(factory.bound());
        assertEq(vaultPortal.getVault(token).vault,address(receiver));processor=ITaxProcessor(IFlapTaxTokenV3(token).taxProcessor());
        assertEq(processor.taxToken(),token);assertEq(processor.marketAddress(),address(receiver));
        _buyOnBC(token,1 ether);fee=processor.marketQuoteBalance();assertGt(fee,0);assertEq(receiver.pendingBNB(),0);
    }
    function testForkRealPortalBindingAndPermissionlessNativeFlow() public {
        (ITaxProcessor processor,uint256 fee)=launchAndBuy();(bool dispatched,bool forwarded)=factory.processFees();assertTrue(dispatched);assertTrue(forwarded);
        assertEq(receiver.totalForwarded(),fee);assertEq(receiver.pendingBNB(),0);assertEq(processor.marketQuoteBalance(),0);checkAllocation(fee);
        emit ForkFeeObservation(predicted,address(processor),address(receiver),fee,receiver.totalForwarded(),dispatched,forwarded);
    }
    function testForkForwardFailureRetainsBNBAndRetryCreditsOnce() public {
        (ITaxProcessor processor,uint256 fee)=launchAndBuy();vm.deal(address(kernel),99 ether);(bool dispatched,bool forwarded)=factory.processFees();assertTrue(dispatched);assertFalse(forwarded);
        assertEq(receiver.pendingBNB(),fee);assertEq(receiver.totalForwarded(),0);assertEq(processor.marketQuoteBalance(),0);assertEq(kernel.accountedQuote(),100 ether);
        vm.deal(address(kernel),100 ether);(dispatched,forwarded)=factory.processFees();assertTrue(dispatched);assertTrue(forwarded);
        assertEq(receiver.totalForwarded(),fee);assertEq(receiver.pendingBNB(),0);checkAllocation(fee);
        (,forwarded)=factory.processFees();assertFalse(forwarded);checkAllocation(fee);
        emit ForkFeeObservation(predicted,address(processor),address(receiver),fee,receiver.totalForwarded(),dispatched,forwarded);
    }
    function testForkRealPortalRejectsUnapprovedTaxBeforeBinding() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p=params();p.buyTaxRate=500;
        vm.expectRevert();vaultPortal.newTokenV6WithVault(p);assertFalse(factory.bound());assertEq(predicted.code.length,0);checkAllocation(0);
    }
}
