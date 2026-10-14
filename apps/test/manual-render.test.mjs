import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
function dom(){
 class Node {constructor(dataset={}){this.dataset=dataset;this.children=[];this._text='';this.classList={toggle(){},contains(){return false;}};}set textContent(v){this._text=v;this.children=[];}get textContent(){return this._text;}append(...nodes){this.children.push(...nodes);}replaceChildren(...nodes){this.children=nodes;this._text='';}addEventListener(){}}
 const metrics=[new Node({manual:'treasury.availableReserveWei',format:'bnb'}),new Node({manual:'totals.tokensPurchasedBaseUnits'}),new Node({manual:'totals.deadTokensBaseUnits'}),new Node({manual:'totals.nativeBurnedBaseUnits'})],history=new Node(),treasury=new Node(),status=new Node();
 const all=selector=>selector==='[data-manual]'?metrics:selector==='[data-manual-history]'?[history]:selector==='[data-manual-treasury]'?[treasury]:selector==='[data-manual-status]'?[status]:selector==='[data-manual],[data-manual-history],[data-manual-treasury]'?[...metrics,history,treasury]:[];
 const ctx={window:{},document:{querySelector(){return null;},querySelectorAll:all,createElement(){return new Node();}},setInterval(){},AbortSignal,console,TextEncoder};return {ctx,metrics,history,treasury,status};
}
async function setup(){const d=dom();vm.createContext(d.ctx);vm.runInContext(await readFile(new URL('../src/compd-live.js',import.meta.url),'utf8'),d.ctx);vm.runInContext(await readFile(new URL('../src/compd-manual.js',import.meta.url),'utf8'),d.ctx);return d;}
test('manual unavailable and empty state shows no fabricated amounts',async()=>{
 const d=await setup();d.ctx.window.CompdManual.render({treasury:null,totals:null,history:[]});assert.ok(d.metrics.every(n=>n.textContent==='Not Available'));assert.equal(d.history.textContent,'No verified submitted records available.');
});
test('dead transfers and actual supply reductions remain separately labelled',async()=>{
 const d=await setup();const h='0x'+'1'.repeat(64);d.ctx.window.CompdManual.render({treasury:{availableReserveWei:'1500000000000000000'},totals:{tokensPurchasedBaseUnits:'1000',deadTokensBaseUnits:'700',nativeBurnedBaseUnits:'0'},history:[{hash:h,kind:'BURN',status:'Verified',observation:{funding:'OWNER_FUNDED',kind:'BURN',burnType:'DEAD_ADDRESS_TRANSFER_NOT_SUPPLY_BURN',deadTokensBaseUnits:'700',nativeBurnedBaseUnits:'0'}}]});
 assert.equal(d.metrics[0].textContent,'1.5 BNB');assert.equal(d.metrics[2].textContent,'700');assert.equal(d.metrics[3].textContent,'0');assert.match(d.history.children[0].children[0].textContent,/DEAD_ADDRESS_TRANSFER_NOT_SUPPLY_BURN/);assert.equal(d.history.children[0].children[1].href,'https://bscscan.com/tx/'+h);
});
test('failure clearing removes prior values and receipt links',async()=>{
 const d=await setup();d.ctx.window.CompdManual.render({treasury:{availableReserveWei:'1'},totals:{tokensPurchasedBaseUnits:'5',deadTokensBaseUnits:'0',nativeBurnedBaseUnits:'0'},history:[]});d.ctx.window.CompdManual.clear();assert.ok(d.metrics.every(n=>n.textContent==='Not Available'));assert.equal(d.history.textContent,'Not Available');assert.equal(d.history.children.length,0);
});
