// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "../phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";
import {CompdStrategyExecutorV2R2 as Executor} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {CompdNativeFeeReceiverV3 as Receiver} from "../../contracts/production/v3/phase7cr2ch/CompdNativeFeeReceiverV3.sol";
import {ICompdBuybackAdapterV3} from "../../contracts/production/v3/phase7cr2ch/CompdBuybackExecutorV3.sol";
import {CompdManualBuybackExecutorV3 as Burner} from "../../contracts/production/v3/phase7cr2ch/CompdManualBuybackExecutorV3.sol";
import {CompdBuybackPolicyModuleV3 as Policy} from "../../contracts/production/v3/phase7cr2ch/CompdBuybackPolicyModuleV3.sol";
contract ManualFixtureToken {
    bool public shortDisposal;
    function setShortDisposal(bool b) external {shortDisposal=b;}
    mapping(address=>uint256) public balanceOf;uint256 public totalSupply;bool public badBurn;
    function mint(address to,uint256 n) external {balanceOf[to]+=n;totalSupply+=n;}
    function setBadBurn(bool b) external {badBurn=b;}
    function transfer(address to,uint256 n) external returns(bool){require(!badBurn && balanceOf[msg.sender]>=n);balanceOf[msg.sender]-=n;balanceOf[to]+=shortDisposal?n-1:n;return true;}
}
contract ManualFixtureAdapter is ICompdBuybackAdapterV3 {
    address public constant token=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    bool public fail;uint256 public output=1000;uint256 public minimum=970;uint64 public observed;uint64 public deadline;
    function configure(bool f,uint256 out,uint256 min,uint64 at,uint64 end) external {fail=f;output=out;minimum=min;observed=at;deadline=end;}
    function quote(bytes32,uint256) external view returns(uint256,uint256,uint64,uint64){return(1000,minimum,observed,deadline);}
    function swapExactBNBForCOMPD(bytes32,uint256,uint64,address recipient) external payable {require(!fail);ManualFixtureToken(token).mint(recipient,output);}
}
contract CompdManualTreasuryLocalTest is Test {
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant BUYBACK_ADMIN=0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address constant AGENT=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address constant TOKEN=0x7b7Af51136574c91A12988989c0a08E98aE97777;
    Kernel kernel;Burner burner;Policy policy;ManualFixtureAdapter adapter;
    function setUp() public {
        vm.chainId(56);vm.warp(10000);ManualFixtureToken mock=new ManualFixtureToken();vm.etch(TOKEN,address(mock).code);
        adapter=new ManualFixtureAdapter();adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));
        MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();
        address k=vm.computeCreateAddress(address(kd),1);address st=vm.computeCreateAddress(address(md),2);
        address d=vm.computeCreateAddress(address(md),3);address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);
        address c=md.candidate(k,st,d,address(0xF1A1),TOKEN);st=md.state(k,d,l,e,address(0xF1A1),c,TOKEN,c.codehash);
        d=md.distributor(k,st,c,address(0xF1A1));l=md.liability(k,st);e=md.evidence(k,st);
        address r=md.recovery(k,e,e.codehash);address h=md.holder(k,d,l,st);
        address probe=address(new Executor(k,ADMIN,GUARDIAN));address settle=md.settlement(k,vm.computeCreateAddress(k,1),probe.codehash);
        md.policy(k);burner=new Burner(k,address(adapter),TOKEN.codehash);policy=new Policy(k,address(burner));
        address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);
        address[6] memory modules=[settle,h,address(policy),r,em,registry];
        bytes32[13] memory hashes=[probe.codehash,address(burner).codehash,d.codehash,l.codehash,e.codehash,c.codehash,st.codehash,settle.codehash,h.codehash,address(policy).codehash,r.codehash,em.codehash,registry.codehash];
        kernel=Kernel(payable(kd.deploy(address(0xA11CE),address(0xB0B),address(burner),d,l,e,c,TOKEN,modules,hashes)));
        vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();
        vm.deal(address(this),10 ether);(bool ok,)=kernel.nativeFeeReceiver().call{value:10 ether}("");require(ok);
        Receiver(payable(kernel.nativeFeeReceiver())).forwardPending();
    }
    function _enable() private {bytes32 commitment=burner.policyCommitment();vm.prank(BUYBACK_ADMIN);kernel.activateBuyback(commitment);vm.prank(ADMIN);kernel.activate();}
    function _attempt(bytes32 id) private {vm.prank(BUYBACK_ADMIN);policy.attempt(id,keccak256("QUOTE"));}
    function testDefaultDisabledAndOnlyBuybackAdminActivation() public {
        assertFalse(kernel.buybackActivated());bytes32 commitment=burner.policyCommitment();vm.expectRevert();kernel.activateBuyback(commitment);
        vm.prank(ADMIN);kernel.activate();vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),1.5 ether);
    }
    function testDeadTransferReserveConservationAndNoNativeBurn() public {
        _enable();_attempt(bytes32(uint256(1)));
        assertEq(kernel.buybackReserve(),1.2 ether);assertEq(kernel.accountedQuote(),109.7 ether);
        assertEq(kernel.strategyCapital(),13.5 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.protocolReserve(),5 ether);
        assertEq(burner.totalCOMPDBurned(),0);assertEq(burner.totalCOMPDDisposed(),1000);assertEq(burner.totalCOMPDPurchased(),1000);assertEq(ManualFixtureToken(TOKEN).balanceOf(burner.DISPOSAL()),1000);assertEq(ManualFixtureToken(TOKEN).totalSupply(),1000);
        assertEq(ManualFixtureToken(TOKEN).balanceOf(address(burner)),0);assertEq(address(kernel).balance,109.7 ether);
    }
    function testSwapFailureRollbackThenSameOperationRetry() public {
        _enable();adapter.configure(true,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),1.5 ether);assertFalse(policy.operationUsed(bytes32(uint256(1))));assertEq(burner.totalBNBSpent(),0);
        adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));_attempt(bytes32(uint256(1)));
        assertEq(kernel.buybackReserve(),1.2 ether);
    }
    function testSlippageDeadlineAndFailedDisposalAllRollback() public {
        _enable();adapter.configure(false,100,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        adapter.configure(false,1000,960,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));assertFalse(burner.isExecutable(keccak256("QUOTE"),.3 ether));
        adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()-1),uint64(vm.getBlockTimestamp()-1));assertFalse(burner.isExecutable(keccak256("QUOTE"),.3 ether));
        adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));ManualFixtureToken(TOKEN).setBadBurn(true);
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));assertEq(kernel.buybackReserve(),1.5 ether);
    }
    function testCooldownDuplicateAndRollingCap() public {
        _enable();_attempt(bytes32(uint256(1)));vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(2)),keccak256("QUOTE"));
        for(uint256 i=2;i<=3;i++){vm.warp(vm.getBlockTimestamp()+6 hours);adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));_attempt(bytes32(i));}
        assertEq(burner.totalBNBSpent(),.6 ether);assertEq(kernel.buybackReserve(),.9 ether);
        vm.warp(vm.getBlockTimestamp()+6 hours);adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(4)),keccak256("QUOTE"));
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
    }
    function testChangedAdapterAndWrongChainFailClosed() public {
        _enable();vm.chainId(97);assertFalse(burner.isExecutable(keccak256("QUOTE"),.3 ether));
        vm.chainId(56);vm.etch(address(adapter),hex"00");assertFalse(burner.configurationValid());
    }
    function testUnauthorizedExecutorCannotSpendOrBuyOtherToken() public {
        _enable();vm.expectRevert();burner.executeExactInput(bytes32(uint256(1)),keccak256("QUOTE"));
        vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        vm.prank(AGENT);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        vm.prank(BUYBACK_ADMIN);policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));assertEq(kernel.buybackReserve(),1.2 ether);
    }

    function testStaleQuoteFailsWithoutAnyReserveDebit() public {
        _enable();vm.warp(vm.getBlockTimestamp()+301);
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),1.5 ether);assertEq(burner.totalBNBSpent(),0);
    }
    function testShutdownBlocksNewSpendAndProtectsReserves() public {
        _enable();vm.prank(GUARDIAN);kernel.emergencyShutdown();
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),1.5 ether);assertEq(kernel.accountedQuote(),110 ether);
    }
    function testAbsoluteCapAndProtectedOtherBuckets() public {
        vm.deal(address(this),30 ether);(bool ok,)=kernel.nativeFeeReceiver().call{value:30 ether}("");require(ok);
        Receiver(payable(kernel.nativeFeeReceiver())).forwardPending();_enable();_attempt(bytes32(uint256(1)));
        assertEq(burner.totalBNBSpent(),.5 ether);assertEq(kernel.buybackReserve(),5.5 ether);
        assertEq(kernel.strategyCapital(),24 ether);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(kernel.protocolReserve(),20 ether);
    }
    function testNoNativeBurnABIIsRequired() public {
        _enable();(bool burnSupported,)=TOKEN.call(abi.encodeWithSignature("burn(uint256)",1));assertFalse(burnSupported);
        _attempt(bytes32(uint256(1)));assertEq(burner.totalCOMPDBurned(),0);
    }
    function testTaxedDisposalRevertsPurchaseAndLedgerAtomically() public {
        _enable();ManualFixtureToken(TOKEN).setShortDisposal(true);
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(1)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),1.5 ether);assertEq(ManualFixtureToken(TOKEN).totalSupply(),0);
        assertEq(ManualFixtureToken(TOKEN).balanceOf(burner.DISPOSAL()),0);assertFalse(burner.operationUsed(bytes32(uint256(1))));
    }
    function testMinimumReserveStopsSpending() public {
        _enable();
        for(uint256 i=1;kernel.buybackReserve()>=.25 ether;i++){
            vm.warp(vm.getBlockTimestamp()+24 hours);adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));_attempt(bytes32(i));
        }
        uint256 reserve=kernel.buybackReserve();vm.warp(vm.getBlockTimestamp()+24 hours);
        adapter.configure(false,1000,970,uint64(vm.getBlockTimestamp()),uint64(vm.getBlockTimestamp()+300));
        vm.prank(BUYBACK_ADMIN);vm.expectRevert();policy.attempt(bytes32(uint256(100)),keccak256("QUOTE"));
        assertEq(kernel.buybackReserve(),reserve);
    }
}



