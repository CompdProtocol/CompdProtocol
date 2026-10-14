// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {MockBurnableCOMPD,MockFixedBuybackAdapter} from "./CompdBuybackV3Local.t.sol";
import {CompdPhaseBuybackAdapterV3 as Selector} from "../../contracts/production/v3/phase7cr2ch/CompdPhaseBuybackAdapterV3.sol";
contract PhaseToken is MockBurnableCOMPD {uint8 public state;address public mainPool;function set(uint8 s,address p) external {state=s;mainPool=p;}}
contract PhasePortal {uint256[18] internal words;function set(uint8 status,address pool,uint256 threshold) external {words[0]=status;words[4]=6;words[8]=threshold;words[14]=uint160(pool);}function getTokenV8Safe(address) external view returns(uint256[18] memory){return words;}}
contract PhaseRoute is MockFixedBuybackAdapter {bool public verified=true;function setVerified(bool v) external {verified=v;}function routeVerified(address) external view returns(bool){return verified;}}
contract PhaseMutatingRoute {
 address public constant token=0x7b7Af51136574c91A12988989c0a08E98aE97777;PhasePortal public immutable portal;
 constructor(PhasePortal p){portal=p;}
 function routeVerified(address) external pure returns(bool){return true;}
 function quote(bytes32,uint256) external view returns(uint256,uint256,uint64,uint64){return(1000,970,uint64(block.timestamp),uint64(block.timestamp+300));}
 function swapExactBNBForCOMPD(bytes32,uint256,uint64,address recipient) external payable {MockBurnableCOMPD(token).mint(recipient,1000);portal.set(4,address(0),123);}
}
contract CompdPhaseBuybackLocalTest is Test {
 address constant TOKEN=0x7b7Af51136574c91A12988989c0a08E98aE97777;PhasePortal portal;PhaseRoute pre;PhaseRoute post;Selector selector;
 function setUp() public {vm.chainId(56);vm.warp(10000);PhaseToken t=new PhaseToken();vm.etch(TOKEN,address(t).code);portal=new PhasePortal();portal.set(1,address(0),123456);pre=new PhaseRoute();post=new PhaseRoute();selector=new Selector(address(portal),TOKEN.codehash,address(pre),address(post));}
 function testPreBondingReadsActualThreshold() public view {(address r,uint8 phase,uint256 threshold,address pool)=selector.selectedRoute();assertEq(r,address(pre));assertEq(phase,1);assertEq(threshold,123456);assertEq(pool,address(0));}
 function testPostRequiresPoolBindingAndConsistentState() public {address pool=address(new PhasePortal());portal.set(4,pool,987);PhaseToken(TOKEN).set(3,pool);(address r,uint8 phase,,)=selector.selectedRoute();assertEq(r,address(post));assertEq(phase,2);PhaseToken(TOKEN).set(3,address(123));(r,,,)=selector.selectedRoute();assertEq(r,address(0));}
 function testMigratingAndMissingLiquidityDisable() public {PhaseToken(TOKEN).set(1,address(0));(address r,,,)=selector.selectedRoute();assertEq(r,address(0));portal.set(4,address(0),987);PhaseToken(TOKEN).set(3,address(0));(r,,,)=selector.selectedRoute();assertEq(r,address(0));}
 function testUnverifiedOrChangedRouteDisabled() public {pre.setVerified(false);(address r,,,)=selector.selectedRoute();assertEq(r,address(0));vm.expectRevert();selector.quote(bytes32(0),1);pre.setVerified(true);vm.etch(address(pre),hex"00");(r,,,)=selector.selectedRoute();assertEq(r,address(0));}
 function testMissingAdapterAndWrongChainDisabled() public {Selector empty=new Selector(address(portal),TOKEN.codehash,address(0),address(0));(address r,,,)=empty.selectedRoute();assertEq(r,address(0));vm.chainId(97);(r,,,)=selector.selectedRoute();assertEq(r,address(0));}
 function testMidSwapMigrationRollsBackFundsAndTokens() public {PhaseMutatingRoute route=new PhaseMutatingRoute(portal);Selector guarded=new Selector(address(portal),TOKEN.codehash,address(route),address(post));vm.deal(address(this),1 ether);vm.expectRevert();guarded.swapExactBNBForCOMPD{value:1 ether}(bytes32(0),970,10300,address(this));assertEq(address(this).balance,1 ether);assertEq(address(route).balance,0);assertEq(MockBurnableCOMPD(TOKEN).totalSupply(),0);(address selected,,,)=guarded.selectedRoute();assertEq(selected,address(route));}
 function testRecipientAndDeadlineCannotBeBypassed() public {vm.expectRevert();selector.swapExactBNBForCOMPD(bytes32(0),1,10001,address(1));vm.expectRevert();selector.swapExactBNBForCOMPD(bytes32(0),1,9999,address(this));}
}
