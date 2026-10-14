import unittest,tempfile,os,copy,json,hashlib,sqlite3
from pathlib import Path
from holder_executor import Executor,ABI,LocalRPC,checked,digest,FINALIZER
from holder_executor_fixtures import config,Transport,CastFixture,Encoder,View,A,H
class ExecutorTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('COMPD_TEST_TEMP'));self.path=Path(self.tmp.name)/'jobs.sqlite';self.c=config();self.r=Transport();self.v=View(self.r);self.now=10000;self.e=self.open()
 def tearDown(self):self.e.db.close();self.tmp.cleanup()
 def open(self,mode='offline'):
  e=Executor(self.path,self.c,self.r,CastFixture(),Encoder(),mode=mode,submitter=self.r if mode=='offline' else None,clock=lambda:self.now);e.view=lambda block:self.v;return e
 def action(self,m='finalizeZeroWindow',**kw):
  a=dict(to=A(3),method=m,args=[0],value='0',mode='DRY_RUN');a.update(kw);return a
 def retry(self):return self.action('retry',to=A(5),args=[H(77)])
 def queued(self,a=None):return self.e.enqueue(a or self.action())
 def state(self,j):return self.e.db.execute('SELECT * FROM holder_exec_jobs WHERE id=?',(j,)).fetchone()
 def confirm(self):self.r.advance();return self.e.tick()
 def test_zero_permissionless_sender_rejected(self):
  c=copy.deepcopy(self.c);c['permissionlessSender']=A(0);self.assertRaises(ValueError,checked,c)
 def test_zero_contract_rejected(self):
  c=copy.deepcopy(self.c);c['contracts']['holder']['address']=A(0);self.assertRaises(ValueError,checked,c)
 def test_two_connections_share_duplicate_and_reservation(self):
  other=self.open()
  try:
   j=self.queued();self.assertEqual(other.enqueue(self.action()),j);self.e.tick();self.assertEqual(other.tick()['status'],'PENDING');self.assertEqual(len(self.r.sent),1)
  finally:other.db.close()
 def test_terminal_retry_shutdown_predeadline(self):
  self.v.life=2;self.v.terminal=True;self.v.status=2;self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'PENDING')
 def scan_fixture(self,tip=2000):
  from types import SimpleNamespace
  db=sqlite3.connect(':memory:');db.executescript('CREATE TABLE blocks(n,t);INSERT INTO blocks VALUES(100,'+str(tip)+');CREATE TABLE holder_scan_cursor(id,next_start);INSERT INTO holder_scan_cursor VALUES(1,1000);')
  index=SimpleNamespace(db=db,launch=1000,kernel=A(1));calls=[]
  keeper=SimpleNamespace(plan=lambda view,start,end:(calls.append((start,end)) or {'actions':[self.action()]}))
  return index,keeper,calls
 def test_window_revisited_for_review_and_payment(self):
  i,k,calls=self.scan_fixture()
  try:
   self.e.plan_indexed(i,k);self.e.plan_indexed(i,k);self.assertEqual(calls,[(1000,1900),(1000,1900)]);self.assertEqual(self.e.db.execute('SELECT COUNT(*) FROM holder_exec_jobs').fetchone()[0],1)
  finally:i.db.close()
 def test_future_window_not_planned(self):
  i,k,calls=self.scan_fixture(1899)
  try:self.assertEqual(self.e.plan_indexed(i,k),[]);self.assertFalse(calls)
  finally:i.db.close()
 def test_shutdown_does_not_generate_candidates(self):
  i,k,calls=self.scan_fixture();self.v.life=2
  try:self.assertEqual(self.e.plan_indexed(i,k),[]);self.assertFalse(calls)
  finally:i.db.close()
 def test_allowlist_rejects_recovery_and_arbitrary_router(self):
  for m in ('recoverAllTerminatedFunds','transfer','execute','terminalize'):self.assertRaises(ValueError,self.e.enqueue,self.action(m))
 def test_nonzero_value_rejected(self):self.assertRaises(ValueError,self.e.enqueue,self.action(value='1'))
 def test_wrong_target_rejected(self):self.assertRaises(ValueError,self.e.enqueue,self.action(to=A(999)))
 def test_raw_calldata_rejected(self):self.assertRaises(ValueError,self.e.enqueue,self.action(data='0x1234'))
 def test_wrong_finalizer_rejected(self):
  c=copy.deepcopy(self.c);c['finalizer']=A(9);self.assertRaises(ValueError,checked,c)
 def test_separate_permissionless_identity_required(self):
  c=copy.deepcopy(self.c);c['permissionlessSender']=FINALIZER;self.assertRaises(ValueError,checked,c)
 def test_production_enabled_rejected(self):
  c=copy.deepcopy(self.c);c['productionExecutionEnabled']=True;self.assertRaises(ValueError,checked,c)
 def test_duplicate_enqueue_and_restart(self):
  j=self.queued();self.assertEqual(j,self.queued());self.e.db.close();self.e=self.open();self.assertEqual(j,self.queued());self.assertEqual(self.e.db.execute('SELECT count(*) FROM holder_exec_jobs').fetchone()[0],1)
 def test_exact_nonce_gas_reservation_and_confirmation(self):
  j=self.queued();self.assertEqual(self.e.tick()['status'],'PENDING');self.assertEqual(self.state(j)['nonce'],0);self.assertEqual(self.state(j)['reserved'],'1000000');self.assertEqual(self.e.tick()['status'],'PENDING');self.confirm();self.assertEqual(self.state(j)['status'],'CONFIRMED');self.assertEqual(len(self.r.sent),1)
 def test_restart_pending_no_resend(self):
  j=self.queued();self.e.tick();self.e.db.close();self.e=self.open();self.e.tick();self.assertEqual(len(self.r.sent),1);self.confirm();self.assertEqual(self.state(j)['status'],'CONFIRMED')
 def test_uncertain_submission_halts_both_lanes(self):
  self.r.raise_send=True;j=self.queued();self.assertEqual(self.e.tick()['status'],'UNKNOWN');self.queued(self.action(args=[1]));self.assertEqual(self.e.tick()['status'],'UNKNOWN');self.assertEqual(len(self.r.sent),1)
 def test_crash_after_submitting_never_resends(self):
  j=self.queued();self.e.db.execute("UPDATE holder_exec_jobs SET status='SUBMITTING' WHERE id=?",(j,));self.assertEqual(self.e.tick()['status'],'UNKNOWN');self.assertFalse(self.r.sent)
 def test_rpc_failure_before_submission_bounded_backoff(self):
  self.queued();self.r.raise_read=True;self.assertEqual(self.e.tick()['status'],'RETRY');self.assertEqual(self.e.tick()['status'],'IDLE');self.now+=10;self.assertEqual(self.e.tick()['status'],'RETRY');self.now+=20;self.assertEqual(self.e.tick()['status'],'EXHAUSTED');self.assertFalse(self.r.sent)
 def test_rpc_failure_during_pending_does_not_resend(self):
  self.queued();self.e.tick();self.r.raise_read=True;self.assertEqual(self.e.tick()['status'],'RPC_UNAVAILABLE');self.assertEqual(len(self.r.sent),1)
 def test_wrong_chain(self):self.queued();self.r.chain=1;self.assertEqual(self.e.tick()['status'],'RETRY');self.assertFalse(self.r.sent)
 def test_wrong_binding(self):self.queued();self.v.bad_bind=True;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_wrong_grace(self):self.queued();self.v.bad_grace=True;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_insufficient_backing(self):self.queued();self.v.reserve=99;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_insufficient_sender_gas(self):self.queued();self.r.sender_balance=1;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_gas_estimate_exceeds_cap(self):self.queued();self.r.estimate=500001;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_gas_price_exceeds_cap(self):self.queued();self.r.price=11;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_daily_budget_exhaustion(self):
  self.c['dailyGasBudgetWei']=999999;self.e.db.close();Path(self.path).unlink();self.e=self.open();self.queued();self.assertEqual(self.e.tick()['status'],'RETRY');self.assertFalse(self.r.sent)
 def test_pending_timeout_safe_halt(self):self.queued();self.e.tick();self.r.receipts.clear();self.now+=101;self.assertEqual(self.e.tick()['status'],'UNKNOWN');self.assertEqual(len(self.r.sent),1)
 def test_nonce_consumed_without_receipt(self):self.queued();self.e.tick();self.r.receipts.clear();self.assertEqual(self.e.tick()['status'],'UNKNOWN')
 def test_receipt_mismatch(self):
  self.queued();r=self.e.tick();self.r.receipts[r['transactionHash']]['to']=A(99);self.confirm();self.assertEqual(self.e.tick()['status'],'UNKNOWN')
 def test_transaction_calldata_mismatch(self):
  self.queued();r=self.e.tick();self.r.txs[r['transactionHash']]['input']='0xaaaa';self.confirm();self.assertEqual(self.e.tick()['status'],'UNKNOWN')
 def test_transaction_nonce_mismatch(self):
  self.queued();r=self.e.tick();self.r.txs[r['transactionHash']]['nonce']='0x2';self.confirm();self.assertEqual(self.e.tick()['status'],'UNKNOWN')
 def test_reverted_receipt_stops(self):
  self.r.mine_status=0;j=self.queued();self.e.tick();self.confirm();self.assertEqual(self.state(j)['status'],'REVERTED');self.assertEqual(self.e.tick()['status'],'REVERTED')
 def test_unconfirmed_reorg_remains_pending(self):
  self.queued();r=self.e.tick();self.r.blocks[101]['hash']=H(999);self.r.advance();self.assertEqual(self.e.tick()['status'],'PENDING');self.assertEqual(len(self.r.sent),1)
 def test_deep_confirmed_reorg_halts(self):
  j=self.queued();self.e.tick();self.confirm();self.r.blocks[101]['hash']=H(999);self.assertEqual(self.e.tick()['status'],'UNKNOWN');self.assertEqual(self.state(j)['status'],'UNKNOWN')
 def test_known_hash_requires_exact_bound_identity(self):
  j=self.queued();out=self.e.tick();self.e.fail(j,'UNKNOWN','fixture crash');self.e.record_known_hash(j,out['transactionHash']);self.assertEqual(self.state(j)['status'],'PENDING');self.e.fail(j,'UNKNOWN','fixture crash');self.r.txs[out['transactionHash']]['input']='0xab';self.assertRaises(ValueError,self.e.record_known_hash,j,out['transactionHash'])
 def test_config_mutation_on_restart_rejected(self):
  self.e.db.close();self.c['maxGas']=400000;self.assertRaises(ValueError,self.open);self.c['maxGas']=500000;self.e=self.open()
 def test_dryrun_no_submission_or_budget_reservation(self):
  self.e.db.close();Path(self.path).unlink();self.e=self.open('dry-run');j=self.queued();self.assertEqual(self.e.tick()['status'],'SIMULATED');self.assertEqual(self.state(j)['reserved'],'0');self.assertFalse(self.r.sent)
 def test_new_work_rejected_shutdown_and_terminated(self):
  for life in (2,3):self.v.life=life;self.queued(self.action(args=[life]));self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_normal_retry_active_and_shutdown(self):
  for life in (0,2):
   self.v.life=life;j=self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'PENDING');self.confirm();self.now+=11
 def test_terminal_retry_predeadline(self):
  self.v.life=3;self.v.terminal=True;self.v.status=2;self.r.now=self.v.expires-1;self.r.blocks[100]['timestamp']=hex(self.r.now);self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'PENDING')
 def test_terminal_retry_at_and_after_deadline(self):
  self.v.life=3;self.v.terminal=True;self.v.status=2;self.r.blocks[100]['timestamp']=hex(self.v.expires);self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'RETRY');self.now+=11;self.r.blocks[100]['timestamp']=hex(self.v.expires+1);self.assertEqual(self.e.tick()['status'],'RETRY');self.assertFalse(self.r.sent)
 def test_terminal_status_identity_and_grace(self):
  self.v.life=3;self.v.status=2;self.v.terminal=True;self.v.bad_failure=True;self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_normal_retry_not_allowed_terminated(self):self.v.life=3;self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_paid_leaf_never_sent(self):self.v.paid=True;self.queued(self.retry());self.assertEqual(self.e.tick()['status'],'RETRY');self.assertFalse(self.r.sent)
 def test_bounded_payment_retry_transactions(self):
  a=self.retry()
  for i in range(3):
   j=self.queued(a);self.assertEqual(self.e.tick()['status'],'PENDING');self.confirm();self.assertEqual(self.state(j)['outcome'],'FAILED_PAYMENT');self.now+=11
  self.assertEqual(self.queued(a),j);self.assertEqual(self.e.tick()['status'],'IDLE');self.assertEqual(len(self.r.sent),3)
 def test_successful_retry_prevents_repeat(self):
  a=self.retry();j=self.queued(a);self.e.tick();self.v.paid=True;self.confirm();self.now+=11;self.assertEqual(self.queued(a),j);self.assertEqual(self.e.tick()['status'],'IDLE');self.assertEqual(self.state(j)['outcome'],'PAID')
 def test_candidate_review_boundary(self):
  self.v.review=10001;a=dict(to=A(4),method='finalizeCandidate',distributionId=H(1),version=1);j=self.queued(a);self.assertEqual(self.e.tick()['status'],'RETRY');self.now+=11;self.r.blocks[100]['timestamp']=hex(10001);self.assertEqual(self.e.tick()['status'],'PENDING')
 def test_candidate_materialization_completeness(self):
  self.v.complete=False;self.queued(dict(to=A(4),method='finalizeCandidate',distributionId=H(1),version=1));self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_wrong_review_policy(self):
  self.queued(dict(to=A(4),method='finalizeCandidate',distributionId=H(1),version=1));old=self.v.words
  def words(*a,**kw):
   out=old(*a,**kw)
   if a[1]=='candidate(bytes32,uint32)':out[12]+=1
   return out
  self.v.words=words;self.assertEqual(self.e.tick()['status'],'RETRY')
 def test_batch_size_and_duplicate_bounds(self):
  for leaves in ([],[H(55)]*2,[H(i) for i in range(11)]):self.assertRaises(ValueError,self.e.enqueue,dict(to=A(5),method='payBatch',leaves=leaves))
 def test_correction_requires_explicit_action_bound_approval(self):
  a=dict(to=A(4),method='correctCandidate',candidate=[],evidence=[],reason=H(1));self.assertRaises(KeyError,self.e.enqueue,a);a['authorization']=dict(reference='reviewed-fixture',actionSha256=digest(a),expiresAt=11000,finalizer=FINALIZER);j=self.queued(a);self.assertEqual(self.state(j)['role'],'finalizer');b=copy.deepcopy(a);b['reason']=H(2);self.assertRaises(ValueError,self.e.enqueue,b)
 def test_finalizer_lane_identity(self):
  j=self.queued(dict(to=A(4),method='submitCandidate',candidate=[],evidence=[],requiredCaller=FINALIZER));self.e.tick();self.assertEqual(self.r.sent[0]['from'],FINALIZER)
 def test_offline_transport_rejects_remote_and_credentials(self):
  for url in ('https://bsc-dataseed.bnbchain.org','http://user:pw@localhost:1234','http://example.com'):self.assertRaises(ValueError,LocalRPC,url)
 def test_nonoffline_submitter_rejected(self):self.assertRaises(ValueError,Executor,self.path,self.c,self.r,CastFixture(),Encoder(),mode='offline',submitter=object())
if __name__=='__main__':unittest.main(verbosity=2)
