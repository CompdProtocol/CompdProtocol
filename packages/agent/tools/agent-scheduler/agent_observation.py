"""Durable observation of the existing decision engine. No transaction runner."""
import json
import sqlite3
from xstocks_agent import ASSETS, DEFAULT_POLICY, decision
from agent_scheduler import CYCLE

class ObservationHistory:
    def __init__(self, path):
        self.db=sqlite3.connect(path)
        self.db.execute('CREATE TABLE IF NOT EXISTS observations (cycle INTEGER PRIMARY KEY, snapshot TEXT NOT NULL)')
        self.db.commit()

    def evaluate_due(self, snapshot, now):
        cycle=int(now)//CYCLE
        prior=self.db.execute('SELECT snapshot FROM observations WHERE cycle=?',(cycle,)).fetchone()
        if prior: return json.loads(prior[0])
        header=snapshot['publicSnapshot'];prices={x['symbol']:x for x in snapshot['xstocks']['prices']}
        results=[]
        for symbol in ASSETS:
            # Invoke canonical evaluator with honest missing production inputs.
            # No fixture route or synthetic capital/quote is injected to force a signal.
            action,reason=decision(symbol,{'blockHash':header['blockHash']},None,None,DEFAULT_POLICY)
            blockers=[reason,'MARKET_SESSION_AND_HALT_NOT_VERIFIED','LIQUIDITY_AND_EXECUTION_QUOTE_UNAVAILABLE','VERIFIED_TREASURY_AND_POSITION_INPUTS_UNAVAILABLE','LIVE_TRADING_NOT_AUTHORIZED']
            price=prices.get(symbol)
            if not price or price['status']=='PRICE_UNAVAILABLE':blockers.insert(0,'PRICE_UNAVAILABLE')
            elif price['status']=='STALE_PRICE':blockers.insert(0,'STALE_PRICE')
            if price:
                blockers.extend(price.get('qualification',{}).get('blockers',[]))
            blockers=list(dict.fromkeys(blockers))
            if prices.get('BNB',{}).get('status')!='FRESH_REFERENCE_ONLY':blockers.append('BNB_REFERENCE_UNAVAILABLE_OR_STALE')
            results.append(dict(market=symbol,timeframe='8_HOUR_EVALUATION_CYCLE',status='BLOCKED',decision='NO_TRADE',
                                reason=reason,blockers=blockers,confidence=None,entry=None,target=None,invalidation=None))
            if action is not None:raise ValueError('Observation unexpectedly generated an action')
        record=dict(cycle=cycle,evaluatedAt=int(now),observedBlockTimestamp=header['blockTimestamp'],blockHash=header['blockHash'],
                    scope='OBSERVATION_ONLY',engine='xstocks_agent.decision',results=results)
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO observations VALUES (?,?)',(cycle,json.dumps(record)))
            self.db.execute('DELETE FROM observations WHERE cycle NOT IN (SELECT cycle FROM observations ORDER BY cycle DESC LIMIT 20)')
        return json.loads(self.db.execute('SELECT snapshot FROM observations WHERE cycle=?',(cycle,)).fetchone()[0])

    def attach(self,snapshot,now):
        snapshot['xstocks']['latestEvaluation']=self.evaluate_due(snapshot,now)
        snapshot['xstocks']['observationHistory']=[json.loads(r[0]) for r in self.db.execute('SELECT snapshot FROM observations ORDER BY cycle DESC LIMIT 20')]
        return snapshot
