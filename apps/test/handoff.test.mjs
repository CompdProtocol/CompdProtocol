import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { after, before, test } from 'node:test';

let server;
let baseUrl;

before(async () => {
  server = spawn(process.execPath, ['tools/dev-server.mjs'], {
    cwd: new URL('../', import.meta.url),
    env: { ...process.env, PORT: '0',COMPD_STATUS_URL:'', },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let errors = '';
  const startup = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Local mock server startup timed out. ' + output + errors)), 7000);
    server.stdout.on('data', (chunk) => {
      output += chunk.toString();
      const match = output.match(/COMPD local frontend \(source \+ read-only API\): http:\/\/127\.0\.0\.1:(\d+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    server.stderr.on('data', (chunk) => { errors += chunk.toString(); });
    server.once('error', (error) => { clearTimeout(timer); reject(error); });
    server.once('exit', (code) => { clearTimeout(timer); reject(new Error('Local mock server exited with ' + code + '. ' + output + errors)); });
  });
  const port = await startup;
  baseUrl = 'http://127.0.0.1:' + port;
});

after(async () => {
  if (server && server.exitCode === null) {
    const exited = once(server, 'exit');
    server.kill('SIGTERM');
    await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 2000))]);
  }
});

test('all seven page routes load, including clean URLs and Paper Workspace', async () => {
  const routes = ['/', '/treasury', '/agent', '/flow', '/protocol', '/docs', '/app'];
  for (const route of routes) {
    const response = await fetch(baseUrl + route);
    assert.equal(response.status, 200, route + ' should load');
    assert.match(response.headers.get('content-type') || '', /text\/html/);
    assert.match(await response.text(), /<title>/);
  }
});

test('Flow route includes its CSS, interaction script, and public economics view', async () => {
  const html = await (await fetch(baseUrl + '/flow')).text();
  assert.match(html, /Capital,/);
  assert.match(html, /data-flow-tab="revenue"/);
  assert.match(html, /data-flow-tab="strategy"/);
  assert.match(html, /data-flow-tab="buyback"/);
  for (const asset of ['/flow-page.css', '/flow-page.js', '/compd-system.css', '/compd-stack-mark.png']) {
    assert.equal((await fetch(baseUrl + asset)).status, 200, asset + ' should load');
  }
});

test('read-only API exposes no-provider markets and unavailable holder eligibility', async () => {
  const health = await (await fetch(baseUrl + '/api/health')).json();
  assert.equal(health.mode, 'read-only-integration');
  assert.equal(health.tradingEnabled, false);
  assert.equal(health.paperTradingEnabled, false);
  assert.equal(health.holderTokenLabel, 'COMPD');
  assert.equal(health.tokenAddress, undefined);
  assert.equal(health.rpcUrl, undefined);
  const assets = await (await fetch(baseUrl + '/api/assets')).json();
  assert.equal(assets.mode, 'read-only-integration');
  assert.equal(assets.stale, true);
  assert.ok(assets.assets.length > 0);
  assert.ok(assets.assets.every((asset) => asset.quote === null && asset.tokenAddress === undefined && asset.verifiedOnBsc === false));
  const address = '0x' + 'a'.repeat(40);
  const eligibility = await (await fetch(baseUrl + '/api/eligibility?address=' + address)).json();
  assert.equal(eligibility.network, 'BNB Chain');
  assert.equal(eligibility.tokenLabel, 'COMPD');
  assert.equal(eligibility.eligible, null);
  assert.equal(eligibility.balance,null);
});

test('paper controls are disabled by default and never route to a signer',async()=>{
 const response=await fetch(baseUrl+'/api/paper/runs',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({markets:['AAPLx'],durationDays:1})});
 assert.equal(response.status,503);assert.match((await response.json()).error,/not enabled/);
 for(const route of ['/api/execute','/api/config','/api/activate'])assert.equal((await fetch(baseUrl+route)).status,404);
});

test('landing links all five pages, has one primary CTA, and loads only local scripts', async () => {
  const html = await (await fetch(baseUrl + '/')).text();
  for (const page of ['agent.html', 'treasury.html', 'flow.html', 'protocol.html', 'docs.html', 'app.html']) assert.ok(html.includes('href="' + page + '"'), page + ' should be linked');
  assert.equal((html.match(/class="button-primary"/g) || []).length, 1);
  assert.doesNotMatch(html, /(?:src|href)="https?:/);
  for (const asset of ['/landing.css', '/landing.js', '/compd-scene.js', '/compd-atmosphere.css', '/vendor/gsap.min.js', '/vendor/ScrollTrigger.min.js', '/vendor/three-subset.min.js']) {
    assert.equal((await fetch(baseUrl + asset)).status, 200, asset + ' should load');
  }
});

test('every page includes the shared atmosphere, and Paper Workspace links to Flow', async () => {
  for (const route of ['/', '/treasury', '/agent', '/flow', '/protocol', '/docs', '/app']) {
    const html = await (await fetch(baseUrl + route)).text();
    assert.match(html, /compd-atmosphere\.css/, route + ' should include the shared atmosphere');
    assert.match(html, /class="scene-layer"/, route + ' should render the atmosphere layer');
    assert.doesNotMatch(html, /(?:src|href)="https?:/, route + ' should not load external assets');
  }
  const app = await (await fetch(baseUrl + '/app')).text();
  assert.equal((app.match(/href="flow\.html"/g) || []).length, 3, 'nav, menu and footer link to Flow');
  assert.doesNotMatch(app, /compd-scene\.js/);
});

test('content pages load the shared intro scene with their Chapter layout', async () => {
  for (const page of ['treasury', 'agent', 'protocol', 'docs']) {
    const html = await (await fetch(baseUrl + '/' + page)).text();
    assert.match(html, new RegExp('data-scene="' + page + '"'));
    assert.match(html, /compd-page\.js/);
    assert.match(html, /<canvas id="scene">/);
  }
  assert.equal((await fetch(baseUrl + '/compd-page.js')).status, 200);
});

test('Flow tabs carry each flow, the dot legend, manual buyback labels and approved values', async () => {
  const html = await (await fetch(baseUrl + '/flow')).text();
  assert.equal((html.match(/data-flow-panel="/g) || []).length, 3);
  assert.equal((html.match(/data-flow-stage="/g) || []).length, 3);
  assert.match(html, /1 dot = 1% of the flow/);
  assert.match(html, /automatic buyback execution is disabled/);
  for (const value of ['35 go to Strategy Capital', '15 to the Buyback Reserve', '50 to the Protocol Reserve', '65 compound', '15 go to the Buyback Reserve', '10 to the Protocol Reserve', '0.25 BNB', '0.50 BNB']) {
    assert.ok(html.includes(value), value);
  }
});
