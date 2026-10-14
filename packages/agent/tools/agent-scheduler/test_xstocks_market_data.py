import unittest
from xstocks_market_data import observation, session_open, timestamp, AlpacaReader
from xstocks_agent import independent_observations, DEFAULT_POLICY

class MarketTests(unittest.TestCase):
    def setUp(self):
        self.now=timestamp('2026-10-12T14:00:00Z')
        self.cal=[dict(date='2026-10-12',open='09:30',close='16:00')]
        self.q=dict(t='2026-10-12T14:00:00Z',bp=100,ap=100.1,bs=10,**{'as':10})
        self.h=dict(coverage='ALL_VENUES',halted=False,timestamp=self.q['t'])
    def read(self, **kw):
        return observation('TSLAx',kw.get('quote',self.q),kw.get('calendar',self.cal),self.now,halt=kw.get('halt',self.h))
    def test_fresh_observation_never_authorizes_execution(self):
        r=self.read();self.assertTrue(r['observationUsable']);self.assertFalse(r['executionEnabled']);self.assertFalse(r['priceSourceVerified'])
    def test_unknown_halt_blocks(self): self.assertIn('HALT_STATUS_UNKNOWN',self.read(halt=None)['reasons'])
    def test_halt_blocks(self): self.assertIn('TRADING_HALTED',self.read(halt={**self.h,'halted':True})['reasons'])
    def test_stale_halt_blocks(self): self.assertIn('HALT_STATUS_STALE',self.read(halt={**self.h,'timestamp':'2026-10-12T13:58:59Z'})['reasons'])
    def test_stale_quote_blocks(self): self.assertIn('STALE_OR_FUTURE_PRICE',self.read(quote={**self.q,'t':'2026-10-12T13:58:59Z'})['reasons'])
    def test_future_quote_blocks(self): self.assertIn('STALE_OR_FUTURE_PRICE',self.read(quote={**self.q,'t':'2026-10-12T14:00:01Z'})['reasons'])
    def test_holiday_closed(self): self.assertIn('MARKET_CLOSED',self.read(calendar=[])['reasons'])
    def test_early_close_boundary(self):
        c=[dict(date='2026-11-27',open='09:30',close='13:00')]
        self.assertTrue(session_open(c,timestamp('2026-11-27T17:59:59Z')))
        self.assertFalse(session_open(c,timestamp('2026-11-27T18:00:00Z')))
    def test_dst(self):
        c=[dict(date='2026-11-02',open='09:30',close='16:00')]
        self.assertFalse(session_open(c,timestamp('2026-11-02T14:29:59Z')))
        self.assertTrue(session_open(c,timestamp('2026-11-02T14:30:00Z')))
    def test_bad_quote_and_spread(self):
        self.assertFalse(self.read(quote={**self.q,'bp':'NaN'})['observationUsable'])
        self.assertIn('WIDE_SPREAD',self.read(quote={**self.q,'ap':110})['reasons'])
    def test_reader_integration_all_five_and_no_halt_guess(self):
        r=AlpacaReader(lambda url:self.cal if '/calendar?' in url else {'quotes':{s:self.q for s in ('NVDA','TSLA','AMZN','AAPL','SPY')}})
        result=independent_observations(self.now,r)
        self.assertEqual(len(result),5)
        self.assertTrue(all('HALT_STATUS_UNKNOWN' in v['reasons'] for v in result.values()))
    def test_outage_no_retries(self):
        calls=[]
        def unavailable(url): calls.append(url);raise ValueError('secret must not escape')
        r=AlpacaReader(unavailable).read(self.now)
        self.assertEqual(len(calls),1);self.assertNotIn('secret',str(r))
    def test_sizing_only(self):
        capital=10**17
        self.assertEqual(capital*1000//10000,10**16)
        self.assertEqual(capital*DEFAULT_POLICY['allocationBps']//10000,5*10**15)
        self.assertEqual(capital*3000//10000,3*10**16)

if __name__=='__main__': unittest.main()
