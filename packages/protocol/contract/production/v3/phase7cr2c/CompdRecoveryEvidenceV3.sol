// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IC2G2BRecoveryEvidence} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdCanonicalHolderStateV3 as State} from "./CompdCanonicalHolderStateV3.sol";

/// @notice Deterministic V3 recovery view/consume adapter; no eligibility storage or authority.
contract CompdRecoveryEvidenceV3 is IC2G2BRecoveryEvidence {
    address public immutable kernel;
    address public immutable state;
    bytes32 public immutable stateCodeHash;
    error ChangedCode(); error Unauthorized();
    constructor(address kernel_,address state_){if(kernel_==address(0)||state_.code.length==0)revert Unauthorized();kernel=kernel_;state=state_;stateCodeHash=_hash(state_);if(State(state_).kernel()!=kernel_||State(state_).recoveryEvidence()!=address(this))revert Unauthorized();}
    function protocolReserveRecovery(bytes32 id) external view override returns(bool,uint256){_check();return State(state).protocolReserveRecovery(id);}
    function treasuryPrincipalRecovery(bytes32 id) external view override returns(bool,uint256){_check();return State(state).treasuryPrincipalRecovery(id);}
    function noRecipientRecovery(bytes32 id) external view override returns(bool,uint256){_check();return State(state).noRecipientRecovery(id);}
    function expiredHolderRecovery(bytes32 id) external view override returns(bool,uint256){_check();return State(state).expiredHolderRecovery(id);}
    function consumeProtocolReserve(bytes32 id) external override {_onlyKernel();_check();State(state).consumeProtocolReserve(id);}
    function consumeTreasuryPrincipal(bytes32 id) external override {_onlyKernel();_check();State(state).consumeTreasuryPrincipal(id);}
    function consumeNoRecipient(bytes32 id) external override {_onlyKernel();_check();State(state).consumeNoRecipient(id);}
    function consumeExpiredHolder(bytes32 id) external override {_onlyKernel();_check();State(state).consumeExpiredHolder(id);}
    function recoveryReconciliationComplete() external view returns(bool){return State(state).recoveryReconciliationComplete();}
    function _onlyKernel() private view {if(msg.sender!=kernel)revert Unauthorized();}
    function _check() private view {if(_hash(state)!=stateCodeHash)revert ChangedCode();}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
