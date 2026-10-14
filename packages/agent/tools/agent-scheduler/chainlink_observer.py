"""Pinned BNB Chain reference prices. Read-only; never authorizes trading."""
from decimal import Decimal
from market_session import qualify

FEEDS = {
 'NVDAx':'0xea5c2Cbb5cD57daC24E26180b19a929F3E9699B8',
 'TSLAx':'0xEEA2ae9c074E87596A85ABE698B2Afebc9B57893',
 'AMZNx':'0x51d08ca89d3e8c12535BA8AEd33cDf2557ab5b2a',
 'AAPLx':'0xb7Ed5bE7977d61E83534230f3256C021e0fae0B6',
 'SPYx':'0xb24D1DeE5F9a3f761D286B56d2bC44CE1D02DF7e',
 'BNB':'0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE'}

def prices(rpc, block, now):
    result=[]
    for symbol, feed in FEEDS.items():
        row=dict(symbol=symbol,feed=feed,priceUSD=None,updatedAt=None,ageSeconds=None,
                 status='PRICE_UNAVAILABLE',executionEnabled=False)
        try:
            if rpc.call('eth_getCode',[feed,block])=='0x': raise ValueError('Missing feed')
            d=rpc.call('eth_call',[{'to':feed,'data':'0x313ce567'},block])
            r=rpc.call('eth_call',[{'to':feed,'data':'0xfeaf968c'},block])
            if len(d)!=66 or len(r)!=322: raise ValueError('Malformed ABI')
            decimals=int(d,16);round_id,answer,_,updated,answered=[int(r[i:i+64],16) for i in range(2,322,64)]
            if decimals>18 or not round_id or not 0<answer<2**255 or answered<round_id or not 0<updated<=now:raise ValueError('Invalid round')
            age=now-updated
            row.update(priceUSD=format(Decimal(answer)/Decimal(10**decimals),'f'),updatedAt=updated,ageSeconds=age,
                       status='FRESH_REFERENCE_ONLY' if age<=60 else 'STALE_PRICE',roundId=str(round_id))
        except Exception: pass
        row['heartbeatSeconds']=27 if symbol=='BNB' else 86400
        row['deviationThresholdPercent']='0.1' if symbol=='BNB' else '0.5'
        row['heartbeatBasis']='PRESERVED_CHAINLINK_CATALOG_NOT_MAXIMUM_TRADING_PRICE_AGE'
        row['qualification']=qualify(symbol,row['status'],now)
        result.append(row)
    return result

def market_snapshot(rpc):
    if int(rpc.call('eth_chainId',[]),16)!=56:raise ValueError('Wrong chain')
    b=rpc.call('eth_getBlockByNumber',['latest',False]);block=b['number'];now=int(b['timestamp'],16)
    rows=prices(rpc,block,now)
    if rpc.call('eth_getBlockByNumber',[block,False])['hash']!=b['hash']:raise ValueError('Reorg')
    return dict(publicSnapshot=dict(chainId=56,blockNumber=block,blockHash=b['hash'],blockTimestamp=now),
                xstocks=dict(mode='OBSERVE_ONLY',prices=rows,blockers=['LIVE_TRADING_NOT_AUTHORIZED','MARKET_SESSION_AND_HALT_NOT_VERIFIED','ROUTES_NOT_PRODUCTION_QUALIFIED']),
                agentTransactions=[],activeRunCount=None)

if __name__=='__main__':
    import argparse,os,time
    from public_status import PublicRPC,serve_public
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serve',type=int,default=4174);p.add_argument('--state',default='agent-observations.sqlite');a=p.parse_args()
    url=os.environ.get('BSC_RPC_URL')
    if not url:p.error('BSC_RPC_URL required')
    class Observer:
        def __init__(self):
            from agent_observation import ObservationHistory
            self.rpc=PublicRPC(url);self.cached=None;self.at=0;self.history=ObservationHistory(a.state)
        def status(self,now):
            if self.cached is None or now-self.at>=30:
                self.cached=market_snapshot(self.rpc);self.at=now
            return self.history.attach(self.cached,now)
    serve_public(Observer(),a.serve)
