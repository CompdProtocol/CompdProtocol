// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {OfflineToken,OfflinePurchasePortal} from "./OfflineFixtures.sol";
/// @dev Disposable fixture, never independently qualified or production allowlisted.
contract DeferredRouteFixture {
 address public constant token=0x7b7Af51136574c91A12988989c0a08E98aE97777;
 address public executor;address public boundSelector;
 uint64 public observed;uint64 public deadline;
 constructor(address e){executor=e;boundSelector=e;}
 function configure(uint64 o,uint64 d) external {observed=o;deadline=d;}
 function routeVerified(address p) external pure returns(bool){return p==address(0);}
 function quote(bytes32,uint256) external view returns(uint256,uint256,uint64,uint64){return(1000,970,observed,deadline);}
 function swapExactBNBForCOMPD(bytes32,uint256 m,uint64 d,address recipient) external payable {
  require(msg.sender==executor&&recipient==executor&&d>=block.timestamp);
  OfflinePurchasePortal(0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0).swapExactInput{value:msg.value}(OfflinePurchasePortal.ExactInputParams(address(0),token,msg.value,m,""));
  require(OfflineToken(token).transfer(executor,1000));
 }
}
