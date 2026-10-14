import unittest
from chainlink_observer import prices,market_snapshot

class RPC:
    def __init__(self):self.calls=[];self.updated=1000;self.chain='0x38';self.reorg=False;self.headers=0
    def call(self,m,p):
        self.calls.append(m)
        if m=='eth_chainId':return self.chain
        if m=='eth_getBlockByNumber':
            self.headers+=1
            return dict(number='0x1',timestamp=hex(1030),hash='0x'+('2' if self.reorg and self.headers>1 else '1')*64)
        if m=='eth_getCode':return '0x01'
        if m=='eth_call':
            values=[8] if p[0]['data']=='0x313ce567' else [1,12345678900,1000,self.updated,1]
            return '0x'+''.join(f'{x:064x}' for x in values)
        raise AssertionError(m)
class Tests(unittest.TestCase):
    def test_fresh_references_never_enable(self):
        r=RPC();s=market_snapshot(r);self.assertEqual(len(s['xstocks']['prices']),6)
        self.assertTrue(all(x['status']=='FRESH_REFERENCE_ONLY' and x['executionEnabled'] is False for x in s['xstocks']['prices']))
        self.assertFalse(any('send' in x for x in r.calls));self.assertIsNone(s['activeRunCount'])
    def test_stale_and_future(self):
        r=RPC();r.updated=900;self.assertTrue(all(x['status']=='STALE_PRICE' for x in prices(r,'0x1',1030)))
        r.updated=1031;self.assertTrue(all(x['priceUSD'] is None for x in prices(r,'0x1',1030)))
    def test_wrong_chain_reorg(self):
        r=RPC();r.chain='0x1'
        with self.assertRaises(ValueError):market_snapshot(r)
        r=RPC();r.reorg=True
        with self.assertRaises(ValueError):market_snapshot(r)
    def test_outage_unavailable_not_zero(self):
        class Broken:
            def call(self,*args):raise RuntimeError('offline')
        self.assertTrue(all(x['priceUSD'] is None and x['status']=='PRICE_UNAVAILABLE' for x in prices(Broken(),'0x1',1030)))

if __name__=='__main__':unittest.main()
