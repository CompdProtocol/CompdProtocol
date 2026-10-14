import unittest
from datetime import datetime
from market_session import session,qualify
from unittest.mock import patch

def t(value):return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
class Tests(unittest.TestCase):
 def test_regular_open_close(self):
  self.assertEqual(session('TSLAx',t('2026-10-12T13:29:59Z'))['state'],'CLOSED')
  self.assertEqual(session('TSLAx',t('2026-10-12T13:30:00Z'))['state'],'OPEN')
  self.assertEqual(session('TSLAx',t('2026-10-12T20:00:00Z'))['state'],'CLOSED')
 def test_weekends(self):
  for d in ('2026-10-10T15:00:00Z','2026-10-11T15:00:00Z'):self.assertEqual(session('NVDAx',t(d))['reason'],'WEEKEND')
 def test_holidays(self):
  for d in ('2026-04-03','2026-07-03','2026-11-26','2026-12-25'):self.assertEqual(session('AAPLx',t(d+'T15:00:00Z'))['reason'],'EXCHANGE_HOLIDAY')
 def test_early_close(self):
  for d in ('2026-11-27','2026-12-24'):
   self.assertEqual(session('SPYx',t(d+'T17:59:59Z'))['state'],'OPEN')
   self.assertEqual(session('SPYx',t(d+'T18:00:00Z'))['reason'],'AFTER_EARLY_CLOSE')
 def test_dst_spring_and_fall(self):
  for date,before,opened in [('2026-03-06','14:29:59','14:30:00'),('2026-03-09','13:29:59','13:30:00'),('2026-10-30','13:29:59','13:30:00'),('2026-11-02','14:29:59','14:30:00')]:
   self.assertEqual(session('AMZNx',t(date+'T'+before+'Z'))['state'],'CLOSED')
   self.assertEqual(session('AMZNx',t(date+'T'+opened+'Z'))['state'],'OPEN')
 def test_unknown_inputs_and_year(self):
  self.assertEqual(session('TSLAx',None)['state'],'UNKNOWN')
  self.assertEqual(session('TSLAx',t('2027-01-04T15:00:00Z'))['reason'],'CALENDAR_YEAR_NOT_COVERED')
  self.assertEqual(session('TSLAx',t('2026-10-12T15:00:00Z'),'not-existing-calendar.json')['state'],'UNKNOWN')
  with patch('market_session.ZoneInfo',side_effect=KeyError()):self.assertEqual(session('TSLAx',t('2026-10-12T15:00:00Z'))['state'],'UNKNOWN')
 def test_open_fresh_never_grants_halt_or_trading_clearance(self):
  q=qualify('TSLAx','FRESH_REFERENCE_ONLY',t('2026-10-12T15:00:00Z'))
  self.assertTrue(q['referenceUsable']);self.assertTrue(q['scheduledSessionUsable']);self.assertEqual(q['session']['halt'],'UNKNOWN');self.assertFalse(q['tradingReady']);self.assertIn('HALT_STATUS_UNKNOWN',q['blockers'])
 def test_stale_closed_and_unavailable(self):
  q=qualify('TSLAx','STALE_PRICE',t('2026-10-11T15:00:00Z'));self.assertIn('STALE_PRICE',q['blockers']);self.assertIn('MARKET_CLOSED',q['blockers']);self.assertFalse(q['referenceUsable'])
  self.assertIn('PRICE_UNAVAILABLE',qualify('TSLAx','PRICE_UNAVAILABLE',t('2026-10-12T15:00:00Z'))['blockers'])

if __name__=='__main__':unittest.main()
