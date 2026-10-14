import copy,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from agent_scheduler import Scheduler
from launch_status import *
from test_agent_scheduler import configuration,FakeCast,addr,h
from test_agent_lifecycle import LifecycleRPC

def word_addr(a):return '0x'+a[2:].rjust(64,'0')
class LaunchFixtureRPC(LifecycleRPC):
    def __init__(self):
        super().__init__();self.timestamp=1000;self.receipts={};self.trace=None;self.profit=0;self.loss=0;self.reward=0
    def call(self,method,params):
        if method=='eth_getTransactionReceipt':return self.receipts.get(params[0])
        if method=='debug_traceTransaction':
            if self.trace is None:raise RuntimeError('missing trace')
            return self.trace
        if method=='eth_call' and params[0]['data'].startswith('selector:'):
            sig=params[0]['data'][9:]
            bindings={'taxProcessor()':addr(9),'taxToken()':TOKEN,'marketAddress()':addr(6),
                'receiver()':addr(6),'nativeFeeReceiver()':addr(6),'buybackExecutor()':addr(8)}
            if sig in bindings:return word_addr(bindings[sig])
            vals={'bound()':1,'cumulativeRealizedProfit()':self.profit,'cumulativeRealizedLoss()':self.loss,'holderRewardReserve()':self.reward}
            if sig in vals:return h(vals[sig])
        return super().call(method,params)
class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.c=configuration();self.rpc=LaunchFixtureRPC();self.cast=FakeCast();self.workers=[];self.evaluations=0
        self.identities=dict(factory=addr(7),receiver=addr(6),token=TOKEN,vaultPortal=VAULT_PORTAL,portal=PORTAL,buybackExecutor=addr(8))
        for name,value in list(self.identities.items()):self.identities[name+'CodeHash']=h(int(value,16))
        self.obs=self.observer()
        launch_event=dict(address=VAULT_PORTAL,topics=[self.obs.topics['launch'],word_addr(TOKEN),word_addr(addr(6)),word_addr(addr(7))],data='0x')
        created=dict(address=PORTAL,topics=[self.obs.topics['created']],data='0x'+''.join(f'{x:064x}' for x in [1000,123,1,int(TOKEN,16),224,256,288]))
        fee=dict(address=addr(1),topics=[self.obs.topics['fees'],word_addr(addr(6))],data='0x'+''.join(f'{x:064x}' for x in [1000,350,150,500]))
        for tx,number,logs in [(h(10),'0x8',[launch_event,created]),(h(11),'0x9',[fee])]:
            self.rpc.receipts[tx]=dict(transactionHash=tx,blockNumber=number,blockHash=h(9),status='0x1',logs=logs)
        self.rpc.latest=12
        self.rpc.trace=dict(type='CALL',calls=[dict(type='CALL',**{'from':addr(9),'to':addr(6),'value':hex(1000)}),dict(type='CALL',**{'from':addr(6),'to':addr(1),'value':hex(1000)})])
    def tearDown(self):
        for s in self.workers:s.db.close()
        self.tmp.cleanup()
    def observer(self):
        s=Scheduler(Path(self.tmp.name)/'state',self.c,self.rpc,self.cast);self.workers.append(s)
        def evaluate():self.evaluations+=1;return {'status':'ENTRY_POLICY_UNDEFINED','submitted':False}
        return LaunchStatus(s,self.identities,evaluate)
    def test_verified_once_only_restart_and_no_extra_allocation(self):
        r=self.obs.verify(h(10),h(11));self.assertEqual(r['feeAllocationsWei'],dict(strategy='350',buyback='150',protocol='500'))
        self.obs.verify(h(10),h(11));self.observer().verify(h(10),h(11));self.assertEqual(self.evaluations,1)
        self.assertFalse(self.cast.sent);self.assertEqual(self.rpc.capital,1000)
    def test_immediate_evaluation_waits_for_capital_once(self):
        self.rpc.capital=0;r=self.obs.verify(h(10),h(11));self.assertEqual(r['immediateEvaluation'],'WAITING_CAPITAL')
        self.assertEqual(self.evaluations,0);self.rpc.capital=350;self.obs.verify(h(10),h(11));self.obs.verify(h(10),h(11))
        self.assertEqual(self.evaluations,1)
    def test_different_launch_tx_is_not_rebound(self):
        self.obs.verify(h(10),h(11))
        with self.assertRaises(ValueError):self.obs.verify(h(99),h(11))
    def test_first_15_minute_checkpoint_no_profit_never_pays(self):
        self.obs.verify(h(10),h(11));early=self.obs.status(1001);self.assertEqual(early['firstDistributionCountdownSeconds'],899)
        due=self.obs.status(1900);self.assertEqual(due['firstDistributionOutcome'],'NO_REALIZED_PROFIT');self.assertFalse(self.cast.sent)
    def test_positive_accrual_still_does_not_bypass_twab(self):
        self.obs.verify(h(10),h(11));self.rpc.profit=100;self.rpc.reward=10
        r=self.obs.status(1900);self.assertEqual(r['firstDistributionOutcome'],'PAYOUT_STATUS_NOT_VERIFIED')
        self.assertIsNone(r['firstCheckpoint']['paidWei'])
        self.assertEqual(r['accruedHolderReserveWei'],'10');self.assertEqual(self.rpc.reward,10)
    def test_checkpoint_outcome_persists_once_across_restart(self):
        self.obs.verify(h(10),h(11));r=self.obs.status(1900);self.assertEqual(r['firstDistributionOutcome'],'NO_REALIZED_PROFIT')
        self.rpc.profit=100;self.rpc.reward=10
        restarted=self.observer();later=restarted.status(5000)
        self.assertEqual(later['firstDistributionOutcome'],'NO_REALIZED_PROFIT');self.assertEqual(later['firstCheckpoint']['observedAt'],1900)
        self.assertEqual(later['firstCheckpoint']['paidWei'],'0')
    def test_regular_eight_hour_windows_are_preserved(self):
        self.obs.verify(h(10),h(11));self.assertEqual(self.obs.status(1900)['regularAgentAndHolderWindowSeconds'],28800)
    def test_trace_unavailable_is_not_verified(self):
        self.rpc.trace=None
        with self.assertRaises(RuntimeError):self.obs.verify(h(10),h(11))
        self.assertEqual(self.obs.load()['status'],'NOT_VERIFIED');self.assertEqual(self.evaluations,0)
    def test_pending_funds_or_donations_not_falsely_attributed(self):
        self.rpc.trace['calls'][0]['value']=hex(500)
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_failed_trace_subcall_not_counted(self):
        self.rpc.trace['calls'][0]['error']='reverted'
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_wrong_chain_and_missing_receipt_rejected(self):
        self.rpc.chain=97
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
        self.rpc.chain=56;self.rpc.receipts[h(10)]['status']='0x0'
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_wrong_reserved_token_or_factory_event_rejected(self):
        self.rpc.receipts[h(10)]['logs'][0]['topics'][1]=word_addr(addr(123))
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_unconfirmed_launch_rejected(self):
        self.rpc.latest=8
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_wrong_fee_allocation_rejected(self):
        self.rpc.receipts[h(11)]['logs'][0]['data']='0x'+''.join(f'{x:064x}' for x in [1000,100,150,750])
        with self.assertRaises(ValueError):self.obs.verify(h(10),h(11))
    def test_reorg_suspends_previously_verified_status(self):
        self.obs.verify(h(10),h(11));self.rpc.reorg=True
        with self.assertRaises(ValueError):self.obs.status(1000)
    def test_callback_crash_never_repeats_evaluation(self):
        def crash():self.evaluations+=1;raise RuntimeError('crash')
        self.obs.evaluate=crash
        with self.assertRaises(RuntimeError):self.obs.verify(h(10),h(11))
        self.observer().verify(h(10),h(11));self.assertEqual(self.evaluations,1)
        self.assertEqual(self.obs.load()['immediateEvaluation'],'RUNNING_OBSERVE_ONLY')
    def test_readonly_adapter_rejects_send_method(self):
        with self.assertRaises(ValueError):LaunchRPC('http://offline.invalid').call('eth_sendRawTransaction',[])
    def test_dashboard_unrealized_is_unknown_not_distributable(self):
        self.obs.verify(h(10),h(11));r=self.obs.status(1000)
        self.assertIsNone(r['unrealizedPnL']);self.assertEqual(r['agent'],'OBSERVE_ONLY');self.assertFalse(r['productionActivated'])
    def test_confirmed_burn_record_idempotent(self):
        event=dict(address=addr(8),topics=[self.obs.topics['burn'],h(1),h(2)],data='0x'+f'{100:064x}{1000:064x}')
        self.rpc.receipts[h(12)]=dict(transactionHash=h(12),blockNumber='0x9',blockHash=h(9),status='0x1',logs=[event])
        self.obs.record_burn(h(12));self.obs.record_burn(h(12))
        self.assertEqual(len(self.obs.status(1000)['buybackBurnReceipts']),1)
    def test_identity_replacement_requires_reconciliation(self):
        bad=dict(self.identities,factory=addr(77),factoryCodeHash=h(77))
        with self.assertRaises(ValueError):LaunchStatus(self.workers[0],bad,lambda:None)
    def test_actual_agent_cli_keeps_production_trading_disabled(self):
        folder=Path(__file__).parent
        r=subprocess.run([sys.executable,str(folder/'agent_scheduler.py'),'--config',str(folder/'config.blocked.json'),'--execute','--once'],capture_output=True,text=True)
        self.assertEqual(r.returncode,2);self.assertIn('Production trading remains disabled',r.stderr)
        self.assertFalse(self.cast.sent)

if __name__=='__main__':unittest.main(verbosity=2)
