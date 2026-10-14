// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdTerminatedCustodyV3 as Recovery} from "./CompdTerminatedCustodyV3.sol";

/// @dev A reviewed adapter must validate independent price/route/tax assumptions.
/// No caller can select a token, router, route, recipient or arbitrary calldata.
interface ICompdBuybackAdapterV3 {
    function token() external view returns(address);
    function quote(bytes32 quoteId,uint256 exactInput) external view returns(uint256 expectedOut,uint256 minOut,uint64 observedAt,uint64 deadline);
    function swapExactBNBForCOMPD(bytes32 quoteId,uint256 minOut,uint64 deadline,address recipient) external payable;
}
interface ICompdBurnableV3 {
    function balanceOf(address) external view returns(uint256);
    function totalSupply() external view returns(uint256);
    function burn(uint256) external;
}
contract CompdBuybackExecutorV3 {
    address public constant COMPD=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    uint256 public constant MAX_SLIPPAGE_BPS=300;
    uint256 public constant MAX_QUOTE_AGE=300;
    uint256 public constant MAX_DEADLINE_WINDOW=300;
    address public immutable boundKernel;
    address public immutable adapter;
    bytes32 public immutable adapterCodeHash;
    bytes32 public immutable tokenCodeHash;
    bytes32 public immutable policyCommitment;
    mapping(bytes32=>bool) public operationUsed;
    uint256 public totalBNBSpent;uint256 public totalCOMPDBurned;
    bool private entered;
    modifier recoveryLock(){if(entered)revert Rejected();entered=true;_;entered=false;}
    error Rejected();
    event BuybackBurned(bytes32 indexed operationId,bytes32 indexed quoteId,uint256 bnbSpent,uint256 compdBurned);
    function recoverTerminatedFunds() external recoveryLock returns(uint256){return Recovery.native(boundKernel);}
    function rescueAccidentalERC20(address token,uint256 amount) external recoveryLock {Recovery.token(boundKernel,token,amount);}
    constructor(address kernel_,address adapter_,bytes32 tokenCodeHash_){
        if(kernel_==address(0)||adapter_.code.length==0||tokenCodeHash_==0)revert Rejected();
        boundKernel=kernel_;adapter=adapter_;adapterCodeHash=adapter_.codehash;tokenCodeHash=tokenCodeHash_;
        policyCommitment=keccak256(abi.encode(uint256(56),kernel_,adapter_,adapter_.codehash,COMPD,tokenCodeHash_,MAX_SLIPPAGE_BPS,MAX_QUOTE_AGE,MAX_DEADLINE_WINDOW));
    }
    function configurationValid() public view returns(bool){
        return block.chainid==56&&adapter.codehash==adapterCodeHash&&COMPD.code.length!=0&&COMPD.codehash==tokenCodeHash
            &&ICompdBuybackAdapterV3(adapter).token()==COMPD;
    }
    function isExecutable(bytes32 quoteId,uint256 input) public view returns(bool){
        if(!configurationValid()||quoteId==0||input==0)return false;
        try ICompdBuybackAdapterV3(adapter).quote(quoteId,input) returns(uint256 expected,uint256 minimum,uint64 observed,uint64 deadline){
            return _validQuote(expected,minimum,observed,deadline);
        }catch{return false;}
    }
    function _validQuote(uint256 expected,uint256 minimum,uint64 observed,uint64 deadline) private view returns(bool){
        return expected!=0&&minimum!=0&&minimum<=expected&&minimum*10_000>=expected*(10_000-MAX_SLIPPAGE_BPS)
            &&observed<=block.timestamp&&block.timestamp-observed<=MAX_QUOTE_AGE&&deadline>=block.timestamp
            &&deadline>=observed&&deadline-observed<=MAX_DEADLINE_WINDOW;
    }
    function executeExactInput(bytes32 operationId,bytes32 quoteId) external payable {
        if(msg.sender!=boundKernel||entered||operationId==0||operationUsed[operationId]||quoteId==0||msg.value==0||!configurationValid())revert Rejected();
        entered=true;operationUsed[operationId]=true;
        (uint256 expected,uint256 minimum,uint64 observed,uint64 deadline)=ICompdBuybackAdapterV3(adapter).quote(quoteId,msg.value);
        if(!_validQuote(expected,minimum,observed,deadline))revert Rejected();
        ICompdBurnableV3 token=ICompdBurnableV3(COMPD);uint256 beforeBalance=token.balanceOf(address(this));
        ICompdBuybackAdapterV3(adapter).swapExactBNBForCOMPD{value:msg.value}(quoteId,minimum,deadline,address(this));
        uint256 received=token.balanceOf(address(this))-beforeBalance;if(received<minimum)revert Rejected();
        uint256 supply=token.totalSupply();token.burn(received);
        if(token.balanceOf(address(this))!=beforeBalance||supply-token.totalSupply()!=received||address(this).balance!=0)revert Rejected();
        totalBNBSpent+=msg.value;totalCOMPDBurned+=received;entered=false;
        emit BuybackBurned(operationId,quoteId,msg.value,received);
    }
}

