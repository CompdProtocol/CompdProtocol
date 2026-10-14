import unittest, tempfile,os
from buyback_keeper import BuybackKeeper
ID='0x'+'01'*32;TX='0x'+'02'*32
class Tests(unittest.TestCase):
 def setUp(self):self.k=BuybackKeeper(':memory:')
 def tearDown(self):self.k.db.close()
 def test_automatic_plan_disabled(self):self.assertEqual(self.k.observe(ID,chain_id=56,route_verified=True,executable=True)['status'],'DISABLED_AUTOMATIC_BUYBACK_MANUAL_ONLY')
 def test_no_spending_or_submission_recording(self):
  self.k.observe(ID,chain_id=56,route_verified=True,executable=True)
  with self.assertRaises(RuntimeError):self.k.record_external_submission(ID,TX)
 def test_wrong_route_still_disabled(self):self.assertEqual(self.k.observe(ID,chain_id=56,route_verified=False,executable=True)['status'],'DISABLED_UNVERIFIED_ROUTE')
 def test_existing_confirmation_preserved(self):
  self.k.db.execute('INSERT INTO buyback_jobs VALUES (?,1,\'AWAITING_CONFIRMATION\',?)',(ID,TX));self.k.db.commit()
  result=self.k.observe(ID,chain_id=56,route_verified=True,executable=True,receipt=dict(identityVerified=True,finalityVerified=True,transactionHash=TX,success=True));self.assertEqual(result['status'],'ALREADY_CONFIRMED')
 def test_restart_preserves_prior_pending_without_resubmit(self):
  fd,path=tempfile.mkstemp(dir=os.environ['COMPD_TEST_TEMP']);os.close(fd)
  try:
   a=BuybackKeeper(path);a.db.execute('INSERT INTO buyback_jobs VALUES (?,1,\'AWAITING_CONFIRMATION\',?)',(ID,TX));a.db.commit();a.db.close();b=BuybackKeeper(path);self.assertEqual(b.observe(ID,chain_id=56,route_verified=True,executable=True)['status'],'WAIT_CONFIRMATION');b.db.close()
  finally:os.remove(path)
 def test_unverified_receipt_rejected(self):
  with self.assertRaises(ValueError):self.k.observe(ID,chain_id=56,route_verified=True,executable=True,receipt={})
if __name__=='__main__':unittest.main()
