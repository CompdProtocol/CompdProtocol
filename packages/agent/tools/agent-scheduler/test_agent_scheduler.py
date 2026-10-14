import copy
from contextlib import closing
import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from agent_scheduler import *

if os.environ.get('COMPD_TEST_TEMP'):
    tempfile.tempdir = os.environ['COMPD_TEST_TEMP']

def addr(n): return '0x' + f'{n:040x}'
def h(n): return '0x' + f'{n:064x}'
def configuration():
    return dict(chainId=56, agent=AGENT, kernel=addr(1), settlement=addr(2), executor=addr(3),
        kernelCodeHash=h(1), settlementCodeHash=h(2), executorCodeHash=h(3), anchorBlock=1, anchorHash=h(4),
        approvedAdapters=[addr(5)], maxGas=100000, maxGasPriceWei=10, dailyGasBudgetWei=2000000,
        maxPrincipalWei=100, dailyPrincipalBudgetWei=200, confirmations=3, maxAttempts=3, retrySeconds=30)
def plan(slot=0, method='startRun'):
    a = dict(method=method, runId=1, reference=h(7))
    if method == 'startRun': a.update(adapter=addr(5), amountWei='100')
    return dict(cycle=slot, approvalReference='LOCAL_TEST_ONLY', action=a)

class FakeCast:
    def __init__(self): self.sent=[]; self.fail=False
    def run(self, args): return 'selector:' + args[1]
    def code_hash(self, code): return h(int(code,16))
    def submit(self, tx, nonce, price, url):
        self.sent.append((tx,nonce,price))
        if self.fail: raise TimeoutError('unknown submission')
        return h(8)

class FakeRPC:
    url='http://offline.invalid'
    def __init__(self):
        self.calls=[]; self.chain=56; self.anchor=h(4); self.latest=10; self.receipt=None
        self.tx=None; self.reorg=False; self.simulation_fail=False; self.price=10; self.pending_nonce=0
        self.graph_bad=False; self.code_bad=False
    def call(self, method, params):
        self.calls.append((method,params))
        if method=='eth_chainId': return hex(self.chain)
        if method=='eth_blockNumber': return hex(self.latest)
        if method=='eth_getBlockByNumber':
            return {'hash': self.anchor if params[0]=='0x1' else h(99 if self.reorg else 9)}
        if method=='eth_getCode': return '0x99' if self.code_bad else hex(int(params[0],16))
        if method=='eth_call':
            tx=params[0]; data=tx['data']; to=tx['to']
            if data.startswith('selector:'):
                signature=data[len('selector:'):]
                if signature.startswith('moduleAddress'): return '0x'+addr(2)[2:].rjust(64,'0')
                if signature=='strategyExecutor()': return '0x'+addr(3)[2:].rjust(64,'0')
                if signature in ('executorHash()', 'strategyExecutorHash()'): return h(3)
                if signature=='kernel()': return '0x'+addr(99 if self.graph_bad else 1)[2:].rjust(64,'0')
                raise AssertionError(signature)
            if self.simulation_fail: raise RuntimeError('revert: risk/lifecycle')
            return '0x'
        if method=='eth_gasPrice': return hex(self.price)
        if method=='eth_getTransactionCount': return hex(self.pending_nonce) if params[1]=='pending' else '0x0'
        if method=='eth_getTransactionReceipt': return self.receipt
        if method=='eth_getTransactionByHash': return self.tx
        raise AssertionError(method)

class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.db=Path(self.tmp.name)/'state.sqlite'
        self.c=configuration(); self.rpc=FakeRPC(); self.cast=FakeCast(); self.workers=[]; self.now=0
    def tearDown(self):
        for s in self.workers: s.db.close()
        self.tmp.cleanup()
    def worker(self, execute=False):
        s=Scheduler(self.db,self.c,self.rpc,self.cast,execute,'FUTURE_TEST_ONLY' if execute else None,clock=lambda:self.now)
        self.workers.append(s); return s
    def mined(self,status=1):
        tx,_=action_transaction(self.c,plan(),0)
        self.rpc.receipt=dict(transactionHash=h(8),blockNumber='0x8',blockHash=h(9),status=hex(status),gasUsed=hex(90000),effectiveGasPrice='0xa')
        self.rpc.tx=dict(hash=h(8),to=tx['to'],input=tx['data'],value='0x0',nonce='0x0',**{'from':AGENT})
    def test_idle_requires_approved_plan(self):
        self.assertEqual(self.worker().tick(0)['status'],'IDLE_NO_APPROVED_PLAN'); self.assertFalse(self.rpc.calls)
    def test_dry_run_default_never_submits(self):
        r=self.worker().tick(0,plan()); self.assertEqual(r['status'],'SIMULATED'); self.assertFalse(self.cast.sent)
        self.assertEqual(r['unsignedTransaction']['from'],AGENT); self.assertEqual(r['unsignedTransaction']['value'],'0x0')
    def test_restart_duplicate_cycle_prevention(self):
        self.worker().tick(0,plan()); self.assertEqual(self.worker().tick(0,plan())['status'],'SIMULATED')
    def test_plan_mutation_rejected(self):
        s=self.worker(); s.tick(0,plan()); changed=plan(); changed['action']['amountWei']='99'
        with self.assertRaises(ValueError): s.tick(0,changed)
    def test_exact_eight_hour_utc_slots_no_missed_replay(self):
        s=self.worker(); s.tick(CYCLE-1,plan())
        with self.assertRaises(ValueError): s.tick(CYCLE,plan())
        self.assertEqual(s.tick(CYCLE*5,plan(5))['status'],'SIMULATED')
        self.assertEqual(s.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],2)
    def test_wrong_chain_anchor_code_and_graph_stop(self):
        for field,value in [('chain',97),('anchor',h(55)),('code_bad',True),('graph_bad',True)]:
            with self.subTest(field=field):
                rpc=FakeRPC(); setattr(rpc,field,value)
                with tempfile.TemporaryDirectory() as td:
                    s=Scheduler(Path(td)/'db',self.c,rpc,self.cast,True,'TEST',clock=lambda:0)
                    try: self.assertEqual(s.tick(0,plan())['status'],'RETRY'); self.assertFalse(self.cast.sent)
                    finally:s.db.close()
    def test_adapter_and_principal_caps(self):
        for field,value in [('adapter',addr(99)),('amountWei','101'),('amountWei','0')]:
            p=plan(); p['action'][field]=value
            with self.assertRaises(ValueError): self.worker().tick(0,p)
    def test_only_canonical_lifecycle_no_guardian_or_raw_calls(self):
        for method in ('requestExit','collectRun','closeRun'):
            tx,principal=action_transaction(self.c,plan(method=method),0)
            self.assertEqual(len(tx['data']),138); self.assertEqual(principal,0)
        for method in ('recordBlocked','proposeStrategy','writeOff','bootstrapTreasury','withdraw'):
            with self.assertRaises(ValueError): action_transaction(self.c,plan(method=method),0)
        p=plan(); p['action']['to']=addr(99)
        with self.assertRaises(ValueError): action_transaction(self.c,p,0)
    def test_bounded_retries_backoff_and_restart(self):
        self.rpc.simulation_fail=True; s=self.worker(True)
        self.assertEqual(s.tick(0,plan())['status'],'RETRY')
        self.assertEqual(s.tick(1,plan())['status'],'BACKOFF')
        self.assertEqual(self.worker(True).tick(30,plan())['status'],'RETRY')
        self.assertEqual(s.tick(90,plan())['status'],'EXHAUSTED')
        self.assertEqual(s.tick(200,plan())['status'],'EXHAUSTED'); self.assertFalse(self.cast.sent)
    def test_gas_price_cap_prevents_submission(self):
        self.rpc.price=11; self.assertEqual(self.worker(True).tick(0,plan())['status'],'RETRY'); self.assertFalse(self.cast.sent)
    def test_individual_daily_budget_caps_prevent_submission(self):
        for field,value in [('dailyGasBudgetWei',999999),('dailyPrincipalBudgetWei',99)]:
            with self.subTest(field=field),tempfile.TemporaryDirectory() as td:
                c=configuration();c[field]=value
                s=Scheduler(Path(td)/'db',c,self.rpc,self.cast,True,'TEST',clock=lambda:0)
                try:self.assertEqual(s.tick(0,plan())['status'],'RETRY');self.assertFalse(self.cast.sent)
                finally:s.db.close()
    def test_daily_fee_and_principal_reservations(self):
        s=self.worker(True); s.tick(0,plan()); self.mined(); self.assertEqual(s.tick(0)['status'],'CONFIRMED')
        self.now=CYCLE; self.rpc.receipt=None
        self.assertEqual(s.tick(CYCLE,plan(1))['status'],'PENDING'); self.assertEqual(len(self.cast.sent),2)
        self.mined(); s.tick(CYCLE)
        self.now=CYCLE*2
        self.assertEqual(s.tick(self.now,plan(2))['status'],'RETRY'); self.assertEqual(len(self.cast.sent),2)
    def test_unknown_submission_is_never_retried_on_restart(self):
        self.cast.fail=True; self.assertEqual(self.worker(True).tick(0,plan())['status'],'SUBMISSION_UNKNOWN')
        self.assertEqual(self.worker(True).tick(CYCLE,plan(1))['status'],'SUBMISSION_UNKNOWN'); self.assertEqual(len(self.cast.sent),1)
    def test_pre_submit_state_and_budgets_are_durable(self):
        class CrashCast(FakeCast):
            def submit(inner,tx,nonce,price,url):
                with closing(sqlite3.connect(self.db)) as db:
                    row=db.execute('SELECT state,nonce,reserved_gas,principal FROM jobs').fetchone()
                    self.assertEqual(row,('SUBMITTING',0,'1000000','100'))
                raise KeyboardInterrupt()
        self.cast=CrashCast()
        with self.assertRaises(KeyboardInterrupt): self.worker(True).tick(0,plan())
        self.assertEqual(self.worker(True).tick(0)['status'],'SUBMISSION_UNKNOWN')
    def test_pending_transaction_blocks_new_cycles(self):
        s=self.worker(True); s.tick(0,plan())
        self.assertEqual(self.worker(True).tick(CYCLE,plan(1))['status'],'PENDING'); self.assertEqual(len(self.cast.sent),1)
    def test_confirmations_and_restart_receipt_reconciliation(self):
        s=self.worker(True); s.tick(0,plan()); self.mined(); self.rpc.latest=9
        self.assertEqual(self.worker(True).tick(0)['status'],'PENDING')
        self.rpc.latest=10; self.assertEqual(s.tick(0)['status'],'CONFIRMED')
        self.assertEqual(s.db.execute('SELECT COUNT(*) FROM receipts').fetchone()[0],1)
    def test_reorg_does_not_confirm_or_resubmit(self):
        s=self.worker(True); s.tick(0,plan()); self.mined(); self.rpc.reorg=True
        self.assertEqual(s.tick(0)['status'],'REORG_PENDING'); self.assertEqual(len(self.cast.sent),1)
        self.rpc.reorg=False; self.assertEqual(s.tick(0)['status'],'CONFIRMED')
    def test_reverted_receipt_stops_future_cycles(self):
        s=self.worker(True); s.tick(0,plan()); self.mined(0)
        self.assertEqual(s.tick(0)['status'],'REVERTED')
        self.assertEqual(s.tick(CYCLE,plan(1))['status'],'REVERTED_STOP'); self.assertEqual(len(self.cast.sent),1)
    def test_receipt_wrong_sender_not_accepted(self):
        s=self.worker(True); s.tick(0,plan()); self.mined(); self.rpc.tx['from']=addr(99)
        with self.assertRaises(ValueError): s.tick(0)
    def test_pending_nonce_requires_manual_reconciliation(self):
        self.rpc.pending_nonce=1
        self.assertEqual(self.worker(True).tick(0,plan())['status'],'RETRY'); self.assertFalse(self.cast.sent)
    def test_cycle_expiring_during_preflight_does_not_submit(self):
        self.now=CYCLE
        self.assertEqual(self.worker(True).tick(0,plan())['status'],'EXPIRED'); self.assertFalse(self.cast.sent)
    def test_concurrent_database_lock_blocks_second_worker(self):
        a=self.worker(); b=self.worker(); a.db.execute('BEGIN IMMEDIATE')
        try:
            with self.assertRaises(sqlite3.OperationalError): b.tick(0,plan())
        finally:a.db.rollback()
    def test_state_config_change_rejected(self):
        self.worker(); self.c['maxGas']=99999
        with self.assertRaises(ValueError):self.worker()
    def test_frozen_wallet_and_execution_approval(self):
        c=configuration(); c['agent']=addr(99)
        with self.assertRaises(ValueError):config_check(c)
        with self.assertRaises(ValueError):Scheduler(self.db,self.c,self.rpc,self.cast,True)
    def test_readonly_rpc_disallows_broadcast(self):
        with self.assertRaises(ValueError):RPC('http://offline.invalid').call('eth_sendRawTransaction',[])
    def test_actual_cast_abi_matches_all_four_calls(self):
        binary=os.environ['COMPD_CAST_BIN']
        for method in SELECTORS:
            p=plan(method=method); tx,_=action_transaction(self.c,p,0)
            sig='startRun(uint256,address,uint256,bytes32)' if method=='startRun' else method+'(uint256,bytes32)'
            values=['1',addr(5),'100',h(7)] if method=='startRun' else ['1',h(7)]
            r=subprocess.run([binary,'calldata',sig]+values,capture_output=True,text=True,check=True)
            self.assertEqual(tx['data'],r.stdout.strip())
    def test_large_runtime_hash_stdin_works_on_windows(self):
        # 44,468 hex characters: larger than Windows command-line maximum, similar to Kernel runtime.
        cast=Cast(os.environ['COMPD_CAST_BIN'])
        self.assertEqual(len(cast.code_hash('0x'+'00'*22234)),66)
        self.assertEqual(cast.code_hash('0xdeadbeef'),cast.run(['keccak','0xdeadbeef']))
    def test_cast_submission_uses_frozen_wallet_nonce_and_secret_files(self):
        with tempfile.TemporaryDirectory() as td:
            store=Path(td)/'key'; pw=Path(td)/'password'; store.write_text('TEST');pw.write_text('TEST')
            calls=[]
            def runner(cmd,**kwargs):
                calls.append((cmd,kwargs)); return subprocess.CompletedProcess(cmd,0,AGENT if cmd[1]=='wallet' else h(8),'')
            with patch.dict(os.environ,{'COMPD_AGENT_KEYSTORE':str(store),'COMPD_AGENT_PASSWORD_FILE':str(pw)}):
                tx,_=action_transaction(self.c,plan(),0)
                self.assertEqual(Cast('cast',runner).submit(tx,7,10,'http://offline.invalid'),h(8))
            cmd,opts=calls[-1]; self.assertIn('--nonce',cmd);self.assertIn('7',cmd);self.assertNotIn('--private-key',cmd)
            self.assertNotIn('http://offline.invalid',cmd);self.assertEqual(opts['env']['ETH_RPC_URL'],'http://offline.invalid')
    def test_cast_wrong_keystore_never_sends(self):
        with tempfile.TemporaryDirectory() as td:
            store=Path(td)/'key';pw=Path(td)/'password';store.touch();pw.touch();calls=[]
            def runner(cmd,**kwargs): calls.append(cmd);return subprocess.CompletedProcess(cmd,0,addr(99),'')
            with patch.dict(os.environ,{'COMPD_AGENT_KEYSTORE':str(store),'COMPD_AGENT_PASSWORD_FILE':str(pw)}):
                with self.assertRaises(RuntimeError):Cast('cast',runner).submit({},0,1,'http://offline.invalid')
            self.assertEqual(len(calls),1)

if __name__=='__main__':unittest.main(verbosity=2)
