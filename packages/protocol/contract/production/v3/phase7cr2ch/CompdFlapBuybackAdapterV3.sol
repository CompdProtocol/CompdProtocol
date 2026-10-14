// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {ICompdBuybackAdapterV3} from "./CompdBuybackExecutorV3.sol";
/// @dev A separately qualified immutable guard must verify implementation identities,
/// route/tax assumptions and an independent price bound. No guard is approved by this patch.
interface ICompdFlapQuoteGuardV3 {
 function routeVerified(address portal,address token,bytes32 tokenHash) external view returns(bool);
 function quote(bytes32 id,uint256 input) external view returns(uint256,uint256,uint64,uint64);
}
interface ICompdFlapPurchaseV3 {
 struct ExactInputParams {address inputToken;address outputToken;uint256 inputAmount;uint256 minOutputAmount;bytes permitData;}
 function swapExactInput(ExactInputParams calldata params) external payable returns(uint256);
}
interface ICompdRouteTokenV3 {function balanceOf(address) external view returns(uint256);function transfer(address,uint256) external returns(bool);function state() external view returns(uint8);}
/// @notice Fixed native bonding-curve purchase transport; never a caller-selected router.
/// @dev Official IPortal ABI at commit 5949cc7. Deployment remains blocked pending guard
/// and actual COMPD native-burn qualification. Portal spot quoting alone is not a price oracle.
contract CompdFlapBuybackAdapterV3 is ICompdBuybackAdapterV3 {
 address public constant token=0x7b7Af51136574c91A12988989c0a08E98aE97777;
 address public constant portal=0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
 address public immutable boundSelector;address public immutable executor;address public immutable guard;
 bytes32 public immutable portalHash;bytes32 public immutable tokenHash;bytes32 public immutable guardHash;
 bool private entered;error Disabled();
 constructor(address selector_,address executor_,address guard_,bytes32 tokenHash_){
  if(selector_==address(0)||executor_==address(0)||guard_.code.length==0||portal.code.length==0||tokenHash_==0)revert Disabled();
  boundSelector=selector_;executor=executor_;guard=guard_;portalHash=portal.codehash;tokenHash=tokenHash_;guardHash=guard_.codehash;
 }
 function routeVerified(address pool) public view returns(bool){
  if(pool!=address(0)||block.chainid!=56||portal.codehash!=portalHash||token.code.length==0||token.codehash!=tokenHash||guard.codehash!=guardHash)return false;
  try ICompdRouteTokenV3(token).state() returns(uint8 state){if(state!=0)return false;}catch{return false;}
  (bool ok,bytes memory data)=portal.staticcall(abi.encodeWithSignature("getTokenV8Safe(address)",token));
  if(!ok||data.length!=576)return false;
  uint256 status;uint256 version;uint256 quoteAsset;uint256 poolWord;bytes32 extension;
  assembly{status:=mload(add(data,32)) version:=mload(add(data,160)) quoteAsset:=mload(add(data,320)) extension:=mload(add(data,384)) poolWord:=mload(add(data,480))}
  // Extensions require separate qualification and are not admitted by this minimal route.
  if(status!=1||version!=6||quoteAsset!=0||poolWord!=0||extension!=0)return false;
  try ICompdFlapQuoteGuardV3(guard).routeVerified(portal,token,tokenHash) returns(bool valid){return valid;}catch{return false;}
 }
 function quote(bytes32 id,uint256 input) public view returns(uint256 expected,uint256 minimum,uint64 observed,uint64 deadline){
  if(id==0||input==0||!routeVerified(address(0)))revert Disabled();
  (expected,minimum,observed,deadline)=ICompdFlapQuoteGuardV3(guard).quote(id,input);
  if(expected==0||minimum==0||minimum>expected||minimum<expected-(expected*300/10000)||observed>block.timestamp||block.timestamp-observed>300||deadline<block.timestamp||deadline<observed||deadline-observed>300)revert Disabled();
  // Non-view official ABI: only accept deployments whose quote succeeds under STATICCALL.
  (bool ok,bytes memory data)=portal.staticcall(abi.encodeWithSignature("quoteExactInput((address,address,uint256))",address(0),token,input));
  if(!ok||data.length!=32)revert Disabled();uint256 spot=abi.decode(data,(uint256));
  if(spot<minimum||spot>expected+expected*300/10000)revert Disabled();
 }
 function swapExactBNBForCOMPD(bytes32 id,uint256 minimum,uint64 deadline,address recipient) external payable {
  if(entered||msg.sender!=boundSelector||recipient!=executor)revert Disabled();entered=true;
  (,uint256 committedMinimum,,uint64 committedDeadline)=quote(id,msg.value);
  if(minimum!=committedMinimum||deadline!=committedDeadline)revert Disabled();
  uint256 nativeBefore=address(this).balance-msg.value;ICompdRouteTokenV3 t=ICompdRouteTokenV3(token);uint256 beforeBalance=t.balanceOf(address(this));uint256 recipientBefore=t.balanceOf(executor);
  ICompdFlapPurchaseV3(portal).swapExactInput{value:msg.value}(ICompdFlapPurchaseV3.ExactInputParams(address(0),token,msg.value,minimum,""));
  uint256 received=t.balanceOf(address(this))-beforeBalance;
  if(address(this).balance!=nativeBefore||received<minimum||!t.transfer(executor,received)||t.balanceOf(address(this))!=beforeBalance||t.balanceOf(executor)-recipientBefore<minimum||!routeVerified(address(0)))revert Disabled();
  entered=false;
 }
}


