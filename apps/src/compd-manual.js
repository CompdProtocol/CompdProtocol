// Manual review only. The only wallet signing request is an expiring sign-in message.
(() => {
 const isAdmin=!!document.querySelector('[data-manual-signin]');let authenticated=false,busy=false;
 const status=message=>{for(const n of document.querySelectorAll('[data-manual-status]'))n.textContent=message;};
 const path=(o,p)=>p.split('.').reduce((v,k)=>v?.[k],o);
 const bnb=v=>window.CompdLive?.bnb(v)||'Not Available';
 const api=(route,body)=>window.CompdAPI.manual(route,body);
 function history(node,records,privateView=false){
  node.replaceChildren();if(!records?.length){node.textContent='No verified submitted records available.';return;}
  for(const r of records){const row=document.createElement('div');row.className='flow-row';const text=document.createElement('span');const x=r.observation;
   text.textContent=r.kind+' · '+r.status+(privateView&&r.error?' · '+r.error:'')+(x?' · '+x.funding.replaceAll('_',' ')+' · '+(x.kind==='BUYBACK'?bnb(x.bnbSpentWei)+' / '+x.tokensPurchasedBaseUnits+' COMPD base units received':x.burnType+' / '+(x.nativeBurnedBaseUnits!=='0'?x.nativeBurnedBaseUnits:x.deadTokensBaseUnits)+' base units'):'');row.append(text);
   if(/^0x[0-9a-f]{64}$/i.test(r.hash||'')){const link=document.createElement('a');link.href='https://bscscan.com/tx/'+r.hash;link.textContent=r.hash;link.target='_blank';link.rel='noopener noreferrer';row.append(link);
    if(privateView){const retry=document.createElement('button');retry.type='button';retry.textContent='Re-verify';retry.addEventListener('click',async()=>{retry.disabled=true;try{await api('records/reverify',{transactionHash:r.hash});await privateHistory();await refresh();}catch(e){status(e.message);}finally{retry.disabled=false;}});row.append(retry);}}
   node.append(row);
  }
 }
 function render(data){
  for(const n of document.querySelectorAll('[data-manual]')){const v=path(data,n.dataset.manual);n.textContent=v===null||v===undefined?'Not Available':n.dataset.format==='bnb'?bnb(v):String(v);}
  for(const n of document.querySelectorAll('[data-manual-treasury]'))n.textContent=data.treasury?.availableReserveWei!==null&&data.treasury?.availableReserveWei!==undefined?'Kernel reserve '+bnb(data.treasury.availableReserveWei)+' · treasury execution blocked pending verified route, fixed dead-address disposal and deployed graph. Dead-address transfers are not native supply burns. Owner-funded buys do not debit this reserve.':'Kernel reserve Not Available. Treasury execution is blocked; no personal-wallet funding is inferred.';
  for(const n of document.querySelectorAll('[data-manual-history]'))history(n,data.history);
  if(!isAdmin)status(data.totals?'Manual only · verified submitted records; not complete chain history.':'Not Available — reviewed deployment identities and RPC evidence required.');
 }
 function clear(){for(const n of document.querySelectorAll('[data-manual],[data-manual-history],[data-manual-treasury]'))n.textContent='Not Available';}
 function privacy(value){authenticated=value;for(const n of document.querySelectorAll('[data-manual-private]'))n.hidden=!value;if(!value)for(const n of document.querySelectorAll('[data-manual-admin-history]'))n.replaceChildren();}
 async function privateHistory(){try{const data=await api('records');privacy(true);for(const n of document.querySelectorAll('[data-manual-admin-history]'))history(n,data.records,true);render(data.public);}catch(e){privacy(false);throw e;}}
 async function refresh(){try{render(await api('public'));}catch(e){clear();if(!isAdmin)status(e.message);}}
 async function signin(){
  if(busy)return;busy=true;
  try{
   if(!window.ethereum?.request)throw Error('A browser wallet is required; no keys are requested.');
   if(await window.ethereum.request({method:'eth_chainId'})!=='0x38')throw Error('Select BNB Chain (56) in your wallet.');
   const accounts=await window.ethereum.request({method:'eth_requestAccounts'});const wallet=accounts?.[0];const challenge=await api('auth/challenge',{address:wallet});
   if(wallet?.toLowerCase()!==challenge.owner.toLowerCase())throw Error('Canonical Buyback Admin wallet required.');
   const message='0x'+Array.from(new TextEncoder().encode(challenge.message),x=>x.toString(16).padStart(2,'0')).join('');
   const signature=await window.ethereum.request({method:'personal_sign',params:[message,wallet]});
   await api('auth/login',{nonce:challenge.nonce,signature});await privateHistory();status('Signed in for transaction review only. No spending authorization.');
  }catch(e){privacy(false);status(e.message);}finally{busy=false;}
 }
 async function logout(){try{await api('auth/logout',{});}catch{}privacy(false);status('Signed out.');}
 const form=document.querySelector('[data-manual-submit]');
 form?.addEventListener('submit',async e=>{
  e.preventDefault();if(!authenticated||busy)return;busy=true;const button=form.querySelector('button');button.disabled=true;
  try{const data=await api('records',{kind:form.elements.kind.value,transactionHash:form.elements.transactionHash.value.trim()});status(data.status+(data.error?' — '+data.error:''));await privateHistory();await refresh();}
  catch(ex){status(ex.message);}finally{busy=false;button.disabled=false;}
 });
 document.querySelector('[data-manual-signin]')?.addEventListener('click',signin);document.querySelector('[data-manual-logout]')?.addEventListener('click',logout);
 if(isAdmin){window.ethereum?.on?.('accountsChanged',logout);window.ethereum?.on?.('chainChanged',logout);void privateHistory().catch(()=>privacy(false));}
 if(document.querySelector('[data-manual-status]')){void refresh();setInterval(()=>{if(!document.hidden){void refresh();if(isAdmin&&authenticated)void privateHistory().catch(e=>status(e.message));}},60000);}
 window.CompdManual=Object.freeze({render,clear,history});
})();
