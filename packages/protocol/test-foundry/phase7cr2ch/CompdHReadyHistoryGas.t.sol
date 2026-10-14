// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdPhase7CR2CHCurrentV3Test, T, Settlement} from "./CompdPhase7CR2CHCurrentV3.t.sol";

/// @dev Qualification diagnostics only. No production source or existing test is changed.
contract CompdHReadyHistoryGasTest is CompdPhase7CR2CHCurrentV3Test {
    uint256 constant TX_CAP = 16_777_216;

    function _cycle(uint256 id) internal {
        address automation = kernel.AUTOMATION_EXECUTOR();
        vm.prank(automation);
        settlement.startRun(id,address(adapter),1 ether,keccak256(abi.encode("history-allocation",id)));
        vm.prank(automation);
        settlement.requestExit(id,keccak256(abi.encode("history-exit",id)));
        vm.prank(automation);
        settlement.closeRun(id,keccak256(abi.encode("history-close",id)));
    }

    /// @dev Large-N scaling fixture seeds ONLY the slots read by terminationReady.
    /// Compiler storage layout: _history slot 3; _runs slot 0; Run.state offset 9.
    /// Real lifecycle controls independently validate these exact slots below.
    function _seedClosedHistory(uint256 count) internal {
        vm.store(address(settlement),bytes32(uint256(3)),bytes32(count));
        uint256 first=uint256(keccak256(abi.encode(uint256(3))));
        for(uint256 i;i<count;++i){
            uint256 id=i+1;
            vm.store(address(settlement),bytes32(first+i),bytes32(id));
            uint256 stateSlot=uint256(keccak256(abi.encode(id,uint256(0))))+9;
            vm.store(address(settlement),bytes32(stateSlot),bytes32(uint256(T.StrategyRunState.CLOSED)));
        }
    }

    function _measure(uint256 count) internal {
        _seedClosedHistory(count);
        vm.cool(address(settlement));
        uint256 beforeGas=gasleft();
        bool ready=settlement.terminationReady();
        uint256 used=beforeGas-gasleft();
        assertTrue(ready);
        emit log_named_uint("closedHistory",count);
        emit log_named_uint("coldTerminationReadyGas",used);
    }

    function testQualificationGasHistory0() public {_measure(0);}
    function testQualificationGasHistory100() public {_measure(100);}
    function testQualificationGasHistory1000() public {_measure(1000);}
    function testQualificationGasHistory5000() public {_measure(5000);}
    function testQualificationGasHistory10000() public {_measure(10000);}

    function testQualificationRealClosedRunsValidateSeedLayoutAndGrowth() public {
        for(uint256 id=1;id<=64;++id)_cycle(id);
        assertEq(settlement.historyLength(),64);
        uint256 first=uint256(keccak256(abi.encode(uint256(3))));
        for(uint256 id=1;id<=64;++id){
            assertEq(settlement.historyAt(id-1),id);
            assertEq(uint256(vm.load(address(settlement),bytes32(first+id-1))),id);
            uint256 stateSlot=uint256(keccak256(abi.encode(id,uint256(0))))+9;
            assertEq(uint256(vm.load(address(settlement),bytes32(stateSlot))),uint256(T.StrategyRunState.CLOSED));
            assertEq(uint256(settlement.run(id).state),uint256(T.StrategyRunState.CLOSED));
        }
        assertEq(kernel.activePrincipal(),0);
        assertEq(kernel.cumulativeRealizedProfit(),0);
        assertEq(kernel.cumulativeRealizedLoss(),0);
        _assertAccounting();
        vm.cool(address(settlement));
        uint256 beforeGas=gasleft();assertTrue(settlement.terminationReady());
        emit log_named_uint("realClosedHistory",64);
        emit log_named_uint("realColdTerminationReadyGas",beforeGas-gasleft());
    }

    function testQualificationKernelTerminationHistoryFitsBscTransactionCap() public {
        // Scaling proof, not a claim that 10,000 real transactions were executed.
        _seedClosedHistory(10000);
        vm.prank(GUARDIAN);kernel.initiateShutdown(72 hours);
        vm.warp(kernel.shutdownAt());
        _assertAccounting();
        assertEq(kernel.activePrincipal(),0);
        assertEq(kernel.holderRewardReserve(),0);
        assertTrue(settlement.terminationReady());
        vm.cool(address(settlement));vm.cool(address(kernel));
        vm.prank(GUARDIAN);
        (bool ok,bytes memory reason)=address(kernel).call{gas:TX_CAP}(abi.encodeWithSignature("terminate()"));
        assertTrue(ok,string(reason));
        assertEq(uint256(kernel.lifecycle()),uint256(T.Lifecycle.TERMINATED));
    }
}
