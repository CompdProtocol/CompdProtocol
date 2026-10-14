// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdPancakeXStocksAdapterV3 as A,IXStockToken,IXStockRouter,IXStockIndependentGuard} from "../contracts/production/v3/phase7cr2ch/CompdPancakeXStocksAdapterV3.sol";
import {XKernelFixture} from "./CompdPancakeXStocksAdapter.t.sol";
/// FORK TEST ONLY. Deliberately router-derived: proves swap mechanics, NOT independent pricing.
contract XForkQuoteFixture is IXStockIndependentGuard {
 address constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;address constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
 function referenceOut(address token,bool buy,uint256 input) external view returns(uint256,uint64,uint64,bool){address[] memory p=new address[](2);p[0]=buy?WBNB:token;p[1]=buy?token:WBNB;uint256[] memory n=IXStockRouter(ROUTER).getAmountsOut(input,p);return(n[1],uint64(block.timestamp),uint64(block.timestamp)+60,true);}
}
interface XForkIssuerRebase {function multiplierUpdater() external view returns(address);function getCurrentMultiplier() external view returns(uint256,uint256,uint256);function updateMultiplierValue(uint256,uint256,uint256) external;}
interface XForkPairSync {function sync() external;}
contract CompdPancakeXStocksForkTest is Test {
 function testForkActualTSLAPancakeV2RoundTripMechanics() public {roundTrip(0);}
 // Local issuer impersonation proves deployed token/swap mechanics only, NOT issuer authorization or independent pricing.
 function testForkActualTSLAPositiveRebaseRoundTrip() public {roundTrip(13 ether/10);}
 function testForkActualTSLANegativeRebaseRoundTrip() public {roundTrip(7 ether/10);}
 function roundTrip(uint256 multiplier) private {
  string memory url=vm.envOr("BSC_RPC_URL",string(""));uint256 blockNumber=vm.envOr("COMPD_XSTOCKS_FORK_BLOCK",uint256(0));if(bytes(url).length==0||blockNumber==0){vm.skip(true);return;}vm.createSelectFork(url,blockNumber);assertEq(block.chainid,56);
  XKernelFixture k=new XKernelFixture();XForkQuoteFixture guard=new XForkQuoteFixture();A a=new A(address(k.executor()),1,address(0),address(guard));k.executor().proposeStrategy(address(a),a.strategyIdentity(),a.riskConfigCommitment(),a.venueDependencyCommitment());vm.warp(block.timestamp+24 hours);k.executor().activateStrategy(address(a));vm.deal(address(k),1 ether);uint256 n=10**10;uint256 beforeBalance=address(k).balance;bytes32 id=k.open(a,1,n);assertGt(a.positionShares(id),0);if(multiplier!=0){XForkIssuerRebase issuer=XForkIssuerRebase(a.token());(uint256 old,,)=issuer.getCurrentMultiplier();address updater=issuer.multiplierUpdater();assertTrue(updater!=address(0));vm.prank(updater);issuer.updateMultiplierValue(multiplier,old,block.timestamp);(uint256 current,,)=issuer.getCurrentMultiplier();assertEq(current,multiplier);
 // Reconcile real pair reserves after its balances rebase; no mock pool or bypass of swap invariant.
 XForkPairSync(0xFC934F5b8FeDcea8Bf666774060c87455CfcC99A).sync();}k.exit(1,bytes32(uint256(22)));(uint256 principal,uint256 returned,)=k.close(1);assertEq(principal,n);assertGt(returned,0);assertEq(address(k).balance,beforeBalance-n+returned);assertEq(address(a).balance,0);assertEq(a.positionShares(id),0);assertEq(a.totalPositionShares(),0);assertEq(IXStockToken(a.token()).sharesOf(address(a)),0);assertEq(IXStockToken(a.token()).allowance(address(a),a.ROUTER()),0);
 }
}
