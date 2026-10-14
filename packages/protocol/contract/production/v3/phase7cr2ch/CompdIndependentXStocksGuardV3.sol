// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {IXStockIndependentGuard} from "./CompdPancakeXStocksAdapterV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
interface IXStockUSDFeed {function decimals() external view returns(uint8);function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);}
/// Requires independently qualified holiday, halt and session evidence; not weekday inference.
interface IXStockCalendarFeed {function session(address token) external view returns(bool open,uint64 observedAt,uint64 validUntil);}
/// Fixed independent oracle bridge. No setters, router prices, signing role or fund custody.
/// Asset feed MUST price one raw-token unit denomination (not an unadjusted underlying share).
contract CompdIndependentXStocksGuardV3 is IXStockIndependentGuard {
 address public immutable token;address public immutable tokenUSD;address public immutable bnbUSD;address public immutable calendar;
 bytes32 public immutable tokenFeedHash;bytes32 public immutable bnbFeedHash;bytes32 public immutable calendarHash;
 uint8 public immutable tokenDecimals;uint8 public immutable assetFeedDecimals;uint8 public immutable bnbFeedDecimals;
 uint256 public constant MAX_AGE=60;
 error Unavailable();
 constructor(address token_,uint8 decimals_,address assetUSD_,address bnbUSD_,address calendar_) {
  if(block.chainid!=56||token_.code.length==0||decimals_>18||assetUSD_.code.length==0||bnbUSD_.code.length==0||calendar_.code.length==0||assetUSD_==bnbUSD_||assetUSD_==calendar_||bnbUSD_==calendar_)revert Unavailable();
  token=token_;tokenDecimals=decimals_;tokenUSD=assetUSD_;bnbUSD=bnbUSD_;calendar=calendar_;tokenFeedHash=assetUSD_.codehash;bnbFeedHash=bnbUSD_.codehash;calendarHash=calendar_.codehash;
  assetFeedDecimals=IXStockUSDFeed(assetUSD_).decimals();bnbFeedDecimals=IXStockUSDFeed(bnbUSD_).decimals();if(assetFeedDecimals>18||bnbFeedDecimals>18)revert Unavailable();
 }
 function _price(address feed,uint8 decimals_) private view returns(uint256 price,uint64 observedAt){
  if(IXStockUSDFeed(feed).decimals()!=decimals_)revert Unavailable();(uint80 round,int256 answer,,uint256 updated,uint80 answered)=IXStockUSDFeed(feed).latestRoundData();
  if(round==0||answered<round||answer<=0||updated==0||updated>block.timestamp||block.timestamp-updated>MAX_AGE||updated>type(uint64).max)revert Unavailable();price=uint256(answer)*10**(18-decimals_);observedAt=uint64(updated);
 }
 function referenceOut(address asset,bool buy,uint256 input) external view returns(uint256 output,uint64 observedAt,uint64 validUntil,bool marketOpen){
  if(block.chainid!=56||asset!=token||input==0||tokenUSD.codehash!=tokenFeedHash||bnbUSD.codehash!=bnbFeedHash||calendar.codehash!=calendarHash)revert Unavailable();
  (uint256 stock,uint64 stockAt)=_price(tokenUSD,assetFeedDecimals);(uint256 bnb,uint64 bnbAt)=_price(bnbUSD,bnbFeedDecimals);(bool opened,uint64 calendarAt,uint64 until)=IXStockCalendarFeed(calendar).session(token);
  if(!opened||calendarAt==0||calendarAt>block.timestamp||block.timestamp-calendarAt>MAX_AGE||until<=block.timestamp||until>block.timestamp+MAX_AGE)revert Unavailable();
  // BNB uses18 decimals; token quantities use the configured verified raw-token decimals.
  uint256 scale=10**(18-tokenDecimals);output=buy?Math.mulDiv(input,bnb,stock)/scale:Math.mulDiv(input,stock,bnb)*scale;if(output==0)revert Unavailable();
  observedAt=stockAt<bnbAt?stockAt:bnbAt;if(calendarAt<observedAt)observedAt=calendarAt;validUntil=until;uint64 ageExpiry=observedAt+uint64(MAX_AGE);if(ageExpiry<validUntil)validUntil=ageExpiry;if(validUntil<=block.timestamp)revert Unavailable();marketOpen=true;
 }
}
