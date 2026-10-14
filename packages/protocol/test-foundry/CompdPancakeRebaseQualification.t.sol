// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdPancakeXStocksAdapterTest,XTokenFixture} from "./CompdPancakeXStocksAdapter.t.sol";
import {C2G2BTypes as T} from "../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
/// Labeled local model of issuer-documented EVM share/index mechanics, not deployed issuer bytecode.
contract XRebaseFixture {
 mapping(address=>uint256) public sharesOf;mapping(address=>mapping(address=>uint256)) public allowance;uint256 public index;
 function setIndex(uint256 i) external {index=i;}
 function balanceOf(address who) external view returns(uint256){return sharesOf[who]*index/1 ether;}
 function getSharesByUnderlyingAmount(uint256 n) external view returns(uint256){return n*1 ether/index;}
 function getUnderlyingAmountByShares(uint256 n) external view returns(uint256){return n*index/1 ether;}
 function transferShares(address to,uint256 n) external returns(bool){sharesOf[msg.sender]-=n;sharesOf[to]+=n;return true;}
 function mint(address who,uint256 amount) external {sharesOf[who]+=amount*1 ether/index;}
 function approve(address to,uint256 amount) external returns(bool){allowance[msg.sender][to]=amount;return true;}
 function transferFrom(address from,address to,uint256 amount) external returns(bool){allowance[from][msg.sender]-=amount;uint256 shares=amount*1 ether/index;sharesOf[from]-=shares;sharesOf[to]+=shares;return true;}
}
contract CompdPancakeRebaseQualificationTest is CompdPancakeXStocksAdapterTest {
 function testRebasePositiveFullPositionMustBeSold() public {XRebaseFixture impl=new XRebaseFixture();vm.etch(TOKEN,address(impl).code);XRebaseFixture token=XRebaseFixture(TOKEN);token.setIndex(1 ether);
 // Reconstruct adapter so pinned runtime matches the modeled token from entry onward.
 a=newAdapter();admitNew();k.open(a,1,1 ether);token.setIndex(2 ether);k.exit(1,bytes32(uint256(22)));k.close(1);assertEq(token.balanceOf(address(a)),0,"REBASE_POSITION_STRANDED");}
 function testRebaseNegativePositionMustRemainClosable() public {XRebaseFixture impl=new XRebaseFixture();vm.etch(TOKEN,address(impl).code);XRebaseFixture token=XRebaseFixture(TOKEN);token.setIndex(1 ether);a=newAdapter();admitNew();k.open(a,1,1 ether);token.setIndex(.5 ether);k.exit(1,bytes32(uint256(22)));assertEq(uint256(e.runState(1)),uint256(T.StrategyRunState.RETURN_PENDING),"REBASE_EXIT_BLOCKED");}
 function testRebaseFractionalRemainderNotStrandedOrTakenFromOtherPosition() public {
  XRebaseFixture token=installRebase();bytes32 first=k.open(a,1,1 ether+1);bytes32 second=k.open(a,2,1 ether+2);token.setIndex(7 ether/10);
  uint256 secondShares=a.positionShares(second);uint256 firstValue=a.positionUnderlying(first);
  k.exit(1,bytes32(uint256(22)));(,uint256 returned,)=k.close(1);
  assertEq(returned,firstValue);assertEq(a.positionShares(first),0);assertEq(token.sharesOf(address(a)),secondShares);assertEq(a.totalPositionShares(),secondShares);
  token.setIndex(13 ether/10);k.exit(2,bytes32(uint256(23)));k.close(2);assertEq(token.sharesOf(address(a)),0);assertEq(a.totalPositionShares(),0);
 }
 function testRebaseFailedSellRollsBackRemainderAndRetry() public {
  XRebaseFixture token=installRebase();bytes32 id=k.open(a,1,1 ether+1);token.setIndex(7 ether/10);uint256 owned=a.positionShares(id);uint256 pairShares=token.sharesOf(address(pair));
  r.setFail(true);k.exit(1,bytes32(uint256(22)));assertEq(token.sharesOf(address(a)),owned);assertEq(token.sharesOf(address(pair)),pairShares);assertEq(a.positionShares(id),owned);assertEq(token.allowance(address(a),ROUTER),0);
  r.setFail(false);k.exit(1,bytes32(uint256(22)));k.close(1);assertEq(token.sharesOf(address(a)),0);
 }
 function testRebaseAccidentalSharesNeverCreditedToPosition() public {
  XRebaseFixture token=installRebase();token.mint(address(a),12345);uint256 accidental=token.sharesOf(address(a));k.open(a,1,1 ether+1);token.setIndex(7 ether/10);k.exit(1,bytes32(uint256(22)));k.close(1);assertEq(token.sharesOf(address(a)),accidental);assertEq(a.totalPositionShares(),0);
 }
 function testRebaseFuzzRoundingAndIsolation(uint64 raw,uint64 multiplier) public {
  XRebaseFixture token=installRebase();uint256 principal=bound(uint256(raw),1e9,1e15);uint256 index=bound(uint256(multiplier),1e17,3e18);
  token.mint(address(a),12345);uint256 accidental=token.sharesOf(address(a));bytes32 id=k.open(a,1,principal);token.setIndex(index);uint256 value=a.positionUnderlying(id);k.exit(1,bytes32(uint256(22)));(,uint256 returned,)=k.close(1);assertEq(returned,value);assertEq(token.sharesOf(address(a)),accidental);assertEq(a.positionShares(id),0);assertEq(a.totalPositionShares(),0);
 }
 function installRebase() private returns(XRebaseFixture token){XRebaseFixture impl=new XRebaseFixture();vm.etch(TOKEN,address(impl).code);token=XRebaseFixture(TOKEN);token.setIndex(1 ether);a=newAdapter();admitNew();}
 function newAdapter() private returns(A){return new A(address(e),1,address(0),address(g));}
 function admitNew() private {e.proposeStrategy(address(a),a.strategyIdentity(),a.riskConfigCommitment(),a.venueDependencyCommitment());vm.warp(block.timestamp+24 hours);e.activateStrategy(address(a));}
}
import {CompdPancakeXStocksAdapterV3 as A} from "../contracts/production/v3/phase7cr2ch/CompdPancakeXStocksAdapterV3.sol";
