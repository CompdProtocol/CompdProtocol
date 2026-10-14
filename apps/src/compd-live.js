// Read-only protocol observations. Simulation never feeds these fields.
(() => {
 const value=(object,path)=>path.split('.').reduce((o,k)=>o?.[k],object);
 const label=v=>typeof v==='string'?v.replaceAll('_',' ').toLowerCase().replace(/^./,c=>c.toUpperCase()):'Not Available';
 function bnb(v){
  if(typeof v!=='string'||!/^\d+$/.test(v))return 'Not Available';
  const n=BigInt(v),unit=10n**18n;if(n>0n&&n<10n**12n)return '<0.000001 BNB';
  const f=(n%unit).toString().padStart(18,'0').slice(0,6).replace(/0+$/,'');return (n/unit).toString()+(f?'.'+f:'')+' BNB';
 }
 function format(v,kind){
  if(v===null||v===undefined)return 'Not Available';
  if(kind==='bnb')return bnb(v);
  if(kind==='time')return Number.isSafeInteger(v)?new Date(v*1000).toISOString():'Not Available';
  if(kind==='seconds')return Number.isSafeInteger(v)?v+' seconds':'Pending';
  if(Array.isArray(v))return v.join(', ');
  return kind==='state'?label(v):String(v);
 }
 function rows(container,items,empty){
  container.replaceChildren();if(!items?.length){container.textContent=empty;return;}
  for(const item of items){const row=document.createElement('div');row.className='flow-row';const text=document.createElement('span');text.textContent=item.text;row.append(text);
   if(/^0x[0-9a-f]{64}$/i.test(item.hash||'')){const link=document.createElement('a');link.textContent=item.hash;link.href='https://bscscan.com/tx/'+item.hash;link.target='_blank';link.rel='noopener noreferrer';row.append(link);}container.append(row);}
 }
 function render(data){
  if(data.schemaVersion!==1)throw Error('Unsupported public API schema');
  for(const node of document.querySelectorAll('[data-compd]')){const v=value(data,node.dataset.compd);node.textContent=format(v,node.dataset.format);node.classList.toggle('is-unavailable',v===null||v===undefined);}
  for(const node of document.querySelectorAll('[data-compd-state]'))node.textContent=node.classList.contains?.('status-neutral')?(data.availability==='NOT_AVAILABLE'?'Not Available':'Backend observed'):(data.availability==='NOT_AVAILABLE'?'Not Available — observer not connected':'Backend observations at '+data.observedAt+' — not independent deployment clearance');
  for(const node of document.querySelectorAll('[data-compd-burns]'))rows(node,data.flow.burns.map(x=>({text:bnb(x.bnbSpentWei)+' spent · '+x.compdBurnedBaseUnits+' COMPD base units burned',hash:x.transactionHash})),'No recorded burn receipts available; full history not verified.');
  for(const node of document.querySelectorAll('[data-compd-jobs]'))rows(node,data.agent.transactions.map(x=>({text:'Cycle '+(x.cycle??'Not Available')+' · '+label(x.state),hash:x.transactionHash})),'No recorded Agent transactions available.');
  for(const node of document.querySelectorAll('[data-compd-evaluations]'))rows(node,(data.agent.evaluations||[]).map(x=>({text:'UTC cycle '+x.cycle+' · '+label(x.stage)+' · dry-run observation'})),'No recorded evaluations available.');
  for(const node of document.querySelectorAll('[data-compd-routes]'))rows(node,(data.agent.routes||[]).map(x=>({text:x.symbol+' · '+label(x.status)})),'Route qualification Not Available.');
  for(const node of document.querySelectorAll('[data-compd-prices]'))rows(node,(data.agent.prices||[]).map(x=>({text:x.symbol+' · '+(x.priceUSD===null?'Not Available':'$'+x.priceUSD+' USD reference')+' · '+label(x.status)+' · '+(x.ageSeconds??'Unknown')+'s old · scheduled session '+(x.qualification?.session?.state||'UNKNOWN')+' ('+label(x.qualification?.session?.reason)+') · halt '+(x.symbol==='BNB'?'not applicable':'UNKNOWN')+' · heartbeat '+(x.heartbeatSeconds??'Unknown')+'s; price guard 60s · '+(x.qualification?.blockers||[]).map(label).join(', ')})),'Chainlink reference prices Not Available.');
  for(const node of document.querySelectorAll('[data-compd-blockers]'))rows(node,(data.agent.blockers||[]).map(x=>({text:label(x)})),'Execution readiness Not Available.');
  for(const node of document.querySelectorAll('[data-compd-positions]'))rows(node,(data.agent.positions||[]).map(x=>({text:'Run '+x.id+' · state '+x.state+' · principal '+bnb(x.principalWei)+' · credited '+bnb(x.creditedWei)})),data.agent.positions===null?'Position history Not Available.':'No observed positions in indexed runs.');
  const latest=data.agent.latestEvaluation;
  for(const node of document.querySelectorAll('[data-compd-intelligence]')){
   const key=node.dataset.compdIntelligence;
   node.textContent=!latest?'Not Available':key==='timestamp'?format(latest.evaluatedAt,'time'):key==='market'?latest.results.map(x=>x.market).join(', '):key==='timeframe'?'8-hour evaluation cycle':key==='decision'?'BLOCKED · NO TRADE':key==='reason'?[...new Set(latest.results.flatMap(x=>x.blockers))].map(label).join(' · '):'Not Available — engine supplied no '+key;
  }
  for(const node of document.querySelectorAll('[data-compd-observation-history]'))rows(node,(data.agent.observationHistory||[]).map(x=>({text:format(x.evaluatedAt,'time')+' · cycle '+x.cycle+' · '+x.results.map(r=>r.market+': '+r.status+' / '+r.decision+' ('+r.blockers.map(label).join(', ')+')').join(' · ')})),'No completed observation evaluations.');
  for(const node of document.querySelectorAll('[data-compd-holders]'))rows(node,(data.flow.holders.top30||[]).map((x,i)=>({text:'Rank '+(i+1)+' · '+x.address+' · provisional '+bnb(x.amountWei)})),'Eligible holder observations Not Available.');
  for(const node of document.querySelectorAll('[data-compd-payouts]'))rows(node,(data.flow.holders.payouts||[]).map(x=>({text:x.recipient+' · '+bnb(x.amountWei),hash:x.transactionHash})),'No confirmed holder payouts available.');
  for(const node of document.querySelectorAll('[data-compd-contracts]'))rows(node,Object.entries(data.protocol.contracts).map(([name,x])=>({text:name+' · '+x.address+' · backend code pin match'})),'Verified contract observations Not Available.');
  for(const node of document.querySelectorAll('[data-compd-recovery]'))rows(node,(data.protocol.recovery?.transactions||[]).map(x=>({text:label(x.kind)+' · '+(/^0x0{40}$/i.test(x.asset||'')?bnb(x.amount):x.amount+' token base units')+' · fixed Recovery Treasury',hash:x.transactionHash})),'Confirmed recovery records Not Available. History covers a bounded recent window only.');
  for(const node of document.querySelectorAll('[data-compd-recoverable-vaults]'))rows(node,(data.protocol.recovery?.connectedVaults||[]).map(x=>({text:x.name+' · '+bnb(x.recoverableNativeWei)})),'Connected-vault recoverable balances Not Available.');
 }
 function clear(message){
  for(const node of document.querySelectorAll('[data-compd]'))node.textContent='Not Available';
  for(const node of document.querySelectorAll('[data-compd-intelligence],[data-compd-observation-history]'))node.textContent='Not Available';
  for(const node of document.querySelectorAll('[data-compd-burns],[data-compd-jobs],[data-compd-contracts],[data-compd-holders],[data-compd-payouts],[data-compd-evaluations],[data-compd-routes],[data-compd-recovery],[data-compd-recoverable-vaults],[data-compd-prices],[data-compd-blockers],[data-compd-positions]'))node.textContent='Not Available';
  for(const node of document.querySelectorAll('[data-compd-state]'))node.textContent=node.classList.contains?.('status-neutral')?(message.startsWith('Loading')?'Loading…':'Not Available'):message;
 }
 let inflight=false;
 async function refresh(){
  if(inflight)return;inflight=true;
  try{render(await window.CompdAPI.status());}catch{clear('Not Available — data connection failed');}finally{inflight=false;}
 }
 // Exposed for zero-dependency rendering tests; read-only functions only.
 window.CompdLive=Object.freeze({bnb,format,render,refresh});
 if(document.querySelector('[data-compd-state]')){clear('Loading read-only observations…');void refresh();setInterval(()=>{if(!document.hidden)void refresh();},30000);}
})();
