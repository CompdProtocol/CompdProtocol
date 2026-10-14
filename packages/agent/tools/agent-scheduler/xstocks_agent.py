"""Five-asset dry-run policy. No signer, swap calldata, or production route approval.

Candidate token identities are observations, not an execution allowlist. Until
fixed adapters, independent prices and settlement finality are qualified, every
production asset remains disabled. Injected markets/routes are test fixtures.
"""
import json
from agent_lifecycle import AutoLifecycle, digest
from agent_scheduler import CYCLE, address, hash32

ASSETS = ('NVDAx', 'TSLAx', 'AMZNx', 'AAPLx', 'SPYx')
DEFAULT_POLICY = dict(allocationBps=500, momentumBps=100, takeProfitBps=600,
                      maxPriceAgeSeconds=60, deadlineSeconds=60, slippageBps=50)

def independent_observations(now, reader=None):
    """Observe-only provider integration; never upgrades route qualification."""
    from xstocks_market_data import AlpacaReader
    return (reader or AlpacaReader()).read(now)

def check_policy(policy):
    if set(policy) != set(DEFAULT_POLICY): raise ValueError('Explicit policy schema required')
    bounds = dict(allocationBps=(1,1000), momentumBps=(1,1000), takeProfitBps=(1,10000),
                  maxPriceAgeSeconds=(1,60), deadlineSeconds=(1,60), slippageBps=(1,100))
    for key, (lo,hi) in bounds.items():
        if type(policy[key]) is not int or not lo <= policy[key] <= hi: raise ValueError(key)
    return dict(policy)

def market_check(m, snap, p):
    """Input contract for a future pinned market reader; fixtures are not live data."""
    if not m: return 'MARKET_DATA_UNAVAILABLE'
    if m.get('blockHash') != snap['blockHash']: return 'QUOTE_BLOCK_MISMATCH'
    for key in ('priceWei','referenceWei','quoteOut','minimumOut','liquidityWei','timestamp','referenceTimestamp','validUntil'):
        if type(m.get(key)) is not int or m[key] < 0: return 'MALFORMED_MARKET_DATA'
    now=snap['timestamp']
    if not 0 <= now-m['timestamp'] <= p['maxPriceAgeSeconds']: return 'STALE_PRICE'
    if not 0 < now-m['referenceTimestamp'] <= CYCLE: return 'INVALID_REFERENCE_PRICE'
    if not now < m['validUntil'] <= now+p['deadlineSeconds']: return 'INVALID_DEADLINE'
    if m.get('marketOpen') is not True or m.get('calendarVerified') is not True: return 'MARKET_CLOSED_OR_CALENDAR_UNVERIFIED'
    if m.get('priceSourceVerified') is not True or m.get('quoteVerified') is not True: return 'PRICE_OR_QUOTE_UNVERIFIED'
    if min(m['priceWei'],m['referenceWei'],m['quoteOut'],m['minimumOut']) <= 0: return 'INVALID_QUOTE'
    if m['minimumOut'] < m['quoteOut']*(10000-p['slippageBps'])//10000 or m['minimumOut'] > m['quoteOut']: return 'SLIPPAGE_LIMIT'
    return None

def decision(symbol, snap, m, route, policy, position=None):
    if symbol not in ASSETS: raise ValueError('Unauthorized trading target')
    p=check_policy(policy)
    if not route or route.get('qualification') != 'TEST_FIXTURE': return None,'ROUTE_NOT_QUALIFIED'
    # This implementation deliberately cannot turn a configuration flag into
    # approval of a production route. Fixture decisions never authorize signing.
    for key in ('adapter','router','token','settlementToken'): address(route[key])
    hash32(route['adapterCodeHash'])
    if route.get('symbol') != symbol: return None,'ROUTE_ASSET_MISMATCH'
    reason=market_check(m,snap,p)
    if reason: return None,reason
    if position:
        if position['principal'] <= 0 or position['entryPriceWei'] <= 0: raise ValueError('Invalid position')
        change=(m['priceWei']-position['entryPriceWei'])*10000//position['entryPriceWei']
        if change <= -300 or change >= p['takeProfitBps']:
            return dict(method='requestExit',runId=position['id'],reference=digest('XSTOCKS_EXIT',symbol,position['id'])),'FIXTURE_EXIT_SIGNAL_NOT_GUARANTEED_STOP'
        return None,'HOLD'
    if snap['lifecycle'] != 0: return None,'PAUSED_NO_ENTRY'
    if snap['halted'] or snap['risk']: return None,'ONCHAIN_RISK_BREAKER'
    if snap['runCount'] >= 3: return None,'POSITION_CAP'
    if m['priceWei']*10000 < m['referenceWei']*(10000+p['momentumBps']): return None,'NO_ENTRY_SIGNAL'
    amount=min(snap['capital']*p['allocationBps']//10000,snap['maxPrincipalWei'],snap['accounted'],
               snap['capital']-snap['active'],max(0,snap['capital']*3000//10000-snap['active']))
    if amount <= 0: return None,'INSUFFICIENT_CAPITAL'
    if m.get('amountInWei') != amount: return None,'QUOTE_SIZE_MISMATCH'
    if m['liquidityWei'] < amount*100: return None,'INSUFFICIENT_LIQUIDITY'
    return dict(method='startRun',adapter=route['adapter'],amountWei=str(amount)), 'FIXTURE_ENTRY_SIGNAL'

class XStocksLifecycle(AutoLifecycle):
    """Reuses scheduler simulation/retry/confirmation and canonical settlement.

    All production routes are disabled. A fixture provider is injectable only
    with fixture_mode=True and a non-executing scheduler, for local testing.
    """
    def __init__(self,scheduler,policy=None,*,fixture_mode=False,markets=None,routes=None):
        if scheduler.execute: raise ValueError('Live xStocks execution disabled')
        self.approval_reference='DRY_RUN_EXPERIMENTAL_XSTOCKS_POLICY_NOT_LIVE_APPROVAL'
        self.xpolicy=check_policy(policy or DEFAULT_POLICY)
        if (markets or routes) and not fixture_mode: raise ValueError('Unqualified market/route injection')
        self.fixture_mode=fixture_mode; self.markets=markets; self.routes=routes or {}
        if set(self.routes)-set(ASSETS): raise ValueError('Unauthorized asset route')
        for route in self.routes.values():
            if route.get('qualification') != 'TEST_FIXTURE': raise ValueError('Production route unavailable')
        super().__init__(scheduler)
        commitment=digest('COMPD_XSTOCKS_POLICY_V1',self.xpolicy,self.routes,fixture_mode)
        old=scheduler.db.execute("SELECT value FROM metadata WHERE key='xstocks_policy'").fetchone()
        if old and old[0] != commitment: raise ValueError('Policy changed; reconcile persisted plans')
        scheduler.db.execute("INSERT OR IGNORE INTO metadata VALUES ('xstocks_policy',?)",(commitment,));scheduler.db.commit()

    def decide(self,snap,view,slot):
        if snap['lifecycle'] in (3,4) or not snap['historyComplete']: return super().decide(snap,view,slot)
        if not self.fixture_mode: return None,'XSTOCKS_ROUTES_DISABLED'
        # Existing exit/collect/close semantics are retained; a loss is never
        # written off from a quote or a fabricated terminal state.
        snap={**snap,'maxPrincipalWei':self.s.c['maxPrincipalWei']}
        for run in snap['runs']:
            matches=[symbol for symbol,r in self.routes.items() if address(r['adapter'])==address(run['adapter'])]
            if len(matches)!=1: return None,'POSITION_ROUTE_UNKNOWN'
            if run['state'] != 1:
                route=self.routes[matches[0]]
                self.policy=dict(adapter=route['adapter'],adapterCodeHash=route['adapterCodeHash'])
                try:return super().decide(snap,view,slot,allow_entry=False)
                finally:self.policy=None
            symbol=matches[0];m=self.markets(symbol,snap,run)
            if not m or type(m.get('entryPriceWei')) is not int: return None,'ENTRY_PRICE_EVIDENCE_MISSING'
            action,reason=decision(symbol,snap,m,self.routes[symbol],self.xpolicy,{**run,'entryPriceWei':m['entryPriceWei']})
            if action:return action,reason
        for symbol in ASSETS:
            route=self.routes.get(symbol)
            action,reason=decision(symbol,snap,self.markets(symbol,snap,None) if route else None,route,self.xpolicy)
            self.record(slot,'ASSET_EVALUATED',dict(asset=symbol,reason=reason,scope='TEST_FIXTURE'))
            if action:
                adapter=action['adapter']
                if view.one(self.s.c['executor'],'isApprovedStrategy(address)',(adapter,)) != 1:return None,'ADAPTER_NOT_ADMITTED'
                if self.s.cast.code_hash(self.s.rpc.call('eth_getCode',[adapter,snap['block']])) != hash32(route['adapterCodeHash']):return None,'ADAPTER_CODE_CHANGED'
                rid=int(digest('COMPD_XSTOCKS_RUN',self.s.scope,symbol,slot,self.xpolicy),16)
                if view.run(rid)['state'] != 0:return None,'DUPLICATE_CYCLE_RUN'
                return {**action,'runId':rid,'reference':digest('COMPD_XSTOCKS_ALLOCATION',self.s.scope,rid)},reason
        return None,'NO_ELIGIBLE_ENTRY'

    def observe_launch(self):
        block=self.s.preflight()
        self.s.db.execute('BEGIN IMMEDIATE')
        try:
            snap,_=self.snapshot(block)
            result=dict(status='OBSERVE_ONLY',blockHash=snap['blockHash'],timestamp=snap['timestamp'],
                        assets=list(ASSETS),liveEnabled=False,positions=snap['runs'])
            self.record(snap['timestamp']//CYCLE,'LAUNCH_OBSERVE_ONLY',result);self.s.db.commit();return result
        except BaseException:self.s.db.rollback();raise

    def public_snapshot(self):
        rows=self.s.db.execute('SELECT cycle,stage,evidence FROM auto_records ORDER BY id DESC LIMIT 20').fetchall()
        return dict(mode='DRY_RUN_ONLY',liveEnabled=False,assets=[dict(symbol=x,status='DISABLED_ROUTE_NOT_QUALIFIED') for x in ASSETS],
                    evaluations=[dict(cycle=x[0],stage=x[1],scope='DRY_RUN',evidence=json.loads(x[2])) for x in rows],
                    positions=None,unrealizedPnlWei=None,qualification='NOT_VERIFIED_EXECUTABLE_ROUTES')

    def tick(self,now):
        if self.fixture_mode:return super().tick(now)
        slot=int(now)//CYCLE
        prior=self.s.db.execute("SELECT evidence FROM auto_records WHERE cycle=? AND stage='EVALUATED' ORDER BY id DESC LIMIT 1",(slot,)).fetchone()
        if prior:
            observed=json.loads(prior[0]);header=self.s.rpc.call('eth_getBlockByNumber',[observed['block'],False])
            if not header or header['hash'].lower()!=observed['blockHash']:return {'status':'REORG_REQUIRES_REVIEW','cycle':slot}
            return {'status':'ALREADY_EVALUATED_OBSERVE_ONLY','cycle':slot}
        return super().tick(now)
