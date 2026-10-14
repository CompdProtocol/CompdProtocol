// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdFlapBuybackAdapterV3 as Route,ICompdFlapPurchaseV3} from "../../contracts/production/v3/phase7cr2ch/CompdFlapBuybackAdapterV3.sol";
import {CompdPhaseBuybackAdapterV3 as Selector} from "../../contracts/production/v3/phase7cr2ch/CompdPhaseBuybackAdapterV3.sol";
import {CompdBuybackExecutorV3 as Burner} from "../../contracts/production/v3/phase7cr2ch/CompdBuybackExecutorV3.sol";
contract FlapRouteToken {
 mapping(address=>uint256) public balanceOf;uint256 public totalSupply;uint8 public state;bool public badBurn;bool public taxedTransfer;
 function configure(bool b,bool t,uint8 s) external{badBurn=b;taxedTransfer=t;state=s;}
 function mint(address to,uint256 n) external{balanceOf[to]+=n;totalSupply+=n;}
 function transfer(address to,uint256 n) external returns(bool){balanceOf[msg.sender]-=n;balanceOf[to]+=taxedTransfer?n/2:n;return true;}
 function burn(uint256 n) external{balanceOf[msg.sender]-=n;if(!badBurn)totalSupply-=n;}
}
contract FlapForceNative {constructor(address target) payable{selfdestruct(payable(target));}}
contract FlapRoutePortal is ICompdFlapPurchaseV3 {
 address constant TOKEN=0x7b7Af51136574c91A12988989c0a08E98aE97777;
 uint256 public output;bool public fail;bool public migrate;bool public mutateQuote;uint256 public counter;bool public refund;
 function setRefund(bool v) external{refund=v;}
 function configure(uint256 n,bool f,bool m,bool q) external{output=n;fail=f;migrate=m;mutateQuote=q;}
 function getTokenV8Safe(address) external view returns(uint256[18] memory a){a[0]=1;a[4]=6;a[8]=123456;}
 function quoteExactInput(address,address,uint256) external pure returns(uint256){revert();}
 struct Quote {address inputToken;address outputToken;uint256 inputAmount;}
 function quoteExactInput(Quote calldata p) external returns(uint256){require(p.inputToken==address(0)&&p.outputToken==TOKEN&&p.inputAmount!=0);if(mutateQuote)counter++;return output;}
 function swapExactInput(ExactInputParams calldata p) external payable returns(uint256){require(!fail&&p.inputToken==address(0)&&p.outputToken==TOKEN&&p.inputAmount==msg.value&&p.permitData.length==0&&output>=p.minOutputAmount);FlapRouteToken(TOKEN).mint(msg.sender,output);if(refund)new FlapForceNative{value:0.01 ether}(msg.sender);if(migrate)FlapRouteToken(TOKEN).configure(false,false,1);return output;}
}
contract FlapRouteGuard {
 bool public verified=true;uint256 public minimum=970;uint64 public observed;uint64 public deadline;
 function configure(bool v,uint256 m,uint64 a,uint64 d) external{verified=v;minimum=m;observed=a;deadline=d;}
 function routeVerified(address,address,bytes32) external view returns(bool){return verified;}
 function quote(bytes32,uint256) external view returns(uint256,uint256,uint64,uint64){return(1000,minimum,observed,deadline);}
}
contract CompdFlapBuybackLocalTest is Test {
 address constant TOKEN=0x7b7Af51136574c91A12988989c0a08E98aE97777;
 address constant PORTAL=address(bytes20(hex"e2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"));
 Route route;Selector selector;Burner burner;FlapRouteGuard guard;
 function setUp() public {
  vm.chainId(56);vm.warp(10000);vm.deal(address(this),10 ether);
  FlapRouteToken t=new FlapRouteToken();vm.etch(TOKEN,address(t).code);
  FlapRoutePortal p=new FlapRoutePortal();vm.etch(PORTAL,address(p).code);FlapRoutePortal(PORTAL).configure(1000,false,false,false);
  guard=new FlapRouteGuard();guard.configure(true,970,10000,10300);
  uint64 n=vm.getNonce(address(this));address selected=vm.computeCreateAddress(address(this),n+1);address burned=vm.computeCreateAddress(address(this),n+2);
  route=new Route(selected,burned,address(guard),TOKEN.codehash);selector=new Selector(PORTAL,TOKEN.codehash,address(route),address(0));burner=new Burner(address(this),address(selector),TOKEN.codehash);
  assertEq(address(selector),selected);assertEq(address(burner),burned);
 }
 function run() internal{burner.executeExactInput{value:0.1 ether}(bytes32(uint256(1)),bytes32(uint256(2)));}
 function testFixedPurchaseAndActualSupplyBurn() public{run();assertEq(burner.totalBNBSpent(),0.1 ether);assertEq(burner.totalCOMPDBurned(),1000);assertEq(FlapRouteToken(TOKEN).totalSupply(),0);assertEq(PORTAL.balance,0.1 ether);assertEq(TOKEN.balance,0);assertEq(FlapRouteToken(TOKEN).balanceOf(address(route)),0);}
 function testPurchaseFailureAtomicRetry() public{FlapRoutePortal(PORTAL).configure(1000,true,false,false);vm.expectRevert();run();assertEq(PORTAL.balance,0);assertFalse(burner.operationUsed(bytes32(uint256(1))));FlapRoutePortal(PORTAL).configure(1000,false,false,false);run();}
 function testNonSupplyReducingBurnRollsBack() public{FlapRouteToken(TOKEN).configure(true,false,0);vm.expectRevert();run();assertEq(PORTAL.balance,0);assertEq(FlapRouteToken(TOKEN).totalSupply(),0);}
 function testTransferTaxNetMinimumRollsBack() public{FlapRouteToken(TOKEN).configure(false,true,0);vm.expectRevert();run();assertEq(PORTAL.balance,0);}
 function testMigrationMidPurchaseRollsBack() public{FlapRoutePortal(PORTAL).configure(1000,false,true,false);vm.expectRevert();run();assertEq(FlapRouteToken(TOKEN).state(),0);assertEq(PORTAL.balance,0);}
 function testIndependentPriceAndSlippageBounds() public{FlapRoutePortal(PORTAL).configure(969,false,false,false);vm.expectRevert();run();FlapRoutePortal(PORTAL).configure(1031,false,false,false);vm.expectRevert();run();guard.configure(true,900,10000,10300);vm.expectRevert();run();}
 function testQuoteWritesFailClosed() public{FlapRoutePortal(PORTAL).configure(1000,false,false,true);vm.expectRevert();run();assertEq(FlapRoutePortal(PORTAL).counter(),0);}
 function testExpiredAndUnverifiedGuard() public{guard.configure(false,970,10000,10300);assertFalse(route.routeVerified(address(0)));assertFalse(burner.isExecutable(bytes32(uint256(2)),0.1 ether));vm.expectRevert();run();guard.configure(true,970,10000,10300);vm.warp(10301);vm.expectRevert();run();}
 function testCallerRecipientAndPinsFixed() public{vm.expectRevert();route.swapExactBNBForCOMPD{value:0.1 ether}(bytes32(uint256(2)),970,10300,address(this));vm.etch(address(guard),hex"00");assertFalse(route.routeVerified(address(0)));vm.expectRevert();run();}
 function testForcedNativeRefundCannotStrandProtocolFunds() public{FlapRoutePortal(PORTAL).setRefund(true);vm.expectRevert();run();assertEq(address(route).balance,0);assertEq(PORTAL.balance,0);}
 function testPreexistingForcedDonationsRemainSeparate() public{new FlapForceNative{value:0.01 ether}(address(route));FlapRouteToken(TOKEN).mint(address(route),111);run();assertEq(address(route).balance,0.01 ether);assertEq(FlapRouteToken(TOKEN).balanceOf(address(route)),111);assertEq(burner.totalCOMPDBurned(),1000);}
 function testNoPostRouteOrWrongChain() public{assertEq(selector.postRoute(),address(0));assertFalse(route.routeVerified(address(123)));vm.chainId(1);assertFalse(route.routeVerified(address(0)));}
}

