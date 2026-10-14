"""Deterministic RPC-response fixtures; no live balances, keys or transactions."""
import unittest,hashlib
from types import SimpleNamespace
from recovery_status import recovery_snapshot,confirmed_recovery_events,EVENTS,GUARDIAN,TREASURY
H='0x'+'1'*64;K='0x'+'2'*40;E='0x'+'3'*40;R='0x'+'4'*40;B='0x'+'5'*40
class Cast:
 def run(self,args):return '0x11111111' if args[0]=='sig' else '0x'+hashlib.sha256(args[1].encode()).hexdigest()
 def code_hash(self,code):return H
class RPC:
 def __init__(self):
  self.reads=[];self.balance='0x64';self.topic=Cast().run(['keccak',next(iter(EVENTS))]);self.data='0x'+''.join(f'{x:064x}' for x in [100,30,50,10,5,5]);
  self.log=dict(address=K,topics=[self.topic],data=self.data,blockNumber='0x5a',blockHash=H,transactionHash=H,logIndex='0x0',removed=False)
  self.receipt=dict(transactionHash=H,blockHash=H,blockNumber='0x5a',status='0x1',logs=[dict(self.log)])
  self.tx=dict(hash=H,chainId='0x38',to=K,**{'from':GUARDIAN},input='0x11111111',value='0x0');self.header=H;self.code='0x01';self.logs=[self.log]
 def call(self,m,p):
  self.reads.append((m,p))
  if m=='eth_getLogs':return self.logs
  if m=='eth_getBalance':return self.balance
  if m=='eth_getTransactionReceipt':return self.receipt
  if m=='eth_getTransactionByHash':return self.tx
  if m=='eth_getBlockByNumber':return {'hash':self.header}
  if m=='eth_getCode':return self.code
  raise AssertionError('Non-read RPC')
def observer():
 rpc=RPC();s=SimpleNamespace(c=dict(kernel=K,executor=E,confirmations=3,kernelCodeHash=H,executorCodeHash=H),rpc=rpc,cast=Cast());return SimpleNamespace(s=s,c=dict(receiver=R,buybackExecutor=B,receiverCodeHash=H,buybackExecutorCodeHash=H))
def state(life=3):return dict(observedLifecycle=life,ledger=dict(holderReserveWei='10',activePrincipalWei='0',accountedWei='100',vaultBalanceWei='100'))
class Tests(unittest.TestCase):
 def setUp(self):self.o=observer()
 def test_confirmed_native_conservation_guardian_purpose_and_receipt(self):
  rows,coverage=confirmed_recovery_events(self.o,'0x64');self.assertEqual(rows[0]['amount'],'100');self.assertEqual(rows[0]['destination'],TREASURY);self.assertFalse(coverage['completeHistory']);self.assertEqual(coverage['toBlock'],'0x62');self.assertFalse(any(m.startswith('eth_send') for m,p in self.o.s.rpc.reads))
 def test_repeated_logs_deduplicated(self):self.o.s.rpc.logs*=2;self.assertEqual(len(confirmed_recovery_events(self.o,'0x64')[0]),1)
 def test_removed_logs_not_displayed(self):self.o.s.rpc.log['removed']=True;self.assertEqual(confirmed_recovery_events(self.o,'0x64')[0],[])
 def test_wrong_sender_rejected(self):self.o.s.rpc.tx['from']=E;self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_wrong_chain_rejected(self):self.o.s.rpc.tx['chainId']='0x1';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_failed_receipt_rejected(self):self.o.s.rpc.receipt['status']='0x0';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_reorged_receipt_rejected(self):self.o.s.rpc.header='0x'+'9'*64;self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_missing_receipt_log_rejected(self):self.o.s.rpc.receipt['logs']=[];self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_wrong_recipient_or_call_rejected(self):
  self.o.s.rpc.tx['to']=E;self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64');self.o.s.rpc.tx['to']=K;self.o.s.rpc.tx['input']='0xdeadbeef';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_unconfirmed_block_rejected(self):self.o.s.rpc.log['blockNumber']='0x63';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_malformed_or_nonconserving_event_rejected(self):
  self.o.s.rpc.log['data']='0x00';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64');self.o.s.rpc.log['data']='0x'+''.join(f'{x:064x}' for x in [99,30,50,10,5,5]);self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_empty_or_missing_code_rejected(self):self.o.s.rpc.code='0x';self.assertRaises(ValueError,confirmed_recovery_events,self.o,'0x64')
 def test_balance_subtracts_entire_hr_and_blocks_active_or_unsettled(self):
  r=recovery_snapshot(self.o,'0x64',None,state());self.assertEqual(r['recoverableNativeWei'],'90');self.assertEqual(r['protectedHolderWei'],'10');self.assertEqual(r['lifecycle'],'TERMINATED')
  for life in [0,1,2,4]:self.assertIsNone(recovery_snapshot(self.o,'0x64',None,state(life))['recoverableNativeWei'])
  s=state();s['ledger']['activePrincipalWei']='1';self.assertIsNone(recovery_snapshot(self.o,'0x64',None,s)['recoverableNativeWei'])
 def test_insolvent_or_unavailable_balance_never_fabricated(self):
  for b in ['99',None]:s=state();s['ledger']['vaultBalanceWei']=b;self.assertIsNone(recovery_snapshot(self.o,'0x64',None,s)['recoverableNativeWei'])
 def test_history_failure_is_unverified_and_reverification_is_fresh(self):
  self.assertEqual(recovery_snapshot(self.o,'0x64',None,state())['historyStatus'],'CONFIRMED_RECENT_EVENT_WINDOW');self.o.s.rpc.receipt=None
  r=recovery_snapshot(self.o,'0x64',None,state());self.assertEqual(r['transactions'],[]);self.assertEqual(r['historyStatus'],'NOT_VERIFIED_RECEIPTS_OR_HISTORY_UNAVAILABLE')
 def test_connected_custody_balances_only_after_termination(self):
  r=recovery_snapshot(self.o,'0x64',None,state());self.assertTrue(all(x['recoverableNativeWei']=='100' for x in r['connectedVaults']));r=recovery_snapshot(self.o,'0x64',None,state(2));self.assertTrue(all(x['recoverableNativeWei'] is None for x in r['connectedVaults']))
if __name__=='__main__':unittest.main()
