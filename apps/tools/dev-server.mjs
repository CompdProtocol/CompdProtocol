import {manualEndpoint,proxyManual} from './manual-api.mjs';
import {fetchStatus,statusEndpoint} from './protocol-api.mjs';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildDirectory, frontendFiles, marketSymbols, pageRoutes, sourceDirectory } from '../site.config.mjs';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const useBuild = process.argv.includes('--dist');
const staticRoot = resolve(packageRoot, useBuild ? buildDirectory : sourceDirectory);
const allowedFiles = new Set(frontendFiles);
const runs = new Map();
const paperDemo=process.argv.includes('--paper-demo');
const backend=statusEndpoint(process.env.COMPD_STATUS_URL);
const manualBackend=manualEndpoint(process.env.COMPD_MANUAL_URL);
const marketNames = Object.freeze({ AAPLx: 'Apple Inc.', NVDAx: 'NVIDIA', SPCXx: 'SpaceX exposure', TSLAx: 'Tesla', MSFTx: 'Microsoft', AMZNx: 'Amazon', SPYx: 'S&P 500' });
const mimeTypes = Object.freeze({ '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png' });

function sendJson(response, status, data) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  response.end(JSON.stringify(data));
}
function sendText(response, status, message) {
  response.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'x-content-type-options': 'nosniff' });
  response.end(message);
}
async function readJsonBody(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 64 * 1024) throw Object.assign(new Error('Request body is too large.'), { statusCode: 413 });
  }
  try { return body ? JSON.parse(body) : {}; }
  catch { throw Object.assign(new Error('Request body must be valid JSON.'), { statusCode: 400 }); }
}
function timestamp() { return new Date().toISOString(); }
function addStatusEvent(run, message) { run.events.unshift({ type: 'status', stage: 'paper', timestamp: timestamp(), message }); }
function publicRun(run) { return structuredClone({ ...run, transactionsSent: false }); }

async function handleApi(request, response, url) {
  const pathname = url.pathname;
  if(pathname.startsWith('/api/manual/'))return proxyManual(request,response,url,manualBackend);
  if(pathname==='/api/protocol/status') {
    if(request.method!=='GET')return sendJson(response,405,{error:'Read-only endpoint.'});
    try{return sendJson(response,200,await fetchStatus(backend));}
    catch{return sendJson(response,503,{error:'Protocol data not available',availability:'NOT_AVAILABLE'});}
  }
  if (pathname === '/api/health') {
    if (request.method !== 'GET') return sendJson(response, 405, { error: 'Method not allowed.' });
    return sendJson(response, 200, { mode: 'read-only-integration', tradingEnabled: false, paperTradingEnabled: paperDemo, internalTestProfile: false, holderTokenLabel: 'COMPD', walletEligibilityConfigured: false });
  }
  if (pathname === '/api/assets') {
    if (request.method !== 'GET') return sendJson(response, 405, { error: 'Method not allowed.' });
    const assets = marketSymbols.map((symbol) => ({ symbol, name: marketNames[symbol], underlying: { symbol: symbol.replace(/x$/, ''), currency: 'USD' }, deployments: [], isTradingHalted: null, verifiedOnBsc: false, quote: null, currency: 'USD', quoteFreshnessVerified: false, quoteSource: 'No approved price provider connected' }));
    return sendJson(response, 200, { mode: 'read-only-integration', stale: true, fetchedAt: null, assets });
  }
  if (pathname === '/api/eligibility') {
    if (request.method !== 'GET') return sendJson(response, 405, { error: 'Method not allowed.' });
    const address = url.searchParams.get('address') || '';
    if (!/^0x[a-fA-F0-9]{40}$/.test(address)) return sendJson(response, 400, { configured: true, eligible: null, error: 'Enter a valid 42-character demo address.' });
    return sendJson(response, 200, {mode:'read-only-integration',configured:false,eligible:null,balance:null,minimumBalance:'500000',network:'BNB Chain',blockNumber:null,tokenLabel:'COMPD',reason:'Finalized COMPD holder tracking not available'});
  }
  if(pathname.startsWith('/api/paper/')&&!paperDemo)return sendJson(response,503,{error:'Paper preview not enabled. No strategy engine or market provider connected.'});
  if (pathname === '/api/paper/runs' && request.method === 'POST') {
    let input;
    try { input = await readJsonBody(request); }
    catch (error) { return sendJson(response, error.statusCode || 400, { error: error.message }); }
    const markets = Array.isArray(input.markets) ? [...new Set(input.markets)] : [];
    const durationDays = Number(input.durationDays);
    if (!markets.length || markets.some((symbol) => !marketSymbols.includes(symbol))) return sendJson(response, 400, { error: 'Choose one or more supported demo markets.' });
    if (![1, 3, 7].includes(durationDays)) return sendJson(response, 400, { error: 'Demo duration must be 1, 3, or 7 days.' });
    const run = { id: randomUUID(), mode: 'paper-mock', status: 'waiting_for_data', markets, durationDays, remainingMs: durationDays * 86400000, observations: Object.fromEntries(markets.map((symbol) => [symbol, 0])), events: [{ type: 'status', stage: 'paper', timestamp: timestamp(), message: 'Local mock only · live market quotes unavailable · no orders or transactions are sent.' }], openPaperPositions: [], risk: null, createdAt: timestamp() };
    runs.set(run.id, run);
    return sendJson(response, 201, publicRun(run));
  }
  const runMatch = pathname.match(/^\/api\/paper\/runs\/([^/]+)(?:\/(pause|resume|stop))?$/);
  if (runMatch) {
    const [, runId, action] = runMatch;
    const run = runId === 'latest' ? [...runs.values()].at(-1) : runs.get(runId);
    if (!run) return sendJson(response, 404, { error: 'Paper run not found.' });
    if (!action && request.method === 'GET') return sendJson(response, 200, publicRun(run));
    if (request.method !== 'POST' || !action) return sendJson(response, 405, { error: 'Method not allowed.' });
    if (action === 'pause' && run.status === 'waiting_for_data') { run.status = 'paused'; addStatusEvent(run, 'Local paper mock paused.'); }
    else if (action === 'resume' && run.status === 'paused') { run.status = 'waiting_for_data'; addStatusEvent(run, 'Local paper mock resumed · still waiting for provider data.'); }
    else if (action === 'stop' && ['waiting_for_data', 'paused'].includes(run.status)) { run.status = 'stopped'; addStatusEvent(run, 'Local paper mock stopped. No orders or transactions were sent.'); }
    else return sendJson(response, 409, { error: 'Action is unavailable for this local mock run state.' });
    return sendJson(response, 200, publicRun(run));
  }
  return sendJson(response, 404, { error: 'No local mock API route exists here.' });
}

const server = createServer(async (request, response) => {
  let url;
  try { url = new URL(request.url || '/', 'http://127.0.0.1'); }
  catch { return sendText(response, 400, 'Bad request.'); }
  const host=request.headers.host;
  if(!host||!['127.0.0.1','localhost','[::1]'].some(h=>host===h+':'+server.address().port))return sendText(response,403,'Local host required.');
  if(request.headers.origin&&request.headers.origin!=='http://'+host)return sendText(response,403,'Same-origin requests only.');
  if (url.pathname.startsWith('/api/')) return handleApi(request, response, url);
  if (request.method !== 'GET' && request.method !== 'HEAD') return sendText(response, 405, 'Method not allowed.');
  let pathname;
  try { pathname = decodeURIComponent(url.pathname); }
  catch { return sendText(response, 400, 'Bad path.'); }
  const relativeFile = pageRoutes[pathname] || pathname.replace(/^\/+/, '');
  if (!allowedFiles.has(relativeFile) || relativeFile.includes('..') || relativeFile.includes('\\')) return sendText(response, 404, 'Not found.');
  try {
    const bytes = await readFile(resolve(staticRoot, relativeFile));
    response.writeHead(200, { 'content-type': mimeTypes[extname(relativeFile)] || 'application/octet-stream', 'cache-control': 'no-cache', 'x-content-type-options': 'nosniff' });
    response.end(request.method === 'HEAD' ? undefined : bytes);
  } catch {
    sendText(response, 404, 'Not found. Run npm run build before using the dist preview.');
  }
});

const port = Number(process.env.PORT || 4173);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('PORT must be an integer from 0 to 65535.');
server.listen(port, '127.0.0.1', () => {
  const address = server.address();
  process.stdout.write('COMPD local frontend (' + (useBuild ? 'dist' : 'source') + ' + read-only API): http://127.0.0.1:' + address.port + '\n');
});