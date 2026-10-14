"""Focused public projection tests. Only mock chain reads; no RPC or transaction submission."""
import unittest
from unittest.mock import patch
from public_status import PublicLaunchStatus,PublicRPC
from launch_status import LaunchStatus
TOKEN='0x7b7af51136574c91a12988989c0a08e98ae97777';H='0x'+'1'*64
class RPC:
 def __init__(self):self.chain=56;self.reads=[];self.reorg=False
 def call(self,method,params):
  self.reads.append((method,params))
  if method=='eth_getBlockByNumber':return {'hash':H if not self.reorg or len([x for x in self.reads if x[0]==method])<2 else '0x'+'2'*64,'timestamp':'0x100'}
  if method=='eth_getBalance':return '0x0'
  if method=='eth_getCode':return '0x01'
  raise AssertionError('Unexpected RPC')
class Scheduler:
 def __init__(self):self.rpc=RPC();self.c={'kernel':'0x'+'3'*40,'executor':'0x'+'4'*40,'settlement':'0x'+'5'*40}
 def preflight(self):
  if self.rpc.chain!=56:raise ValueError('Wrong chain')
  return '0x10'
class View:
 phase=0;bad_pool=False
 def __init__(self,s,block):assert block=='0x10'
 def one(self,target,sig,args=()):
  if sig=='state()':return self.phase
  if sig=='mainPool()':return 99 if self.bad_pool else 123
  return 0
 def words(self,target,sig,args,count):
  words=[0]*18;words[0]=1 if self.phase<2 else 4;words[4]=6;words[8]=123456;words[14]=123 if self.phase>=2 else 0;return words
class Tests(unittest.TestCase):
 def setUp(self):
  self.obs=object.__new__(PublicLaunchStatus);self.obs.s=Scheduler();self.obs.c={k:TOKEN for k in ('receiver','token','factory','vaultPortal','portal','buybackExecutor')};self.pins=[];self.obs.verify_code=lambda block:self.pins.append(block);View.phase=0;View.bad_pool=False
 def status(self):
  with patch.object(LaunchStatus,'status',return_value={'status':'NOT_VERIFIED'}),patch('public_status.ChainView',View):return self.obs.status(0)
 def test_actual_zero_and_same_block_ledger_pin(self):
  r=self.status();self.assertEqual(r['ledger']['vaultBalanceWei'],'0');self.assertEqual(r['ledger']['accountedWei'],'0');self.assertEqual(self.pins,['0x10']);self.assertEqual(r['publicSnapshot']['blockHash'],H);self.assertFalse(any(x[0].startswith('eth_send') for x in self.obs.s.rpc.reads))
 def test_phase_threshold_is_read_not_eighty_percent(self):self.assertEqual(self.status()['bonding']['thresholdBaseUnits'],'123456');self.assertEqual(self.status()['bonding']['phase'],'PRE_BONDING')
 def test_post_requires_pool_binding(self):
  View.phase=3;self.assertEqual(self.status()['bonding']['phase'],'POST_BONDING_PANCAKE_REPORTED');View.bad_pool=True;self.assertEqual(self.status()['bonding']['phase'],'NOT_VERIFIED')
 def test_optional_phase_failure_does_not_invent_state(self):
  with patch.object(LaunchStatus,'status',return_value={}),patch('public_status.ChainView',View),patch.object(View,'words',side_effect=RuntimeError()):self.assertEqual(self.obs.status(0)['bonding']['phase'],'NOT_VERIFIED')
 def test_wrong_chain_and_snapshot_reorg_rejected(self):
  self.obs.s.rpc.chain=1
  with self.assertRaises(ValueError):self.status()
  self.obs.s.rpc.chain=56;self.obs.s.rpc.reorg=True
  with self.assertRaises(ValueError):self.status()
 def test_buyback_actual_zero_is_observation_not_clearance(self):
  result=self.status()['buybackObservation'];self.assertFalse(result['activated']);self.assertEqual(result['totalBNBSpentWei'],'0');self.assertEqual(result['qualification'],'NOT_VERIFIED_ROUTES_DISPOSAL_AND_GRAPH')
 def test_rpc_still_rejects_transaction_submission(self):
  with self.assertRaises(ValueError):PublicRPC('http://unused.local').call('eth_sendRawTransaction',['0x00'])
if __name__=='__main__':unittest.main()
