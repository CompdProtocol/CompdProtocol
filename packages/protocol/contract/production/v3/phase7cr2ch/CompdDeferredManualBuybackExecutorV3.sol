// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {ICompdBuybackAdapterV3} from "./CompdBuybackExecutorV3.sol";
import {CompdTerminatedCustodyV3 as Recovery} from "./CompdTerminatedCustodyV3.sol";
interface IDeferredKernelV3 {function lifecycle() external view returns(uint8);}
interface IBoundManualRouteV3 is ICompdBuybackAdapterV3 {function executor() external view returns(address);function boundSelector() external view returns(address);function routeVerified(address pool) external view returns(bool);}
interface IManualCOMPDV3 {
    function balanceOf(address) external view returns(uint256);
    function totalSupply() external view returns(uint256);
    function transfer(address,uint256) external returns(bool);
}
/// @notice Kernel-funded purchase and fixed dead-address transfer. Never a native burn.
/// @dev Reuses the immutable admin-only V3 policy and Kernel reserve controls; routes require separate admin and Guardian approval while paused.
/// A separately verified fixed adapter is mandatory; no production route is approved here.
contract CompdDeferredManualBuybackExecutorV3 {
    address public constant COMPD=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public constant DISPOSAL=0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_SLIPPAGE_BPS=300;
    uint256 public constant MAX_QUOTE_AGE=300;
    uint256 public constant MAX_DEADLINE_WINDOW=300;
    address public immutable boundKernel;
    address public adapter;
    bytes32 public adapterCodeHash;
    bytes32 public tokenCodeHash;
    bytes32 public immutable policyCommitment;
    mapping(bytes32=>bool) public operationUsed;
    uint256 public totalBNBSpent;
    uint256 public totalCOMPDPurchased;
    uint256 public totalCOMPDDisposed;
    // Explicitly zero: no supply-reducing operation is performed by this executor.
    uint256 public constant totalCOMPDBurned=0;
    bool private entered;
    error Rejected();
    event ManualBuybackDisposed(bytes32 indexed operationId,bytes32 indexed quoteId,uint256 bnbSpent,uint256 compdPurchased,uint256 compdDisposed);
    modifier lock(){if(entered)revert Rejected();entered=true;_;entered=false;}
    address public constant ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address public constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    bool public routeEnabled;
    uint256 public configurationNonce;
    bytes32 public pendingProposal;
    bytes32 public qualificationEvidenceHash;
    address public routePool;
    bytes32 public poolCodeHash;
    event RouteProposed(bytes32 indexed proposal,address indexed adapter,bytes32 indexed evidence);
    event RouteConfirmed(bytes32 indexed proposal,address indexed adapter,bytes32 indexed evidence);
    event RouteDisabled();
    constructor(address kernel_){
        if(kernel_==address(0))revert Rejected();boundKernel=kernel_;
        // Stable policy identity pins this executor; mutable routes never change Kernel pins.
        policyCommitment=keccak256(abi.encode("COMPD_DEFERRED_MANUAL_V1",uint256(56),kernel_,COMPD,DISPOSAL,ADMIN,GUARDIAN,MAX_SLIPPAGE_BPS,MAX_QUOTE_AGE,MAX_DEADLINE_WINDOW));
    }
    function _paused() private view {
        if(block.chainid!=56||IDeferredKernelV3(boundKernel).lifecycle()!=1)revert Rejected();
    }
    function _routeValid(address candidate,bytes32 codeHash,bytes32 tokenHash,address pool,bytes32 poolHash) private view returns(bool){
        if(candidate.code.length==0||candidate.codehash!=codeHash||COMPD.code.length==0||COMPD.codehash!=tokenHash||DISPOSAL.code.length!=0
            ||(pool!=address(0)&&(pool.code.length==0||pool.codehash!=poolHash)))return false;
        try IBoundManualRouteV3(candidate).token() returns(address t){if(t!=COMPD)return false;}catch{return false;}
        try IBoundManualRouteV3(candidate).executor() returns(address x){if(x!=address(this))return false;}catch{return false;}
        try IBoundManualRouteV3(candidate).boundSelector() returns(address x){if(x!=address(this))return false;}catch{return false;}
        try IBoundManualRouteV3(candidate).routeVerified(pool) returns(bool v){return v;}catch{return false;}
    }
    function _proposal(address candidate,bytes32 codeHash,bytes32 tokenHash,address pool,bytes32 poolHash,bytes32 evidence) private view returns(bytes32){
        return keccak256(abi.encode(block.chainid,address(this),configurationNonce,candidate,codeHash,tokenHash,pool,poolHash,evidence));
    }
    /// @dev Evidence hash is a joint admin/Guardian attestation to independent qualification,
    /// not an onchain oracle or proof that a malicious approved adapter is safe.
    function proposeRoute(address candidate,address pool,bytes32 evidence) external lock returns(bytes32 proposal){
        if(msg.sender!=ADMIN||evidence==0)revert Rejected();_paused();
        bytes32 codeHash=candidate.codehash;bytes32 tokenHash=COMPD.codehash;bytes32 poolHash=pool==address(0)?bytes32(0):pool.codehash;
        if(!_routeValid(candidate,codeHash,tokenHash,pool,poolHash))revert Rejected();
        ++configurationNonce;proposal=_proposal(candidate,codeHash,tokenHash,pool,poolHash,evidence);pendingProposal=proposal;
        emit RouteProposed(proposal,candidate,evidence);
    }
    function confirmRoute(address candidate,bytes32 codeHash,bytes32 tokenHash,address pool,bytes32 poolHash,bytes32 evidence,bytes32 proposal) external lock {
        if(msg.sender!=GUARDIAN||evidence==0||proposal==0||pendingProposal!=proposal)revert Rejected();_paused();
        if(_proposal(candidate,codeHash,tokenHash,pool,poolHash,evidence)!=proposal||!_routeValid(candidate,codeHash,tokenHash,pool,poolHash))revert Rejected();
        adapter=candidate;adapterCodeHash=codeHash;tokenCodeHash=tokenHash;routePool=pool;poolCodeHash=poolHash;qualificationEvidenceHash=evidence;
        pendingProposal=0;routeEnabled=true;emit RouteConfirmed(proposal,candidate,evidence);
    }
    /// @notice Guardian can immediately disable execution/cancel any pending proposal.
    function disableRoute() external lock {if(msg.sender!=GUARDIAN)revert Rejected();routeEnabled=false;pendingProposal=0;++configurationNonce;emit RouteDisabled();}
    function configurationValid() public view returns(bool){
        return block.chainid==56&&routeEnabled&&qualificationEvidenceHash!=0&&_routeValid(adapter,adapterCodeHash,tokenCodeHash,routePool,poolCodeHash);
    }
    function _valid(uint256 expected,uint256 minimum,uint64 observed,uint64 deadline) private view returns(bool){
        return expected!=0&&minimum!=0&&minimum<=expected&&minimum*10000>=expected*(10000-MAX_SLIPPAGE_BPS)
            &&observed<=block.timestamp&&block.timestamp-observed<=MAX_QUOTE_AGE
            &&deadline>=block.timestamp&&deadline>=observed&&deadline-observed<=MAX_DEADLINE_WINDOW;
    }
    function isExecutable(bytes32 quoteId,uint256 input) external view returns(bool){
        if(!configurationValid()||quoteId==0||input==0)return false;
        try ICompdBuybackAdapterV3(adapter).quote(quoteId,input) returns(uint256 e,uint256 m,uint64 o,uint64 d){return _valid(e,m,o,d);}catch{return false;}
    }
    function executeExactInput(bytes32 operationId,bytes32 quoteId) external payable lock {
        if(msg.sender!=boundKernel||operationId==0||operationUsed[operationId]||quoteId==0||msg.value==0||address(this).balance!=msg.value||!configurationValid())revert Rejected();
        operationUsed[operationId]=true;
        (uint256 expected,uint256 minimum,uint64 observed,uint64 deadline)=ICompdBuybackAdapterV3(adapter).quote(quoteId,msg.value);
        if(!_valid(expected,minimum,observed,deadline))revert Rejected();
        IManualCOMPDV3 t=IManualCOMPDV3(COMPD);uint256 beforeBalance=t.balanceOf(address(this));
        ICompdBuybackAdapterV3(adapter).swapExactBNBForCOMPD{value:msg.value}(quoteId,minimum,deadline,address(this));
        uint256 purchased=t.balanceOf(address(this))-beforeBalance;
        if(purchased<minimum||address(this).balance!=0||!configurationValid())revert Rejected();
        uint256 deadBefore=t.balanceOf(DISPOSAL);uint256 supply=t.totalSupply();
        if(!t.transfer(DISPOSAL,purchased)||t.balanceOf(address(this))!=beforeBalance||t.balanceOf(DISPOSAL)-deadBefore!=purchased||t.totalSupply()!=supply||!configurationValid())revert Rejected();
        totalBNBSpent+=msg.value;totalCOMPDPurchased+=purchased;totalCOMPDDisposed+=purchased;
        emit ManualBuybackDisposed(operationId,quoteId,msg.value,purchased,purchased);
    }
    function recoverTerminatedFunds() external lock returns(uint256){return Recovery.native(boundKernel);}
    function rescueAccidentalERC20(address asset,uint256 amount) external lock {Recovery.token(boundKernel,asset,amount);}
}
