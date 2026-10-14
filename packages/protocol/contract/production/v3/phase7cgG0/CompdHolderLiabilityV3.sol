// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IC2G2BHolderLiability} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdCanonicalHolderStateV3 as State} from "./CompdCanonicalHolderStateV3.sol";

/// @notice Independent R2-compatible Liability peer; stores no duplicate liability database.
contract CompdHolderLiabilityV3 is IC2G2BHolderLiability {
    address public immutable kernel;
    address public immutable state;
    bytes32 public immutable stateCodeHash;
    error Unauthorized(); error ChangedCode();
    constructor(address kernel_,address state_){if(kernel_==address(0)||state_.code.length==0)revert Unauthorized();kernel=kernel_;state=state_;stateCodeHash=_hash(state_);if(State(state_).kernel()!=kernel_)revert Unauthorized();}
    function canonicalState() external view returns(address){return state;}
    function paymentDigest(bytes32 leafId) external view override returns(bytes32){return State(state).paymentDigest(leafId);}
    function canonicalPayment(bytes32 leafId) external view returns(bytes32,address,address,uint256,uint8,bool){return State(state).canonicalPayment(leafId);}
    function terminalReconciliation() external view returns(bytes32,uint256){return State(state).terminalReconciliation();}
    function consumePayment(bytes32 leafId,bytes32 digest) external override {if(msg.sender!=kernel)revert Unauthorized();if(_hash(state)!=stateCodeHash)revert ChangedCode();State(state).acknowledgePayment(leafId,digest);}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
