const routes=new Map([['/public',['GET']],['/auth/challenge',['POST']],['/auth/login',['POST']],['/auth/logout',['POST']],['/records',['GET','POST']],['/records/reverify',['POST']]]);
export function manualEndpoint(value){
 if(!value)return null;const u=new URL(value);
 if(u.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(u.hostname)||u.username||u.password||u.search||u.hash||u.pathname!=='/')throw Error('Manual service must be a credential-free loopback base URL');
 return u.href;
}
export async function proxyManual(request,response,url,base){
 const path=url.pathname.slice('/api/manual'.length),methods=routes.get(path);
 const send=(status,data)=>{response.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});response.end(JSON.stringify(data));};
 if(!methods||url.search||!methods.includes(request.method))return send(405,{error:'Unsupported manual evidence API request'});
 if(!base)return send(503,{error:'Manual evidence service not configured',availability:'Not Available'});
 let body;if(request.method==='POST'){
  let size=0;const chunks=[];for await(const chunk of request){size+=chunk.length;if(size>4096)return send(413,{error:'Request too large'});chunks.push(chunk);}body=Buffer.concat(chunks);
 }
 try{
  const upstream=await fetch(new URL(path.slice(1),base),{method:request.method,redirect:'error',signal:AbortSignal.timeout(180000),headers:{'content-type':'application/json',Origin:'http://'+request.headers.host,...(request.headers.cookie?{Cookie:request.headers.cookie}:{})},body});
  const data=await upstream.text();if(Buffer.byteLength(data)>1024*1024)throw Error('Response too large');
  if(!upstream.ok)return send(upstream.status,{error:upstream.status===401?'Owner sign-in required':upstream.status===400?'Invalid submission':'Evidence service unavailable'});
  const payload=JSON.parse(data);const cookie=upstream.headers.get('set-cookie');if(cookie)response.setHeader('Set-Cookie',cookie);
  return send(200,payload);
 }catch{return send(503,{error:'Evidence service unavailable; no transaction sent'});}
}
