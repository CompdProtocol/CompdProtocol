// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {C2G2BTypes as T} from "./C2G2BTypes.sol";
interface ILensKernel {function lifecycle() external view returns(T.Lifecycle);function strategyCapital() external view returns(uint256);function buybackReserve() external view returns(uint256);function protocolReserve() external view returns(uint256);function holderRewardReserve() external view returns(uint256);function accountedQuote() external view returns(uint256);function activePrincipal() external view returns(uint256);function emergencySnapshotId() external view returns(bytes32);function emergencyStatus() external view returns(T.ProcessingStatus);function preEmergencyHolderDeficit() external view returns(uint256);function activeRunCount() external view returns(uint256);function activeRunAt(uint256) external view returns(uint256);function runPrincipal(uint256) external view returns(uint256);function runStrategy(uint256) external view returns(address);function runStatus(uint256) external view returns(T.RunStatus);}
import {CompdSettlementModuleV2R4} from "./CompdSettlementModuleV2R4.sol";
interface ILensSettlementR4 {function run(uint256) external view returns(CompdSettlementModuleV2R4.Run memory);}
contract CompdProtocolLensV2 {
    address public immutable kernel;address public immutable settlement;address public immutable emergencyRegistry;
    constructor(address kernel_,address settlement_,address registry_){kernel=kernel_;settlement=settlement_;emergencyRegistry=registry_;}
    function accounting() external view returns(T.Lifecycle lifecycle,uint256 sc,uint256 br,uint256 pr,uint256 hr,uint256 aq,uint256 ap){ILensKernel k=ILensKernel(kernel);return(k.lifecycle(),k.strategyCapital(),k.buybackReserve(),k.protocolReserve(),k.holderRewardReserve(),k.accountedQuote(),k.activePrincipal());}
    function run(uint256 id) external view returns(CompdSettlementModuleV2R4.Run memory){return CompdSettlementModuleV2R4(settlement).run(id);}
    function holderBacking() external view returns(uint256 hb,uint256 hd,uint256 ecd){ILensKernel k=ILensKernel(kernel);uint256 aq=k.accountedQuote();uint256 hr=k.holderRewardReserve();if(aq<hr)revert();uint256 n=aq-hr;uint256 vb=address(kernel).balance;hb=vb>n?vb-n:0;if(hb>hr)hb=hr;hd=hr-hb;uint256 pre=k.preEmergencyHolderDeficit();ecd=hd>pre?hd-pre:0;}
    function emergency() external view returns(bytes32,T.ProcessingStatus){ILensKernel k=ILensKernel(kernel);return(k.emergencySnapshotId(),k.emergencyStatus());}
}
