// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {C2G2BTypes as T, IC2G2BKernel, IC2G2BBuybackQuote} from "./C2G2BTypes.sol";

contract CompdBuybackModuleV2 {
    uint8 public constant MODULE_ID=2; uint32 public constant MODULE_VERSION=2; address public immutable kernel; address public immutable quoteSource; bytes32 public immutable quoteHash;
    struct QuoteRecord {bytes32 operationId;bytes32 quoteId;bytes32 route;uint256 amountOut;uint256 referenceOut;uint64 observedAt;uint64 recordedAt;bool blocked;}
    mapping(bytes32=>bool) public operationUsed; QuoteRecord[] private _history; error Unauthorized(); error QuotePolicyUnresolved(); error ChangedCode(); event QuoteBlocked(bytes32 indexed operationId,bytes32 indexed quoteId,bytes32 route,uint64 observedAt);
    constructor(address kernel_,address quoteSource_){if(kernel_==address(0))revert Unauthorized();kernel=kernel_;quoteSource=quoteSource_;if(quoteSource_!=address(0)){if(quoteSource_.code.length==0)revert Unauthorized();quoteHash=_hash(quoteSource_);}}
    function moduleId() external pure returns(uint8){return MODULE_ID;}function moduleVersion() external pure returns(uint32){return MODULE_VERSION;}
    function recordQuote(bytes32 operationId,bytes32 quoteId) external {if(msg.sender!=_automation()||operationId==0||quoteId==0||operationUsed[operationId]||quoteSource==address(0))revert Unauthorized();if(_hash(quoteSource)!=quoteHash)revert ChangedCode();(bytes32 route,uint256 out,uint64 observed,uint256 referenceOut)=IC2G2BBuybackQuote(quoteSource).quote(quoteId);operationUsed[operationId]=true;_history.push(QuoteRecord(operationId,quoteId,route,out,referenceOut,observed,uint64(block.timestamp),true));emit QuoteBlocked(operationId,quoteId,route,observed);}
    function attemptRelease(bytes32 operationId,uint256 amount,bytes32 quoteId) external {if(msg.sender!=_automation()||operationId==0)revert Unauthorized();IC2G2BKernel(kernel).releaseBuyback(operationId,amount,quoteId);revert QuotePolicyUnresolved();}
    function historyLength() external view returns(uint256){return _history.length;}function historyAt(uint256 i) external view returns(QuoteRecord memory){return _history[i];}function terminationReady() external pure returns(bool){return true;}
    function _automation() private pure returns(address){return 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;}function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
