import assert from 'node:assert/strict';
import {test,before,after} from 'node:test';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {POLICY,projectStatus,statusEndpoint} from '../tools/protocol-api.mjs';
const H='0x'+'a'.repeat(64),A='0x'+'b'.repeat(40);
let raw,upstream,child,url;
const fixture=()=>({status:'VERIFIED_LOCAL_LAUNCH_OBSERVATION',launchTX:H,launchTimestamp:1000,firstWindowEnd:1900,feeInflowWei:'1000',
 publicSnapshot:{chainId:56,blockNumber:'0x10',blockHash:H,blockTimestamp:1900},publicContracts:{kernel:A},
 ledger:{strategyCapitalWei:'12345678901234567890',accountedWei:'0',realizedProfitWei:'100',holderReserveWei:'10'},
 firstCheckpoint:{observedAt:1900,outcome:'NO_REALIZED_PROFIT',paidWei:'0'},
 agentTransactions:[{cycle:1,state:'CONFIRMED',txhash:H}],
 buybackBurnReceipts:[{transactionHash:H,blockHash:H,events:[{topics:[H,H,H],data:'0x'+(10n).toString(16).padStart(64,'0')+(20n).toString(16).padStart(64,'0')}]}],
 privateKey:'SECRET_NEVER_PUBLIC',rpcUrl:'https://secret.invalid/key',credentials:{signer:'SECRET_NEVER_PUBLIC'}});
async function start(extra=[]){
 const process=spawn(globalThis.process.execPath,['tools/dev-server.mjs',...extra],{cwd:new URL('../',import.meta.url),env:{...globalThis.process.env,PORT:'0',COMPD_STATUS_URL:`http://127.0.0.1:${upstream.address().port}/status`},stdio:['ignore','pipe','pipe']});
 let stdout='';const port=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Startup timeout')),7000);process.stdout.on('data',chunk=>{stdout+=chunk;const m=stdout.match(/http:\/\/127\.0\.0\.1:(\d+)/);if(m){clearTimeout(timer);resolve(m[1]);}});process.on('error',reject);process.on('exit',code=>{clearTimeout(timer);if(code!==null&&code!==0)reject(Error('Server exited'));});});
 return [process,'http://127.0.0.1:'+port];
}
async function stop(p){if(p.exitCode===null){const exit=once(p,'exit');p.kill();await exit;}}
before(async()=>{raw=fixture();upstream=createServer((req,res)=>{assert.equal(req.url,'/status');if(raw==='ERROR'){res.writeHead(503);res.end('SECRET_NEVER_PUBLIC');return;}res.setHeader('content-type','application/json');res.end(JSON.stringify(raw));});upstream.listen(0,'127.0.0.1');await once(upstream,'listening');[child,url]=await start();});
after(async()=>{await stop(child);upstream.close();});
test('default contract has null balances, known reserved CA, locked economics and inactive features',()=>{
 const p=projectStatus();assert.equal(p.treasury.accountedWei,null);assert.equal(p.agent.positions,null);assert.equal(p.protocol.tokenStatus,'RESERVED_NOT_INDEPENDENTLY_VERIFIED_DEPLOYED');
 assert.deepEqual(p.policy.profit,{strategy:65,buyback:15,holders:10,protocol:10});assert.deepEqual(p.policy.fees,{strategy:35,buyback:15,protocol:50});assert.deepEqual(p.policy.bootstrap,{strategy:10,treasury:90});assert.equal(p.policy.assets.length,5);assert.equal(p.agent.cycleSeconds,28800);assert.equal(p.flow.buybackStatus,'MANUAL_ONLY_TREASURY_EXECUTION_BLOCKED');
});
test('loopback source rejects credentials, redirects/remote targets and query parameters',()=>{
 for(const v of ['https://127.0.0.1/status','http://user:secret@localhost/status','http://example.com/status','http://localhost/status?key=secret','http://localhost/activate'])assert.throws(()=>statusEndpoint(v));
 assert.equal(statusEndpoint('http://127.0.0.1:4174/status'),'http://127.0.0.1:4174/status');
});
test('observer integration preserves precision, real zero, sample coverage, hashes and safe confirmed events',async()=>{
 raw=fixture();const p=await(await fetch(url+'/api/protocol/status')).json();assert.equal(p.schemaVersion,1);assert.equal(p.treasury.strategyCapitalWei,'12345678901234567890');assert.equal(p.treasury.accountedWei,'0');assert.equal(p.treasury.buybackReserveWei,null);
 assert.equal(p.treasury.feeCoverage,'VERIFIED_RECEIPT_SAMPLE_ONLY');assert.equal(p.protocol.launchTransactionHash,H);assert.equal(p.flow.burns.length,1);assert.equal(p.flow.burns[0].compdBurnedBaseUnits,'20');assert.equal(p.agent.transactions[0].transactionHash,H);assert.match(p.flow.holders.checkpoint.meaning,/NON_PAYING/);assert.doesNotMatch(JSON.stringify(p),/SECRET|secret.invalid|rpcUrl|privateKey|credentials/);
});
test('read-only, source override and file exposure defenses',async()=>{
 assert.equal((await fetch(url+'/api/protocol/status',{method:'POST'})).status,405);
 assert.equal((await fetch(url+'/api/activate')).status,404);assert.equal((await fetch(url+'/../tools/protocol-api.mjs')).status,404);
 assert.equal((await fetch(url+'/api/protocol/status?url=https://evil.invalid')).status,200);
 assert.equal((await fetch(url+'/api/paper/runs',{method:'POST',headers:{Origin:'https://evil.invalid'}})).status,403);
});
test('backend failure and wrong-chain snapshot are unavailable; secrets never appear in errors',async()=>{
 raw='ERROR';let r=await fetch(url+'/api/protocol/status');assert.equal(r.status,503);assert.doesNotMatch(await r.text(),/SECRET|secret.invalid/);
 raw=fixture();raw.publicSnapshot.chainId=1;r=await fetch(url+'/api/protocol/status');assert.equal(r.status,503);raw=fixture();
});
test('malformed values, arbitrary contract fields and forged-looking events are discarded',()=>{
 const f=fixture();f.ledger.realizedProfitWei='NaN';f.publicContracts.signer='SECRET';f.agentTransactions[0].state='SECRET';f.buybackBurnReceipts[0].events[0].data='0x00';const p=projectStatus(f);assert.equal(p.treasury.realizedProfitWei,null);assert.equal(p.flow.burns.length,0);assert.equal(p.agent.transactions[0].state,'NOT_VERIFIED');assert.equal(p.protocol.contracts.signer,undefined);
});
test('explicit paper preview is segregated and cannot fabricate holder eligibility or quotes',async()=>{
 const [p,u]=await start(['--paper-demo']);try{
  const health=await(await fetch(u+'/api/health')).json();assert.equal(health.paperTradingEnabled,true);assert.equal(health.tradingEnabled,false);
  const eligibility=await(await fetch(u+'/api/eligibility?address='+A)).json();assert.equal(eligibility.eligible,null);assert.equal(eligibility.balance,null);
  const assets=await(await fetch(u+'/api/assets')).json();assert.deepEqual(assets.assets.map(x=>x.symbol),POLICY.assets);assert.ok(assets.assets.every(x=>x.quote===null));
  const post=(path,body={})=>fetch(u+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
  const created=await(await post('/api/paper/runs',{markets:['NVDAx'],durationDays:1})).json();assert.equal(created.mode,'paper-mock');assert.equal(created.transactionsSent,false);assert.equal(created.risk,null);assert.equal(created.status,'waiting_for_data');
  const paused=await(await post('/api/paper/runs/'+created.id+'/pause')).json();assert.equal(paused.status,'paused');
  const stopped=await(await post('/api/paper/runs/'+created.id+'/stop')).json();assert.equal(stopped.status,'stopped');assert.equal(stopped.txHash,undefined);
  assert.equal((await post('/api/paper/runs',{markets:['MSFTx'],durationDays:1})).status,400);
 }finally{await stop(p);}
});
function dom(){
 const make=(dataset={})=>({dataset,textContent:'',children:[],classList:{toggle(){}},replaceChildren(){this.children=[];},append(x){this.children.push(x);}});
 const capital=make({compd:'treasury.strategyCapitalWei',format:'bnb'}),profit=make({compd:'treasury.realizedProfitWei',format:'bnb'}),state=make(),burns=make();
 let resolve,reject;const pending=new Promise((a,b)=>{resolve=a;reject=b;});
 const document={hidden:false,querySelector:()=>state,createElement:()=>make(),querySelectorAll:(selector)=>selector==='[data-compd]'?[capital,profit]:selector==='[data-compd-state]'?[state]:selector==='[data-compd-burns]'?[burns]:selector.includes('data-compd-burns')?[burns]:[]};
 const context={document,window:{CompdAPI:{status:()=>pending}},setInterval(){}};vm.createContext(context);return {context,capital,profit,state,burns,resolve,reject};
}
test('browser render loading/success and exact BNB units use null instead of fake zero',async()=>{
 const d=dom();vm.runInContext(await readFile(new URL('../src/compd-live.js',import.meta.url),'utf8'),d.context);assert.match(d.state.textContent,/Loading/);
 d.resolve(projectStatus(fixture()));await d.context.window.CompdLive.refresh();await new Promise(r=>setImmediate(r));assert.equal(d.capital.textContent,'12.345678 BNB');assert.equal(d.profit.textContent,'<0.000001 BNB');
 assert.equal(d.context.window.CompdLive.bnb('0'),'0 BNB');assert.equal(d.context.window.CompdLive.bnb(null),'Not Available');d.context.window.CompdLive.render(projectStatus());assert.equal(d.capital.textContent,'Not Available');
});
test('browser error clears previous financial values and receipt lists',async()=>{
 const d=dom();vm.runInContext(await readFile(new URL('../src/compd-live.js',import.meta.url),'utf8'),d.context);d.context.window.CompdLive.render(projectStatus(fixture()));assert.match(d.capital.textContent,/12/);d.reject(Error('secret backend failure'));await new Promise(r=>setImmediate(r));assert.equal(d.capital.textContent,'Not Available');assert.equal(d.burns.textContent,'Not Available');assert.match(d.state.textContent,/connection failed/);assert.doesNotMatch(d.state.textContent,/secret/);
});
