import copy
import tempfile
import unittest
from agent_scheduler import *
from agent_lifecycle import *
from test_agent_scheduler import FakeRPC, FakeCast, configuration, plan, addr, h

def standing():
    return dict(approvalReference='LOCAL_STANDING_POLICY_TEST',adapter=addr(5),adapterCodeHash=h(5),
        entryRule='ADMITTED_ADAPTER_EACH_8H_SLOT',allocationBps=1000,holdSeconds=CYCLE,
        settlementRule='FULL_PRINCIPAL_NO_PENDING_CLAIM')

class LifecycleRPC(FakeRPC):
    def __init__(self):
        super().__init__();self.timestamp=0;self.capital=1000;self.active=0;self.accounted=1000
        self.life=0;self.risk=0;self.halted=0;self.approved=1;self.runs={};self.observations={}
    def call(self,method,params):
        if method=='eth_getBlockByNumber':
            b=super().call(method,params);b['timestamp']=hex(self.timestamp);return b
        if method=='eth_call' and params[0]['data'].startswith('selector:'):
            data=params[0]['data'][9:];end=data.index(')')+1;sig=data[:end];args=data[end:]
            rid=int(args,16) if args else 0
            vals={'lifecycle()':self.life,'strategyCapital()':self.capital,'activePrincipal()':self.active,
                'accountedQuote()':self.accounted,'activeRunCount()':len([r for r in self.runs.values() if r['state']!=6]),
                'strategyAllocationHalted()':self.halted,'riskLatched()':self.risk,'historyLength()':len(self.runs),
                'isApprovedStrategy(address)':self.approved}
            if sig in vals:return '0x'+f'{vals[sig]:064x}'
            if sig=='historyAt(uint256)':return '0x'+f'{list(self.runs)[rid]:064x}'
            if sig=='run(uint256)':
                r=self.runs.get(rid,dict(state=0,principal=0,credited=0,openedAt=0,exit=0,attempts=0))
                words=[5,r['principal'],r['credited'],r['credited'],r['openedAt'],0,7,r['exit'],0,0,r['state'],0,0,0,r['attempts']]
                return '0x'+''.join(f'{w:064x}' for w in words)
            if sig=='observe(uint256)':return '0x'+''.join(f'{w:064x}' for w in self.observations.get(rid,(2,0,0)))
        return super().call(method,params)

class LifecycleCast(FakeCast):
    def __init__(self,rpc):super().__init__();self.rpc=rpc;self.counter=0
    def submit(self,tx,nonce,price,url):
        self.counter+=1;self.sent.append((tx,nonce,price));txhash=h(100+self.counter)
        selector=tx['data'][2:10];words=[int(tx['data'][10+i:10+i+64],16) for i in range(0,len(tx['data'])-10,64)]
        rid=words[0];r=self.rpc.runs.get(rid)
        if selector==SELECTORS['startRun']:
            r=dict(state=1,principal=words[2],credited=0,openedAt=self.rpc.timestamp,exit=0,attempts=0)
            self.rpc.runs[rid]=r;self.rpc.active+=words[2];self.rpc.accounted-=words[2]
        elif selector==SELECTORS['requestExit']:
            r['state']=3;r['exit']=words[1];self.rpc.observations[rid]=(2,r['principal']-r['credited'],0)
        elif selector==SELECTORS['collectRun']:
            amount=r['principal']-r['credited'];r['credited']+=amount;r['state']=4;r['attempts']+=1
            self.rpc.active-=amount;self.rpc.accounted+=amount;self.rpc.observations[rid]=(2,0,0)
        elif selector==SELECTORS['closeRun']:r['state']=6
        self.rpc.receipt=dict(transactionHash=txhash,blockNumber='0x8',blockHash=h(9),status='0x1',gasUsed=hex(90000))
        self.rpc.tx=dict(hash=txhash,to=tx['to'],input=tx['data'],value='0x0',nonce=hex(nonce),**{'from':AGENT})
        return txhash

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.c=configuration();self.c['dailyGasBudgetWei']=10000000
        self.rpc=LifecycleRPC();self.cast=LifecycleCast(self.rpc);self.now=0;self.workers=[]
    def tearDown(self):
        for s in self.workers:s.db.close()
        self.tmp.cleanup()
    def worker(self,policy=True,execute=False):
        s=Scheduler(Path(self.tmp.name)/'state',self.c,self.rpc,self.cast,execute,'TEST' if execute else None,clock=lambda:self.now)
        self.workers.append(s);return AutoLifecycle(s,standing() if policy else None)
    def run_record(self,rid=12,state=3,credited=0,exit=7):
        self.rpc.runs[rid]=dict(state=state,principal=100,credited=credited,openedAt=0,exit=exit,attempts=0)
        self.rpc.active=100-credited
    def test_successful_automatic_cycle_and_settlement(self):
        auto=self.worker(execute=True)
        self.assertEqual(auto.tick(0)['status'],'PENDING');self.assertEqual(auto.tick(0)['status'],'CONFIRMED')
        self.now=CYCLE;self.rpc.timestamp=CYCLE
        for method in ('requestExit','collectRun','closeRun'):
            self.assertEqual(auto.tick(self.now)['status'],'PENDING')
            self.assertEqual(self.cast.sent[-1][0]['data'][2:10],SELECTORS[method])
            self.assertEqual(auto.tick(self.now)['status'],'CONFIRMED')
        self.assertEqual(self.rpc.runs[next(iter(self.rpc.runs))]['state'],6)
        auto.tick(self.now)
        self.assertTrue(auto.s.db.execute("SELECT 1 FROM auto_records WHERE stage='SETTLED'").fetchone())
    def test_no_default_trading_policy(self):
        self.assertEqual(self.worker(False).tick(0)['status'],'ENTRY_POLICY_UNDEFINED');self.assertFalse(self.cast.sent)
    def test_no_manual_cycle_plan_needed_for_dry_run(self):
        r=self.worker().tick(0);self.assertEqual(r['status'],'SIMULATED');self.assertFalse(self.cast.sent)
    def test_insufficient_capital_no_allocation(self):
        self.rpc.capital=0;self.rpc.accounted=0
        self.assertEqual(self.worker().tick(0)['status'],'INSUFFICIENT_CAPITAL_OR_RUN_CAP')
    def test_capital_ten_percent_and_total_thirty_percent(self):
        self.rpc.capital=1000;self.rpc.active=290
        r=self.worker().tick(0);words=r['unsignedTransaction']['data'][10:]
        self.assertEqual(int(words[128:192],16),10)
    def test_risk_pause_shutdown_and_emergency(self):
        auto=self.worker()
        for life,expected in ((1,'PAUSED_NO_NEW_ENTRY'),(2,'PAUSED_NO_NEW_ENTRY'),(3,'EMERGENCY_OR_TERMINATED_STOP'),(4,'EMERGENCY_OR_TERMINATED_STOP')):
            self.rpc.life=life;self.assertEqual(auto.tick(0)['status'],expected)
        self.rpc.life=0;self.rpc.risk=1;self.assertEqual(auto.tick(0)['status'],'RISK_BREAKER')
    def test_permissionless_principal_recovery_without_trading_policy(self):
        self.run_record();self.rpc.observations[12]=(2,100,0)
        result=self.worker(False).tick(0);self.assertEqual(result['status'],'SIMULATED')
        self.assertEqual(result['unsignedTransaction']['data'][2:10],SELECTORS['collectRun'])
    def test_exit_holding_period_not_invented(self):
        self.run_record(state=1,exit=0)
        self.assertEqual(self.worker(False).tick(0)['status'],'EXIT_POLICY_UNDEFINED')
    def test_loss_finality_not_invented(self):
        self.run_record(credited=50);self.rpc.observations[12]=(3,0,0)
        result=self.worker().tick(0)
        self.assertNotEqual(result.get('unsignedTransaction',{}).get('data','')[2:10],SELECTORS['closeRun'])
    def test_pending_claim_prevents_close(self):
        self.run_record(credited=100);self.rpc.observations[12]=(2,0,77)
        self.assertEqual(self.worker().tick(0)['status'],'PENDING_CLAIM_NOT_FINAL')
    def test_close_retry_rechecks_pending_claim(self):
        self.run_record(credited=100);self.rpc.observations[12]=(2,0,0)
        auto=self.worker();self.rpc.simulation_fail=True
        self.assertEqual(auto.tick(0)['status'],'RETRY')
        self.rpc.simulation_fail=False;self.rpc.observations[12]=(2,0,77)
        result=auto.tick(30);self.assertEqual(result['status'],'QUEUED_ACTION_NO_LONGER_ELIGIBLE')
        self.assertFalse(self.cast.sent)
    def test_recovery_continues_when_paused_but_not_emergency(self):
        self.run_record();self.rpc.observations[12]=(2,100,0);self.rpc.life=1
        auto=self.worker(False);self.assertEqual(auto.tick(0)['status'],'SIMULATED')
        self.rpc.life=4;self.assertEqual(auto.tick(0)['status'],'EMERGENCY_OR_TERMINATED_STOP')
    def test_blocked_existing_run_prevents_fresh_entry(self):
        self.run_record(state=5)
        self.assertEqual(self.worker().tick(0)['status'],'BLOCKED_RUN_REQUIRES_REVIEW')
    def test_undefined_settlement_policy_prevents_close(self):
        self.run_record(credited=100);self.rpc.observations[12]=(2,0,0)
        self.assertEqual(self.worker(False).tick(0)['status'],'SETTLEMENT_POLICY_UNDEFINED')
    def test_failed_transaction_stops_automatic_lifecycle(self):
        auto=self.worker(execute=True);auto.tick(0);self.rpc.receipt['status']='0x0'
        self.assertEqual(auto.tick(0)['status'],'REVERTED')
        self.assertEqual(auto.tick(0)['status'],'REVERTED_STOP');self.assertEqual(len(self.cast.sent),1)
    def test_restart_recovers_pending_then_exit(self):
        auto=self.worker(execute=True);auto.tick(0)
        restarted=self.worker(execute=True);self.assertEqual(restarted.tick(0)['status'],'CONFIRMED')
        self.now=CYCLE;self.rpc.timestamp=CYCLE
        self.assertEqual(restarted.tick(self.now)['status'],'PENDING')
        self.assertEqual(self.cast.sent[-1][0]['data'][2:10],SELECTORS['requestExit'])
    def test_automatic_retry_keeps_original_plan_after_capital_change(self):
        auto=self.worker();self.rpc.simulation_fail=True;self.assertEqual(auto.tick(0)['status'],'RETRY')
        self.rpc.capital=500;self.rpc.simulation_fail=False
        r=self.worker().tick(30);self.assertEqual(r['status'],'SIMULATED')
        self.assertEqual(int(r['unsignedTransaction']['data'][138:202],16),100)
    def test_disabled_or_changed_adapter_never_started(self):
        self.rpc.approved=0;self.assertEqual(self.worker().tick(0)['status'],'ADAPTER_NOT_ADMITTED')
    def test_clock_lag_is_not_a_new_cycle(self):
        self.rpc.timestamp=CYCLE;self.assertEqual(self.worker().tick(0)['status'],'CLOCK_OR_RPC_LAG')
    def test_policy_change_requires_reconciliation(self):
        auto=self.worker();changed=standing();changed['holdSeconds']=1
        with self.assertRaises(ValueError):AutoLifecycle(auto.s,changed)
    def test_history_sync_is_bounded_and_blocks_entry_until_complete(self):
        for rid in range(1000,1070):
            self.rpc.runs[rid]=dict(state=6,principal=100,credited=100,openedAt=0,exit=7,attempts=1)
        auto=self.worker();self.assertEqual(auto.tick(0)['status'],'HISTORY_SYNC_PENDING')
        self.assertEqual(auto.s.db.execute("SELECT value FROM metadata WHERE key='history_cursor'").fetchone()[0],'64')
        self.assertEqual(auto.tick(0)['status'],'SIMULATED')
    def test_unapproved_entry_rule_or_destination_rejected(self):
        for field,value in [('entryRule','buy_anything'),('adapter',addr(99)),('allocationBps',1001),('holdSeconds',0),('settlementRule','write_off_loss')]:
            p=standing();p[field]=value
            with self.assertRaises(ValueError):policy_check(p,self.c)
    def test_dry_run_cannot_advance_a_simulated_position(self):
        auto=self.worker();auto.tick(0);auto.tick(0)
        self.assertFalse(self.rpc.runs);self.assertFalse(self.cast.sent)
        self.assertEqual(auto.s.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)

if __name__=='__main__':unittest.main(verbosity=2)
