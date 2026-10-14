// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdPancakeXStocksAdapterV3 as A,IXStockRouter,IXStockIndependentGuard,IXStockToken} from "../contracts/production/v3/phase7cr2ch/CompdPancakeXStocksAdapterV3.sol";
import {XKernelFixture} from "./CompdPancakeXStocksAdapter.t.sol";
interface RouteToken {function balanceOf(address) external view returns(uint256);function transfer(address,uint256) external returns(bool);}
interface RouteV3Pool {function token0() external view returns(address);function token1() external view returns(address);function fee() external view returns(uint24);function liquidity() external view returns(uint128);function swap(address,bool,int256,uint160,bytes calldata) external returns(int256,int256);}
// MECHANICS ONLY: router-derived quote fixture is never an independent production price source.
contract RouteQuoteFixture is IXStockIndependentGuard {
 address immutable bridge;constructor(address b){bridge=b;}
 function referenceOut(address token,bool buy,uint256 n) external view returns(uint256,uint64,uint64,bool){address[] memory path=new address[](3);path[0]=buy?0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c:token;path[1]=bridge;path[2]=buy?token:0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;uint256[] memory amounts=IXStockRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E).getAmountsOut(n,path);return(amounts[2],uint64(block.timestamp),uint64(block.timestamp+60),true);}
}
contract CompdXStocksRouteQualificationTest is Test {
 address constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;address constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;address constant USDT=0x55d398326f99059fF775485246999027B3197955;address constant USDC=0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
 address callbackPool;address xToken;bool inSwap;
 event MechanicalResult(string symbol,uint256 inputWei,uint256 outputWei,uint256 quoteTokens);
 function fork() private {string memory url=vm.envOr("BSC_RPC_URL",string(""));uint256 b=vm.envOr("COMPD_XSTOCKS_FORK_BLOCK",uint256(0));if(bytes(url).length==0||b==0){vm.skip(true);return;}vm.createSelectFork(url,b);assertEq(block.chainid,56);}
 function v2(uint8 asset,address stable,string memory symbol) private {fork();XKernelFixture k=new XKernelFixture();RouteQuoteFixture g=new RouteQuoteFixture(stable);A a=new A(address(k.executor()),asset,stable,address(g));k.executor().proposeStrategy(address(a),a.strategyIdentity(),a.riskConfigCommitment(),a.venueDependencyCommitment());vm.warp(block.timestamp+24 hours);k.executor().activateStrategy(address(a));vm.deal(address(k),1 ether);uint256 n=1e9;uint256 beforeBalance=address(k).balance;bytes32 id=k.open(a,1,n);uint256 bought=a.positionUnderlying(id);assertGt(bought,0);k.exit(1,bytes32(uint256(22)));(uint256 principal,uint256 returned,)=k.close(1);assertEq(principal,n);assertGt(returned,0);assertEq(address(k).balance,beforeBalance-n+returned);assertEq(a.positionShares(id),0);assertEq(IXStockToken(a.token()).sharesOf(address(a)),0);assertEq(IXStockToken(a.token()).allowance(address(a),ROUTER),0);emit MechanicalResult(symbol,n,returned,bought);}
 function testForkV2TSLAUSDTShareAdapterRoundTrip() public {v2(1,USDT,"TSLAx V2 USDT");}
 function testForkV2AAPLUSDTShareAdapterRoundTrip() public {v2(3,USDT,"AAPLx V2 USDT");}
 function testForkV2SPYUSDCShareAdapterRoundTrip() public {v2(4,USDC,"SPYx V2 USDC");}
 // Direct deployed Pancake V3 pool API fixture, not an installed production V3 adapter.
 function v3(address pool,address token,uint24 fee_,string memory symbol) private {
  fork();callbackPool=pool;xToken=token;RouteV3Pool venue=RouteV3Pool(pool);assertEq(venue.fee(),fee_);assertGt(venue.liquidity(),0);address t0=venue.token0();address t1=venue.token1();assertTrue((t0==USDT&&t1==token)||(t1==USDT&&t0==token));
  uint256 initialStable=RouteToken(USDT).balanceOf(address(this));uint256 initialShares=IXStockToken(token).sharesOf(address(this));uint256 initialToken=RouteToken(token).balanceOf(address(this));vm.deal(address(this),1 ether);address[] memory path=new address[](2);path[0]=WBNB;path[1]=USDT;IXStockRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value:1e9}(1,path,address(this),block.timestamp+60);uint256 input=RouteToken(USDT).balanceOf(address(this))-initialStable;assertGt(input,0);
  inSwap=true;venue.swap(address(this),t0==USDT,int256(input),t0==USDT?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341),"");inSwap=false;
  uint256 bought=RouteToken(token).balanceOf(address(this))-initialToken;assertGt(bought,0);assertEq(RouteToken(USDT).balanceOf(address(this)),initialStable);
  inSwap=true;venue.swap(address(this),t0==token,int256(bought),t0==token?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341),"");inSwap=false;
  uint256 returned=RouteToken(USDT).balanceOf(address(this))-initialStable;assertGt(returned,0);assertGe(returned*10000,input*9900,"V3_MICRO_ROUND_TRIP_LOSS_EXCEEDS_ONE_PERCENT");assertEq(IXStockToken(token).sharesOf(address(this)),initialShares);emit MechanicalResult(symbol,input,returned,bought);
 }
 function pancakeV3SwapCallback(int256 d0,int256 d1,bytes calldata) external {require(inSwap&&msg.sender==callbackPool);address t0=RouteV3Pool(callbackPool).token0();address t1=RouteV3Pool(callbackPool).token1();if(d0>0){require(t0==USDT||t0==xToken);require(RouteToken(t0).transfer(callbackPool,uint256(d0)));}if(d1>0){require(t1==USDT||t1==xToken);require(RouteToken(t1).transfer(callbackPool,uint256(d1)));}}
 function testForkV3TSLAUSDTPoolBuySellMechanics() public {v3(0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492,0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0,2500,"TSLAx V3 USDT");}
 function testForkV3AMZNUSDTPoolBuySellMechanics() public {v3(0x28A73f5bd589Fea90BA0D24117BF91D648be3ef2,0x3557Ba345B01EFa20A1bdDC61F573BFD87195081,100,"AMZNx V3 USDT");}
}

