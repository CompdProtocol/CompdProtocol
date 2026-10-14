import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';import vm from 'node:vm';
import {projectStatus} from '../tools/protocol-api.mjs';
const snapshot={chainId:56,blockHash:'0x'+'1'.repeat(64),blockTimestamp:1000};
const record={cycle:0,evaluatedAt:1000,blockHash:snapshot.blockHash,scope:'OBSERVATION_ONLY',engine:'xstocks_agent.decision',results:[{market:'TSLAx',status:'BLOCKED',decision:'NO_TRADE',reason:'ROUTE_NOT_QUALIFIED',blockers:['STALE_PRICE'],confidence:99,entry:300}]};
const data=()=>projectStatus({publicSnapshot:snapshot,xstocks:{mode:'OBSERVE_ONLY',observationHistory:[record]}});
test('evaluation projection retains genuine blockers and drops invented confidence/targets',()=>{const r=data();assert.equal(r.agent.latestEvaluation.results[0].confidence,null);assert.equal(r.agent.latestEvaluation.results[0].entry,null);assert.equal(r.agent.latestEvaluation.results[0].decision,'NO_TRADE');assert.equal(r.agent.latestEvaluation.evaluatedAt,1000)});
test('unavailable snapshots and unsupported evaluation signals are never promoted',()=>{assert.equal(projectStatus().agent.latestEvaluation,null);const r=projectStatus({publicSnapshot:snapshot,xstocks:{observationHistory:[{...record,results:[{...record.results[0],decision:'BUY',status:'READY'}]}]}});assert.deepEqual(r.agent.latestEvaluation.results,[])});
test('render shows blocked evaluation, timestamp/history and clears on errors',()=>{
 const make=()=>({textContent:'',children:[],classList:{toggle(){},contains(){return false}},replaceChildren(){this.children=[]},append(x){this.children.push(x)}});
 const reason={...make(),dataset:{compdIntelligence:'reason'}},when={...make(),dataset:{compdIntelligence:'timestamp'}},history=make();
 const document={querySelector(){return null},querySelectorAll(s){if(s==='[data-compd-intelligence]')return [reason,when];if(s==='[data-compd-observation-history]')return [history];if(s==='[data-compd-intelligence],[data-compd-observation-history]')return [reason,when,history];return []},createElement:make};
 const window={CompdAPI:{status:async()=>{throw Error('offline')}}};vm.runInNewContext(readFileSync(new URL('../src/compd-live.js',import.meta.url),'utf8'),{window,document,console,setInterval(){}});
 window.CompdLive.render(data());assert.match(reason.textContent,/Stale price/);assert.match(when.textContent,/1970/);assert.equal(history.children.length,1);
 return window.CompdLive.refresh().then(()=>assert.equal(reason.textContent,'Not Available'));
});
