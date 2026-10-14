// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdIndependentXStocksGuardV3 as G} from "../contracts/production/v3/phase7cr2ch/CompdIndependentXStocksGuardV3.sol";
contract IndependentFeedFixture {uint8 public decimals=8;int256 public answer;uint256 public updated;uint80 public round=1;uint80 public answered=1;constructor(int256 a){answer=a;updated=block.timestamp;}function set(int256 a,uint256 t,uint80 r) external {answer=a;updated=t;answered=r;}function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80){return(round,answer,updated,updated,answered);}}
contract IndependentCalendarFixture {bool public opened=true;uint64 public at;uint64 public until;constructor(){at=uint64(block.timestamp);until=at+60;}function set(bool o,uint64 a,uint64 u) external {opened=o;at=a;until=u;}function session(address) external view returns(bool,uint64,uint64){return(opened,at,until);}}
contract CompdIndependentXStocksGuardTest is Test {
 G g;IndependentFeedFixture stock;IndependentFeedFixture bnb;IndependentCalendarFixture calendar;address token=address(0x1234);
 function setUp() public {vm.chainId(56);vm.warp(100000);vm.etch(token,hex"00");stock=new IndependentFeedFixture(500e8);bnb=new IndependentFeedFixture(1000e8);calendar=new IndependentCalendarFixture();g=new G(token,18,address(stock),address(bnb),address(calendar));}
 function testIndependentBuySellUnits() public {(uint256 out,,,bool open)=g.referenceOut(token,true,1 ether);assertEq(out,2 ether);assertTrue(open);(out,,,)=g.referenceOut(token,false,2 ether);assertEq(out,1 ether);}
 function testSixDecimalTokenUnits() public {G small=new G(token,6,address(stock),address(bnb),address(calendar));(uint256 out,,,)=small.referenceOut(token,true,1 ether);assertEq(out,2e6);(out,,,)=small.referenceOut(token,false,2e6);assertEq(out,1 ether);}
 function testStalePrice() public {stock.set(500e8,block.timestamp-61,1);vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testFuturePrice() public {stock.set(500e8,block.timestamp+1,1);vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testNonpositivePrice() public {stock.set(0,block.timestamp,1);vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testIncompleteRound() public {stock.set(500e8,block.timestamp,0);vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testClosedSession() public {calendar.set(false,uint64(block.timestamp),uint64(block.timestamp+60));vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testStaleCalendar() public {calendar.set(true,uint64(block.timestamp-61),uint64(block.timestamp+60));vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testExpiryBoundary() public {calendar.set(true,uint64(block.timestamp),uint64(block.timestamp));vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testWrongAsset() public {vm.expectRevert(G.Unavailable.selector);g.referenceOut(address(0x555),true,1 ether);}
 function testChangedDependency() public {vm.etch(address(stock),hex"00");vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
 function testCrossChainRejected() public {vm.chainId(1);vm.expectRevert(G.Unavailable.selector);g.referenceOut(token,true,1 ether);}
}

