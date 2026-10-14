// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CompdVaultKernelV2RehomeProto, RehomeSettlementModule, RehomeHolderModule, RehomeBuybackModule, RehomeRecoveryModule, RehomeEmergencyModule, RehomeRegistryModule} from "../../contracts/prototype/phase6c2g2a/CompdVaultKernelV2RehomeProto.sol";

contract RehomeExecMock {
    mapping(uint256=>uint256) public principal;
    mapping(uint256=>uint256) public returnsForRun;
    bool public fakePrincipal;
    function setReturn(uint256 id,uint256 amount) external {returnsForRun[id]=amount;} function setFakePrincipal(bool yes) external {fakePrincipal=yes;} function open(uint256 id,uint256 amount,bytes32 evidence) external payable returns(bytes32){require(msg.value==amount);principal[id]=amount;return evidence;}
    function closeToKernel(uint256 id,bytes32 closeId) external returns(uint256 p,uint256 returned,bytes32 proof){p=principal[id];if(fakePrincipal)p++;returned=returnsForRun[id];(bool ok,)=payable(msg.sender).call{value:returned}("");require(ok);proof=closeId;}
    function buyback(bytes32,bytes32) external payable returns(uint256 spent,uint256 received,uint256 burned,bytes32 burnId){spent=msg.value;received=msg.value;burned=received;burnId=keccak256(abi.encode(msg.value));}
}
contract RehomeDistributorMock {
    bytes32 public digest;address public recipient;uint256 public amount;address public asset;uint8 public status=1;
    function set(bytes32 d,address r,uint256 a,address asst) external {digest=d;recipient=r;amount=a;asset=asst;}
    function committedPayment(bytes32) external view returns(bytes32,address,uint256,address,uint8){return(digest,recipient,amount,asset,status);}
    function markPaid(bytes32) external {status=3;}
}
contract RehomeLiabilityMock {
    bytes32 public digest;uint8 public status=2;
    function set(bytes32 d,uint8 s) external {digest=d;status=s;}
    function paymentAuthorization(bytes32) external view returns(bytes32,uint8){return(digest,status);}
    function markPaid(bytes32) external {status=3;}
}
contract RehomeRecoveryMock {
    uint256 public protocolAmount;uint256 public holderAmount;
    function set(uint256 p,uint256 h) external {protocolAmount=p;holderAmount=h;}
    function protocolReserveEligible(bytes32) external view returns(uint256){return protocolAmount;}
    function holderLiabilityEligible(bytes32) external view returns(uint256){return holderAmount;}
    function consumeProtocolReserve(bytes32) external {protocolAmount=0;}
    function consumeHolderLiability(bytes32) external {holderAmount=0;}
}
contract RehomeRejectBNB {receive() external payable {revert();}}

contract Phase6C2G2ARehomeTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant AUTH=address(0xA117);
    address constant WALLET=address(0xBEEF);
    address constant ALICE=address(0xA11CE);
    RehomeExecMock exec;RehomeDistributorMock dist;RehomeLiabilityMock liability;RehomeRecoveryMock recovery;
    CompdVaultKernelV2RehomeProto kernel;RehomeSettlementModule settlement;RehomeHolderModule holder;RehomeBuybackModule buyback;RehomeRecoveryModule recoveryModule;RehomeEmergencyModule emergency;RehomeRegistryModule registry;
    function setUp() public {
        exec=new RehomeExecMock();dist=new RehomeDistributorMock();liability=new RehomeLiabilityMock();recovery=new RehomeRecoveryMock();
        kernel=new CompdVaultKernelV2RehomeProto(AUTH,WALLET,address(exec),address(exec),address(dist),address(liability),address(recovery));
        settlement=new RehomeSettlementModule(address(kernel));holder=new RehomeHolderModule(address(kernel));buyback=new RehomeBuybackModule(address(kernel));recoveryModule=new RehomeRecoveryModule(address(kernel));emergency=new RehomeEmergencyModule(address(kernel));registry=new RehomeRegistryModule(address(kernel));
        address[6] memory mods=[address(settlement),address(holder),address(buyback),address(recoveryModule),address(emergency),address(registry)];vm.prank(ADMIN);kernel.bind(mods);
        vm.deal(ADMIN,20 ether);vm.prank(ADMIN);kernel.fund{value:10 ether}();vm.prank(ADMIN);kernel.activate();
        vm.deal(address(exec),100 ether);
    }
    function _makeProfit() internal {bytes32 a=keccak256("alloc");settlement.allocate(1,1 ether,a);exec.setReturn(1,3 ether);settlement.settle(1,keccak256("close"));}
    function testWrongModuleCannotAllocate() public {vm.expectRevert(CompdVaultKernelV2RehomeProto.Unauthorized.selector);vm.prank(address(holder));kernel.allocate(2,1 ether,keccak256("x"));}
    function testWrongLifecycleBlocksAllocation() public {vm.prank(GUARDIAN);kernel.pause();vm.expectRevert(CompdVaultKernelV2RehomeProto.InvalidAmount.selector);settlement.allocate(2,1 ether,keccak256("x"));}
    function testFakePrincipalRejectedAndAtomic() public {settlement.allocate(1,1 ether,keccak256("alloc"));exec.setReturn(1,2 ether);exec.setFakePrincipal(true);vm.expectRevert(CompdVaultKernelV2RehomeProto.BadEvidence.selector);settlement.settle(1,keccak256("close"));assertEq(kernel.principalOf(1),1 ether);assertEq(kernel.activePrincipal(),1 ether);}
    function testFakeHolderAuthorizationAndWrongRecipientRejected() public {_makeProfit();bytes32 leaf=keccak256("leaf");dist.set(keccak256(abi.encode(ALICE,0.1 ether)),ALICE,0.1 ether,address(0));liability.set(keccak256("different recipient"),2);vm.expectRevert(CompdVaultKernelV2RehomeProto.BadEvidence.selector);holder.pay(leaf);}
    function testRecipientMutationWithoutDigestChangeRejected() public {_makeProfit();bytes32 leaf=keccak256("recipient-leaf");bytes32 d=keccak256(abi.encode(leaf,ALICE,0.1 ether,address(0),uint8(1),uint8(2)));dist.set(d,address(0xBAD),0.1 ether,address(0));liability.set(d,2);vm.expectRevert(CompdVaultKernelV2RehomeProto.BadEvidence.selector);holder.pay(leaf);}
    function testInflatedHolderAmountRejected() public {_makeProfit();bytes32 leaf=keccak256("leaf");bytes32 d=keccak256(abi.encode(leaf,ALICE,0.3 ether,address(0),uint8(1),uint8(2)));dist.set(d,ALICE,0.3 ether,address(0));liability.set(d,2);vm.expectRevert(CompdVaultKernelV2RehomeProto.BadEvidence.selector);holder.pay(leaf);}
    function testHolderPaymentReplayRejected() public {_makeProfit();bytes32 leaf=keccak256("leaf");bytes32 d=keccak256(abi.encode(leaf,ALICE,0.1 ether,address(0),uint8(1),uint8(2)));dist.set(d,ALICE,0.1 ether,address(0));liability.set(d,2);assertTrue(holder.pay(leaf));vm.expectRevert(CompdVaultKernelV2RehomeProto.InvalidState.selector);holder.pay(leaf);}
    function testWrongRecoveryBucketAndLifecycleRejected() public {_makeProfit();bytes32 leaf=keccak256("leaf");bytes32 d=keccak256(abi.encode(leaf,ALICE,0.2 ether,address(0),uint8(1),uint8(2)));dist.set(d,ALICE,0.2 ether,address(0));liability.set(d,2);assertTrue(holder.pay(leaf));recovery.set(0,0.2 ether);vm.prank(GUARDIAN);kernel.beginShutdown(72 hours);vm.warp(block.timestamp+72 hours);vm.prank(GUARDIAN);kernel.terminate();vm.expectRevert(CompdVaultKernelV2RehomeProto.BadEvidence.selector);recoveryModule.protocolReserve(keccak256("wrong typed source"),0.2 ether);}
    function testEmergencyEntryWorksWithoutRegistryCallback() public {vm.prank(AUTH);kernel.emergencyEnter();assertEq(uint8(kernel.lifecycle()),uint8(CompdVaultKernelV2RehomeProto.Life.EMERGENCY_RECOVERY));assertNotEq(kernel.emergencySnapshot(),bytes32(0));}
    function testEmergencyTransferReplayAndFixedDestination() public {_makeProfit();vm.prank(AUTH);kernel.emergencyEnter();uint256 w0=WALLET.balance;emergency.protocolTransfer(0.2 ether,keccak256("protocol"));assertEq(WALLET.balance-w0,0.2 ether);vm.expectRevert(CompdVaultKernelV2RehomeProto.InvalidAmount.selector);emergency.protocolTransfer(0.2 ether,keccak256("protocol"));}
}






