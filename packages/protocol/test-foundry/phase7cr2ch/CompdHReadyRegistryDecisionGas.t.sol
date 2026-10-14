// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase} from "./CompdHReadyLocalQualification.t.sol";
import {CompdEmergencyScopeRegistryV3} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyScopeRegistryV3.sol";

contract CompdHReadyRegistryDecisionGasTest is CompdHReadyQualificationBase {
    function _shape(uint256 n,uint8 kind) private pure returns(bytes32[] memory ids,uint8[] memory kinds) {
        ids=new bytes32[](n);kinds=new uint8[](n);
        for(uint256 i;i<n;++i){ids[i]=keccak256(abi.encode("OWNER_SCOPE_GAS",i));kinds[i]=kind;}
    }
    function _intrinsic(bytes memory data) private pure returns(uint256 gas_) {
        gas_=21000;for(uint256 i;i<data.length;++i)gas_+=data[i]==0?4:16;
    }
    function _measure(uint256 n,uint8 kind) private {
        uint256 snap=vm.snapshotState();vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();
        (bytes32[] memory ids,uint8[] memory kinds)=_shape(n,kind);
        bytes memory data=abi.encodeWithSignature("initialize(bytes32[],uint8[])",ids,kinds);
        vm.cool(address(kernel));vm.cool(address(emergency));vm.cool(emergency.registry());
        vm.prank(EMERGENCY_AUTHORITY);uint256 before_=gasleft();emergency.initialize(ids,kinds);uint256 used=before_-gasleft();
        emit log_named_uint("scope count",n);emit log_named_uint("scope kind",kind);
        emit log_named_uint("cold initialization call gas",used);emit log_named_uint("actual ABI intrinsic gas",_intrinsic(data));
        emit log_named_uint("conservative call plus intrinsic",used+_intrinsic(data));
        (uint256 scopes,uint256 open,,,)=CompdEmergencyScopeRegistryV3(emergency.registry()).summary(kernel.emergencySnapshotId());
        assertEq(scopes,n);assertEq(open,n);assertTrue(vm.revertToState(snap));
    }
    function testOwnerRegistry64EveryKindGas() public {for(uint8 kind;kind<4;++kind)_measure(64,kind);}
    function testOwnerRegistryNonzeroKindScalingGas() public {_measure(96,3);_measure(128,3);_measure(192,3);}
    function testOwnerRegistry64BoundedCallAndLateDiscoveryGas() public {
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();(bytes32[] memory ids,uint8[] memory kinds)=_shape(64,3);
        bytes memory data=abi.encodeWithSignature("initialize(bytes32[],uint8[])",ids,kinds);
        vm.cool(address(kernel));vm.cool(address(emergency));vm.cool(emergency.registry());
        vm.prank(EMERGENCY_AUTHORITY);(bool ok,)=address(emergency).call{gas:8_000_000}(data);assertTrue(ok);
        vm.cool(address(kernel));vm.cool(address(emergency));vm.cool(emergency.registry());
        vm.prank(EMERGENCY_AUTHORITY);uint256 before_=gasleft();emergency.discover(keccak256("late scope"),3,keccak256("late evidence"));
        emit log_named_uint("cold single late discovery call gas",before_-gasleft());
        (uint256 scopes,uint256 open,,,)=CompdEmergencyScopeRegistryV3(emergency.registry()).summary(kernel.emergencySnapshotId());assertEq(scopes,65);assertEq(open,65);
        vm.prank(EMERGENCY_AUTHORITY);(ok,)=address(emergency).call(data);assertFalse(ok,"initialization is one-shot");
    }
}

