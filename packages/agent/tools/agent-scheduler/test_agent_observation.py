import unittest,tempfile,os
from pathlib import Path
from agent_observation import ObservationHistory
from agent_scheduler import CYCLE
from unittest.mock import patch

class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('COMPD_TEST_TEMP'));self.path=str(Path(self.tmp.name)/'history.sqlite');self.h=ObservationHistory(self.path)
  self.s={'publicSnapshot':dict(blockHash='0x'+'1'*64,blockTimestamp=1000),'xstocks':{'prices':[dict(symbol='TSLAx',status='STALE_PRICE')]}}
 def tearDown(self):self.h.db.close();self.tmp.cleanup()
 def test_engine_called_all_assets_and_blockers(self):
  from xstocks_agent import decision
  with patch('agent_observation.decision',wraps=decision) as engine:r=self.h.attach(self.s,1000)
  self.assertEqual(engine.call_count,5);rows=r['xstocks']['latestEvaluation']['results'];self.assertTrue(all(x['decision']=='NO_TRADE' and x['status']=='BLOCKED' and x['confidence'] is None for x in rows));self.assertIn('STALE_PRICE',rows[1]['blockers']);self.assertIn('PRICE_UNAVAILABLE',rows[0]['blockers'])
 def test_refresh_restart_cycle_idempotent(self):
  a=self.h.evaluate_due(self.s,1000);self.assertEqual(a,self.h.evaluate_due(self.s,2000));self.h.db.close();self.h=ObservationHistory(self.path);self.assertEqual(a,self.h.evaluate_due(self.s,2500));self.h.evaluate_due(self.s,CYCLE);self.assertEqual(self.h.db.execute('SELECT count(*) FROM observations').fetchone()[0],2)
 def test_bounded_history(self):
  for i in range(25):self.h.evaluate_due(self.s,i*CYCLE)
  self.assertEqual(self.h.db.execute('SELECT count(*) FROM observations').fetchone()[0],20)
 def test_unexpected_action_never_persisted(self):
  with patch('agent_observation.decision',return_value=({'method':'startRun'},'INVALID')):
   with self.assertRaises(ValueError):self.h.evaluate_due(self.s,1000)
  self.assertEqual(self.h.db.execute('SELECT count(*) FROM observations').fetchone()[0],0)

if __name__=='__main__':unittest.main()
