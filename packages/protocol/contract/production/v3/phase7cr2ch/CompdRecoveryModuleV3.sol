// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {IC2G2BKernel,IC2G2BRecoveryEvidence} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface IRecoveryV3Kernel {
    function executeRecovery(uint8,bytes32) external returns(uint256);
    function recoveryEvidence() external view returns(address);
    function recoveryEvidenceHash() external view returns(bytes32);
    function lifecycle() external view returns(uint8);
}
interface IRecoveryV3Evidence {
    function nonpayableHolderRecovery(bytes32,uint8) external view returns(bool,uint256);
}

/// @notice Typed Guardian recovery executor; all amounts and destination are derived by Kernel/evidence.
contract CompdRecoveryModuleV3 {
    uint8 public constant MODULE_ID=3;
    uint32 public constant MODULE_VERSION=3;
    address public immutable kernel;
    address public immutable evidenceSource;
    bytes32 public immutable sourceHash;
    mapping(bytes32=>bool) public processed;
    error Unauthorized(); error ChangedCode(); error InvalidEvidence();
    event RecoveryEvaluated(bytes32 indexed id,uint8 indexed kind,uint256 amount,bool eligible);
    constructor(address kernel_,address evidence_,bytes32 evidenceHash_){if(kernel_==address(0)||evidence_==address(0)||evidenceHash_==0)revert Unauthorized();kernel=kernel_;evidenceSource=evidence_;sourceHash=evidenceHash_;}
    function moduleId() external pure returns(uint8){return MODULE_ID;}
    function moduleVersion() external pure returns(uint32){return MODULE_VERSION;}
    function recoverProtocol(bytes32 id) external {_recover(id,0);}
    function recoverNoRecipient(bytes32 id) external {_recover(id,1);}
    function recoverExpiredLiability(bytes32 id) external {_recover(id,2);}
    function recoverTreasuryPrincipal(bytes32 id) external {_recover(id,3);}
    function recoverPartialActivation(bytes32 id) external {_recoverPartition(id,1);}
    function recoverActivationSealFailure(bytes32 id) external {_recoverPartition(id,2);}
    function recoverShutdownTail(bytes32 id) external {_recoverPartition(id,3);}
    function _recover(bytes32 id,uint8 kind) private {bytes32 key=keccak256(abi.encode(kind,id));if(msg.sender!=_guardian()||id==0||processed[key]||!_bound())revert Unauthorized();processed[key]=true;uint256 amount=IRecoveryV3Kernel(kernel).executeRecovery(kind,id);emit RecoveryEvaluated(id,kind,amount,true);}    function _recoverPartition(bytes32 id,uint8 partition) private {bytes32 key=keccak256(abi.encode(partition,id));if(msg.sender!=_guardian()||id==0||processed[key]||!_bound())revert Unauthorized();processed[key]=true;uint8 category=uint8(3+partition);uint256 amount=IRecoveryV3Kernel(kernel).executeRecovery(category,id);emit RecoveryEvaluated(id,uint8(3+partition),amount,true);}
    function authorizeRecovery(uint8 category,bytes32 id) external view returns(bool eligible,uint256 amount){if(msg.sender!=kernel||id==0||!_bound())revert Unauthorized();if(category==0)return IC2G2BRecoveryEvidence(evidenceSource).protocolReserveRecovery(id);if(category==1)return IC2G2BRecoveryEvidence(evidenceSource).noRecipientRecovery(id);if(category==2)return IC2G2BRecoveryEvidence(evidenceSource).expiredHolderRecovery(id);if(category==3)return IC2G2BRecoveryEvidence(evidenceSource).treasuryPrincipalRecovery(id);if(category>=4&&category<=6)return IRecoveryV3Evidence(evidenceSource).nonpayableHolderRecovery(id,category-3);revert InvalidEvidence();}    function terminationReady() external view returns(bool){return _bound()&&IRecoveryFinalityV3(evidenceSource).recoveryReconciliationComplete();}
    function _bound() private view returns(bool){return _hash(evidenceSource)==sourceHash&&IRecoveryV3Kernel(kernel).recoveryEvidence()==evidenceSource&&IRecoveryV3Kernel(kernel).recoveryEvidenceHash()==sourceHash;}
    function _guardian() private pure returns(address){return 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
interface IRecoveryFinalityV3 {function recoveryReconciliationComplete() external view returns(bool);}
