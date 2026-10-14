"""Read-only launch verification and local dashboard. Never activates contracts or sends transactions."""
import argparse,hashlib,json,os,sqlite3,time
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
from agent_scheduler import RPC,Cast,Scheduler,AGENT,address,hash32
from agent_lifecycle import AutoLifecycle,ChainView

TOKEN='0x7b7af51136574c91a12988989c0a08e98ae97777'
VAULT_PORTAL='0x90497450f2a706f1951b5bdda52b4e5d16f34c06'
PORTAL='0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0'
SIGNATURES={'launch':'FlapTaxVaultTokenCreated(address,address,address)',
    'created':'TokenCreated(uint256,address,uint256,address,string,string,string)',
    'fees':'NativeRevenueCredited(address,uint256,uint256,uint256,uint256)',
    'burn':'BuybackBurned(bytes32,bytes32,uint256,uint256)'}

class LaunchRPC(RPC):
    def call(self,method,params):
        if method=='debug_traceTransaction':
            # Trace retrieval is read-only; no eth_send* exposed.
            import urllib.request
            time.sleep(.2)
            req=urllib.request.Request(self.url,data=json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode(),headers={'Content-Type':'application/json'})
            try:
                with urllib.request.urlopen(req,timeout=30) as response:r=json.loads(response.read())
                if 'error' in r:raise RuntimeError()
                return r['result']
            except Exception:raise RuntimeError('Read-only call trace unavailable; Flap attribution NOT VERIFIED') from None
        return super().call(method,params)

class LaunchStatus:
    def __init__(self,scheduler,identities,evaluate,*,observe_without_capital=False):
        if scheduler.execute:raise ValueError('Launch observer must be dry-run only')
        self.s=scheduler;self.c=identities;self.evaluate=evaluate;self.observe_without_capital=observe_without_capital
        for name in ('factory','receiver','token','vaultPortal','portal','buybackExecutor'):
            address(identities[name]);hash32(identities[name+'CodeHash'])
        if address(identities['token'])!=TOKEN or address(identities['vaultPortal'])!=VAULT_PORTAL or address(identities['portal'])!=PORTAL:
            raise ValueError('Frozen launch identities')
        fingerprint=hashlib.sha256(json.dumps(identities,sort_keys=True).encode()).hexdigest()
        old=self.s.db.execute("SELECT value FROM metadata WHERE key='launch_identities'").fetchone()
        if old and old[0]!=fingerprint:raise ValueError('Launch identities changed; reconciliation required')
        self.s.db.execute("INSERT OR IGNORE INTO metadata VALUES ('launch_identities',?)",(fingerprint,))
        self.s.db.execute('CREATE TABLE IF NOT EXISTS launch_status (id INTEGER PRIMARY KEY CHECK(id=1), state TEXT)')
        self.s.db.execute('CREATE TABLE IF NOT EXISTS burn_receipts (hash TEXT PRIMARY KEY, evidence TEXT)');self.s.db.commit()
        self.topics={k:self.s.cast.run(['keccak',v]).lower() for k,v in SIGNATURES.items()}

    def load(self):
        row=self.s.db.execute('SELECT state FROM launch_status WHERE id=1').fetchone()
        return json.loads(row[0]) if row else dict(status='NOT_VERIFIED',agent='OBSERVE_ONLY',firstDistribution='NOT_SCHEDULED')
    def save(self,state):
        self.s.db.execute('INSERT OR REPLACE INTO launch_status VALUES (1,?)',(json.dumps(state,sort_keys=True),));self.s.db.commit()
    def confirmed(self,txhash):
        txhash=hash32(txhash);r=self.s.rpc.call('eth_getTransactionReceipt',[txhash])
        if not r or int(r['status'],16)!=1:raise ValueError('Successful mined receipt required')
        if r['transactionHash'].lower()!=txhash:raise ValueError('Receipt hash mismatch')
        number=int(r['blockNumber'],16);b=self.s.rpc.call('eth_getBlockByNumber',[hex(number),False])
        if not b or b['hash'].lower()!=r['blockHash'].lower():raise ValueError('Noncanonical receipt')
        latest=int(self.s.rpc.call('eth_blockNumber',[]),16)
        if latest-number+1<self.s.c['confirmations']:raise ValueError('Receipt lacks confirmations')
        return r,b
    def verify_code(self,block):
        for name in ('factory','receiver','token','vaultPortal','portal','buybackExecutor'):
            code=self.s.rpc.call('eth_getCode',[address(self.c[name]),block])
            if code=='0x' or self.s.cast.code_hash(code)!=hash32(self.c[name+'CodeHash']):raise ValueError('Launch integration code pin mismatch')
    def logs(self,receipt,name,emitter):
        return [l for l in receipt['logs'] if not l.get('removed',False) and address(l['address'])==address(emitter)
                and l['topics'] and l['topics'][0].lower()==self.topics[name]]
    @staticmethod
    def address_word(word):
        if len(word)!=66 or int(word[2:26],16)!=0:raise ValueError('Malformed indexed address')
        return address('0x'+word[-40:])
    def verify(self,launch_tx,fee_tx):
        old=self.load();launch_tx=hash32(launch_tx);fee_tx=hash32(fee_tx)
        if old.get('launchTX') and old['launchTX']!=launch_tx:raise ValueError('One-time launch already bound')
        block=self.s.preflight();self.verify_code(block)
        receipt,launch_block=self.confirmed(launch_tx)
        self.verify_code(receipt['blockNumber'])
        events=self.logs(receipt,'launch',VAULT_PORTAL)
        expected=[TOKEN,address(self.c['receiver']),address(self.c['factory'])]
        if not any(len(e['topics'])==4 and [self.address_word(t) for t in e['topics'][1:]]==expected for e in events):
            raise ValueError('Verified VaultPortal token/receiver/factory event missing')
        created=self.logs(receipt,'created',PORTAL)
        if not any(len(e['data'])>=2+7*64 and self.address_word('0x'+e['data'][2+3*64:2+4*64])==TOKEN
                   and int(e['data'][2:66],16)==int(launch_block['timestamp'],16) for e in created):
            raise ValueError('Actual Portal creation event missing')
        fee,fee_block=self.confirmed(fee_tx)
        if int(fee['blockNumber'],16)<int(receipt['blockNumber'],16):raise ValueError('Fee receipt predates launch')
        credits=self.logs(fee,'fees',self.s.c['kernel'])
        credit=[]
        for event in credits:
            if len(event['topics'])!=2 or self.address_word(event['topics'][1])!=address(self.c['receiver']) or len(event['data'])!=258:continue
            amount,sc,br,pr=[int(event['data'][2+i*64:2+(i+1)*64],16) for i in range(4)]
            if amount<=0 or (sc,br,pr)!=(amount*3500//10000,amount*1500//10000,amount-amount*3500//10000-amount*1500//10000):raise ValueError('Incorrect recurring revenue allocation')
            credit.append((amount,sc,br,pr))
        if not credit:raise ValueError('Confirmed native revenue ingress missing')
        view=ChainView(self.s,fee['blockNumber'])
        def addr_read(to,sig):return address('0x'+f'{view.one(to,sig):040x}')
        processor=addr_read(TOKEN,'taxProcessor()')
        if addr_read(processor,'taxToken()')!=TOKEN or addr_read(processor,'marketAddress()')!=address(self.c['receiver']):raise ValueError('TaxProcessor binding mismatch')
        if addr_read(self.c['factory'],'receiver()')!=address(self.c['receiver']) or view.one(self.c['factory'],'bound()')!=1:raise ValueError('Factory is not bound')
        if addr_read(self.s.c['kernel'],'nativeFeeReceiver()')!=address(self.c['receiver']):raise ValueError('Kernel receiver binding mismatch')
        if addr_read(self.s.c['kernel'],'buybackExecutor()')!=address(self.c['buybackExecutor']):raise ValueError('Kernel buyback binding mismatch')
        trace=self.s.rpc.call('debug_traceTransaction',[fee_tx,{'tracer':'callTracer'}])
        def transfers(node,src,dst):
            if not isinstance(node,dict) or node.get('error'):return 0
            amount=int(node.get('value','0x0'),16) if node.get('type','').upper()=='CALL' and node.get('from','').lower()==src and node.get('to','').lower()==dst else 0
            return amount+sum(transfers(child,src,dst) for child in node.get('calls',[]))
        received=transfers(trace,processor,address(self.c['receiver']));forwarded=transfers(trace,address(self.c['receiver']),address(self.s.c['kernel']))
        total=sum(x[0] for x in credit)
        if received!=total or forwarded!=total:raise ValueError('Trace cannot prove unmixed automatic Flap fee delivery')
        # Same-TX trace avoids attributing donations or previously pending funds to Flap.
        self.s.db.execute('BEGIN IMMEDIATE')
        old=self.load()
        if old.get('launchTX') and old['launchTX']!=launch_tx:
            self.s.db.rollback();raise ValueError('One-time launch already bound')
        state=dict(old,status='VERIFIED_LOCAL_LAUNCH_OBSERVATION',launchTX=launch_tx,launchTimestamp=int(launch_block['timestamp'],16),
            launchBlockHash=receipt['blockHash'],feeTX=fee_tx,feeBlockHash=fee['blockHash'],
            feeInflowWei=str(total),feeCoverage='VERIFIED_RECEIPT_SAMPLE_ONLY',feeAllocationsWei=dict(strategy=str(sum(x[1] for x in credit)),buyback=str(sum(x[2] for x in credit)),protocol=str(sum(x[3] for x in credit))),
            firstWindowEnd=int(launch_block['timestamp'],16)+900,firstDistribution='PAYOUT_STATUS_NOT_VERIFIED',agent='OBSERVE_ONLY',productionActivated=False)
        capital=ChainView(self.s,block).one(self.s.c['kernel'],'strategyCapital()')
        if capital<=0 and not self.observe_without_capital and 'immediateEvaluation' not in state:
            state['immediateEvaluation']='WAITING_CAPITAL'
        elif (capital>0 or self.observe_without_capital) and state.get('immediateEvaluation') in (None,'WAITING_CAPITAL'):
            state['immediateEvaluation']='RUNNING_OBSERVE_ONLY';self.save(state) # durable once-only marker before callback
            state['immediateEvaluationResult']=self.evaluate();state['immediateEvaluation']='RECORDED_OBSERVE_ONLY'
        self.save(state);return state
    def status(self,now):
        state=self.load();block=self.s.preflight();v=ChainView(self.s,block);k=self.s.c['kernel']
        if state.get('launchTX'):
            for key,expected in (('launchTX','launchBlockHash'),('feeTX','feeBlockHash')):
                r,_=self.confirmed(state[key])
                if r['blockHash'].lower()!=state[expected].lower():raise ValueError('Activation observation reorg; suspend')
        state['strategyCapitalWei']=str(v.one(k,'strategyCapital()'))
        state['realizedProfitWei']=str(v.one(k,'cumulativeRealizedProfit()'));state['realizedLossWei']=str(v.one(k,'cumulativeRealizedLoss()'))
        state['unrealizedPnL']=None;state['unrealizedPnLStatus']='NOT_VERIFIED_NO_PRICE_SOURCE'
        reward=v.one(k,'holderRewardReserve()');state['accruedHolderReserveWei']=str(reward)
        if 'firstWindowEnd' in state:
            state['firstDistributionCountdownSeconds']=max(0,state['firstWindowEnd']-int(now))
            if int(now)>=state['firstWindowEnd']:
                self.s.db.execute('BEGIN IMMEDIATE');stored=self.load()
                if 'firstCheckpoint' not in stored:
                    stored['firstCheckpoint']=dict(observedAt=int(now),observedBlock=block,realizedProfitObservedWei=state['realizedProfitWei'],
                        outcome='NO_REALIZED_PROFIT' if int(state['realizedProfitWei'])==0 else 'PAYOUT_STATUS_NOT_VERIFIED',paidWei='0' if int(state['realizedProfitWei'])==0 else None)
                    self.save(stored)
                else:self.s.db.commit()
                state['firstCheckpoint']=stored['firstCheckpoint'];state['firstDistributionOutcome']=stored['firstCheckpoint']['outcome']
                # No holder calls or accounting changes. Reserve is not automatically an eligible pool.
        state['utilityQualification']=dict(buyback='MANUAL_ONLY_TREASURY_ROUTE_DISPOSAL_GRAPH_NOT_VERIFIED',
            firstWindow='IMPLEMENTED_LOCAL_VERIFIED_LAUNCH_AND_INDEX_REQUIRED',firstWindowSeconds=900,
            tracking='NOT_VERIFIED_COMPLETE_TOKEN_TRANSFER_HISTORY',
            keeper='DISABLED_AUTOMATIC_MANUAL_TX_VERIFICATION',productionActivation=False)
        state['regularAgentAndHolderWindowSeconds']=28800
        state['buybackBurnReceipts']=[json.loads(r[0]) for r in self.s.db.execute('SELECT evidence FROM burn_receipts')]
        state['agentTransactions']=[dict(r) for r in self.s.db.execute("SELECT cycle,state,txhash FROM jobs WHERE mode LIKE 'EXECUTE%' ORDER BY cycle DESC LIMIT 20")]
        return state
    def record_burn(self,txhash):
        self.s.preflight();r,b=self.confirmed(txhash);self.verify_code(r['blockNumber'])
        v=ChainView(self.s,r['blockNumber'])
        if address('0x'+f'{v.one(self.s.c["kernel"],"buybackExecutor()"):040x}')!=address(self.c['buybackExecutor']):raise ValueError('Burn executor is not Kernel bound')
        events=self.logs(r,'burn',self.c['buybackExecutor'])
        if not events:raise ValueError('Confirmed bound-executor burn event missing')
        if not all(len(e['topics'])==3 and len(e['data'])==130 and int(e['data'][2:66],16)>0 and int(e['data'][66:],16)>0 for e in events):
            raise ValueError('Malformed burn execution event')
        evidence=dict(transactionHash=hash32(txhash),blockHash=r['blockHash'],timestamp=int(b['timestamp'],16),events=events)
        self.s.db.execute('INSERT OR IGNORE INTO burn_receipts VALUES (?,?)',(hash32(txhash),json.dumps(evidence)));self.s.db.commit()
        return evidence

def serve(observer,port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            if self.path!='/status':self.send_error(404);return
            try:payload=observer.status(time.time());code=200
            except Exception as error:payload={'status':'NOT_VERIFIED','failureType':type(error).__name__};code=503
            body=json.dumps(payload).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
    class Server(HTTPServer):
        last_poll=0
        def service_actions(self):
            if time.time()-self.last_poll<60:return
            self.last_poll=time.time();state=observer.load()
            if state.get('immediateEvaluation')=='WAITING_CAPITAL':
                try:observer.verify(state['launchTX'],state['feeTX'])
                except Exception:pass # Still NOT executable; dashboard revalidates and reports failure.
    Server(('127.0.0.1',port),Handler).serve_forever()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--config',required=True);p.add_argument('--identities',required=True)
    p.add_argument('--state',default='agent-state.sqlite');p.add_argument('--launch-tx');p.add_argument('--fee-tx');p.add_argument('--burn-tx');p.add_argument('--serve',type=int)
    a=p.parse_args();url=os.environ.get('BSC_RPC_URL')
    if not url:p.error('BSC_RPC_URL required')
    s=Scheduler(a.state,json.loads(Path(a.config).read_text()),LaunchRPC(url),Cast(os.environ.get('COMPD_CAST_BIN','cast')))
    from xstocks_agent import XStocksLifecycle
    auto=XStocksLifecycle(s);observer=LaunchStatus(s,json.loads(Path(a.identities).read_text()),auto.observe_launch,observe_without_capital=True)
    if a.launch_tx:
        if not a.fee_tx:p.error('Confirmed fee transaction and trace required')
        observer.verify(a.launch_tx,a.fee_tx)
    if a.burn_tx:observer.record_burn(a.burn_tx)
    if a.serve:serve(observer,a.serve)
    else:print(json.dumps(observer.status(time.time()),indent=2))
if __name__=='__main__':main()
