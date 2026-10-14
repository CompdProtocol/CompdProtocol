// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../../contracts/production/v2/phase6c2g2br4/C2G2BTypes.sol";
import {CompdVaultKernelV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdVaultKernelV2.sol";
import {CompdSettlementModuleV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdSettlementModuleV2R4.sol";
import {CompdStrategyExecutorV2R4} from "../../contracts/production/v2/phase6c2g2br4/CompdStrategyExecutorV2R4.sol";
import {CompdEmergencyScopeRegistryV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyScopeRegistryV2.sol";
import {CompdEmergencyModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdEmergencyModuleV2.sol";
import {CompdHolderModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdHolderModuleV2.sol";
import {CompdBuybackModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdBuybackModuleV2.sol";
import {CompdRecoveryModuleV2} from "../../contracts/production/v2/phase6c2g2br4/CompdRecoveryModuleV2.sol";
import {ReferenceStrategyAdapterR4} from "./ReferenceStrategyAdapterR4.sol";
import {R4BuybackExec,R4Distributor,R4Liability,R4Recovery} from "./Phase6C2G2BR4.t.sol";

contract R4InvariantHandler is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTOMATION=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address constant EMERGENCY_AUTHORITY=address(0xE001);
    CompdVaultKernelV2R4 public immutable kernel;
    CompdSettlementModuleV2R4 public immutable settlement;
    ReferenceStrategyAdapterR4 public immutable adapter;
    uint256[] private _ids;
    mapping(uint256=>uint256) public originalPrincipal;
    mapping(uint256=>uint256) private _nonce;
    mapping(uint256=>bool) public closedObserved;
    uint256 private _nextRunId;
    bool public allocationHaltObserved;
    bool public emergencyExposureStable=true;

    constructor(CompdVaultKernelV2R4 k,CompdSettlementModuleV2R4 s,ReferenceStrategyAdapterR4 a){kernel=k;settlement=s;adapter=a;}
    function runCount() external view returns(uint256){return _ids.length;}
    function runAt(uint256 i) external view returns(uint256){return _ids[i];}

    function open(uint96 raw) external {
        uint256 id=++_nextRunId;uint256 amount=bound(uint256(raw),1,1 ether);uint256 ap=kernel.activePrincipal();
        vm.prank(AUTOMATION);(bool ok,)=address(settlement).call(abi.encodeCall(settlement.startRun,(id,address(adapter),amount,keccak256(abi.encode("inv-allocation",id)))));
        if(ok){_ids.push(id);originalPrincipal[id]=amount;}
        if(kernel.lifecycle()==T.Lifecycle.EMERGENCY_RECOVERY&&kernel.activePrincipal()!=ap)emergencyExposureStable=false;
        if(kernel.strategyAllocationHalted())allocationHaltObserved=true;
    }
    function exit(uint256 rawIndex) external {
        if(_ids.length==0)return;uint256 id=_ids[rawIndex%_ids.length];bytes32 exitId=keccak256(abi.encode("inv-exit",id));vm.prank(AUTOMATION);
        address(settlement).call(abi.encodeCall(settlement.requestExit,(id,exitId)));
    }
    function collect(uint256 rawIndex,uint96 rawAmount) external {
        if(_ids.length==0)return;uint256 id=_ids[rawIndex%_ids.length];bytes32 position=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);
        adapter.setNextCollection(position,uint256(rawAmount));bytes32 attempt=keccak256(abi.encode("inv-collect",id,++_nonce[id]));uint256 sc=kernel.strategyCapital();
        address(settlement).call(abi.encodeCall(settlement.collectRun,(id,attempt)));
        assertEq(kernel.strategyCapital(),sc,"partial principal changed SC");if(kernel.strategyAllocationHalted())allocationHaltObserved=true;
    }
    function close(uint256 rawIndex,bool eraseExternalPosition) external {
        if(_ids.length==0)return;uint256 id=_ids[rawIndex%_ids.length];bytes32 position=CompdStrategyExecutorV2R4(payable(kernel.strategyExecutor())).positionId(id);
        if(eraseExternalPosition)adapter.setCash(position,0);adapter.setTerminal(position,true);bytes32 closeId=keccak256(abi.encode("inv-close",id));vm.prank(AUTOMATION);
        (bool ok,)=address(settlement).call(abi.encodeCall(settlement.closeRun,(id,closeId)));if(ok)closedObserved[id]=true;
        if(kernel.strategyAllocationHalted())allocationHaltObserved=true;
    }
    function blockRun(uint256 rawIndex) external {
        if(_ids.length==0)return;uint256 id=_ids[rawIndex%_ids.length];uint256 ap=kernel.activePrincipal();vm.prank(GUARDIAN);
        address(settlement).call(abi.encodeCall(settlement.recordBlocked,(id,keccak256(abi.encode("inv-block",id,++_nonce[id])))));
        assertEq(kernel.activePrincipal(),ap,"BLOCKED changed AP");
    }
    function enterEmergency() external {
        if(kernel.lifecycle()==T.Lifecycle.EMERGENCY_RECOVERY||kernel.lifecycle()==T.Lifecycle.TERMINATED)return;
        vm.prank(EMERGENCY_AUTHORITY);address(kernel).call(abi.encodeCall(kernel.emergencyEnter,()));
    }
    function reopenClosed(uint256 rawIndex) external {
        if(_ids.length==0)return;uint256 id=_ids[rawIndex%_ids.length];if(!closedObserved[id])return;
        vm.prank(AUTOMATION);address(settlement).call(abi.encodeCall(settlement.startRun,(id,address(adapter),1,keccak256(abi.encode("reopen",id)))));
        assertEq(uint8(settlement.run(id).state),uint8(T.StrategyRunState.CLOSED),"CLOSED reopened");
    }
}

contract Phase6C2G2BR4InvariantTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    uint256 constant CAPITAL=100 ether;
    ReferenceStrategyAdapterR4 private adapter;
    CompdVaultKernelV2R4 private kernel;
    CompdSettlementModuleV2R4 private settlement;
    R4InvariantHandler private handler;

    function setUp() public {
        adapter=new ReferenceStrategyAdapterR4();R4BuybackExec buyExec=new R4BuybackExec();R4Distributor dist=new R4Distributor();R4Liability liability=new R4Liability();R4Recovery recoveryEvidence=new R4Recovery();
        address[] memory approved=new address[](1);approved[0]=address(adapter);
        kernel=new CompdVaultKernelV2R4(address(0xE001),address(0xE002),approved,address(buyExec),address(dist),address(liability),address(recoveryEvidence));
        CompdEmergencyScopeRegistryV2 registry=new CompdEmergencyScopeRegistryV2(address(kernel));CompdEmergencyModuleV2 emergency=new CompdEmergencyModuleV2(address(kernel),address(registry));
        settlement=new CompdSettlementModuleV2R4(address(kernel),kernel.strategyExecutor());CompdHolderModuleV2 holder=new CompdHolderModuleV2(address(kernel),address(dist),address(liability));
        CompdBuybackModuleV2 buyback=new CompdBuybackModuleV2(address(kernel),address(0));CompdRecoveryModuleV2 recovery=new CompdRecoveryModuleV2(address(kernel),address(recoveryEvidence));
        vm.prank(ADMIN);registry.bindEmergencyModule(address(emergency));address[6] memory modules=[address(settlement),address(holder),address(buyback),address(recovery),address(emergency),address(registry)];
        vm.prank(ADMIN);kernel.bindModules(modules);vm.deal(ADMIN,CAPITAL);vm.prank(ADMIN);kernel.seedStrategyCapital{value:CAPITAL}();vm.prank(ADMIN);kernel.activate();
        handler=new R4InvariantHandler(kernel,settlement,adapter);targetContract(address(handler));
    }
    function invariant_bucketConservationAndBounds() public view {
        assertEq(kernel.strategyCapital()+kernel.buybackReserve()+kernel.protocolReserve()+kernel.holderRewardReserve(),kernel.accountedQuote()+kernel.activePrincipal());
        assertLe(kernel.activePrincipal(),kernel.strategyCapital());assertGe(kernel.accountedQuote(),kernel.holderRewardReserve());
    }
    function invariant_eachRunPrincipalAndAPReconcile() public view {
        uint256 expectedAP;for(uint256 i;i<handler.runCount();++i){uint256 id=handler.runAt(i);uint256 p=handler.originalPrincipal(id);uint256 credited=kernel.principalCredited(id);assertLe(credited,p);CompdSettlementModuleV2R4.Run memory r=settlement.run(id);
            assertGe(kernel.runTotalPhysicalReturn(id),credited);if(r.state==T.StrategyRunState.CLOSED){assertEq(kernel.runPrincipal(id),0);}else{expectedAP+=p-credited;}}
        assertEq(kernel.activePrincipal(),expectedAP);
    }
    function invariant_monotonicSafetyStates() public view {
        assertTrue(!handler.allocationHaltObserved()||kernel.strategyAllocationHalted());assertTrue(handler.emergencyExposureStable());
        if(kernel.lifecycle()==T.Lifecycle.TERMINATED)assertEq(kernel.activePrincipal(),0);
        for(uint256 i;i<handler.runCount();++i){uint256 id=handler.runAt(i);CompdSettlementModuleV2R4.Run memory r=settlement.run(id);
            if(handler.closedObserved(id))assertEq(uint8(r.state),uint8(T.StrategyRunState.CLOSED));if(r.state==T.StrategyRunState.BLOCKED)assertGt(kernel.runPrincipal(id),0);}
    }
}
