"""Additive read-only projection of the existing observer. No signing or activation routes."""
import argparse,json,os,time,urllib.request,re
from copy import deepcopy
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
from launch_status import LaunchStatus,LaunchRPC,TOKEN,PORTAL
from agent_scheduler import Scheduler,Cast
from agent_lifecycle import ChainView

LEDGER={'strategyCapitalWei':'strategyCapital()','treasuryPrincipalWei':'nonStrategyTreasuryPrincipal()',
 'buybackReserveWei':'buybackReserve()','protocolReserveWei':'protocolReserve()',
 'holderReserveWei':'holderRewardReserve()','accountedWei':'accountedQuote()',
 'activePrincipalWei':'activePrincipal()','realizedProfitWei':'cumulativeRealizedProfit()',
 'realizedLossWei':'cumulativeRealizedLoss()'}

def dashboard_projection(snapshot):
    """Focused read-only dashboard projection; unavailable data remains explicit."""
    ledger=snapshot.get('ledger') if isinstance(snapshot,dict) else None
    market=snapshot.get('xstocks') if isinstance(snapshot,dict) else None
    if not isinstance(ledger,dict) or not isinstance(market,dict):raise ValueError('Observer snapshot is incomplete')
    latest=market.get('latestEvaluation');history=market.get('observationHistory')
    if not isinstance(history,list):history=market.get('evaluations') if isinstance(market.get('evaluations'),list) else []
    assets=market.get('assets') if isinstance(market.get('assets'),list) else []
    all_disabled=all(isinstance(row,dict) and row.get('status')=='DISABLED_ROUTE_NOT_QUALIFIED' for row in assets)
    profit,loss=ledger.get('realizedProfitWei'),ledger.get('realizedLossWei')
    pnl_ok=isinstance(profit,str) and profit.isdecimal() and isinstance(loss,str) and loss.isdecimal()
    holder=snapshot.get('holderRewards')
    if not isinstance(holder,dict):holder={'status':'NOT_VERIFIED_INDEX_OR_BINDING_UNAVAILABLE'}
    return {'schemaVersion':1,'observedBlock':deepcopy(snapshot.get('publicSnapshot')),
      'agent':{'mode':market.get('mode','OBSERVE_ONLY'),'liveExecutionEnabled':False,
        'evaluationStatus':'OBSERVED' if isinstance(latest,dict) else 'NOT_AVAILABLE',
        'latestEvaluation':deepcopy(latest),'positionObservation':deepcopy(market.get('positions')),
        'blockers':deepcopy(market.get('blockers',[]))},
      'treasury':{'status':'ONCHAIN_READ','balancesWei':deepcopy(ledger)},
      'qualifiedRoutes':{'status':'NOT_QUALIFIED' if all_disabled or not assets else 'STATUS_REPORTED_BY_OBSERVER',
        'assets':deepcopy(assets),'blockers':deepcopy(market.get('blockers',[]))},
      'strategyActivity':{'status':'OBSERVATION_HISTORY' if history else 'NOT_AVAILABLE',
        'latest':deepcopy(latest),'history':deepcopy(history[:20])},
      'verifiedTrades':{'status':'UNAVAILABLE_LIVE_EXECUTION_DISABLED','items':[]},
      'realizedPnl':{'status':'ONCHAIN_CUMULATIVE' if pnl_ok else 'NOT_AVAILABLE',
        'profitWei':profit if pnl_ok else None,'lossWei':loss if pnl_ok else None,
        'netWei':str(int(profit)-int(loss)) if pnl_ok else None},
      'holderRewards':deepcopy(holder)}

def response_for_path(path,snapshot):
    if path=='/status':return snapshot
    if path=='/api/dashboard':return dashboard_projection(snapshot)
    return None

class PublicRPC(LaunchRPC):
    def call(self,method,params):
        if method not in ('eth_getBalance','eth_getLogs'):return super().call(method,params)
        # Read-only holder indexing; original Agent worker whitelist unchanged.
        time.sleep(.2)
        req=urllib.request.Request(self.url,data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req,timeout=20) as response:result=json.loads(response.read())
            if 'error' in result:raise ValueError()
            if method=='eth_getBalance' and not re.fullmatch(r'0x[0-9a-fA-F]+',result.get('result','')):raise ValueError()
            if method=='eth_getLogs' and not isinstance(result.get('result'),list):raise ValueError()
            return result['result']
        except Exception:raise RuntimeError('Read-only balance unavailable') from None

class PublicLaunchStatus(LaunchStatus):
    def status(self,now):
        state=super().status(now)
        block=self.s.preflight();self.verify_code(block);v=ChainView(self.s,block);k=self.s.c['kernel']
        header=self.s.rpc.call('eth_getBlockByNumber',[block,False])
        if not header:raise ValueError('Pinned header missing')
        state['publicSnapshot']=dict(chainId=56,blockNumber=block,blockHash=header['hash'],
            blockTimestamp=int(header['timestamp'],16),scope='BACKEND_OBSERVATION_NOT_INDEPENDENT_DEPLOYMENT_CLEARANCE')
        state['ledger']={key:str(v.one(k,sig)) for key,sig in LEDGER.items()}
        try:state['ledger']['vaultBalanceWei']=str(int(self.s.rpc.call('eth_getBalance',[k,block]),16))
        except Exception:state['ledger']['vaultBalanceWei']=None
        state['ledger']['receiverPendingWei']=str(v.one(self.c['receiver'],'pendingBNB()'))
        state['ledger']['receiverForwardedWei']=str(v.one(self.c['receiver'],'totalForwarded()'))
        state['publicContracts']={key:self.c[key] for key in ('factory','receiver','token','vaultPortal','portal','buybackExecutor')}
        state['publicContracts'].update(kernel=k,strategyExecutor=self.s.c['executor'],settlement=self.s.c['settlement'])
        state['activeRunCount']=v.one(k,'activeRunCount()')
        from xstocks_agent import ASSETS
        state['xstocks']=dict(mode='OBSERVE_ONLY',assets=[dict(symbol=x,status='DISABLED_ROUTE_NOT_QUALIFIED') for x in ASSETS],evaluations=[])
        from chainlink_observer import prices
        state['xstocks']['prices']=prices(self.s.rpc,block,int(header['timestamp'],16))
        state['xstocks']['blockers']=['LIVE_TRADING_NOT_AUTHORIZED','MARKET_SESSION_AND_HALT_NOT_VERIFIED','ROUTES_NOT_PRODUCTION_QUALIFIED']
        state['xstocks']['positions']=None
        if getattr(self.s,'db',None) is not None:
            if self.s.db.execute("SELECT 1 FROM sqlite_master WHERE name='auto_runs'").fetchone():
                try:
                    state['xstocks']['positions']=[{**v.run(int(r[0]))} for r in self.s.db.execute('SELECT id FROM auto_runs LIMIT 3').fetchall()]
                    for position in state['xstocks']['positions']:
                        for key in ('principal','credited','returned','actualLoss'):position[key]=str(position[key])
                except Exception:pass
        db=getattr(self.s,'db',None)
        records=db.execute("SELECT cycle,stage,evidence FROM auto_records ORDER BY id DESC LIMIT 20").fetchall() if db is not None and db.execute("SELECT 1 FROM sqlite_master WHERE name='auto_records'").fetchone() else []
        state['xstocks']['evaluations']=[dict(cycle=r[0],stage=r[1],scope='DRY_RUN') for r in records]
        state['xstocks']['risk']=dict(latched=None,activePrincipalWei=state['ledger']['activePrincipalWei'],strategyCapitalWei=state['ledger']['strategyCapitalWei'])
        try:state['xstocks']['risk']['latched']=bool(v.one(self.s.c['settlement'],'riskLatched()'))
        except Exception:pass
        state['observedLifecycle']=v.one(k,'lifecycle()')
        from recovery_status import recovery_snapshot
        state['recovery']=recovery_snapshot(self,block,v,state)
        state['observedBuybackActivated']=bool(v.one(k,'buybackActivated()'))
        state['buybackObservation']=dict(activated=state['observedBuybackActivated'],totalBNBSpentWei=None,totalCOMPDBurnedBaseUnits=None,
            qualification='NOT_VERIFIED_ROUTES_DISPOSAL_AND_GRAPH',verification='BACKEND_CODE_PIN_MATCH_ONLY')
        try:
            state['buybackObservation']['totalBNBSpentWei']=str(v.one(self.c['buybackExecutor'],'totalBNBSpent()'))
            state['buybackObservation']['totalCOMPDBurnedBaseUnits']=str(v.one(self.c['buybackExecutor'],'totalCOMPDBurned()'))
        except Exception:pass
        state['bonding']=dict(phase='NOT_VERIFIED',thresholdBaseUnits=None,pool=None,verification='NOT_VERIFIED')
        try:
            words=v.words(PORTAL,'getTokenV8Safe(address)',(TOKEN,),18)
            ts=v.one(TOKEN,'state()');pool=words[14]
            if words[4]!=6 or words[9]!=0 or pool>=2**160:raise ValueError('Unsupported token state')
            phase='NOT_VERIFIED'
            if words[0]==1 and ts==0 and pool==0:phase='PRE_BONDING'
            elif words[0] in (1,4) and ts==1:phase='MIGRATING'
            elif words[0]==4 and ts in (2,3,4) and pool and words[17]==0:
                main=v.one(TOKEN,'mainPool()')
                if main==pool and self.s.rpc.call('eth_getCode',['0x'+f'{pool:040x}',block])!='0x':phase='POST_BONDING_PANCAKE_REPORTED'
            state['bonding']=dict(phase=phase,thresholdBaseUnits=str(words[8]),pool='0x'+f'{pool:040x}' if pool else None,
                verification='BACKEND_INTERFACE_STATE_ONLY_NOT_ROUTE_APPROVAL')
        except Exception:pass # Optional read failure never invents a lifecycle or route.
        indexer=getattr(self,'holder_indexer',None)
        state['holderRewards']=None
        if indexer:
            try:
                indexer.sync(max_blocks=4)
                tip=indexer.db.execute('SELECT n FROM blocks ORDER BY n DESC LIMIT 1').fetchone()
                if tip:state['holderRewards']=indexer.public_snapshot(now,ChainView(self.s,hex(tip[0])))
            except Exception:state['holderRewards']={'status':'NOT_VERIFIED_INDEX_OR_BINDING_UNAVAILABLE'}
        # Ensure same numbered snapshot is still canonical after all reads.
        again=self.s.rpc.call('eth_getBlockByNumber',[block,False])
        if not again or again['hash']!=header['hash']:raise ValueError('Snapshot reorg')
        return state

def serve_public(observer,port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            if self.path not in ('/status','/api/dashboard'):self.send_error(404);return
            try:data=observer.status(time.time());code=200
            except Exception:data={'status':'NOT_VERIFIED'};code=503
            else:data=response_for_path(self.path,data)
            body=json.dumps(data).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
    HTTPServer(('127.0.0.1',port),Handler).serve_forever()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--config',required=True);p.add_argument('--identities',required=True);p.add_argument('--state',default='agent-state.sqlite');p.add_argument('--serve',type=int,default=4174)
    p.add_argument('--holder-config');p.add_argument('--holder-state',default='holder-index.sqlite')
    a=p.parse_args();url=os.environ.get('BSC_RPC_URL')
    if not url:p.error('BSC_RPC_URL required server-side only')
    s=Scheduler(a.state,json.loads(Path(a.config).read_text()),PublicRPC(url),Cast(os.environ.get('COMPD_CAST_BIN','cast')))
    observer=PublicLaunchStatus(s,json.loads(Path(a.identities).read_text()),lambda:{'status':'NO_EXECUTION_PUBLIC_OBSERVER'})
    if a.holder_config:
        from holder_rewards import HolderIndexer
        observer.holder_indexer=HolderIndexer(a.holder_state,json.loads(Path(a.holder_config).read_text()),s.rpc,s.cast)
    serve_public(observer,a.serve)
if __name__=='__main__':main()
