import test from 'node:test';import assert from 'node:assert/strict';
import {projectStatus} from '../tools/protocol-api.mjs';
import {readFileSync} from 'node:fs';import vm from 'node:vm';
const snap={chainId:56,blockHash:'0x'+'1'.repeat(64),blockTimestamp:1000};
const price={symbol:'TSLAx',feed:'0x'+'2'.repeat(40),priceUSD:'382.6',ageSeconds:100,status:'STALE_PRICE',heartbeatSeconds:86400};
function project(p){return projectStatus({publicSnapshot:snap,xstocks:{prices:[p]}}).agent.prices[0]}
test('stale and closed reasons survive projection',()=>{
 const r=project({...price,qualification:{session:{state:'CLOSED',reason:'WEEKEND'}}});assert.equal(r.qualification.session.state,'CLOSED');assert.deepEqual(r.qualification.blockers,['STALE_PRICE','MARKET_CLOSED','HALT_STATUS_UNKNOWN']);assert.equal(r.heartbeatSeconds,86400);
});
test('fresh scheduled open never promotes halt or trading approval',()=>{
 const r=project({...price,status:'FRESH_REFERENCE_ONLY',qualification:{tradingReady:true,session:{state:'OPEN',reason:'SCHEDULED_REGULAR_SESSION',halt:'CLEAR'}}});assert.equal(r.qualification.tradingReady,false);assert.equal(r.qualification.session.halt,'UNKNOWN');assert.equal(r.qualification.referenceUsable,true);
});
test('missing calendar stays unknown',()=>assert.equal(project(price).qualification.session.state,'UNKNOWN'));
test('dashboard price row explains closed session, stale price and unknown halt',()=>{
 const container={children:[],replaceChildren(){this.children=[]},append(x){this.children.push(x)}};
 const element=()=>({textContent:'',children:[],append(x){this.children.push(x)}});
 const document={querySelector(){return null},querySelectorAll(s){return s==='[data-compd-prices]'?[container]:[]},createElement:element};
 const window={};vm.runInNewContext(readFileSync(new URL('../src/compd-live.js',import.meta.url),'utf8'),{window,document,console,setInterval(){}});
 const data=projectStatus({publicSnapshot:snap,xstocks:{prices:[{...price,qualification:{session:{state:'CLOSED',reason:'WEEKEND'}}}]}});
 window.CompdLive.render(data);const text=container.children[0].children[0].textContent;
 assert.match(text,/Stale price/);assert.match(text,/CLOSED/);assert.match(text,/halt UNKNOWN/);assert.match(text,/86400s; price guard 60s/);
});
