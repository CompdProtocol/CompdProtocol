import assert from 'node:assert/strict';
import {test,before,after} from 'node:test';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readFile} from 'node:fs/promises';
import {manualEndpoint} from '../tools/manual-api.mjs';
let child,backend,base,received=[];
before(async()=>{
 backend=createServer((request,response)=>{
  received.push({url:request.url,method:request.method,cookie:request.headers.cookie,origin:request.headers.origin});
  response.setHeader('content-type','application/json');
  if(request.url==='/auth/login'){response.setHeader('set-cookie','compd_admin=fixture; HttpOnly; SameSite=Strict; Path=/api/manual; Max-Age=900');response.end(JSON.stringify({authenticated:true}));}
  else if(request.url==='/records'&&!request.headers.cookie){response.writeHead(401);response.end('{}');}
  else response.end(JSON.stringify({mode:'MANUAL_ONLY',automaticExecution:false,history:[],totals:null,records:[]}));
 });backend.listen(0,'127.0.0.1');await once(backend,'listening');
 child=spawn(process.execPath,['tools/dev-server.mjs'],{cwd:new URL('../',import.meta.url),env:{...process.env,PORT:'0',COMPD_STATUS_URL:'',COMPD_MANUAL_URL:'http://127.0.0.1:'+backend.address().port+'/'},stdio:['ignore','pipe','pipe']});
 let text='';base=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Startup timeout')),8000);child.stdout.on('data',chunk=>{text+=chunk;const m=text.match(/http:\/\/127\.0\.0\.1:(\d+)/);if(m){clearTimeout(timer);resolve(m[0]);}});child.once('exit',()=>reject(Error('Server stopped')));});
});
after(async()=>{child?.kill();backend?.closeAllConnections();if(backend)await new Promise(r=>backend.close(r));});
test('manual backend address is fixed loopback without credentials',()=>{
 assert.equal(manualEndpoint('http://127.0.0.1:4175/'),'http://127.0.0.1:4175/');
 for(const value of ['https://remote.example/','http://user:secret@localhost/','http://localhost/private','http://localhost/?key=SECRET'])assert.throws(()=>manualEndpoint(value));
});
test('new admin page preserves design and provides only sign-in/hash controls',async()=>{
 const response=await fetch(base+'/admin');assert.equal(response.status,200);const html=await response.text();
 for(const marker of ['compd-system.css','compd-shell.js','data-manual-signin','data-manual-submit','name="transactionHash"','data-manual-private hidden'])assert.ok(html.includes(marker));
 assert.ok(!html.includes('name="amount"'));assert.equal((await fetch(base+'/compd-manual.js')).status,200);
});
test('public manual records do not fake balances and private API requires session',async()=>{
 const data=await(await fetch(base+'/api/manual/public')).json();assert.equal(data.automaticExecution,false);assert.equal(data.totals,null);
 assert.equal((await fetch(base+'/api/manual/records')).status,401);
});
test('cookie remains HttpOnly and is forwarded to evidence service',async()=>{
 const r=await fetch(base+'/api/manual/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:'fixture',signature:'fixture'})});assert.equal(r.status,200);assert.match(r.headers.get('set-cookie'),/HttpOnly; SameSite=Strict/);
 const h=await fetch(base+'/api/manual/records',{headers:{Cookie:'compd_admin=fixture'}});assert.equal(h.status,200);assert.equal(received.at(-1).cookie,'compd_admin=fixture');assert.equal(received.at(-1).origin,base);
});
test('foreign origin, arbitrary proxy targets and overlarge bodies are rejected',async()=>{
 assert.equal((await fetch(base+'/api/manual/auth/challenge',{method:'POST',headers:{Origin:'https://evil.example'},body:'{}'})).status,403);
 assert.equal((await fetch(base+'/api/manual/execute',{method:'POST',body:'{}'})).status,405);
 assert.equal((await fetch(base+'/api/manual/records?url=https://evil.example')).status,405);
 assert.equal((await fetch(base+'/api/manual/records',{method:'POST',body:'x'.repeat(4097)})).status,413);
});
test('wallet code requests messages only and histories use safe BscScan links',async()=>{
 const js=await readFile(new URL('../src/compd-manual.js',import.meta.url),'utf8');
 assert.match(js,/method:'personal_sign'/);assert.match(js,/eth_chainId/);assert.match(js,/https:\/\/bscscan.com\/tx\//);
 assert.ok(!/eth_send|signTransaction|eth_signTypedData|innerHTML|localStorage|sessionStorage/.test(js));
 const html=await readFile(new URL('../src/flow.html',import.meta.url),'utf8');
 for(const key of ['availableReserveWei','tokensPurchasedBaseUnits','deadTokensBaseUnits','nativeBurnedBaseUnits'])assert.ok(html.includes(key));
 assert.match(html,/owner-funded buys never reduce/);
});
