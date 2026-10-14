// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T,IC2G2BHolderDistributor,IC2G2BHolderLiability,IC2G2BKernel} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface IHolderKernelConfigV3 {
    function distributor() external view returns(address); function distributorHash() external view returns(bytes32);
    function liability() external view returns(address); function liabilityHash() external view returns(bytes32);
    function holderState() external view returns(address); function holderStateHash() external view returns(bytes32);
    function failedHolder(bytes32) external view returns(bytes32,address,uint256,bytes32);
    function holderPaid(bytes32) external view returns(bool); function holderRewardReserve() external view returns(uint256); function eligibleWindowHR() external view returns(uint256);
}
interface IHolderCanonicalV3 { function canonicalPayment(bytes32) external view returns(bytes32,address,address,uint256,uint8,bool); }
interface IHolderStateV3 {
    function terminalize(bytes32 leafId) external;
    function terminalStatus(bytes32 leafId) external view returns(bool,uint64,uint64,bytes32);
    function terminalOutstanding() external view returns(uint256);
    function unresolvedOrdinary() external view returns(uint256);
    function openReviewCount() external view returns(uint256);
    function outstandingHolderLiability() external view returns(uint256);
}

/// @notice Holder slot 1/version 3. The payment digest and Kernel payment path remain R2-identical.
contract CompdHolderModuleV3 {
    uint8 public constant MODULE_ID=1;
    uint32 public constant MODULE_VERSION=3;
    address public immutable kernel;
    address public immutable distributor;
    address public immutable liability;
    address public immutable state;
    bytes32 public immutable distributorHash;
    bytes32 public immutable liabilityHash;
    bytes32 public immutable stateHash;
    mapping(bytes32=>T.HolderPayment) private _failed;
    mapping(bytes32=>bool) public hasFailure;
    mapping(bytes32=>uint64) private _attemptCount;
    bool private _entered;
    error Unauthorized(); error InvalidPayment(); error ChangedCode();
    event PaymentAttempt(bytes32 indexed useId,bytes32 indexed attemptId,bool retry,bool paid);
    event TerminalizationRequested(bytes32 indexed leafId,bytes32 indexed useId);
    modifier lock(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}

    constructor(address k,address d,address l){
        if(k==address(0)||d.code.length==0||l.code.length==0||IHolderKernelConfigV3(k).distributor()!=d||IHolderKernelConfigV3(k).liability()!=l)revert Unauthorized();
        kernel=k;distributor=d;liability=l;distributorHash=_hash(d);liabilityHash=_hash(l);
        state=IHolderKernelConfigV3(k).holderState();stateHash=_hash(state);
        if(state.code.length==0||IHolderKernelConfigV3(k).distributorHash()!=distributorHash||IHolderKernelConfigV3(k).liabilityHash()!=liabilityHash||IHolderKernelConfigV3(k).holderStateHash()!=stateHash)revert Unauthorized();
    }
    function moduleId() external pure returns(uint8){return MODULE_ID;}
    function moduleVersion() external pure returns(uint32){return MODULE_VERSION;}

    function pay(bytes32 leafId) external lock returns(bool){
        if(msg.sender!=_automation()||leafId==bytes32(0))revert Unauthorized();_check();
        (T.HolderPayment memory p,bool proof)=IC2G2BHolderDistributor(distributor).paymentData(leafId);
        if(!proof||p.leafId!=leafId||p.useId==0||p.recipient==address(0)||p.asset!=address(0)||p.amount==0||p.distributionStatus!=1||p.liabilityStatus!=1||p.recoveryStatus!=0||(p.expiresAt!=0&&block.timestamp>p.expiresAt))revert InvalidPayment();
        bytes32 digest=_digest(p);_verifySources(p,digest,1);bytes32 attempt=_next(p.useId);
        bool paid=IC2G2BKernel(kernel).payHolder(leafId,p.useId,digest,p.recipient,p.amount,false,attempt);
        if(paid){delete _failed[p.useId];hasFailure[p.useId]=false;}else{_failed[p.useId]=p;hasFailure[p.useId]=true;}
        emit PaymentAttempt(p.useId,attempt,false,paid);return paid;
    }

    function retry(bytes32 useId) external lock returns(bool){
        if(msg.sender!=_automation()||!hasFailure[useId])revert Unauthorized();_check();T.HolderPayment memory p=_failed[useId];
        (bytes32 failedDigest,address failedRecipient,uint256 failedAmount,bytes32 leaf)=IHolderKernelConfigV3(kernel).failedHolder(useId);
        bytes32 digest=_digest(p);if(failedDigest!=digest||failedRecipient!=p.recipient||failedAmount!=p.amount||leaf!=p.leafId)revert InvalidPayment();
        (bool terminal,,uint64 expiresAt,bytes32 terminalUseId)=IHolderStateV3(state).terminalStatus(p.leafId);
        uint8 status=terminal?2:1;if(terminal&&(terminalUseId!=useId||block.timestamp>=expiresAt))revert InvalidPayment();
        _verifySources(p,digest,status);bytes32 attempt=_next(useId);
        bool paid=IC2G2BKernel(kernel).payHolder(p.leafId,useId,digest,p.recipient,p.amount,true,attempt);
        if(paid){delete _failed[useId];hasFailure[useId]=false;}
        emit PaymentAttempt(useId,attempt,true,paid);return paid;
    }

    /// @notice Anyone may forward the objective one-failure transition during shutdown.
    function terminalize(bytes32 leafId) external { _check();StateCall(state).terminalize(leafId);emit TerminalizationRequested(leafId, _useId(leafId)); }
    function failed(bytes32 useId) external view returns(T.HolderPayment memory){return _failed[useId];}
    function terminationReady() external view returns(bool){
        if(_hash(distributor)!=distributorHash||_hash(liability)!=liabilityHash||_hash(state)!=stateHash)return false;
        try IHolderFinalityV3(distributor).terminalReconciliation() returns(bytes32 d1,uint256 n1){
            try IHolderFinalityV3(liability).terminalReconciliation() returns(bytes32 d2,uint256 n2){
                return d1!=bytes32(0)&&d1==d2&&n1==0&&n2==0&&IHolderStateV3(state).unresolvedOrdinary()==0
                    &&IHolderStateV3(state).openReviewCount()==0&&IHolderStateV3(state).outstandingHolderLiability()==IHolderKernelConfigV3(kernel).eligibleWindowHR();
            }catch{return false;}
        }catch{return false;}
    }
    function _verifySources(T.HolderPayment memory p,bytes32 digest,uint8 expectedStatus) private view {
        (bytes32 d1,address r1,address a1,uint256 n1,uint8 s1,bool v1)=IHolderCanonicalV3(distributor).canonicalPayment(p.leafId);
        (bytes32 d2,address r2,address a2,uint256 n2,uint8 s2,bool v2)=IHolderCanonicalV3(liability).canonicalPayment(p.leafId);
        if(!v1||!v2||d1!=digest||d2!=digest||r1!=p.recipient||r2!=p.recipient||a1!=address(0)||a2!=address(0)||n1!=p.amount||n2!=p.amount||s1!=expectedStatus||s2!=expectedStatus
            ||IC2G2BHolderDistributor(distributor).paymentDigest(p.leafId)!=digest||IC2G2BHolderLiability(liability).paymentDigest(p.leafId)!=digest)revert InvalidPayment();
    }
    function _digest(T.HolderPayment memory p) private view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,kernel,p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));}
    function _useId(bytes32 leafId) private view returns(bytes32){(T.HolderPayment memory p,)=IC2G2BHolderDistributor(distributor).paymentData(leafId);return p.useId;}
    function _next(bytes32 useId) private returns(bytes32){uint64 n=++_attemptCount[useId];return keccak256(abi.encode(address(this),block.chainid,useId,n));}
    function _check() private view {if(_hash(distributor)!=distributorHash||_hash(liability)!=liabilityHash||_hash(state)!=stateHash)revert ChangedCode();}
    function _automation() private pure returns(address){return 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
interface IHolderFinalityV3 { function terminalReconciliation() external view returns(bytes32,uint256); }
interface StateCall { function terminalize(bytes32 leafId) external; }
