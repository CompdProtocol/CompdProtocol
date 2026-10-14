// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {ICompdBuybackAdapterV3} from "./CompdBuybackExecutorV3.sol";
interface ICompdPoolStateV3 {function state() external view returns(uint8);function mainPool() external view returns(address);}
interface ICompdVerifiedRouteV3 is ICompdBuybackAdapterV3 {
    /// @dev The reviewed implementation must independently verify its fixed router,
    /// pool, liquidity, price source, tax and (for post-bonding) Pancake factory binding.
    function routeVerified(address pool) external view returns(bool);
}
/// @notice Immutable phase selector. Missing or contradictory evidence disables both routes.
/// @dev PoolState/getTokenV8Safe layout is interface evidence only; real sources remain required.
contract CompdPhaseBuybackAdapterV3 is ICompdBuybackAdapterV3 {
    address public constant token=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public immutable portal;bytes32 public immutable portalHash;bytes32 public immutable tokenHash;
    address public immutable preRoute;address public immutable postRoute;bytes32 public immutable preHash;bytes32 public immutable postHash;
    error Disabled();
    constructor(address portal_,bytes32 tokenHash_,address pre_,address post_){
        if(portal_.code.length==0||tokenHash_==0||pre_==post_&&pre_!=address(0))revert Disabled();
        if((pre_!=address(0)&&pre_.code.length==0)||(post_!=address(0)&&post_.code.length==0))revert Disabled();
        portal=portal_;portalHash=portal_.codehash;tokenHash=tokenHash_;preRoute=pre_;postRoute=post_;
        preHash=pre_==address(0)?bytes32(0):pre_.codehash;postHash=post_==address(0)?bytes32(0):post_.codehash;
    }
    function selectedRoute() public view returns(address route,uint8 phase,uint256 threshold,address pool){
        if(block.chainid!=56||portal.codehash!=portalHash||token.code.length==0||token.codehash!=tokenHash)return(address(0),0,0,address(0));
        (bool ok,bytes memory data)=portal.staticcall(abi.encodeWithSignature("getTokenV8Safe(address)",token));
        if(!ok||data.length!=18*32)return(address(0),0,0,address(0));
        uint256 status;uint256 quoteAsset;uint256 tokenVersion;uint256 dexId;uint256 poolWord;
        assembly{status:=mload(add(data,32)) tokenVersion:=mload(add(data,160)) threshold:=mload(add(data,288)) quoteAsset:=mload(add(data,320)) poolWord:=mload(add(data,480)) dexId:=mload(add(data,576))}
        if(tokenVersion!=6||quoteAsset!=0||poolWord>type(uint160).max)return(address(0),0,threshold,address(0));
        pool=address(uint160(poolWord));uint8 state;
        try ICompdPoolStateV3(token).state() returns(uint8 s){state=s;}catch{return(address(0),0,threshold,pool);}
        if(status==1&&state==0&&pool==address(0)){phase=1;route=preRoute;}
        else if(status==4&&(state==2||state==3||state==4)&&pool.code.length!=0&&dexId==0){
            try ICompdPoolStateV3(token).mainPool() returns(address main){if(main!=pool)return(address(0),0,threshold,pool);}catch{return(address(0),0,threshold,pool);}
            phase=2;route=postRoute;
        }else{return(address(0),0,threshold,pool);}
        bytes32 expected=phase==1?preHash:postHash;
        if(route==address(0)||route.codehash!=expected)return(address(0),phase,threshold,pool);
        try ICompdVerifiedRouteV3(route).token() returns(address t){if(t!=token)return(address(0),phase,threshold,pool);}catch{return(address(0),phase,threshold,pool);}
        try ICompdVerifiedRouteV3(route).routeVerified(pool) returns(bool verified){if(!verified)return(address(0),phase,threshold,pool);}catch{return(address(0),phase,threshold,pool);}
    }
    function quote(bytes32 id,uint256 input) external view returns(uint256,uint256,uint64,uint64){
        (address route,,,)=selectedRoute();if(route==address(0))revert Disabled();return ICompdVerifiedRouteV3(route).quote(id,input);
    }
    function swapExactBNBForCOMPD(bytes32 id,uint256 minimum,uint64 deadline,address recipient) external payable {
        // Recipient is always the calling executor/keeper; no arbitrary recipient is accepted.
        if(recipient!=msg.sender||deadline<block.timestamp)revert Disabled();
        (address route,uint8 phase,,)=selectedRoute();if(route==address(0))revert Disabled();
        ICompdVerifiedRouteV3(route).swapExactBNBForCOMPD{value:msg.value}(id,minimum,deadline,recipient);
        (address afterRoute,uint8 afterPhase,,)=selectedRoute();
        // A swap that migrates mid-operation must be retried on the new verified phase, atomically.
        if(afterRoute!=route||afterPhase!=phase)revert Disabled();
    }
}
