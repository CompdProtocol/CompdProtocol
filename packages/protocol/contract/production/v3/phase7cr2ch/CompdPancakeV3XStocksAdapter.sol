// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {IXStockToken,IXStockRouter,IXStockFactory,IXStockPair,IXStockIndependentGuard} from "./CompdPancakeXStocksAdapterV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
interface IXStocksV3Pool {
 function token0() external view returns(address);function token1() external view returns(address);
 function fee() external view returns(uint24);function liquidity() external view returns(uint128);
 function slot0() external view returns(uint160,int24,uint16,uint16,uint16,uint32,bool);
 function swap(address,bool,int256,uint160,bytes calldata) external returns(int256,int256);
}
interface IXStocksV3Factory {function getPool(address,address,uint24) external view returns(address);}
interface IXStocksStable {function balanceOf(address) external view returns(uint256);function transfer(address,uint256) external returns(bool);function approve(address,uint256) external returns(bool);function allowance(address,address) external view returns(uint256);}
/// Fixed TSLAx/AMZNx V3 venue; admission and independent guard qualification remain separate.
/// Shares are custody authority. No administrative withdrawals, configurable routes or signer.
contract CompdPancakeV3XStocksAdapter is IC2G2BStrategyAdapterR4 {
 address public constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;
 address public constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
 address public constant USDT=0x55d398326f99059fF775485246999027B3197955;
 address public constant V3_FACTORY=0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
 uint256 private constant Q96=2**96;
 address public immutable executor;address public immutable token;address public immutable guard;address public immutable pool;address public immutable bridgePair;address public immutable factory;
 uint24 public immutable fee;bool public immutable stableIsToken0;
 bytes32 public immutable routerHash;bytes32 public immutable tokenHash;bytes32 public immutable guardHash;bytes32 public immutable poolHash;bytes32 public immutable bridgeHash;bytes32 public immutable factoryHash;bytes32 public immutable v3FactoryHash;
 bytes32 public immutable strategyIdentity;bytes32 public immutable riskConfigCommitment;bytes32 public immutable venueDependencyCommitment;
 struct Position {uint256 principal;uint256 tokens;uint256 proceeds;bytes32 exitId;bool exists;bool closed;}
 mapping(bytes32=>Position) public positions;mapping(bytes32=>uint256) public positionShares;
 mapping(uint256=>bool) public runUsed;mapping(bytes32=>bool) public allocationUsed;uint256 public totalPositionShares;
 bool private entered;bool private swapping;bool private callbackPaid;bool private buying;uint256 private callbackInput;uint256 private callbackShares;
 error Invalid();error Unauthorized();error Unavailable();error TransferFailed();
 event Bought(bytes32 indexed position,uint256 bnb,uint256 tokens);event Sold(bytes32 indexed position,uint256 tokens,uint256 bnb);
 modifier onlyExecutor(){if(msg.sender!=executor)revert Unauthorized();_;}
 modifier lock(){if(entered)revert Unauthorized();entered=true;_;entered=false;}
 constructor(address executor_,uint8 asset,address guard_) {
  if(block.chainid!=56||executor_.code.length==0||guard_.code.length==0||(asset!=1&&asset!=2))revert Invalid();
  executor=executor_;guard=guard_;
  token=asset==1?0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0:0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;
  pool=asset==1?0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492:0x28A73f5bd589Fea90BA0D24117BF91D648be3ef2;
  fee=asset==1?2500:100;factory=IXStockRouter(ROUTER).factory();
  bridgePair=IXStockFactory(factory).getPair(WBNB,USDT);
  if(IXStockRouter(ROUTER).WETH()!=WBNB||token.code.length==0||pool.code.length==0||bridgePair.code.length==0||V3_FACTORY.code.length==0)revert Invalid();
  address a=IXStocksV3Pool(pool).token0();address b=IXStocksV3Pool(pool).token1();
  if(!((a==USDT&&b==token)||(a==token&&b==USDT))||IXStocksV3Pool(pool).fee()!=fee||IXStocksV3Factory(V3_FACTORY).getPool(token,USDT,fee)!=pool)revert Invalid();
  stableIsToken0=a==USDT;
  a=IXStockPair(bridgePair).token0();b=IXStockPair(bridgePair).token1();if(!((a==USDT&&b==WBNB)||(a==WBNB&&b==USDT)))revert Invalid();
  routerHash=ROUTER.codehash;tokenHash=token.codehash;guardHash=guard_.codehash;poolHash=pool.codehash;bridgeHash=bridgePair.codehash;factoryHash=factory.codehash;v3FactoryHash=V3_FACTORY.codehash;
  strategyIdentity=keccak256(abi.encode("COMPD_PANCAKE_V3_XSTOCKS",block.chainid,token));
  riskConfigCommitment=keccak256(abi.encode(uint256(300),uint256(50),uint256(60),uint256(100),guard_,guardHash));
  venueDependencyCommitment=keccak256(abi.encode(ROUTER,routerHash,token,tokenHash,pool,poolHash,bridgePair,bridgeHash,factory,factoryHash,V3_FACTORY,v3FactoryHash,fee));
 }
 receive() external payable {if(msg.sender!=ROUTER)revert Unauthorized();}
 function _check() private view {
  if(block.chainid!=56||ROUTER.codehash!=routerHash||token.codehash!=tokenHash||guard.codehash!=guardHash||pool.codehash!=poolHash||bridgePair.codehash!=bridgeHash||factory.codehash!=factoryHash||V3_FACTORY.codehash!=v3FactoryHash||IXStocksV3Pool(pool).liquidity()==0||IXStocksV3Factory(V3_FACTORY).getPool(token,USDT,fee)!=pool||IXStockFactory(factory).getPair(WBNB,USDT)!=bridgePair)revert Unavailable();
 }
 function _path(bool buy) private pure returns(address[] memory p){p=new address[](2);p[0]=buy?WBNB:USDT;p[1]=buy?USDT:WBNB;}
 function _bridgeQuote(bool buy,uint256 n) private view returns(uint256 quoted){
  (uint112 r0,uint112 r1,)=IXStockPair(bridgePair).getReserves();address input=buy?WBNB:USDT;
  uint256 reserve=IXStockPair(bridgePair).token0()==input?r0:r1;if(n==0||n>reserve/100)revert Unavailable();
  uint256[] memory q=IXStockRouter(ROUTER).getAmountsOut(n,_path(buy));if(q.length!=2||q[0]!=n||q[1]==0)revert Unavailable();return q[1];
 }
 function _spot(bool buy,uint256 n,uint160 sqrt) private view returns(uint256){
  bool zeroForOne=buy?stableIsToken0:!stableIsToken0;
  uint256 out=zeroForOne?Math.mulDiv(Math.mulDiv(n,sqrt,Q96),sqrt,Q96):Math.mulDiv(Math.mulDiv(n,Q96,sqrt),Q96,sqrt);
  return out-Math.mulDiv(out,fee,1000000);
 }
 function _reference(bool buy,uint256 n) private view returns(uint256 ref){
  (uint256 r,uint64 at,uint64 until,bool opened)=IXStockIndependentGuard(guard).referenceOut(token,buy,n);
  if(!opened||r==0||at==0||at>block.timestamp||block.timestamp-at>60||until<=block.timestamp||until>block.timestamp+60)revert Unavailable();return r;
 }
 // Spot is a bounded execution estimate, never an independent price reference.
 function quote(bool buy,uint256 n) external view returns(uint256){return _minimum(buy,n);}
 function _minimum(bool buy,uint256 n) private view returns(uint256 minimum){
  _check();uint256 ref=_reference(buy,n);(uint160 sqrt,,,,,,bool unlocked)=IXStocksV3Pool(pool).slot0();if(!unlocked||sqrt==0)revert Unavailable();
  uint256 estimate=buy?_spot(true,_bridgeQuote(true,n),sqrt):_bridgeQuote(false,_spot(false,n,sqrt));
  if(estimate<ref-ref*300/10000||estimate>ref+ref*300/10000)revert Unavailable();
  uint256 basis=estimate>ref?estimate:ref;minimum=basis-basis*50/10000;if(minimum==0)revert Unavailable();
 }
 function _swap(bool buy,uint256 n,uint256 owned) private returns(uint256 output){
  if(n==0||n>uint256(type(int256).max))revert Invalid();(uint160 sqrt,,,,,,bool unlocked)=IXStocksV3Pool(pool).slot0();if(!unlocked)revert Unavailable();
  bool zeroForOne=buy?stableIsToken0:!stableIsToken0;
  // <=0.5% sqrt-price movement (<1.003% terminal spot movement), plus exact
  // 1% average output-impact bound below. Partial fills always revert atomically.
  uint256 limit=zeroForOne?uint256(sqrt)*995/1000:uint256(sqrt)*1005/1000;
  if(limit<=4295128739||limit>=1461446703485210103287273052203988822378723970342)revert Unavailable();
  swapping=true;buying=buy;callbackInput=n;callbackShares=owned;callbackPaid=false;
  (int256 d0,int256 d1)=IXStocksV3Pool(pool).swap(address(this),zeroForOne,int256(n),uint160(limit),"");
  if(!callbackPaid)revert Invalid();swapping=false;callbackInput=0;callbackShares=0;
  int256 used=zeroForOne?d0:d1;int256 received=zeroForOne?d1:d0;
  if(used!=int256(n)||received>=0||received==type(int256).min)revert Unavailable();output=uint256(-received);
  uint256 spot=_spot(buy,n,sqrt);if(output<spot-spot/100)revert Unavailable();
 }
 function pancakeV3SwapCallback(int256 d0,int256 d1,bytes calldata) external {
  if(msg.sender!=pool||!entered||!swapping||callbackPaid)revert Unauthorized();
  bool zeroForOne=buying?stableIsToken0:!stableIsToken0;int256 owed=zeroForOne?d0:d1;int256 other=zeroForOne?d1:d0;
  if(owed<=0||uint256(owed)>callbackInput||other>=0)revert Invalid();callbackPaid=true;
  if(buying){if(!IXStocksStable(USDT).transfer(pool,uint256(owed)))revert TransferFailed();}
  else {if(uint256(owed)!=callbackInput||callbackShares==0||!IXStockToken(token).transferShares(pool,callbackShares))revert TransferFailed();}
 }
 function open(uint256 run,bytes32 allocation,uint256 principal,uint256) external payable onlyExecutor lock returns(bytes32 id){
  if(run==0||allocation==0||principal==0||msg.value!=principal||runUsed[run]||allocationUsed[allocation])revert Invalid();uint256 min=_minimum(true,principal);
  id=keccak256(abi.encode(block.chainid,address(this),run,allocation));runUsed[run]=true;allocationUsed[allocation]=true;
  IXStockToken asset=IXStockToken(token);uint256 sharesBefore=asset.sharesOf(address(this));uint256 balanceBefore=asset.balanceOf(address(this));uint256 stableBefore=IXStocksStable(USDT).balanceOf(address(this));
  uint256 bridgeMin=_bridgeQuote(true,principal);bridgeMin-=bridgeMin*50/10000;
  IXStockRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value:principal}(bridgeMin,_path(true),address(this),block.timestamp+60);
  uint256 stable=IXStocksStable(USDT).balanceOf(address(this))-stableBefore;_swap(true,stable,0);
  uint256 acquired=asset.balanceOf(address(this))-balanceBefore;uint256 shares=asset.sharesOf(address(this))-sharesBefore;
  if(acquired<min||shares==0||IXStocksStable(USDT).balanceOf(address(this))!=stableBefore)revert Unavailable();
  positionShares[id]=shares;totalPositionShares+=shares;positions[id]=Position(principal,acquired,0,0,true,false);emit Bought(id,principal,acquired);
 }
 function requestExit(bytes32 id,bytes32 exitId) external onlyExecutor lock returns(T.AdapterPositionStatus){
  Position storage p=positions[id];if(!p.exists||p.closed||exitId==0)revert Invalid();if(p.exitId!=0){if(p.exitId!=exitId)revert Invalid();return T.AdapterPositionStatus.RETURN_PENDING;}
  IXStockToken asset=IXStockToken(token);uint256 owned=positionShares[id];uint256 beforeShares=asset.sharesOf(address(this));if(owned==0||beforeShares<totalPositionShares)revert Invalid();
  uint256 sold=asset.getUnderlyingAmountByShares(owned);uint256 min=_minimum(false,sold);uint256 stableBefore=IXStocksStable(USDT).balanceOf(address(this));uint256 nativeBefore=address(this).balance;
  _swap(false,sold,owned);uint256 stable=IXStocksStable(USDT).balanceOf(address(this))-stableBefore;
  if(!IXStocksStable(USDT).approve(ROUTER,0)||!IXStocksStable(USDT).approve(ROUTER,stable))revert TransferFailed();
  IXStockRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(stable,min,_path(false),address(this),block.timestamp+60);
  if(!IXStocksStable(USDT).approve(ROUTER,0)||IXStocksStable(USDT).allowance(address(this),ROUTER)!=0||IXStocksStable(USDT).balanceOf(address(this))!=stableBefore)revert TransferFailed();
  uint256 received=address(this).balance-nativeBefore;if(received<min||beforeShares-asset.sharesOf(address(this))!=owned)revert Invalid();
  positionShares[id]=0;totalPositionShares-=owned;p.tokens=0;p.proceeds=received;p.exitId=exitId;emit Sold(id,sold,received);return T.AdapterPositionStatus.RETURN_PENDING;
 }
 function positionUnderlying(bytes32 id) external view returns(uint256){return IXStockToken(token).getUnderlyingAmountByShares(positionShares[id]);}
 function observe(bytes32 id) external view returns(T.AdapterPositionStatus,uint256,bytes32){Position storage p=positions[id];if(!p.exists)revert Invalid();return(p.closed?T.AdapterPositionStatus.CLOSED:p.exitId==0?T.AdapterPositionStatus.OPEN:T.AdapterPositionStatus.RETURN_PENDING,p.proceeds,bytes32(0));}
 function collect(bytes32,bytes32,uint256) external onlyExecutor view returns(uint256,bytes32){return(0,bytes32(0));}
 function close(bytes32 id,bytes32 closeId) external onlyExecutor lock returns(bytes32){Position storage p=positions[id];if(!p.exists||p.closed||p.exitId==0||closeId==0||p.tokens!=0||positionShares[id]!=0)revert Invalid();uint256 n=p.proceeds;p.proceeds=0;p.closed=true;(bool ok,)=payable(executor).call{value:n}("");if(!ok)revert TransferFailed();return id;}
}
