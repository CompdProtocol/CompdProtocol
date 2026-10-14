// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BKernel} from "./C2G2BTypesR1.sol";

/// @notice Quote source must validate the exact input against the finalized TWAP,
/// quote-deviation and tax-normalized slippage policy. It is code-hash pinned.
interface IExactInputBuybackQuoteR6R2B {
    function policyCommitment() external view returns(bytes32);
    function isExecutable(bytes32 quoteId,uint256 exactInput) external view returns(bool);
}

/// @notice Isolated rolling-cap and trigger policy. Kernel remains the custody authority.
contract CompdBuybackPolicyModuleR1 {
    uint8 public constant MODULE_ID=2;
    uint32 public constant MODULE_VERSION=3;
    uint256 private constant BPS=10_000;
    uint256 private constant MIN_RESERVE=0.25 ether;
    uint256 private constant MAX_EXECUTION=0.50 ether;
    uint64 private constant COOLDOWN=6 hours;
    uint64 private constant WINDOW=24 hours;
    address private constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;

    struct Spend { uint64 timestamp; uint192 amount; }
    address public immutable kernel;
    address public immutable quoteSource;
    bytes32 public immutable quoteSourceCodeHash;
    bytes32 public immutable buybackConfigurationCommitment;
    Spend[4] private _spends;
    uint8 public ringHead;
    uint8 public ringCount;
    uint256 public cohortReserveSnapshot;
    uint64 public lastSuccessfulBuybackAt;
    mapping(bytes32=>bool) public operationUsed;

    error Unauthorized();
    error Disabled();
    error InvalidOperation();
    error PolicyRejected();
    event ExactInputBuyback(bytes32 indexed operationId,uint256 exactInput,uint64 timestamp,uint256 cohortReserveSnapshot);

    constructor(address kernel_,address quoteSource_,bytes32 configurationCommitment_) {
        if(kernel_==address(0))revert Unauthorized();
        if(quoteSource_==address(0)){
            if(configurationCommitment_!=bytes32(0))revert InvalidOperation();
        } else if(quoteSource_.code.length==0||configurationCommitment_==bytes32(0))revert InvalidOperation();
        kernel=kernel_;quoteSource=quoteSource_;quoteSourceCodeHash=quoteSource_==address(0)?bytes32(0):_hash(quoteSource_);
        buybackConfigurationCommitment=configurationCommitment_;
    }

    function moduleId() external pure returns(uint8){return MODULE_ID;}
    function moduleVersion() external pure returns(uint32){return MODULE_VERSION;}
    function kernelAddress() external view returns(address){return kernel;}
    function terminationReady() external pure returns(bool){return true;}

    function attempt(bytes32 operationId,bytes32 quoteId) external {
        if(msg.sender!=AUTOMATION)revert Unauthorized();
        if(buybackConfigurationCommitment==bytes32(0)||quoteSource==address(0))revert Disabled();
        if(operationId==bytes32(0)||quoteId==bytes32(0)||operationUsed[operationId])revert InvalidOperation();
        if(_hash(quoteSource)!=quoteSourceCodeHash||IExactInputBuybackQuoteR6R2B(quoteSource).policyCommitment()!=buybackConfigurationCommitment)revert Disabled();
        uint256 reserve=IC2G2BKernel(kernel).buybackReserve();
        if(reserve<MIN_RESERVE)revert PolicyRejected();
        if(ringCount!=0&&block.timestamp<uint256(lastSuccessfulBuybackAt)+COOLDOWN)revert PolicyRejected();

        uint8 head=ringHead;uint8 count=ringCount;uint256 spentInWindow;
        for(uint8 i;i<count;++i){Spend memory s=_spends[uint8((uint256(head)+i)%4)];spentInWindow+=s.amount;}
        while(count!=0){
            Spend memory oldest=_spends[head];
            if(block.timestamp<uint256(oldest.timestamp)+WINDOW)break;
            spentInWindow-=oldest.amount;head=uint8((uint256(head)+1)%4);count--;
        }
        uint256 basis=count==0?reserve:cohortReserveSnapshot;
        uint256 cap=basis*4_000/BPS;
        if(spentInWindow>=cap)revert PolicyRejected();
        uint256 exactInput=reserve*2_000/BPS;
        if(exactInput>MAX_EXECUTION)exactInput=MAX_EXECUTION;
        if(exactInput>cap-spentInWindow)exactInput=cap-spentInWindow;
        if(exactInput==0||exactInput>type(uint192).max)revert PolicyRejected();
        if(!IExactInputBuybackQuoteR6R2B(quoteSource).isExecutable(quoteId,exactInput))revert PolicyRejected();

        // State is committed only after the Kernel's exact-input call succeeds.
        IC2G2BKernel(kernel).releaseBuyback(operationId,exactInput,quoteId);
        ringHead=head;ringCount=count;
        if(count==0)cohortReserveSnapshot=reserve;
        uint8 tail=uint8((uint256(head)+uint256(count))%4);
        _spends[tail]=Spend(uint64(block.timestamp),uint192(exactInput));
        ringCount=count+1;lastSuccessfulBuybackAt=uint64(block.timestamp);operationUsed[operationId]=true;
        emit ExactInputBuyback(operationId,exactInput,uint64(block.timestamp),cohortReserveSnapshot);
    }

    function spendAt(uint8 logicalIndex) external view returns(uint64 timestamp,uint256 amount){
        if(logicalIndex>=ringCount)revert InvalidOperation();
        Spend storage s=_spends[uint8((uint256(ringHead)+logicalIndex)%4)];return(s.timestamp,s.amount);
    }

    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
