"""Focused manual evidence/auth tests with RPC fixtures. No RPC network, wallet signing or submissions."""
import json,os,tempfile,unittest,hashlib
from pathlib import Path
from unittest.mock import patch
from manual_buyback import *
H='0x'+'1'*64;BH='0x'+'2'*64;CODE='0x60006000';KH='0x'+'3'*40;PH='0x'+'4'*40
SOWNER='0x'+'1'*64;SDEAD='0x'+'2'*64;SSUPPLY='0x'+'3'*64
word=lambda x:'0x'+f'{x:064x}'
def event(f,t,amount):return {'address':TOKEN,'topics':[TRANSFER,'0x'+f[2:].rjust(64,'0'),'0x'+t[2:].rjust(64,'0')],'data':word(amount)}
class FakeCast:
 def code_hash(self,code):
  if code=='0x':raise ValueError('No code')
  return '0x'+hashlib.sha256(bytes.fromhex(code[2:])).hexdigest()
 def run(self,args):return '0x'+hashlib.sha256(args[1].encode()).hexdigest()[:8]
class FakeRPC:
 def __init__(self,kind='BUYBACK',native=False):
  self.chain=56;self.calls=[];self.rpc_failure=False;self.unsupported_override=False;self.reorg=False;self.fail=False;self.latest=200;self.final=150;self.reserve=15*10**17;self.spends=[];self.last=0;self.physical=100*10**18
  self.before={SOWNER:word(0 if kind=='BUYBACK' else 1000),SDEAD:word(0),SSUPPLY:word(10**9)};self.after=dict(self.before)
  if kind=='BUYBACK':
   value=10**17;to=PORTAL;self.after[SOWNER]=word(1000);logs=[event(PORTAL,OWNER,1000)];words=[32,0,int(TOKEN,16),value,970,160,0];data='0xef7ec2e7'+''.join(f'{x:064x}' for x in words)
  elif native:
   value=0;to=TOKEN;self.after[SOWNER]=word(0);self.after[SSUPPLY]=word(10**9-1000);logs=[event(OWNER,ZERO,1000)];data='0x42966c68'+f'{1000:064x}'
  else:
   value=0;to=TOKEN;self.after[SOWNER]=word(0);self.after[SDEAD]=word(1000);logs=[event(OWNER,DEAD,1000)];data='0xa9059cbb'+DEAD[2:].rjust(64,'0')+f'{1000:064x}'
  self.receipt=dict(transactionHash=H,blockHash=BH,blockNumber='0x64',status='0x1',**{'from':OWNER,'to':to},logs=logs)
  self.tx=dict(hash=H,blockHash=BH,blockNumber='0x64',**{'from':OWNER,'to':to},value=hex(value),input=data)
  self.trace=dict(type='CALL',**{'from':OWNER,'to':to},input=data,value=hex(value),calls=[])
  self.pre={TOKEN:{'code':CODE,'storage':self.before},PORTAL:{'code':CODE,'storage':{}},OWNER:{'balance':hex(10**18)}}
  changed={k:v for k,v in self.before.items() if self.after[k]!=v};post={k:self.after[k] for k in changed}
  self.diff={'pre':{TOKEN:{'storage':changed}},'post':{TOKEN:{'storage':post}}}
 def call(self,method,params):
  self.calls.append((method,params))
  if self.rpc_failure:raise RuntimeError('RPC credential should never appear: SECRET_TEST')
  if method=='eth_chainId':return hex(self.chain)
  if method=='eth_getTransactionReceipt':return dict(self.receipt,status='0x0' if self.fail else self.receipt['status'])
  if method=='eth_getTransactionByHash':return self.tx
  if method=='eth_getBlockByNumber':
   tag=params[0];return {'hash':('0x'+'a'*64) if self.reorg else BH,'number':hex(self.latest if tag=='latest' else self.final if tag=='finalized' else 100),'timestamp':hex(100000)}
  if method=='eth_getBalance':return hex(self.physical)
  if method=='eth_getCode':return CODE
  if method=='debug_traceTransaction':
   opt=params[1]
   if opt['tracer']=='callTracer':return self.trace
   return self.diff if opt.get('tracerConfig',{}).get('diffMode') else self.pre
  if method=='eth_call':
   if len(params)==3:
    if self.unsupported_override:raise RuntimeError('State overrides unsupported')
    data=params[0]['data'];st=dict(self.after);st.update(params[2].get(TOKEN,{}).get('stateDiff',{}))
    slot=SSUPPLY if data=='0x18160ddd' else SOWNER if data.endswith(OWNER[2:].rjust(64,'0')) else SDEAD
    return st[slot]
   c=FakeCast();data=params[0]['data'];sig=lambda name:c.run(['sig',name]);target=params[0]['to']
   getters={'buybackReserve()':self.reserve,'accountedQuote()':100*10**18,'moduleAddress(uint8)':int(PH,16),'kernel()':int(KH,16),'ringCount()':len(self.spends),'cohortReserveSnapshot()':self.reserve,'lastSuccessfulBuybackAt()':self.last}
   for name,v in getters.items():
    if data.startswith(sig(name)):return word(v)
   if data.startswith(sig('spendAt(uint8)')):
    i=int(data[10:],16);at,amount=self.spends[i];return word(at)+f'{amount:064x}'
  raise RuntimeError('Unsupported fixture RPC')
class Tests(unittest.TestCase):
 def setUp(self):
  self.now=100000;self.rpc=FakeRPC();self.cast=FakeCast();pins=dict(codeHash=self.cast.code_hash(CODE),implementation=TOKEN,implementationCodeHash=self.cast.code_hash(CODE));self.config=dict(origin='http://127.0.0.1:4173',confirmations=12,token=pins,portal=dict(pins,implementation=PORTAL))
  self.path=':memory:';self.s=self.make();self.session=self.login()
 def tearDown(self):self.s.db.close()
 def make(self,path=':memory:',config=None):return Service(path,config or self.config,self.rpc,self.cast,lambda a,m,sig:sig=='TEST_VALID' and a==OWNER,lambda:self.now)
 def login(self):c=self.s.auth.challenge(OWNER);return self.s.auth.login(c['nonce'],'TEST_VALID')
 def submit(self,kind='BUYBACK'):return self.s.submit(self.session,kind,H)
 def test_nonce_domain_chain_and_scope(self):
  c=self.s.auth.challenge(OWNER);self.assertIn(self.config['origin'],c['message']);self.assertIn('Chain ID: 56',c['message']);self.assertIn(TOKEN,c['message']);self.assertIn('no spending authorization',c['message'])
 def test_signed_nonce_consumed_and_replay_rejected(self):
  c=self.s.auth.challenge(OWNER);self.s.auth.login(c['nonce'],'TEST_VALID')
  with self.assertRaises(Unauthorized):self.s.auth.login(c['nonce'],'TEST_VALID')
 def test_expiring_nonce_session_and_bad_signature(self):
  c=self.s.auth.challenge(OWNER)
  with self.assertRaises(Unauthorized):self.s.auth.login(c['nonce'],'BAD')
  self.now+=301
  with self.assertRaises(Unauthorized):self.s.auth.login(c['nonce'],'TEST_VALID')
  self.now+=600
  with self.assertRaises(Unauthorized):self.s.auth.require(self.session)
 def test_wrong_wallet_unauthorized_submission_no_rpc(self):
  with self.assertRaises(Unauthorized):self.s.auth.challenge(KH)
  with self.assertRaises(Unauthorized):self.s.submit(None,'BUYBACK',H)
  self.assertFalse(self.rpc.calls)
 def test_native_purchase_exact_values_no_manual_amounts(self):
  r=self.submit();self.assertEqual(r['status'],'Verified');o=r['observation'];self.assertEqual(o['bnbSpentWei'],str(10**17));self.assertEqual(o['tokensPurchasedBaseUnits'],'1000');self.assertEqual(o['funding'],'OWNER_FUNDED');self.assertEqual(o['treasuryReserveDebitWei'],'0');self.assertEqual(self.rpc.reserve,15*10**17)
 def test_refunds_net_spend_and_failed_subtree_ignored(self):
  self.rpc.trace['calls']=[dict(type='CALL',**{'from':PORTAL,'to':OWNER},value=hex(10**16)),dict(type='CALL',**{'from':PORTAL,'to':OWNER},value=hex(10**17),error='reverted')]
  self.assertEqual(self.submit()['observation']['bnbSpentWei'],str(9*10**16))
 def test_duplicate_submission_never_double_counts(self):
  self.submit()
  with self.assertRaises(Rejected):self.submit()
  self.assertEqual(self.s.public()['totals']['tokensPurchasedBaseUnits'],'1000')
 def test_invalid_tx_hash(self):
  for h in ['garbage','0x'+'0'*64,H+'00']:
   with self.assertRaises(ValueError):self.s.submit(self.session,'BUYBACK',h)
 def test_wrong_network(self):self.rpc.chain=1;self.assertEqual(self.submit()['status'],'Rejected')
 def test_wrong_sender(self):self.rpc.tx['from']=KH;self.assertEqual(self.submit()['status'],'Rejected')
 def test_wrong_purchase_token(self):self.rpc.tx['input']=self.rpc.tx['input'].replace(TOKEN[2:],KH[2:]);self.assertEqual(self.submit()['status'],'Rejected')
 def test_wrong_purchase_recipient(self):self.rpc.tx['to']=KH;self.rpc.receipt['to']=KH;self.assertEqual(self.submit()['status'],'Rejected')
 def test_failed_tx(self):self.rpc.fail=True;self.assertEqual(self.submit()['status'],'Rejected')
 def test_missing_confirmations_pending(self):self.rpc.latest=105;self.assertEqual(self.submit()['status'],'Pending')
 def test_unfinalized_pending(self):self.rpc.final=99;self.assertEqual(self.submit()['status'],'Pending')
 def test_runtime_mismatch_rejected(self):self.config['token']['codeHash']='0x'+'f'*64;self.assertEqual(self.submit()['status'],'Rejected')
 def test_identity_not_invented(self):self.config['token']['codeHash']=None;self.assertEqual(self.submit()['status'],'Pending')
 def test_native_burn_requires_exact_tx_supply_delta(self):
  self.rpc=FakeRPC('BURN',native=True);self.s.v.rpc=self.rpc;o=self.submit('BURN')['observation'];self.assertEqual(o['nativeBurnedBaseUnits'],'1000');self.assertEqual(o['deadTokensBaseUnits'],'0')
 def test_dead_transfer_never_reports_native_burn(self):
  self.rpc=FakeRPC('BURN');self.s.v.rpc=self.rpc;o=self.submit('BURN')['observation'];self.assertEqual(o['deadTokensBaseUnits'],'1000');self.assertEqual(o['nativeBurnedBaseUnits'],'0')
 def test_wrong_dead_recipient(self):
  self.rpc=FakeRPC('BURN');self.s.v.rpc=self.rpc;self.rpc.tx['input']='0xa9059cbb'+KH[2:].rjust(64,'0')+f'{1000:064x}';self.rpc.trace['input']=self.rpc.tx['input'];self.assertEqual(self.submit('BURN')['status'],'Rejected')
 def test_successful_call_without_supply_reduction_rejected(self):
  self.rpc=FakeRPC('BURN',native=True);self.s.v.rpc=self.rpc;self.rpc.diff['post'][TOKEN]['storage'][SSUPPLY]=word(10**9);self.assertEqual(self.submit('BURN')['status'],'Rejected')
 def test_block_deltas_not_used_when_state_override_unavailable(self):self.rpc.unsupported_override=True;self.assertEqual(self.submit()['status'],'Pending')
 def test_event_without_actual_balance_delta_rejected(self):self.rpc.diff['post'][TOKEN]['storage'][SOWNER]=word(0);self.assertEqual(self.submit()['status'],'Rejected')
 def test_restart_reverification_and_original_proof_retained(self):
  fd,path=tempfile.mkstemp(dir=os.environ['COMPD_TEST_TEMP']);os.close(fd)
  try:
   self.s.db.close();self.s=self.make(path);self.session=self.login();self.submit();self.s.db.close();self.s=self.make(path);self.assertEqual(self.s.record(H)['status'],'Pending');self.s.verify_record(H);self.assertEqual(self.s.record(H)['status'],'Verified');self.assertEqual(self.s.db.execute('SELECT count(*) FROM attempts').fetchone()[0],2)
  finally:self.s.db.close();os.remove(path);self.s=self.make()
 def test_config_domain_change_invalidates_old_nonce_and_session(self):
  fd,path=tempfile.mkstemp(dir=os.environ['COMPD_TEST_TEMP']);os.close(fd)
  try:
   self.s.db.close();self.s=self.make(path);old=self.login();c=self.s.auth.challenge(OWNER);self.s.db.close();self.s=self.make(path,dict(self.config,origin='https://compd.example'))
   with self.assertRaises(Unauthorized):self.s.auth.require(old)
   with self.assertRaises(Unauthorized):self.s.auth.login(c['nonce'],'TEST_VALID')
  finally:self.s.db.close();os.remove(path);self.s=self.make()
 def test_reorg_removes_verified_total(self):
  self.submit();self.rpc.reorg=True;self.s.refresh(True);self.assertEqual(self.s.record(H)['status'],'Rejected');self.assertEqual(self.s.public()['totals']['bnbSpentWei'],'0')
 def test_environment_failure_pending_and_no_credentials(self):self.rpc.rpc_failure=True;r=self.submit();self.assertEqual(r['status'],'Pending');self.assertNotIn('SECRET_TEST',json.dumps(r))
 def test_treasury_custody_not_personal_wallet_debit(self):
  self.config['kernel']={'address':KH,'codeHash':self.cast.code_hash(CODE)};self.config['policy']={'address':PH,'codeHash':self.cast.code_hash(CODE)};self.submit();p=self.s.public();self.assertEqual(p['treasury']['availableReserveWei'],str(15*10**17));self.assertEqual(p['treasury']['policyMaximumWei'],str(3*10**17));self.assertEqual(p['treasury']['maximumPermittedBuybackWei'],'0');self.assertEqual(p['totals']['treasuryReserveDebitWei'],'0')
 def test_policy_cooldown_and_daily_cap_observed(self):
  self.config['kernel']={'address':KH,'codeHash':self.cast.code_hash(CODE)};self.config['policy']={'address':PH,'codeHash':self.cast.code_hash(CODE)};self.rpc.last=99999;self.rpc.spends=[(99999,10**17)];self.assertEqual(self.s.v.treasury()['policyMaximumWei'],'0');self.rpc.last=70000;self.rpc.spends=[(70000,6*10**17)];self.assertEqual(self.s.v.treasury()['policyMaximumWei'],'0')
 def test_treasury_tx_not_relabelled_as_owner_funded(self):
  self.config['kernel']={'address':KH,'codeHash':self.cast.code_hash(CODE)};self.rpc.tx['to']=KH;self.rpc.receipt['to']=KH;r=self.submit();self.assertEqual(r['status'],'Pending');self.assertIsNone(r['observation'])
 def test_canonical_crypto_verifier_rejects_wrong_signer_without_signing(self):
  binary=os.environ['COMPD_CAST_BIN'];verify=SignatureVerifier(binary)
  self.assertFalse(verify(OWNER,'COMPD Manual sign-in','0x'+f'{1:064x}'+f'{1:064x}'+'1b'))
 def test_wrong_token_event_not_credited(self):self.rpc.receipt['logs'][0]['address']=KH;self.assertEqual(self.submit()['status'],'Rejected')
 def test_unreviewed_delegate_is_pending(self):
  self.rpc.trace['calls']=[dict(type='DELEGATECALL',to=KH)];self.assertEqual(self.submit()['status'],'Pending')
 def test_kernel_physical_custody_deficit_not_displayed_as_available(self):
  self.config['kernel']={'address':KH,'codeHash':self.cast.code_hash(CODE)};self.rpc.physical=0
  with self.assertRaises(Pending):self.s.v.treasury()
 def test_new_storage_slot_has_zero_transaction_prestate(self):
  self.rpc=FakeRPC('BURN');self.s.v.rpc=self.rpc;del self.rpc.pre[TOKEN]['storage'][SDEAD];del self.rpc.diff['pre'][TOKEN]['storage'][SDEAD]
  self.assertEqual(self.submit('BURN')['observation']['deadTokensBaseUnits'],'1000')
 def test_manual_rpc_cannot_sign_or_send(self):
  for method in ('eth_sendTransaction','eth_sendRawTransaction','eth_sign','personal_sign'):
   with self.assertRaises(ValueError):ManualRPC(None).call(method,[])
 def test_nonce_attempt_bound(self):
  c=self.s.auth.challenge(OWNER)
  for _ in range(6):
   with self.assertRaises(Unauthorized):self.s.auth.login(c['nonce'],'INVALID')
if __name__=='__main__':unittest.main()
