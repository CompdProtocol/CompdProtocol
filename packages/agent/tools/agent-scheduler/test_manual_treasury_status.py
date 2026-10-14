"""Unqualified local executor never enables treasury spending or invents a reserve debit."""
import unittest
import test_manual_buyback as fixture
from manual_buyback import Service,Pending
class ManualTreasuryStatusTests(unittest.TestCase):
 def setUp(self):
  self.rpc=fixture.FakeRPC();self.cast=fixture.FakeCast()
  pins=dict(codeHash=self.cast.code_hash(fixture.CODE),implementation=fixture.TOKEN,implementationCodeHash=self.cast.code_hash(fixture.CODE))
  self.config=dict(origin='http://127.0.0.1:4173',confirmations=12,token=pins,portal=dict(pins,implementation=fixture.PORTAL),kernel=dict(address=fixture.KH,codeHash=pins['codeHash']),policy=dict(address=fixture.PH,codeHash=pins['codeHash']))
  self.service=Service(':memory:',self.config,self.rpc,self.cast,lambda *a:False,lambda:100000)
 def tearDown(self):self.service.db.close()
 def test_nonburn_executor_does_not_self_approve_live_route(self):
  result=self.service.v.treasury()
  self.assertEqual(result['execution'],'BLOCKED_ROUTE_DISPOSAL_AND_GRAPH_QUALIFICATION')
  self.assertEqual(result['disposalMode'],'FIXED_DEAD_ADDRESS_TRANSFER_NOT_NATIVE_BURN')
  self.assertEqual(result['maximumPermittedBuybackWei'],'0')
  self.assertEqual(result['suggestedManualBuybackWei'],'0')
  self.assertEqual(result['policyMaximumWei'],str(3*10**17))
 def test_unqualified_treasury_receipt_not_owner_funded_or_credited(self):
  self.rpc.tx['to']=fixture.PH;self.rpc.receipt['to']=fixture.PH
  with self.assertRaises(Pending):self.service.v.verify('BUYBACK',fixture.H)
  self.assertEqual(self.service.db.execute('SELECT count(*) FROM records').fetchone()[0],0)
 def test_no_token_or_route_configuration_produces_no_live_values(self):
  self.service.v.c.pop('kernel');r=self.service.v.treasury()
  self.assertIsNone(r['availableReserveWei']);self.assertIsNone(r['maximumPermittedBuybackWei'])
