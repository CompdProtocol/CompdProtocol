// Single same-origin API layer. Public reads omit credentials; manual review uses same-origin HttpOnly cookies. No RPC URL in browser code.
(() => {
 const BASE='/api';
 async function request(path,options={}){
  if(typeof path!=='string'||!path.startsWith(BASE+'/')||path.includes('..'))throw Error('Unsupported API path');
  const response=await fetch(path,{cache:'no-store',credentials:'omit',signal:AbortSignal.timeout(35000),...options,headers:{'content-type':'application/json',...(options.headers||{})}});
  const data=await response.json();if(!response.ok)throw Error(data.error||'Data not available');return data;
 }
 window.CompdAPI=Object.freeze({base:BASE,request,status:()=>request(BASE+'/protocol/status'),manual:(route,body)=>{
  if(!/^(public|auth\/(challenge|login|logout)|records(\/reverify)?)$/.test(route))throw Error('Unsupported manual API route');
  return request(BASE+'/manual/'+route,{method:body===undefined?'GET':'POST',credentials:'same-origin',signal:AbortSignal.timeout(180000),body:body===undefined?undefined:JSON.stringify(body)});
 }});
})();
