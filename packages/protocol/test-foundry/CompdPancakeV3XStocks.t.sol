// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdPancakeV3XStocksAdapter as A} from "../contracts/production/v3/phase7cr2ch/CompdPancakeV3XStocksAdapter.sol";
import {XTokenFixture,XPairFixture,XFactoryFixture,XRouterFixture,XGuardFixture} from "./CompdPancakeXStocksAdapter.t.sol";
import {XRebaseFixture} from "./CompdPancakeRebaseQualification.t.sol";
import {CompdStrategyExecutorV2R2 as E} from "../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {C2G2BTypes as T} from "../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
interface V3CallbackTest {function pancakeV3SwapCallback(int256,int256,bytes calldata) external;}
contract V3StableFixture is XTokenFixture {function transfer(address to,uint256 n) external returns(bool){balanceOf[msg.sender]-=n;balanceOf[to]+=n;return true;}}
contract V3PoolFixture {
 address public token0;address public token1;uint24 public fee;uint128 public liquidity=1e30;uint160 public sqrt=uint160(2**96);
 bool public fail;bool public partialFill;bool public malicious;uint256 public outputBps;
 function init(address stable,address stock,uint24 f) external {token0=stable;token1=stock;fee=f;liquidity=1e30;sqrt=uint160(2**96);outputBps=10000;}
 function setOutputBps(uint256 bps) external {outputBps=bps;}
 function configure(bool f,bool p,bool m) external {fail=f;partialFill=p;malicious=m;}
 function slot0() external view returns(uint160,int24,uint16,uint16,uint16,uint32,bool){return(sqrt,0,0,0,0,0,true);}
 function swap(address to,bool buy,int256 n,uint160,bytes calldata) external returns(int256 d0,int256 d1){
  require(!fail);uint256 used=uint256(n);if(partialFill)used/=2;uint256 out=(used-used*fee/1000000)*outputBps/10000;
  uint256 beforeBalance=buy?V3StableFixture(token0).balanceOf(address(this)):XRebaseFixture(token1).balanceOf(address(this));
  if(buy)require(XRebaseFixture(token1).transferShares(to,XRebaseFixture(token1).getSharesByUnderlyingAmount(out)));
  else require(V3StableFixture(token0).transfer(to,out));
  d0=buy?int256(used):-int256(out);d1=buy?-int256(out):int256(used);
  V3CallbackTest(msg.sender).pancakeV3SwapCallback(malicious?d0+int256(used)*2:d0,d1,"");
  require((buy?V3StableFixture(token0).balanceOf(address(this)):XRebaseFixture(token1).balanceOf(address(this)))>=beforeBalance+used);
 }
}
contract V3FactoryFixture {address public pool;function init(address p) external {pool=p;}function getPool(address,address,uint24) external view returns(address){return pool;}}
contract V3KernelFixture {T.Lifecycle public lifecycle=T.Lifecycle.PAUSED;bool public hasActivated=true;E public executor;constructor(){executor=new E(address(this),msg.sender,msg.sender);}receive() external payable {}
 function open(A a,uint256 run,uint256 n) external returns(bytes32){return executor.openRun{value:n}(run,address(a),n,n*300/10000,bytes32(run));}
 function exit(uint256 r) external {executor.requestExit(r,bytes32(r+100));}function close(uint256 r) external returns(uint256,uint256,bytes32){return executor.closeToKernel(r,bytes32(r+200));}}
contract CompdPancakeV3XStocksTest is Test {
 address constant TOKEN=0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;
 address constant STABLE=0x55d398326f99059fF775485246999027B3197955;
 address constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;
 address constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
 address constant POOL=0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492;
 address constant FACTORY=0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
 A a;V3KernelFixture k;XRebaseFixture token;V3StableFixture stable;V3PoolFixture pool;XGuardFixture guard;XRouterFixture router;
 function setUp() public {vm.chainId(56);vm.warp(1000000);
  XRebaseFixture ti=new XRebaseFixture();vm.etch(TOKEN,address(ti).code);token=XRebaseFixture(TOKEN);token.setIndex(1 ether);
  V3StableFixture si=new V3StableFixture();vm.etch(STABLE,address(si).code);stable=V3StableFixture(STABLE);
  V3PoolFixture pi=new V3PoolFixture();vm.etch(POOL,address(pi).code);pool=V3PoolFixture(POOL);pool.init(STABLE,TOKEN,2500);
  V3FactoryFixture fi=new V3FactoryFixture();vm.etch(FACTORY,address(fi).code);V3FactoryFixture(FACTORY).init(POOL);
  XRouterFixture ri=new XRouterFixture();vm.etch(ROUTER,address(ri).code);router=XRouterFixture(ROUTER);
  router.init(address(new XFactoryFixture(address(new XPairFixture(WBNB,STABLE)))),WBNB);
  token.mint(POOL,1000 ether);stable.mint(POOL,1000 ether);vm.deal(ROUTER,100 ether);
  guard=new XGuardFixture();k=new V3KernelFixture();a=new A(address(k.executor()),1,address(guard));admit();vm.deal(address(k),10 ether);
 }
 function admit() private {E e=k.executor();e.proposeStrategy(address(a),a.strategyIdentity(),a.riskConfigCommitment(),a.venueDependencyCommitment());(,,,,uint64 at,)=e.proposals(address(a));vm.warp(at);e.activateStrategy(address(a));}
 function testBuySellActualExecutorSettlement() public {bytes32 id=k.open(a,1,.01 ether);uint256 shares=a.positionShares(id);assertGt(shares,0);k.exit(1);(uint256 principal,uint256 n,)=k.close(1);assertEq(principal,.01 ether);assertEq(n,.01 ether*9975/10000*9975/10000);assertEq(a.totalPositionShares(),0);assertEq(token.sharesOf(address(a)),0);assertEq(stable.allowance(address(a),ROUTER),0);}
 function testPositiveRebaseFullCustody() public {bytes32 id=k.open(a,1,.01 ether);token.setIndex(2 ether);uint256 owned=a.positionShares(id);k.exit(1);(,uint256 returned,)=k.close(1);assertGt(returned,.01 ether);assertEq(token.sharesOf(address(a)),0);assertEq(a.positionShares(id),0);assertGt(owned,0);}
 function testNegativeRebaseAndTwoPositionIsolation() public {bytes32 first=k.open(a,1,.01 ether);bytes32 second=k.open(a,2,.01 ether);token.mint(address(a),1 ether);uint256 accidental=token.sharesOf(address(a))-a.totalPositionShares();token.setIndex(.7 ether);k.exit(1);k.close(1);assertEq(a.positionShares(first),0);assertEq(token.sharesOf(address(a)),a.positionShares(second)+accidental);token.setIndex(1.3 ether);k.exit(2);k.close(2);assertEq(token.sharesOf(address(a)),accidental);}
 function testRecipientCallbackUnauthorized() public {vm.expectRevert(A.Unauthorized.selector);a.pancakeV3SwapCallback(1,-1,"");}
 function testStaleReferenceAtomicRollback() public {guard.configure(10000,61,true);vm.expectRevert(A.Unavailable.selector);k.open(a,1,.01 ether);assertEq(address(k).balance,10 ether);assertEq(a.totalPositionShares(),0);}
 function testClosedOrUnknownHaltFailsClosed() public {guard.configure(10000,0,false);vm.expectRevert(A.Unavailable.selector);k.open(a,1,.01 ether);}
 function testIndependentDeviationRejected() public {guard.configure(11000,0,true);vm.expectRevert(A.Unavailable.selector);k.open(a,1,.01 ether);}
 function testPartialFillRevertsAllCustody() public {pool.configure(false,true,false);vm.expectRevert();k.open(a,1,.01 ether);assertEq(address(k).balance,10 ether);assertEq(stable.balanceOf(address(a)),0);assertEq(a.totalPositionShares(),0);}
 function testBadCallbackCannotOverpay() public {pool.configure(false,false,true);vm.expectRevert();k.open(a,1,.01 ether);assertEq(a.totalPositionShares(),0);}
 function testDuplicateOpenAndClosePrevented() public {k.open(a,1,.01 ether);vm.expectRevert();k.open(a,1,.01 ether);k.exit(1);k.close(1);vm.expectRevert();k.close(1);}
 function testSellFailureRetryConservesShares() public {bytes32 id=k.open(a,1,.01 ether);uint256 shares=a.positionShares(id);pool.configure(true,false,false);k.exit(1);assertEq(uint256(k.executor().runState(1)),uint256(T.StrategyRunState.BLOCKED));assertEq(token.sharesOf(address(a)),shares);pool.configure(false,false,false);k.exit(1);k.close(1);assertEq(a.totalPositionShares(),0);}
 function testChangedDependencyRejected() public {vm.etch(POOL,hex"00");vm.expectRevert(A.Unavailable.selector);k.open(a,1,.01 ether);}
 function testUnsupportedAssetRejected() public {address ex=address(k.executor());vm.expectRevert(A.Invalid.selector);new A(ex,0,address(guard));}
 function testUnauthorizedEntryExitClose() public {vm.expectRevert(A.Unauthorized.selector);a.open(1,bytes32(uint256(1)),1,0);bytes32 id=k.open(a,1,.01 ether);vm.expectRevert(A.Unauthorized.selector);a.requestExit(id,bytes32(uint256(2)));vm.expectRevert(A.Unauthorized.selector);a.close(id,bytes32(uint256(3)));}
 function testClosedExitKeepsFundedCustodyForRetry() public {bytes32 id=k.open(a,1,.01 ether);guard.configure(10000,0,false);k.exit(1);assertGt(a.positionShares(id),0);guard.configure(10000,0,true);k.exit(1);k.close(1);assertEq(a.totalPositionShares(),0);}
 function testExecutableSlippageRejectsWithoutStrandingFunds() public {pool.setOutputBps(9900);vm.expectRevert(A.Unavailable.selector);k.open(a,1,.01 ether);assertEq(address(k).balance,10 ether);assertEq(a.totalPositionShares(),0);assertEq(stable.balanceOf(address(a)),0);}
 function testFractionalRebaseCannotLeakSecondPositionShares() public {bytes32 first=k.open(a,1,.01 ether+1);bytes32 second=k.open(a,2,.01 ether+3);uint256 other=a.positionShares(second);token.setIndex(.7 ether);k.exit(1);k.close(1);assertEq(a.positionShares(first),0);assertEq(token.sharesOf(address(a)),other);assertEq(a.totalPositionShares(),other);token.setIndex(1.3 ether);k.exit(2);k.close(2);assertEq(token.sharesOf(address(a)),0);}
}
