// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {CompdPancakeV3XStocksAdapter as A} from "../contracts/production/v3/phase7cr2ch/CompdPancakeV3XStocksAdapter.sol";
import {V3StableFixture,V3PoolFixture,V3FactoryFixture} from "./CompdPancakeV3XStocks.t.sol";
import {XRebaseFixture} from "./CompdPancakeRebaseQualification.t.sol";
import {XPairFixture,XFactoryFixture,XRouterFixture,XGuardFixture} from "./CompdPancakeXStocksAdapter.t.sol";
import {T,Kernel,Settlement,StrategyExecutor} from "./phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "./phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
contract CompdPancakeV3KernelTest is Test {
 address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;address constant AGENT=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
 address constant TOKEN=0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0;address constant STABLE=0x55d398326f99059fF775485246999027B3197955;
 address constant ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E;address constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
 address constant POOL=0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492;address constant FACTORY=0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
 Kernel kernel;Settlement settlement;A a;XRebaseFixture token;V3StableFixture stable;V3PoolFixture pool;XRouterFixture router;XGuardFixture guard;
 function kernelAddressRecovery() private pure returns(address){return 0xFa8706AA97B07cb29096381f9101784bA0d1332b;}
 function deployGraph() internal {vm.chainId(56);vm.roll(1000);if(block.timestamp<100000)vm.warp(100000);MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();address k=vm.computeCreateAddress(address(kd),1);address s=vm.computeCreateAddress(address(md),2);address d=vm.computeCreateAddress(address(md),3);address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);address c=md.candidate(k,s,d,address(0xF1A1),address(0x70C0));s=md.state(k,d,l,e,address(0xF1A1),c,address(0x70C0),c.codehash);d=md.distributor(k,s,c,address(0xF1A1));l=md.liability(k,s);e=md.evidence(k,s);address recovery=md.recovery(k,e,e.codehash);address holder=md.holder(k,d,l,s);address probe=address(new StrategyExecutor(k,ADMIN,GUARDIAN));address executor=vm.computeCreateAddress(k,1);address settle=md.settlement(k,executor,probe.codehash);address policy=md.policy(k);address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);address bb=md.buyback(k);address[6] memory modules=[settle,holder,policy,recovery,em,registry];bytes32[13] memory hashes=[probe.codehash,bb.codehash,d.codehash,l.codehash,e.codehash,c.codehash,s.codehash,settle.codehash,holder.codehash,policy.codehash,recovery.codehash,em.codehash,registry.codehash];kernel=Kernel(payable(kd.deploy(GUARDIAN,kernelAddressRecovery(),bb,d,l,e,c,address(0x70C0),modules,hashes)));settlement=Settlement(settle);
 vm.deal(ADMIN,100 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:100 ether}();vm.prank(ADMIN);kernel.activate();uint64 activation=kernel.activationBlock();vm.roll(uint256(activation)+1);vm.setBlockhash(activation,keccak256("LOCAL_XSTOCKS_FIXTURE_HEADER"));assertTrue(kernel.sealActivationCheckpoint());vm.prank(GUARDIAN);kernel.pause();
}
 function setUp() public {deployGraph();
  XRebaseFixture ti=new XRebaseFixture();vm.etch(TOKEN,address(ti).code);token=XRebaseFixture(TOKEN);token.setIndex(1 ether);
  V3StableFixture si=new V3StableFixture();vm.etch(STABLE,address(si).code);stable=V3StableFixture(STABLE);
  V3PoolFixture pi=new V3PoolFixture();vm.etch(POOL,address(pi).code);pool=V3PoolFixture(POOL);pool.init(STABLE,TOKEN,2500);
  V3FactoryFixture fi=new V3FactoryFixture();vm.etch(FACTORY,address(fi).code);V3FactoryFixture(FACTORY).init(POOL);
  XRouterFixture ri=new XRouterFixture();vm.etch(ROUTER,address(ri).code);router=XRouterFixture(ROUTER);
  router.init(address(new XFactoryFixture(address(new XPairFixture(WBNB,STABLE)))),WBNB);
  token.mint(POOL,1000 ether);stable.mint(POOL,1000 ether);vm.deal(ROUTER,100 ether);
 guard=new XGuardFixture();a=new A(kernel.strategyExecutor(),1,address(guard));admit(address(a),a.strategyIdentity(),a.riskConfigCommitment(),a.venueDependencyCommitment());}
 function admit(address adapter,bytes32 identity,bytes32 risk,bytes32 venue) internal {StrategyExecutor ex=StrategyExecutor(payable(kernel.strategyExecutor()));vm.prank(ADMIN);ex.proposeStrategy(adapter,identity,risk,venue);(,,,,uint64 at,)=ex.proposals(adapter);vm.warp(at);vm.prank(ADMIN);ex.activateStrategy(adapter);vm.prank(GUARDIAN);kernel.resume();vm.warp((block.timestamp/28800+1)*28800+1);}
 function start(uint256 run,uint256 n) internal {vm.prank(AGENT);settlement.startRun(run,address(a),n,bytes32(run));}
 function exitClose(uint256 run) internal {vm.prank(AGENT);settlement.requestExit(run,bytes32(run+100));vm.prank(AGENT);settlement.closeRun(run,bytes32(run+200));}
 function testV3KernelPositiveRebaseProfitAllocation() public {start(1,.01 ether);token.setIndex(1.02 ether);exitClose(1);uint256 p=kernel.cumulativeRealizedProfit();assertGt(p,0);assertEq(kernel.strategyCapital(),10 ether+p*6500/10000);assertEq(kernel.buybackReserve(),p*1500/10000);assertEq(kernel.holderRewardReserve(),p*1000/10000);assertEq(kernel.protocolReserve(),p-p*6500/10000-p*1500/10000-p*1000/10000);assertEq(kernel.nonStrategyTreasuryPrincipal(),90 ether);assertEq(address(kernel).balance,kernel.accountedQuote());assertEq(kernel.activePrincipal(),0);}
 function testV3KernelLossDoesNotCreateRewards() public {start(1,.01 ether);exitClose(1);assertGt(kernel.cumulativeRealizedLoss(),0);assertEq(kernel.cumulativeRealizedProfit(),0);assertEq(kernel.buybackReserve(),0);assertEq(kernel.holderRewardReserve(),0);assertEq(address(kernel).balance,kernel.accountedQuote());}
 function testV3KernelExposureShutdownAndSettlement() public {vm.expectRevert();start(1,1 ether+1);start(1,1 ether);start(2,1 ether);start(3,1 ether);vm.expectRevert();start(4,1);assertEq(kernel.activeRunCount(),3);assertEq(kernel.activePrincipal(),3 ether);vm.prank(GUARDIAN);kernel.emergencyShutdown();vm.expectRevert();start(5,1);exitClose(1);exitClose(2);exitClose(3);assertEq(kernel.activePrincipal(),0);assertEq(address(kernel).balance,kernel.accountedQuote());}
 function testV3KernelUnauthorizedAgentRejected() public {vm.expectRevert();settlement.startRun(1,address(a),.01 ether,bytes32(uint256(1)));}
 function testV3KernelGuardRejectionConservesReserves() public {guard.configure(10000,61,true);uint256 balance=address(kernel).balance;vm.expectRevert();start(1,.01 ether);assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),10 ether);assertEq(address(kernel).balance,balance);}
 function testV3KernelFailedSellThenFundedRetry() public {start(1,.01 ether);pool.configure(true,false,false);vm.prank(AGENT);settlement.requestExit(1,bytes32(uint256(101)));assertEq(kernel.activePrincipal(),.01 ether);assertGt(a.totalPositionShares(),0);pool.configure(false,false,false);exitClose(1);assertEq(a.totalPositionShares(),0);assertEq(kernel.activePrincipal(),0);assertEq(address(kernel).balance,kernel.accountedQuote());}
}
