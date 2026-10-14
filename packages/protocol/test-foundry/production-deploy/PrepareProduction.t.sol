// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {PrepareProduction} from "../../script/PrepareProduction.s.sol";
contract PrepareProductionTest is Test {
    PrepareProduction prep;
    function setUp() public {prep=new PrepareProduction();}
    function testWrongChainBlocked() public {vm.expectRevert(PrepareProduction.Blocked.selector);prep.checkConfirmation(1,true);}
    function testNoOwnerConfirmationBlocked() public {vm.expectRevert(PrepareProduction.Blocked.selector);prep.checkConfirmation(56,false);}
    function testConfirmedRolesAndLocalConfirmation() public {prep.checkConfirmation(56,true);assertEq(prep.DEPLOYER(),0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9);assertEq(prep.FINALIZER(),0x4E8eae88355C8730E313bD156008aA49E47Cd8F3);assertTrue(prep.DEPLOYER()!=prep.FINALIZER());}
}
