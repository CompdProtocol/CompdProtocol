// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase,HReadyLargeReturnNative,HReadyRejectNative} from "./CompdHReadyLocalQualification.t.sol";
import {T} from "../phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";

/// Models a code-bearing authority at the same immutable fixture identity.
contract HReadyAuthorityCallbackRelay {
    address immutable emergency;address immutable wallet;bytes32 immutable scope;
    constructor(address e,address w,bytes32 s){emergency=e;wallet=w;scope=s;}
    function callbackAttempt() external returns(bool ok){require(msg.sender==wallet);(ok,)=emergency.call(abi.encodeWithSignature("recoverBNB(bytes32,bytes32,uint32,uint256,bytes32)",scope,keccak256("nested authorized attempt"),uint32(2),uint256(1),keccak256("proof")));}
}
contract HReadyEmergencyWalletCallback {
    address immutable authority;bool public rejected;
    constructor(address a){authority=a;}
    receive() external payable {bool ok=HReadyAuthorityCallbackRelay(authority).callbackAttempt();require(!ok,"authorized callback must reject");rejected=true;}
}

contract CompdHReadyRemainingEmergencyTest is CompdHReadyQualificationBase {
    function testRemainingEmergencyAuthorizedAuthorityRelayCallbackCannotReenter() public {
        bytes32 scope=_emergencyScope();uint256 aq=kernel.accountedQuote();address wallet=kernel.emergencyWallet();
        HReadyAuthorityCallbackRelay relay=new HReadyAuthorityCallbackRelay(address(emergency),wallet,scope);vm.etch(EMERGENCY_AUTHORITY,address(relay).code);
        HReadyEmergencyWalletCallback callback=new HReadyEmergencyWalletCallback(EMERGENCY_AUTHORITY);vm.etch(wallet,address(callback).code);
        vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,keccak256("outer attempt"),1,1 ether,keccak256("proof"));
        assertTrue(HReadyEmergencyWalletCallback(payable(wallet)).rejected());assertEq(kernel.emergencyBNBOutflow(),1 ether);assertEq(kernel.accountedQuote(),aq);assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.COMPLETE_WITHIN_REGISTERED_SCOPE));
        bytes32 second=keccak256("followup scope");vm.prank(EMERGENCY_AUTHORITY);emergency.discover(second,0,keccak256("proof"));vm.etch(wallet,hex"");vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(second,keccak256("followup attempt"),1,1 ether,keccak256("proof"));assertEq(kernel.emergencyBNBOutflow(),2 ether);
    }
    function testRemainingEmergencyDuplicateScopeAndBadKindInitializationAreAtomic() public {
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();bytes32[] memory ids=new bytes32[](2);uint8[] memory kinds=new uint8[](2);ids[0]=keccak256("scope");ids[1]=ids[0];
        vm.prank(EMERGENCY_AUTHORITY);(bool ok,)=address(emergency).call(abi.encodeWithSignature("initialize(bytes32[],uint8[])",ids,kinds));assertFalse(ok);
        ids[1]=keccak256("second");kinds[1]=255;vm.prank(EMERGENCY_AUTHORITY);(ok,)=address(emergency).call(abi.encodeWithSignature("initialize(bytes32[],uint8[])",ids,kinds));assertFalse(ok);
        kinds[1]=0;vm.prank(EMERGENCY_AUTHORITY);emergency.initialize(ids,kinds);assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.IN_PROGRESS));
    }
    function testRemainingEmergencyDepletionAndForcedSurplusUsePhysicalBalanceOnly() public {
        bytes32 scope=_emergencyScope();uint256 aq=kernel.accountedQuote();uint256 physical=address(kernel).balance;vm.deal(address(kernel),physical+2 ether);
        vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,keccak256("all physical"),1,physical+2 ether,keccak256("proof"));assertEq(address(kernel).balance,0);assertEq(kernel.accountedQuote(),aq);assertEq(kernel.emergencyBNBOutflow(),physical+2 ether);
        bytes32 second=keccak256("second physical scope");vm.prank(EMERGENCY_AUTHORITY);emergency.discover(second,0,keccak256("proof"));
        vm.prank(EMERGENCY_AUTHORITY);(bool ok,)=address(emergency).call(abi.encodeWithSignature("recoverBNB(bytes32,bytes32,uint32,uint256,bytes32)",second,keccak256("depleted"),uint32(1),uint256(1),keccak256("proof")));assertFalse(ok);assertEq(kernel.emergencyBNBOutflow(),physical+2 ether);
    }
    function testRemainingEmergencyLargeReturnDataAndRegistryPinFaultRollback() public {
        bytes32 scope=_emergencyScope();uint256 snap=vm.snapshotState();uint256 before_=address(kernel).balance;vm.etch(emergency.registry(),hex"00");
        vm.prank(EMERGENCY_AUTHORITY);(bool ok,)=address(emergency).call(abi.encodeWithSignature("recoverBNB(bytes32,bytes32,uint32,uint256,bytes32)",scope,keccak256("attempt"),uint32(1),1 ether,keccak256("proof")));assertFalse(ok);assertEq(address(kernel).balance,before_);assertEq(kernel.emergencyBNBOutflow(),0);assertTrue(vm.revertToState(snap));
        HReadyLargeReturnNative bomb=new HReadyLargeReturnNative();vm.etch(kernel.emergencyWallet(),address(bomb).code);vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(scope,keccak256("attempt"),1,1 ether,keccak256("proof"));assertEq(kernel.emergencyBNBOutflow(),1 ether);
    }
    function testRemainingEmergencyFiveHundredScopeInitializationAndLastScopeRecovery() public {
        vm.prank(EMERGENCY_AUTHORITY);kernel.emergencyEnter();bytes32[] memory ids=new bytes32[](500);uint8[] memory kinds=new uint8[](500);for(uint256 i;i<500;++i)ids[i]=keccak256(abi.encode("scope",i));
        vm.prank(EMERGENCY_AUTHORITY);uint256 before_=gasleft();emergency.initialize(ids,kinds);emit log_named_uint("500 scope initialization call gas",before_-gasleft());
        vm.prank(EMERGENCY_AUTHORITY);emergency.recoverBNB(ids[499],keccak256("last scope"),1,1 ether,keccak256("proof"));assertEq(kernel.emergencyBNBOutflow(),1 ether);assertEq(uint256(kernel.emergencyStatus()),uint256(T.ProcessingStatus.IN_PROGRESS));
    }
}
