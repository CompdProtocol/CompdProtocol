"""Deterministic fixtures only; no deployed token, signing, RPC or funds."""
import hashlib,json,os,tempfile,unittest
from holder_rewards import *
from holder_keeper import HolderKeeper
from agent_scheduler import Cast
A='0x'+'1'*40;B='0x'+'2'*40;K='0x'+'3'*40;M='0x'+'4'*40
H=lambda n:'0x'+f'{n:064x}'
W=lambda n:'0x'+f'{n:064x}'
class CastFixture:
    def run(self,args):return '0x'+hashlib.sha256(args[1].encode()).hexdigest()
    def code_hash(self,code):return H(999) if code=='0x6000' else H(0)
class ViewFixture:
    block='0xb'
    def __init__(self,pool=0):self.pool=pool;self.closed=False;self.paused=False;self.paid=False;self.failed=False;self.wrong_epoch=False
    def one(self,target,sig,args=()):
        if sig in ('strategyExecutor()','buybackExecutor()','liability()','recoveryEvidence()'):return int(K,16)
        if sig=='activationExclusionSetHash()':return 77
        values={'lifecycle()':1 if self.paused else 0,'activationSealed()':1,'activationSealFailed()':0,'launchHolderEpochs()':1,'activationTimestamp()':1000,'activationBlock()':10,'activationBlockHash()':10,'candidateModule()':int(K,16),'moduleAddress(uint8)':int(M,16),'moduleHash(uint8)':999,'candidateModuleHash()':999,'zeroWindowFinalized(bytes32)':int(self.closed),'distributor()':int(K,16),'holderPaid(bytes32)':int(self.paid),'hasFailure(bytes32)':int(self.failed),'paymentWindowStart(bytes32)':1000,'holderState()':int(K,16),'holderStateHash()':999,'holderRewardReserve()':self.pool,'outstandingHolderLiability()':self.pool}
        return values[sig]
    def words(self,target,sig,args,count):
        if sig=='deriveWindow(uint64)':return [7,8,1900,0 if self.paid else self.pool,int(self.pool>0)]
        if sig=='canonicalPayment(bytes32)':return [5,int(A,16),0,self.pool,1,not self.paid]
        if sig=='paymentData(bytes32)':return [17 if self.wrong_epoch else 7,8,1,0,1,1,int(H(1),16),int(A,16),0,self.pool,1,1,1,0,0,99,not self.paid]
        raise ValueError('unexpected fixture ABI')
class RPCFixture:
    def __init__(self):
        self.blocks={10:dict(number='0xa',hash=H(10),parentHash=H(9),timestamp=hex(1000),transactions=[H(100)])}
        self.receipts={H(100):self.receipt(10,100,0,[self.transfer(10,100,0,ZERO,A,MINIMUM*2)])};self.calls=[];self.chain=56
    def transfer(self,n,tx,i,a,b,amount):return dict(address=TOKEN,topics=[TRANSFER,W(int(a,16)),W(int(b,16))],data=W(amount),blockHash=H(n),transactionHash=H(tx),logIndex=hex(i))
    def receipt(self,n,tx,index,logs):return dict(transactionHash=H(tx),to=PORTAL,blockHash=H(n),blockNumber=hex(n),transactionIndex=hex(index),status='0x1',logs=logs)
    def add(self,n,t,logs=None):
        tx=n*10;self.blocks[n]=dict(number=hex(n),hash=H(n),parentHash=self.blocks[n-1]['hash'],timestamp=hex(t),transactions=[H(tx)] if logs else [])
        if logs:self.receipts[H(tx)]=self.receipt(n,tx,0,logs)
    def call(self,method,params):
        self.calls.append((method,params))
        if method=='eth_chainId':return hex(self.chain)
        if method=='eth_getBlockByNumber':
            n=params[0]
            if n=='latest':return dict(self.blocks[max(self.blocks)],number=hex(max(self.blocks)+12))
            if n=='finalized':return self.blocks[max(self.blocks)]
            return self.blocks.get(int(n,16))
        if method=='eth_getCode':return '0x' if int(params[1],16)<10 else '0x6000'
        if method=='eth_getTransactionReceipt':return self.receipts.get(params[0])
        if method=='eth_getLogs':
            n=int(params[0]['fromBlock'],16)
            return [l for tx in self.blocks[n]['transactions'] for l in self.receipts[tx]['logs']] if all(tx in self.receipts for tx in self.blocks[n]['transactions']) else []
        if method=='eth_call':
            data=params[0]['data'];n=int(params[1],16)
            if data=='0x313ce567':return W(18)
            balances={}
            for i in sorted(self.blocks):
                if i>n:break
                for tx in self.blocks[i]['transactions']:
                    for l in self.receipts[tx]['logs']:
                        if l['address']!=TOKEN or l['topics'][0]!=TRANSFER:continue
                        a='0x'+l['topics'][1][-40:];b='0x'+l['topics'][2][-40:];v=int(l['data'],16)
                        if a!=ZERO:balances[a]=balances.get(a,0)-v
                        if b!=ZERO:balances[b]=balances.get(b,0)+v
            if data=='0x18160ddd':return W(sum(balances.values()))
            if data.startswith('0x70a08231'):return W(balances.get('0x'+data[-40:],0))
            raise ValueError('unexpected eth_call')
        raise ValueError('unexpected RPC')
class HolderTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('COMPD_TEST_TEMP'));self.path=Path(self.tmp.name)/'holders.sqlite';self.rpc=RPCFixture()
        self.c=dict(chainId=56,token=TOKEN,kernel=K,launchTimestamp=1000,creationBlock=10,creationBlockHash=H(10),launchTransactionHash=H(100),excludedAddresses=[K,M],exclusionApprovalReference='TEST ONLY approved exclusion fixture',exclusionSetHash=H(77),confirmations=12,tokenCodeHash=H(999),kernelCodeHash=H(999),holderModule=M)
        self.x=HolderIndexer(self.path,self.c,self.rpc,CastFixture())
    def tearDown(self):self.x.db.close();self.tmp.cleanup()
    def close(self):self.rpc.add(11,1901);self.x.sync()
    def add_event(self,n,i,kind,p):
        self.x.db.execute('INSERT INTO events VALUES(?,?,?,?)',(n,i,kind,json.dumps(p)));self.x.db.commit()
    def test_first_epoch_and_regular_transition(self):
        self.assertEqual(epoch_at(1000,1899),(1000,1900,'FIRST_15_MINUTES'));self.assertEqual(epoch_at(1000,1900),(1900,28800,'UTC_TRANSITION'));self.assertEqual(epoch_at(1000,28800),(28800,57600,'UTC_8_HOURS'))
    def test_exact_boundary_no_empty_bridge(self):self.assertEqual(epoch_at(27900,28800),(28800,57600,'UTC_8_HOURS'))
    def test_before_launch(self):self.assertIsNone(epoch_at(1000,999))
    def test_real_receipt_replay_zero_profit(self):
        self.close();r=self.x.epoch(1000,1900);self.assertEqual(r['poolWei'],'0');self.assertEqual(r['top30'][0]['weight'],str(MINIMUM*2*900));self.assertFalse(r['liveExecution'])
    def test_restart_idempotent_checkpoint(self):
        self.close();self.x.db.close();self.x=HolderIndexer(self.path,self.c,self.rpc,CastFixture());self.assertEqual(self.x.sync(),0);self.assertEqual(self.x.balances()[A],MINIMUM*2)
    def test_reorg_rewinds_events_and_replays(self):
        self.rpc.add(11,1450,[self.rpc.transfer(11,110,0,A,B,MINIMUM)]);self.rpc.add(12,1901);self.x.sync();self.assertEqual(self.x.balances()[B],MINIMUM)
        self.rpc.blocks[11]['hash']=H(111);self.rpc.blocks[11]['transactions']=[];self.rpc.blocks[12]['hash']=H(112);self.rpc.blocks[12]['parentHash']=H(111);self.x.sync();self.assertNotIn(B,self.x.balances())
    def test_transfer_between_snapshots_actual_integral(self):
        self.rpc.add(11,1450,[self.rpc.transfer(11,110,0,A,B,MINIMUM)]);self.rpc.add(12,1901);self.x.sync();r=self.x.epoch(1000,1900);self.assertEqual(r['top30'][0]['weight'],str(MINIMUM*1350));self.assertEqual(r['top30'][1]['weight'],str(MINIMUM*450))
    def test_subminimum_time_excluded(self):
        self.rpc.add(11,1450,[self.rpc.transfer(11,110,0,A,B,MINIMUM-1)]);self.rpc.add(12,1901);self.x.sync();self.assertEqual(len(self.x.epoch(1000,1900)['top30']),1)
    def test_minimum_inclusive(self):
        self.rpc.add(11,1000,[self.rpc.transfer(11,110,0,A,B,MINIMUM)]);self.rpc.add(12,1901);self.x.sync();r=self.x.epoch(1000,1900);self.assertEqual([x['address'] for x in r['top30']],[A,B])
    def test_top30_and_numeric_tie_break(self):
        self.close();self.x.db.execute('DELETE FROM events');self.x.db.commit()
        for i in range(31):self.add_event(10,i,'transfer',dict(sender=ZERO,recipient='0x'+f'{i+1:040x}',amount=str(MINIMUM)))
        r=self.x.epoch(1000,1900);self.assertEqual(len(r['top30']),30);self.assertEqual(r['top30'][-1]['address'],'0x'+f'{30:040x}')
    def test_exclusion(self):self.x.exclude.add(A);self.close();self.assertEqual(self.x.epoch(1000,1900)['top30'],[])
    def test_missing_close_coverage_rejected(self):self.x.sync();self.assertRaises(ValueError,self.x.epoch,1000,1900)
    def test_wrong_chain_rejected(self):self.rpc.chain=97;self.assertRaises(ValueError,self.x.sync)
    def test_fabricated_launch_hash_rejected(self):self.c['creationBlockHash']=H(99);self.assertRaises(ValueError,self.x.sync)
    def test_timestamp_mismatch_rejected(self):self.c['launchTimestamp']=999;self.x.launch=999;self.assertRaises(ValueError,self.x.sync)
    def test_runtime_mismatch_rejected(self):self.c['tokenCodeHash']=H(12);self.assertRaises(ValueError,self.x.sync)
    def test_receipt_revert_rejected(self):self.rpc.receipts[H(100)]['status']='0x0';self.assertRaises(ValueError,self.x.sync)
    def test_missing_receipt_rejected(self):self.rpc.receipts.clear();self.assertRaises(ValueError,self.x.sync)
    def test_missing_mint_rejected(self):self.rpc.receipts[H(100)]['logs']=[];self.assertRaises(ValueError,self.x.sync)
    def test_removed_log_atomic_rollback(self):
        self.rpc.add(11,1450,[dict(self.rpc.transfer(11,110,0,A,B,MINIMUM),removed=True)]);self.assertRaises(ValueError,self.x.sync);self.assertEqual(self.x.db.execute('SELECT max(n) FROM blocks').fetchone()[0],10)
    def test_incomplete_history_atomic_rollback(self):
        self.rpc.add(11,1450,[self.rpc.transfer(11,110,0,B,A,MINIMUM)]);self.assertRaises(ValueError,self.x.sync);self.assertNotIn(B,self.x.balances())
    def test_duplicate_log_rejected(self):
        l=self.rpc.transfer(11,110,0,A,B,MINIMUM);self.rpc.add(11,1450,[l,l]);self.assertRaises(ValueError,self.x.sync)
    def test_profit_requires_matching_kernel_accrual(self):
        self.close();self.add_event(10,1,'profit',dict(reward='101'));self.assertRaises(ValueError,self.x.epoch,1000,1900)
    def test_profit_allocation_conservation(self):
        self.rpc.add(11,1000,[self.rpc.transfer(11,110,0,A,B,MINIMUM)]);self.rpc.add(12,1901);self.x.sync();self.add_event(10,1,'profit',dict(reward='101'));self.add_event(10,2,'accrued',dict(start=1000,amount='101',total='101'));r=self.x.epoch(1000,1900);self.assertEqual([x['amountWei'] for x in r['top30']],['51','50'])
    def test_failure_retry_observation_not_double_total(self):
        self.close();self.add_event(10,1,'profit',dict(reward='9'));self.add_event(10,2,'accrued',dict(start=1000,amount='9',total='9'));p=dict(useId=H(500),recipient=A,amount='9',transactionHash=H(90));self.add_event(11,0,'failed',p);self.add_event(11,1,'failed',p);r=self.x.epoch(1000,1900);self.assertEqual(r['failedPaymentLiabilitiesWei'],'9');self.add_event(11,2,'paid',p);r=self.x.epoch(1000,1900);self.assertEqual(r['paidRewardsWei'],'9');self.assertEqual(r['failedPaymentLiabilitiesWei'],'0')
    def test_duplicate_paid_rejected(self):
        self.close();p=dict(useId=H(500),recipient=A,amount='9',transactionHash=H(90));self.add_event(11,0,'paid',p);self.add_event(11,1,'paid',p);self.assertRaises(ValueError,self.x.epoch,1000,1900)
    def test_config_change_after_restart_rejected(self):
        other=dict(self.c,confirmations=13);self.assertRaises(ValueError,HolderIndexer,self.path,other,self.rpc,CastFixture())
    def test_no_overlap(self):self.close();self.assertRaises(ValueError,self.x.epoch,1001,1901)
    def test_unsigned_push_bounded_and_no_signing(self):
        b=self.x.unsigned_push_batches([H(x) for x in range(30)]);self.assertEqual(len(b),3);self.assertTrue(all(x['mode']=='DRY_RUN' and x['to']==M for x in b))
    def test_duplicate_plan_leaf_rejected(self):self.assertRaises(ValueError,self.x.unsigned_push_batches,[H(1),H(1)])
    def test_batch_bounds(self):self.assertRaises(ValueError,self.x.unsigned_push_batches,[H(1)],11);self.assertRaises(ValueError,self.x.sync,129)
    def funded(self):
        self.close();self.add_event(10,1,'profit',dict(reward='100'));self.add_event(10,2,'accrued',dict(start=1000,amount='100',total='100'))
    def test_zero_keeper_plan_restart_idempotence(self):
        self.close();keeper=HolderKeeper(self.x);v=ViewFixture();r=keeper.plan(v,1000,1900);self.assertEqual(r['actions'][0]['method'],'finalizeZeroWindow(uint64)');keeper.plan(v,1000,1900);self.assertEqual(self.x.db.execute('SELECT count(*) FROM holder_plans').fetchone()[0],1)
    def test_zero_keeper_already_finalized_no_duplicate_action(self):
        self.close();v=ViewFixture();v.closed=True;self.assertEqual(HolderKeeper(self.x).plan(v,1000,1900)['actions'],[])
    def test_keeper_paused_rejected(self):
        self.close();v=ViewFixture();v.paused=True;self.assertRaises(ValueError,HolderKeeper(self.x).plan,v,1000,1900)
    def test_keeper_no_fabricated_candidate(self):
        self.funded();r=HolderKeeper(self.x).plan(ViewFixture(100),1000,1900);self.assertEqual(r['actions'],[]);self.assertIn('EVIDENCE',r['missing'])
    def test_keeper_full_reviewed_push_plan(self):
        self.funded();r=HolderKeeper(self.x).plan(ViewFixture(100),1000,1900,[H(1)]);self.assertEqual(r['actions'][0]['method'],'payBatch(bytes32[])')
    def test_keeper_failed_transfer_retry_plan(self):
        self.funded();v=ViewFixture(100);v.failed=True;r=HolderKeeper(self.x).plan(v,1000,1900,[H(1)]);self.assertEqual(r['actions'][0]['method'],'retry(bytes32)')
    def test_keeper_paid_leaf_not_reexecuted(self):
        self.funded();v=ViewFixture(100);v.paid=True;r=HolderKeeper(self.x).plan(v,1000,1900,[H(1)]);self.assertEqual(r['actions'],[])
    def test_keeper_wrong_epoch_leaf_rejected(self):
        self.funded();v=ViewFixture(100);v.wrong_epoch=True;self.assertRaises(ValueError,HolderKeeper(self.x).plan,v,1000,1900,[H(1)])
    def test_keeper_remaining_reserve_mismatch_rejected(self):
        self.funded();self.assertRaises(ValueError,HolderKeeper(self.x).plan,ViewFixture(101),1000,1900,[H(1)])
    def test_public_holder_snapshot_real_observations_only(self):
        self.close();r=self.x.public_snapshot(1901,ViewFixture());self.assertEqual(r['status'],'NOT_ACTIVATED_DRY_RUN_INDEXED');self.assertEqual(r['pendingLiabilitiesWei'],'0');self.assertEqual(r['firstCheckpoint']['poolWei'],'0')
    def test_public_launch_binding_mismatch_rejected(self):
        self.close();v=ViewFixture();v.one=lambda target,sig,args=():0;self.assertRaises(ValueError,self.x.public_snapshot,1901,v)
    def test_unsupported_decimals_rejected(self):
        old=self.rpc.call
        self.rpc.call=lambda m,p:W(9) if m=='eth_call' and p[0]['data']=='0x313ce567' else old(m,p)
        self.assertRaises(ValueError,self.x.sync)
    def test_missing_historical_state_rejected(self):
        old=self.rpc.call
        self.rpc.call=lambda m,p:'0x' if m=='eth_call' and p[0]['data']=='0x18160ddd' else old(m,p)
        self.assertRaises(ValueError,self.x.sync);self.assertEqual(self.x.db.execute('SELECT count(*) FROM blocks').fetchone()[0],0)
    def test_actual_balance_mismatch_rejected(self):
        old=self.rpc.call
        self.rpc.call=lambda m,p:W(1) if m=='eth_call' and p[0]['data'].startswith('0x70a08231') else old(m,p)
        self.assertRaises(ValueError,self.x.sync);self.assertEqual(self.x.db.execute('SELECT count(*) FROM blocks').fetchone()[0],0)
    def test_actual_total_supply_mismatch_rejected(self):
        old=self.rpc.call
        self.rpc.call=lambda m,p:W(1) if m=='eth_call' and p[0]['data']=='0x18160ddd' else old(m,p)
        self.assertRaises(ValueError,self.x.sync)
    def test_exact_close_timestamp_accepted(self):
        self.rpc.add(11,1900);self.x.sync();self.assertEqual(self.x.epoch(1000,1900)['poolWei'],'0')
    def automatic_fixture(self):
        root=Path(__file__).resolve().parents[2]
        names=('tools/agent-scheduler/holder_rewards.py','tools/agent-scheduler/holder_keeper.py','offchain/holder-rewards-v1/src/core.mjs','offchain/holder-rewards-v1/src/codec.mjs','offchain/holder-rewards-v1/src/indexed-candidate.mjs')
        source_hashes={n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in names}
        real=Cast(os.environ.get('COMPD_CAST_BIN','cast'));bundle=json.dumps(source_hashes,sort_keys=True,separators=(',',':')).encode().hex()
        cfg=dict(self.c,distributor=K,exclusionSetVersion=2,replaySourceHashes=source_hashes,replayCodeHash=real.code_hash('0x'+bundle))
        class SourceCast(CastFixture):
            def code_hash(self,code):return H(999) if code=='0x6000' else real.code_hash(code)
        self.x.db.close();self.path=Path(self.tmp.name)/'auto.sqlite';self.x=HolderIndexer(self.path,cfg,self.rpc,SourceCast());self.funded()
        v=ViewFixture(100);proposal=self.x.candidate_proposal(1000,1900);c=proposal['candidate'];old_words=v.words
        v.words=lambda target,sig,args,count:[int(c['windowId'],16),int(c['distributionId'],16),1900,0 if v.paid else 100,1] if sig=='deriveWindow(uint64)' else old_words(target,sig,args,count)
        return HolderKeeper(self.x),v
    def test_automatic_index_to_real_node_candidate_and_frozen_restart(self):
        keeper,v=self.automatic_fixture();v.one_original=v.one;v.one=lambda target,sig,args=():0 if sig=='currentVersion(bytes32)' else int(A,16) if sig=='finalizer()' else v.one_original(target,sig,args)
        r=keeper.plan(v,1000,1900);self.assertEqual([x['method'] for x in r['actions']],['submitCandidate','materializeLeaf']);self.assertEqual(r['actions'][0]['candidate']['windowPool'],'100')
        self.assertEqual(keeper.plan(v,1000,1900),r);self.assertEqual(self.x.db.execute('SELECT count(*) FROM holder_candidates').fetchone()[0],1)
    def test_cached_proposal_reorg_blocks_automatic_actions(self):
        keeper,v=self.automatic_fixture();old=v.one;v.one=lambda target,sig,args=():0 if sig=='currentVersion(bytes32)' else int(A,16) if sig=='finalizer()' else old(target,sig,args)
        keeper.plan(v,1000,1900);self.x.db.execute('UPDATE blocks SET hash=? WHERE n=11',(H(111),));self.x.db.commit();self.assertRaises(ValueError,keeper.plan,v,1000,1900)
    def test_automatic_candidate_source_pin_mismatch_rejected(self):
        keeper,v=self.automatic_fixture();self.x.c['replaySourceHashes']={};self.assertRaises(ValueError,self.x.candidate_proposal,1000,1900)
    def test_automatic_materialized_review_uses_chain_timestamp_before_finalization(self):
        keeper,v=self.automatic_fixture();old_one=v.one;old_words=v.words
        v.one=lambda target,sig,args=():0 if sig=='currentVersion(bytes32)' else int(A,16) if sig=='finalizer()' else old_one(target,sig,args)
        keeper.plan(v,1000,1900);proposal=json.loads(self.x.db.execute('SELECT proposal FROM holder_candidates').fetchone()[0]);c=proposal['candidate']
        v.one=lambda target,sig,args=():1 if sig=='currentVersion(bytes32)' else int(A,16) if sig=='finalizer()' else old_one(target,sig,args)
        state=[int(c['distributionId'],16),int(c['windowId'],16),1000,1900,0,100,100,1,int(c['root'],16),int(c['datasetHash'],16),1,1,1901,3701,0,0,1,100]
        v.words=lambda target,sig,args,count:state if sig=='candidate(bytes32,uint32)' else old_words(target,sig,args,count)
        self.assertEqual(keeper.plan(v,1000,1900)['actions'],[])
        self.rpc.add(12,3701);self.x.sync();v.block='0xc';r=keeper.plan(v,1000,1900);self.assertEqual(r['actions'][0]['method'],'finalizeCandidate')
    def kernel_log(self,n,tx,i,topic,topics,words):
        return dict(address=K,topics=[topic,*topics],data='0x'+''.join(f'{v:064x}' for v in words),blockHash=H(n),transactionHash=H(tx),logIndex=hex(i))
    def test_raw_confirmed_settlement_and_accrual_decode_in_regular_epoch(self):
        logs=[self.kernel_log(11,110,0,self.x.settled,[H(1)],[100,1100,1000,0,123]),self.kernel_log(11,110,1,self.x.accrued,[H(115200),H(7)],[100,100])]
        self.rpc.add(11,115201,logs);self.rpc.add(12,144000);self.x.sync();r=self.x.epoch(115200,144000);self.assertEqual(r['poolWei'],'100');self.assertEqual(r['top30'][0]['amountWei'],'100')
    def test_raw_nonrealized_profit_mismatch_atomic_rejection(self):
        self.rpc.add(11,115201,[self.kernel_log(11,110,0,self.x.settled,[H(1)],[100,1100,999,0,123])]);self.assertRaises(ValueError,self.x.sync);self.assertEqual(self.x.db.execute('SELECT max(n) FROM blocks').fetchone()[0],10)
    def test_raw_failed_then_paid_event_liability_reconciliation(self):
        self.rpc.add(11,115201,[self.kernel_log(11,110,0,self.x.settled,[H(1)],[100,1100,1000,0,123]),self.kernel_log(11,110,1,self.x.accrued,[H(115200),H(7)],[100,100]),self.kernel_log(11,110,2,self.x.failed,[H(501),H(5)],[int(A,16),10])]);self.rpc.add(12,144001,[self.kernel_log(12,120,0,self.x.paid,[H(501),W(int(A,16))],[10])]);self.x.sync();r=self.x.epoch(115200,144000);self.assertEqual(r['failedPaymentLiabilitiesWei'],'0');self.assertEqual(r['paidRewardsWei'],'10');self.assertEqual(r['payoutTransactions'][0]['transactionHash'],H(120))
    def test_scan_cursor_resets_on_reorg(self):
        self.close();HolderKeeper(self.x);self.x.db.execute('UPDATE holder_scan_cursor SET next_start=28800 WHERE id=1');self.x.db.commit();self.x.rollback(11);self.assertEqual(self.x.db.execute('SELECT next_start FROM holder_scan_cursor').fetchone()[0],1000)
if __name__=='__main__':unittest.main()

