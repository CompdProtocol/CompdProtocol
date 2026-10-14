// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
interface IXStockToken {function balanceOf(address) external view returns(uint256);function sharesOf(address) external view returns(uint256);function getSharesByUnderlyingAmount(uint256) external view returns(uint256);function getUnderlyingAmountByShares(uint256) external view returns(uint256);function transferShares(address,uint256) external returns(bool);function allowance(address,address) external view returns(uint256);function approve(address,uint256) external returns(bool);}
interface IXStockRouter {
 function factory() external view returns(address);function WETH() external view returns(address);
 function getAmountsOut(uint256,address[] calldata) external view returns(uint256[] memory);
 function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[] calldata,address,uint256) external payable;
 function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
}
interface IXStockFactory {function getPair(address,address) external view returns(address);}
interface IXStockPair {function getReserves() external view returns(uint112,uint112,uint32);function token0() external view returns(address);function token1() external view returns(address);}
/// A separately qualified independent source must return output in raw destination units.
/// Router-derived quotes alone MUST NOT be used as this independent guard.
interface IXStockIndependentGuard {
 function referenceOut(address token,bool buy,uint256 input) external view returns(uint256 output,uint64 observedAt,uint64 validUntil,bool marketOpen);
}
/// Fixed PancakeSwap V2 spot adapter. Unadmitted by default; no signer or admin withdrawals.
contract CompdPancakeXStocksAdapterV3 is IC2G2BStrategyAdapterR4 {
 address public constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;
 address public constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
 address public constant USDT=0x55d398326f99059fF775485246999027B3197955;
 address public constant USDC=0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
 address public immutable executor;address public immutable token;address public immutable bridge;address public immutable guard;address public immutable factory;
 bytes32 public immutable routerHash;bytes32 public immutable guardHash;bytes32 public immutable factoryHash;bytes32 public immutable tokenHash;
 bytes32 public immutable strategyIdentity;bytes32 public immutable riskConfigCommitment;bytes32 public immutable venueDependencyCommitment;
 address[] private pairs;bytes32[] private pairHashes;bool private entered;
 struct Position {uint256 principal;uint256 tokens;uint256 proceeds;bytes32 exitId;bool exists;bool closed;}
 // Position.tokens is the entry quantity retained for ABI compatibility, not custody authority.
 mapping(bytes32=>uint256) public positionShares;
 uint256 public totalPositionShares;
 mapping(bytes32=>Position) public positions;mapping(uint256=>bool) public runUsed;mapping(bytes32=>bool) public allocationUsed;
 error Invalid();error Unauthorized();error Unavailable();error TransferFailed();
 event Bought(bytes32 indexed position,uint256 bnb,uint256 tokens);event Sold(bytes32 indexed position,uint256 tokens,uint256 bnb);
 modifier onlyExecutor(){if(msg.sender!=executor)revert Unauthorized();_;}modifier lock(){if(entered)revert Unauthorized();entered=true;_;entered=false;}
 constructor(address executor_,uint8 asset,address bridge_,address guard_) {
  if(block.chainid!=56||executor_.code.length==0||guard_.code.length==0||asset>4||(bridge_!=address(0)&&bridge_!=USDT&&bridge_!=USDC))revert Invalid();
  executor=executor_;guard=guard_;bridge=bridge_;token=_asset(asset);factory=IXStockRouter(ROUTER).factory();
  if(IXStockRouter(ROUTER).WETH()!=WBNB||factory.code.length==0||token.code.length==0)revert Invalid();
  routerHash=ROUTER.codehash;factoryHash=factory.codehash;guardHash=guard_.codehash;tokenHash=token.codehash;
  address[] memory path=_path(true);for(uint256 i;i+1<path.length;i++){address pair=IXStockFactory(factory).getPair(path[i],path[i+1]);if(pair.code.length==0)revert Unavailable();address a=IXStockPair(pair).token0();address b=IXStockPair(pair).token1();if(!((a==path[i]&&b==path[i+1])||(b==path[i]&&a==path[i+1])))revert Invalid();pairs.push(pair);pairHashes.push(pair.codehash);}
  strategyIdentity=keccak256(abi.encode("COMPD_PANCAKE_XSTOCKS_V3",block.chainid,token));riskConfigCommitment=keccak256(abi.encode(uint256(300),uint256(50),uint256(60),uint256(100),guard_,guardHash));venueDependencyCommitment=keccak256(abi.encode(ROUTER,routerHash,factory,factoryHash,token,tokenHash,bridge_,pairs,pairHashes));
 }
 receive() external payable {if(msg.sender!=ROUTER)revert Unauthorized();}
 function _asset(uint8 a) private pure returns(address){if(a==0)return 0xc845b2894dBddd03858fd2D643B4eF725fE0849d;if(a==1)return 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;if(a==2)return 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;if(a==3)return 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a;return 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;}
 function _path(bool buy) private view returns(address[] memory p){p=new address[](bridge==address(0)?2:3);p[0]=buy?WBNB:token;p[p.length-1]=buy?token:WBNB;if(p.length==3)p[1]=bridge;}
 function _quote(bool buy,uint256 input) private view returns(uint256 minimum){
  if(ROUTER.codehash!=routerHash||factory.codehash!=factoryHash||guard.codehash!=guardHash||token.codehash!=tokenHash)revert Unavailable();
  (uint256 ref,uint64 observedAt,uint64 until,bool market)=IXStockIndependentGuard(guard).referenceOut(token,buy,input);
  if(!market||ref==0||observedAt>block.timestamp||block.timestamp-observedAt>60||until<block.timestamp||until>block.timestamp+60)revert Unavailable();
  address[] memory path=_path(buy);uint256[] memory amounts=IXStockRouter(ROUTER).getAmountsOut(input,path);if(amounts.length!=path.length||amounts[0]!=input)revert Invalid();
  for(uint256 i;i+1<path.length;i++){uint256 index=buy?i:pairs.length-1-i;address pair=pairs[index];if(pair.codehash!=pairHashes[index]||IXStockFactory(factory).getPair(path[i],path[i+1])!=pair)revert Unavailable();(uint112 r0,uint112 r1,)=IXStockPair(pair).getReserves();uint256 reserve=IXStockPair(pair).token0()==path[i]?r0:r1;if(amounts[i]>reserve/100)revert Unavailable();}
  uint256 quoted=amounts[amounts.length-1];if(quoted<ref-ref*300/10000||quoted>ref+ref*300/10000)revert Unavailable();uint256 basis=quoted>ref?quoted:ref;minimum=basis-basis*50/10000;if(minimum==0)revert Unavailable();
 }
 function quote(bool buy,uint256 input) external view returns(uint256){return _quote(buy,input);}
 function open(uint256 run,bytes32 allocation,uint256 principal,uint256) external payable onlyExecutor lock returns(bytes32 id){
  if(run==0||allocation==0||principal==0||msg.value!=principal||runUsed[run]||allocationUsed[allocation])revert Invalid();uint256 min=_quote(true,principal);id=keccak256(abi.encode(block.chainid,address(this),run,allocation));runUsed[run]=true;allocationUsed[allocation]=true;
  uint256 beforeShares=IXStockToken(token).sharesOf(address(this));uint256 beforeBalance=IXStockToken(token).balanceOf(address(this));IXStockRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value:principal}(min,_path(true),address(this),block.timestamp+60);uint256 acquired=IXStockToken(token).balanceOf(address(this))-beforeBalance;uint256 acquiredShares=IXStockToken(token).sharesOf(address(this))-beforeShares;if(acquired<min||acquiredShares==0)revert Invalid();positionShares[id]=acquiredShares;totalPositionShares+=acquiredShares;positions[id]=Position(principal,acquired,0,0,true,false);emit Bought(id,principal,acquired);
 }
 function requestExit(bytes32 id,bytes32 exitId) external onlyExecutor lock returns(T.AdapterPositionStatus){Position storage p=positions[id];if(!p.exists||p.closed||exitId==0)revert Invalid();if(p.exitId!=0){if(p.exitId!=exitId)revert Invalid();return T.AdapterPositionStatus.RETURN_PENDING;}
  IXStockToken asset=IXStockToken(token);
  uint256 owned=positionShares[id];uint256 beforeShares=asset.sharesOf(address(this));
  if(owned==0||beforeShares<totalPositionShares)revert Invalid();
  uint256 sold=asset.getUnderlyingAmountByShares(owned);uint256 min=_quote(false,sold);
  uint256 routerShares=asset.getSharesByUnderlyingAmount(sold);
  if(routerShares==0||routerShares>owned)revert Invalid();
  if(!asset.approve(ROUTER,0)||!asset.approve(ROUTER,sold))revert TransferFailed();
  uint256 beforeBalance=address(this).balance;
  // ERC20 transfers floor underlying->shares. Pre-fund only this position's remainder
  // into the fixed SELL input pair. Pancake's supporting-fee swap prices the entire
  // pair balance delta; this transfer and the router swap roll back together.
  uint256 remainder=owned-routerShares;
  if(remainder!=0&&!asset.transferShares(pairs[pairs.length-1],remainder))revert TransferFailed();
  IXStockRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(sold,min,_path(false),address(this),block.timestamp+60);
  if(!asset.approve(ROUTER,0)||asset.allowance(address(this),ROUTER)!=0)revert TransferFailed();
  uint256 received=address(this).balance-beforeBalance;
  if(received<min||beforeShares-asset.sharesOf(address(this))!=owned)revert Invalid();
  totalPositionShares-=owned;positionShares[id]=0;p.tokens=0;p.proceeds=received;p.exitId=exitId;emit Sold(id,sold,received);return T.AdapterPositionStatus.RETURN_PENDING;
 }
 function positionUnderlying(bytes32 id) external view returns(uint256){return IXStockToken(token).getUnderlyingAmountByShares(positionShares[id]);}
 function observe(bytes32 id) external view returns(T.AdapterPositionStatus,uint256,bytes32){Position storage p=positions[id];if(!p.exists)revert Invalid();return(p.closed?T.AdapterPositionStatus.CLOSED:p.exitId==0?T.AdapterPositionStatus.OPEN:T.AdapterPositionStatus.RETURN_PENDING,p.proceeds,bytes32(0));}
 function collect(bytes32,bytes32,uint256) external onlyExecutor view returns(uint256,bytes32){return(0,bytes32(0));}
 function close(bytes32 id,bytes32 closeId) external onlyExecutor lock returns(bytes32){Position storage p=positions[id];if(!p.exists||p.closed||p.exitId==0||closeId==0||p.tokens!=0||positionShares[id]!=0)revert Invalid();uint256 amount=p.proceeds;p.proceeds=0;p.closed=true;(bool ok,)=payable(executor).call{value:amount}("");if(!ok)revert TransferFailed();return id;}
}


