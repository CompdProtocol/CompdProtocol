"""Deterministic local fixtures. No deployed venue or price qualification."""
import copy,json,tempfile,unittest
from pathlib import Path
from xstocks_agent import *
from agent_scheduler import Scheduler
from test_agent_scheduler import configuration,addr,h
from test_agent_lifecycle import LifecycleRPC,LifecycleCast

def snapshot():return dict(block='0x8',blockHash=h(9),timestamp=100,lifecycle=0,capital=10000,active=0,accounted=10000,runCount=0,halted=0,risk=0,maxPrincipalWei=1000,historyComplete=True,runs=[])
def market():return dict(blockHash=h(9),priceWei=102,referenceWei=100,quoteOut=1000,minimumOut=995,liquidityWei=50000,timestamp=100,referenceTimestamp=50,validUntil=160,marketOpen=True,calendarVerified=True,priceSourceVerified=True,quoteVerified=True,amountInWei=500)
def route(symbol='NVDAx'):return dict(symbol=symbol,qualification='TEST_FIXTURE',adapter=addr(5),adapterCodeHash=h(5),router=addr(6),token=addr(7),settlementToken=addr(8))

class DecisionTests(unittest.TestCase):
    def decide(self,s=None,m=None,r=None,p=None,pos=None):return decision('NVDAx',s or snapshot(),m or market(),r or route(),p or DEFAULT_POLICY,pos)
    def test_exact_five_assets(self):
        self.assertEqual(ASSETS,('NVDAx','TSLAx','AMZNx','AAPLx','SPYx'))
        for x in ASSETS:self.assertEqual(decision(x,snapshot(),market(),route(x),DEFAULT_POLICY)[0]['amountWei'],'500')
    def test_unauthorized_assets(self):
        for x in ['MSFTx','SPCXx','BNB','USDT','BAD']:
            with self.assertRaises(ValueError):decision(x,snapshot(),market(),route(x),DEFAULT_POLICY)
    def test_cannot_qualify_route_using_flag(self):self.assertEqual(self.decide(r={**route(),'qualification':'VERIFIED'})[1],'ROUTE_NOT_QUALIFIED')
    def test_route_asset_binding(self):self.assertEqual(self.decide(r=route('TSLAx'))[1],'ROUTE_ASSET_MISMATCH')
    def test_invalid_router(self):
        with self.assertRaises(ValueError):self.decide(r={**route(),'router':'anything'})
    def test_policy_cannot_override_locked_limits(self):
        for change in [dict(allocationBps=1001),dict(leverage=2),dict(slippageBps=101),dict(allocationBps=True)]:
            with self.assertRaises(ValueError):self.decide(p={**DEFAULT_POLICY,**change})
    def test_three_position_cap(self):self.assertEqual(self.decide(s={**snapshot(),'runCount':3})[1],'POSITION_CAP')
    def test_thirty_percent_cap(self):self.assertEqual(self.decide(s={**snapshot(),'active':3000})[1],'INSUFFICIENT_CAPITAL')
    def test_available_funds(self):self.assertEqual(self.decide(s={**snapshot(),'accounted':0})[1],'INSUFFICIENT_CAPITAL')
    def test_paused(self):self.assertEqual(self.decide(s={**snapshot(),'lifecycle':1})[1],'PAUSED_NO_ENTRY')
    def test_daily_or_drawdown_latch(self):self.assertEqual(self.decide(s={**snapshot(),'risk':1})[1],'ONCHAIN_RISK_BREAKER')
    def test_loss_breach_halt(self):self.assertEqual(self.decide(s={**snapshot(),'halted':1})[1],'ONCHAIN_RISK_BREAKER')
    def test_stale_price(self):self.assertEqual(self.decide(m={**market(),'timestamp':39})[1],'STALE_PRICE')
    def test_future_price(self):self.assertEqual(self.decide(m={**market(),'timestamp':101})[1],'STALE_PRICE')
    def test_block_mismatch(self):self.assertEqual(self.decide(m={**market(),'blockHash':h(12)})[1],'QUOTE_BLOCK_MISMATCH')
    def test_market_closed(self):self.assertEqual(self.decide(m={**market(),'marketOpen':False})[1],'MARKET_CLOSED_OR_CALENDAR_UNVERIFIED')
    def test_calendar_unverified(self):self.assertEqual(self.decide(m={**market(),'calendarVerified':False})[1],'MARKET_CLOSED_OR_CALENDAR_UNVERIFIED')
    def test_quote_unverified(self):self.assertEqual(self.decide(m={**market(),'quoteVerified':False})[1],'PRICE_OR_QUOTE_UNVERIFIED')
    def test_low_liquidity(self):self.assertEqual(self.decide(m={**market(),'liquidityWei':49999})[1],'INSUFFICIENT_LIQUIDITY')
    def test_slippage(self):self.assertEqual(self.decide(m={**market(),'minimumOut':994})[1],'SLIPPAGE_LIMIT')
    def test_expired_quote(self):self.assertEqual(self.decide(m={**market(),'validUntil':100})[1],'INVALID_DEADLINE')
    def test_wrong_quote_size(self):self.assertEqual(self.decide(m={**market(),'amountInWei':501})[1],'QUOTE_SIZE_MISMATCH')
    def test_no_forced_trade(self):self.assertEqual(self.decide(m={**market(),'priceWei':100})[1],'NO_ENTRY_SIGNAL')
    def test_stop_signal_not_guarantee(self):self.assertEqual(self.decide(m={**market(),'priceWei':97},pos=dict(id=1,principal=500,entryPriceWei=100))[0]['method'],'requestExit')
    def test_hold(self):self.assertEqual(self.decide(pos=dict(id=1,principal=500,entryPriceWei=102))[1],'HOLD')
    def test_take_profit(self):self.assertIsNotNone(self.decide(m={**market(),'priceWei':106},pos=dict(id=1,principal=500,entryPriceWei=100))[0])
    def test_no_rewards_or_pnl_from_prices(self):self.assertEqual(set(self.decide()[0]),{'method','adapter','amountWei'})

class LifecycleTests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.c=configuration();self.rpc=LifecycleRPC();self.cast=LifecycleCast(self.rpc);self.workers=[]
    def tearDown(self):
        for s in self.workers:s.db.close()
        self.tmp.cleanup()
    def worker(self,**kwargs):
        s=Scheduler(Path(self.tmp.name)/'db',self.c,self.rpc,self.cast);self.workers.append(s);return XStocksLifecycle(s,**kwargs)
    def test_production_assets_disabled(self):
        a=self.worker();self.assertEqual(a.tick(0)['status'],'XSTOCKS_ROUTES_DISABLED');self.assertEqual(self.cast.sent,[])
    def test_duplicate_cycle_and_restart(self):
        a=self.worker();a.tick(0);b=self.worker();self.assertEqual(b.tick(0)['status'],'ALREADY_EVALUATED_OBSERVE_ONLY')
    def test_next_utc_slot_evaluated(self):
        a=self.worker();a.tick(0);self.rpc.timestamp=CYCLE;self.assertEqual(a.tick(CYCLE)['status'],'XSTOCKS_ROUTES_DISABLED')
    def test_launch_observe_never_simulates_transaction(self):
        a=self.worker();self.assertEqual(a.observe_launch()['status'],'OBSERVE_ONLY');self.assertEqual(a.s.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_reorg_does_not_repeat_action(self):
        a=self.worker();a.tick(0);original=self.rpc.call
        def call(method,params):
            r=original(method,params)
            if method=='eth_getBlockByNumber':r={**r,'hash':h(19)}
            return r
        self.rpc.call=call;self.assertEqual(a.tick(0)['status'],'REORG_REQUIRES_REVIEW')
    def test_route_injection_requires_fixture_mode(self):
        with self.assertRaises(ValueError):self.worker(routes={'NVDAx':route()})
    def test_policy_mutation_blocked_on_restart(self):
        self.worker()
        with self.assertRaises(ValueError):self.worker(policy={**DEFAULT_POLICY,'allocationBps':600})
    def test_live_scheduler_rejected(self):
        a=self.worker();a.s.execute=True
        with self.assertRaises(ValueError):XStocksLifecycle(a.s)
    def test_simulation_and_duplicate_without_signing(self):
        def quotes(symbol,snap,run):return {**market(),'blockHash':snap['blockHash'],'timestamp':snap['timestamp'],'referenceTimestamp':snap['timestamp']-1,'validUntil':snap['timestamp']+60,'amountInWei':50}
        a=self.worker(fixture_mode=True,markets=quotes,routes={'NVDAx':route()})
        self.rpc.timestamp=100
        self.assertEqual(a.tick(100)['status'],'SIMULATED');self.assertEqual(a.tick(100)['status'],'SIMULATED');self.assertEqual(self.cast.sent,[])
    def test_fixture_failed_simulation_retries_bounded(self):
        def quotes(symbol,snap,run):return {**market(),'blockHash':snap['blockHash'],'timestamp':0,'referenceTimestamp':-1,'validUntil':60,'amountInWei':50}
        # Invalid market input is rejected before RPC simulation or signing.
        a=self.worker(fixture_mode=True,markets=quotes,routes={'NVDAx':route()})
        self.assertEqual(a.tick(0)['status'],'NO_ELIGIBLE_ENTRY');self.assertEqual(self.cast.sent,[])
    def test_existing_exit_collect_close_lifecycle_simulations(self):
        def quotes(symbol,snap,run):return {**market(),'blockHash':snap['blockHash'],'timestamp':snap['timestamp'],'referenceTimestamp':snap['timestamp']-1,'validUntil':snap['timestamp']+60,'entryPriceWei':100,'priceWei':97}
        a=self.worker(fixture_mode=True,markets=quotes,routes={'NVDAx':route()});self.rpc.timestamp=100
        r=dict(state=1,principal=100,credited=0,openedAt=0,exit=0,attempts=0)
        self.rpc.runs[12]=r;self.rpc.active=100
        result=a.tick(100);self.assertEqual(result['status'],'SIMULATED');self.assertEqual(result['unsignedTransaction']['data'][2:10],'e5a473d5')
        r.update(state=3,exit=7);self.rpc.observations[12]=(2,100,0)
        result=a.tick(100);self.assertEqual(result['status'],'SIMULATED');self.assertEqual(result['unsignedTransaction']['data'][2:10],'77f1a2e3')
        r.update(credited=100,state=4,attempts=1);self.rpc.active=0;self.rpc.observations[12]=(2,0,0)
        result=a.tick(100);self.assertEqual(result['status'],'SIMULATED');self.assertEqual(result['unsignedTransaction']['data'][2:10],'aae128cd')
        self.assertEqual(self.cast.sent,[])
    def test_loss_settlement_not_invented_when_principal_missing(self):
        a=self.worker(fixture_mode=True,markets=lambda *args:None,routes={'NVDAx':route()});self.rpc.timestamp=100
        self.rpc.runs[12]=dict(state=3,principal=100,credited=97,openedAt=0,exit=7,attempts=1);self.rpc.active=3;self.rpc.observations[12]=(2,0,0)
        self.assertEqual(a.tick(100)['status'],'WAITING_PHYSICAL_SETTLEMENT');self.assertEqual(self.cast.sent,[])

class LaunchObserveTests(unittest.TestCase):
    def test_observe_only_launch_does_not_wait_for_capital(self):
        from test_launch_status import LaunchTests
        fixture=LaunchTests();fixture.setUp()
        try:
            fixture.rpc.capital=0;fixture.obs.observe_without_capital=True
            self.assertEqual(fixture.obs.verify(h(10),h(11))['immediateEvaluation'],'RECORDED_OBSERVE_ONLY')
            fixture.obs.verify(h(10),h(11));self.assertEqual(fixture.evaluations,1);self.assertEqual(fixture.cast.sent,[])
        finally:fixture.tearDown()
