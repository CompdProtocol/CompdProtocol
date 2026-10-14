// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {ICompdBuybackAdapterV3} from "./CompdBuybackExecutorV3.sol";
import {CompdTerminatedCustodyV3 as Recovery} from "./CompdTerminatedCustodyV3.sol";
interface IManualCOMPDV3 {
    function balanceOf(address) external view returns(uint256);
    function totalSupply() external view returns(uint256);
    function transfer(address,uint256) external returns(bool);
}
/// @notice Kernel-funded purchase and fixed dead-address transfer. Never a native burn.
/// @dev Reuses the immutable admin-only V3 policy and Kernel reserve controls.
/// A separately verified fixed adapter is mandatory; no production route is approved here.
contract CompdManualBuybackExecutorV3 {
    address public constant COMPD=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public constant DISPOSAL=0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_SLIPPAGE_BPS=300;
    uint256 public constant MAX_QUOTE_AGE=300;
    uint256 public constant MAX_DEADLINE_WINDOW=300;
    address public immutable boundKernel;
    address public immutable adapter;
    bytes32 public immutable adapterCodeHash;
    bytes32 public immutable tokenCodeHash;
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
    constructor(address kernel_,address adapter_,bytes32 tokenHash_){
        if(kernel_==address(0)||adapter_.code.length==0||tokenHash_==0)revert Rejected();
        boundKernel=kernel_;adapter=adapter_;adapterCodeHash=adapter_.codehash;tokenCodeHash=tokenHash_;
        policyCommitment=keccak256(abi.encode("COMPD_MANUAL_DEAD_TRANSFER_V1",uint256(56),kernel_,adapter_,adapterCodeHash,COMPD,tokenHash_,DISPOSAL,MAX_SLIPPAGE_BPS,MAX_QUOTE_AGE,MAX_DEADLINE_WINDOW));
    }
    function configurationValid() public view returns(bool){
        if(block.chainid!=56||adapter.codehash!=adapterCodeHash||COMPD.code.length==0||COMPD.codehash!=tokenCodeHash||DISPOSAL.code.length!=0)return false;
        try ICompdBuybackAdapterV3(adapter).token() returns(address t){return t==COMPD;}catch{return false;}
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
