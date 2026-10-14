"""Self-hosted 8-hour COMPD worker. Read-only unless separately armed by the operator."""
import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import time
import urllib.request
from pathlib import Path

AGENT = '0xb878884a07fc84e6a1336e15ca8c6580cd7164c3'
CYCLE = 8 * 3600
SELECTORS = {'startRun': '727ff841', 'requestExit': 'e5a473d5',
             'collectRun': '77f1a2e3', 'closeRun': 'aae128cd'}
READ_METHODS = {'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber',
                'eth_call', 'eth_getCode', 'eth_gasPrice', 'eth_getTransactionCount',
                'eth_getTransactionReceipt', 'eth_getTransactionByHash'}

def address(v):
    if not isinstance(v, str) or not re.fullmatch(r'0x[0-9a-fA-F]{40}', v) or int(v, 16) == 0:
        raise ValueError('Nonzero address required')
    return v.lower()

def hash32(v):
    if not isinstance(v, str) or not re.fullmatch(r'0x[0-9a-fA-F]{64}', v) or int(v, 16) == 0:
        raise ValueError('Nonzero bytes32 required')
    return v.lower()

def uint(v):
    if isinstance(v, bool) or not isinstance(v, (int, str)):
        raise ValueError('Unsigned integer required')
    n = int(v)
    if n < 0 or n >= 2**256:
        raise ValueError('Unsigned integer out of range')
    return n

def config_check(c):
    if c['chainId'] != 56 or address(c['agent']) != AGENT:
        raise ValueError('Frozen chain / Agent identity mismatch')
    for name in ('kernel', 'settlement', 'executor'):
        address(c[name]); hash32(c[name + 'CodeHash'])
    hash32(c['anchorHash']); uint(c['anchorBlock'])
    for name in ('maxGas', 'maxGasPriceWei', 'dailyGasBudgetWei', 'maxPrincipalWei',
                 'dailyPrincipalBudgetWei', 'confirmations', 'maxAttempts', 'retrySeconds'):
        if type(c[name]) is not int or uint(c[name]) <= 0:
            raise ValueError('Positive explicit spending / confirmation / retry limits required')
    if c['maxAttempts'] > 5 or c['retrySeconds'] < 30 or c['confirmations'] > 100:
        raise ValueError('Unbounded retry / confirmation policy')
    if not isinstance(c['approvedAdapters'], list): raise ValueError('Explicit adapter allowlist required')
    for a in c['approvedAdapters']: address(a)
    return c

def action_transaction(c, plan, slot):
    # One explicitly approved action per UTC slot; never replay missed slots or choose trades.
    if type(plan['cycle']) is not int or plan['cycle'] != slot or not isinstance(plan['approvalReference'], str) or not plan['approvalReference'].strip():
        raise ValueError('An explicit approval and exact current cycle required')
    if set(plan) != {'cycle', 'approvalReference', 'action'}:
        raise ValueError('Unknown plan fields')
    a = plan['action']; method = a['method']; rid = uint(a['runId'])
    if method not in SELECTORS or rid == 0:
        raise ValueError('Only canonical Settlement lifecycle calls supported')
    fields = {'method', 'runId', 'reference'} | ({'adapter', 'amountWei'} if method == 'startRun' else set())
    if set(a) != fields:
        raise ValueError('Unknown action fields')
    words = [f'{rid:064x}']
    principal = 0
    if method == 'startRun':
        adapter = address(a['adapter']); principal = uint(a['amountWei'])
        if adapter not in [address(x) for x in c['approvedAdapters']] or not 0 < principal <= c['maxPrincipalWei']:
            raise ValueError('Unapproved adapter or principal cap')
        words += [adapter[2:].rjust(64, '0'), f'{principal:064x}']
    words += [hash32(a['reference'])[2:]]
    return {'from': AGENT, 'to': address(c['settlement']), 'data': '0x' + SELECTORS[method] + ''.join(words),
            'value': '0x0', 'gas': hex(c['maxGas'])}, principal

class RPC:
    def __init__(self, url): self.url = url
    def call(self, method, params):
        if method not in READ_METHODS:
            raise ValueError('Read-only RPC method restriction')
        time.sleep(.2)
        req = urllib.request.Request(self.url, data=json.dumps({'jsonrpc': '2.0', 'id': 1,
            'method': method, 'params': params}).encode(), headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=20) as response: r = json.loads(response.read())
        except Exception:
            raise RuntimeError('RPC transport unavailable') from None
        if 'error' in r: raise RuntimeError('RPC rejected request')
        return r['result']

class Cast:
    def __init__(self, binary='cast', runner=subprocess.run): self.binary = binary; self.runner = runner
    def run(self, args, env=None, input_data=None):
        r = self.runner([self.binary] + args, env=env, input=input_data, capture_output=True, text=True, timeout=60)
        if r.returncode: raise RuntimeError('Cast operation failed')
        return r.stdout.strip()
    def code_hash(self, code):
        if not isinstance(code, str) or not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', code):
            raise ValueError('Executable runtime bytecode required')
        # Kernel runtime exceeds Windows' command-line limit; stdin preserves full bytes/metadata.
        return hash32(self.run(['keccak'], input_data=code))
    def submit(self, tx, nonce, price, url):
        # Called only AFTER durable SUBMITTING + budget reservation. Any exception is ambiguous.
        store = os.environ.get('COMPD_AGENT_KEYSTORE'); password = os.environ.get('COMPD_AGENT_PASSWORD_FILE')
        if not store or not password or not Path(store).is_file() or not Path(password).is_file():
            raise RuntimeError('Encrypted keystore and password file required')
        env = {'PATH': os.environ.get('PATH', ''), 'ETH_RPC_URL': url}
        for key in ('HOME', 'USERPROFILE', 'SYSTEMROOT', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP'):
            if key in os.environ: env[key] = os.environ[key]
        wallet = self.run(['wallet', 'address', '--keystore', store, '--password-file', password], env)
        if address(wallet) != AGENT: raise RuntimeError('Keystore is not approved Agent')
        return hash32(self.run(['send', tx['to'], '--data', tx['data'], '--value', '0', '--chain', '56',
            '--from', AGENT, '--nonce', str(nonce), '--gas-limit', str(int(tx['gas'], 16)),
            '--gas-price', str(price), '--legacy', '--async', '--keystore', store, '--password-file', password], env))

class Scheduler:
    def __init__(self, db, config, rpc, cast, execute=False, approval=None, clock=time.time):
        self.c = config_check(config); self.rpc = rpc; self.cast = cast
        self.clock = clock
        if execute and (not isinstance(approval, str) or not approval.strip()):
            raise ValueError('Separate future execution authorization required')
        self.execute = execute
        self.db = sqlite3.connect(db, timeout=1); self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS jobs (scope TEXT, cycle INTEGER, mode TEXT, state TEXT, '
            'plan TEXT, attempts INTEGER, next_try INTEGER, nonce INTEGER, txhash TEXT, '
            'reserved_gas TEXT, principal TEXT, day INTEGER, PRIMARY KEY(scope,cycle,mode))')
        self.db.execute('CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)')
        self.db.execute('CREATE TABLE IF NOT EXISTS receipts (txhash TEXT PRIMARY KEY, evidence TEXT)')
        fingerprint = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
        row = self.db.execute("SELECT value FROM metadata WHERE key='config'").fetchone()
        if row and row[0] != fingerprint:
            self.db.close()
            raise ValueError('State database config changed; reconciliation required')
        self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('config',?)", (fingerprint,)); self.db.commit()
        self.scope = '56:' + address(self.c['kernel']); self.mode = 'EXECUTE' if execute else 'DRY_RUN'

    def preflight(self):
        r = self.rpc; c = self.c
        if int(r.call('eth_chainId', []), 16) != 56: raise ValueError('Chain ambiguity: suspended')
        anchor = r.call('eth_getBlockByNumber', [hex(c['anchorBlock']), False])
        if not anchor or anchor['hash'].lower() != hash32(c['anchorHash']): raise ValueError('Chain anchor changed: suspended')
        block = r.call('eth_blockNumber', [])
        for name in ('kernel', 'settlement', 'executor'):
            code = r.call('eth_getCode', [address(c[name]), block])
            if code == '0x' or self.cast.code_hash(code) != hash32(c[name + 'CodeHash']):
                raise ValueError('Graph runtime hash changed: suspended')
        # Verify actual constructor-bound links, rather than trusting independent config addresses.
        def read(to, signature, suffix=''):
            selector = self.cast.run(['sig', signature])
            return r.call('eth_call', [{'to': address(to), 'data': selector + suffix}, block]).lower()
        aw = lambda a: '0x' + address(a)[2:].rjust(64, '0')
        if (read(c['kernel'], 'moduleAddress(uint8)', '0'*64) != aw(c['settlement']) or
            read(c['kernel'], 'strategyExecutor()') != aw(c['executor']) or
            read(c['kernel'], 'strategyExecutorHash()') != hash32(c['executorCodeHash']) or
            read(c['settlement'], 'kernel()') != aw(c['kernel']) or
            read(c['settlement'], 'strategyExecutor()') != aw(c['executor']) or
            read(c['settlement'], 'executorHash()') != hash32(c['executorCodeHash']) or
            read(c['executor'], 'kernel()') != aw(c['kernel'])):
            raise ValueError('Constructor graph mismatch: suspended')
        return block

    def observe(self, job):
        if job['state'] == 'SUBMITTING': return 'SUBMISSION_UNKNOWN'  # never resend after crash/timeout
        if job['state'] != 'PENDING': return job['state']
        # Even receipt monitoring refuses changed chain identities.
        self.preflight()
        receipt = self.rpc.call('eth_getTransactionReceipt', [job['txhash']])
        if not receipt: return 'PENDING'
        number = int(receipt['blockNumber'], 16)
        block = self.rpc.call('eth_getBlockByNumber', [hex(number), False])
        if not block or block['hash'].lower() != receipt['blockHash'].lower(): return 'REORG_PENDING'
        tx = self.rpc.call('eth_getTransactionByHash', [job['txhash']])
        planned, _ = action_transaction(self.c, json.loads(job['plan']), job['cycle'])
        if (not tx or tx['hash'].lower() != job['txhash'].lower() or address(tx['from']) != AGENT or
            address(tx['to']) != planned['to'] or tx['input'].lower() != planned['data'] or
            int(tx['value'], 16) != 0 or int(tx['nonce'], 16) != job['nonce'] or
            receipt['transactionHash'].lower() != job['txhash'].lower()):
            raise ValueError('Receipt transaction identity mismatch')
        latest = int(self.rpc.call('eth_blockNumber', []), 16)
        if latest - number + 1 < self.c['confirmations']: return 'PENDING'
        if int(receipt['gasUsed'], 16) > self.c['maxGas']:
            raise ValueError('Receipt exceeded configured gas limit')
        status = int(receipt['status'], 16)
        if status not in (0, 1): raise ValueError('Invalid receipt status')
        state = 'CONFIRMED' if status else 'REVERTED'
        self.db.execute('INSERT OR REPLACE INTO receipts VALUES (?,?)', (job['txhash'], json.dumps(receipt, sort_keys=True)))
        self.db.execute('UPDATE jobs SET state=? WHERE scope=? AND cycle=? AND mode=?',
            (state, self.scope, job['cycle'], job['mode'])); self.db.commit()
        # Never release reserved fee/principal automatically; conservative UTC-day caps.
        return state

    def tick(self, now, plan=None, action_key=None):
        if action_key is not None and not re.fullmatch(r'[0-9a-f]{64}', action_key):
            raise ValueError('Invalid automatic action key')
        self.mode = ('EXECUTE' if self.execute else 'DRY_RUN') + (':' + action_key if action_key else '')
        # SQLite write lock spans preflight/send: concurrent processes cannot race this DB.
        self.db.execute('BEGIN IMMEDIATE')
        try:
            result = self._tick(int(now), plan)
            self.db.commit(); return result
        except BaseException:
            self.db.rollback(); raise

    def _tick(self, now, plan):
        pending = self.db.execute("SELECT * FROM jobs WHERE scope=? AND mode LIKE 'EXECUTE%' AND state IN ('SUBMITTING','PENDING') ORDER BY cycle LIMIT 1", (self.scope,)).fetchone()
        if pending:
            # Observation can commit; reacquire before proceeding on a later tick.
            return {'status': self.observe(pending), 'cycle': pending['cycle']}
        # A failed/unknown transaction needs explicit operator reconciliation, not an automatic new strategy.
        stopped = self.db.execute("SELECT cycle FROM jobs WHERE scope=? AND mode LIKE 'EXECUTE%' AND state='REVERTED' LIMIT 1", (self.scope,)).fetchone()
        if stopped: return {'status': 'REVERTED_STOP', 'cycle': stopped[0]}
        slot = now // CYCLE
        if plan is None: return {'status': 'IDLE_NO_APPROVED_PLAN', 'cycle': slot, 'mode': self.mode}
        tx, principal = action_transaction(self.c, plan, slot)
        encoded = json.dumps(plan, sort_keys=True, separators=(',', ':'))
        job = self.db.execute('SELECT * FROM jobs WHERE scope=? AND cycle=? AND mode=?', (self.scope, slot, self.mode)).fetchone()
        if job:
            if job['plan'] != encoded: raise ValueError('Cycle plan mutation prohibited')
            if job['state'] != 'RETRY': return {'status': job['state'], 'cycle': slot}
            if now < job['next_try']: return {'status': 'BACKOFF', 'cycle': slot}
        else:
            self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,0,0,NULL,NULL,?,?,?)',
                (self.scope, slot, self.mode, 'RETRY', encoded, '0', '0', now // 86400))
        attempts = (job['attempts'] if job else 0) + 1
        try:
            block = self.preflight()
            # Canonical risk/lifecycle/adapter/position limits remain enforced by eth_call and contracts.
            self.rpc.call('eth_call', [tx, block])
            price = int(self.rpc.call('eth_gasPrice', []), 16)
            if not 0 < price <= self.c['maxGasPriceWei']: raise ValueError('Gas price cap')
            fee = self.c['maxGas'] * price
            spent = self.db.execute("SELECT reserved_gas,principal FROM jobs WHERE scope=? AND mode LIKE 'EXECUTE%' AND day=?", (self.scope, now // 86400)).fetchall()
            if sum(int(x[0]) for x in spent) + fee > self.c['dailyGasBudgetWei']: raise ValueError('Daily fee budget')
            if sum(int(x[1]) for x in spent) + principal > self.c['dailyPrincipalBudgetWei']: raise ValueError('Daily principal budget')
            nonce = int(self.rpc.call('eth_getTransactionCount', [AGENT, 'pending']), 16)
            confirmed_nonce = int(self.rpc.call('eth_getTransactionCount', [AGENT, 'latest']), 16)
            if nonce != confirmed_nonce: raise ValueError('Unreconciled Agent pending nonce')
        except Exception as error:
            state = 'EXHAUSTED' if attempts >= self.c['maxAttempts'] else 'RETRY'
            self.db.execute('UPDATE jobs SET state=?,attempts=?,next_try=? WHERE scope=? AND cycle=? AND mode=?',
                (state, attempts, now + self.c['retrySeconds'] * 2**(attempts-1), self.scope, slot, self.mode))
            return {'status': state, 'cycle': slot, 'errorType': type(error).__name__}
        if not self.execute:
            self.db.execute("UPDATE jobs SET state='SIMULATED',attempts=? WHERE scope=? AND cycle=? AND mode=?", (attempts, self.scope, slot, self.mode))
            return {'status': 'SIMULATED', 'cycle': slot, 'unsignedTransaction': {**tx, 'chainId': '0x38', 'nonce': hex(nonce), 'gasPrice': hex(price)}, 'mode': 'DRY_RUN'}
        if int(self.clock()) // CYCLE != slot:
            self.db.execute("UPDATE jobs SET state='EXPIRED' WHERE scope=? AND cycle=? AND mode=?", (self.scope, slot, self.mode))
            return {'status': 'EXPIRED', 'cycle': slot}
        self.db.execute("UPDATE jobs SET state='SUBMITTING',attempts=?,nonce=?,reserved_gas=?,principal=? WHERE scope=? AND cycle=? AND mode=?",
            (attempts, nonce, str(fee), str(principal), self.scope, slot, self.mode))
        self.db.commit()  # crash boundary: reserve before invoking any signer
        self.db.execute('BEGIN IMMEDIATE')
        try: txhash = hash32(self.cast.submit(tx, nonce, price, self.rpc.url))
        except Exception: return {'status': 'SUBMISSION_UNKNOWN', 'cycle': slot}
        self.db.execute("UPDATE jobs SET state='PENDING',txhash=? WHERE scope=? AND cycle=? AND mode=?", (txhash, self.scope, slot, self.mode))
        return {'status': 'PENDING', 'cycle': slot, 'transactionHash': txhash}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', required=True); p.add_argument('--plan'); p.add_argument('--policy'); p.add_argument('--xstocks-policy'); p.add_argument('--state', default='agent-state.sqlite')
    p.add_argument('--once', action='store_true'); p.add_argument('--interval', type=int, default=60)
    p.add_argument('--execute', action='store_true', help='OFF by default; separate future owner authorization required')
    p.add_argument('--execution-approval'); args = p.parse_args()
    if args.interval < 30: p.error('Polling minimum 30 seconds')
    if args.execute:
        p.error('Production trading remains disabled pending approved xStocks venue/routes, independent pricing, entry/exit and settlement finality. Local injected execution tests remain available.')
    url = os.environ.get('BSC_RPC_URL')
    if not url: p.error('BSC_RPC_URL is required; never logged')
    scheduler = Scheduler(args.state, json.loads(Path(args.config).read_text()), RPC(url),
        Cast(os.environ.get('COMPD_CAST_BIN', 'cast')), args.execute, args.execution_approval)
    from agent_lifecycle import AutoLifecycle
    from xstocks_agent import XStocksLifecycle
    if args.xstocks_policy and (args.policy or args.plan): p.error('xStocks policy cannot be combined with legacy plans')
    automatic = (AutoLifecycle(scheduler, json.loads(Path(args.policy).read_text())) if args.policy else
                 XStocksLifecycle(scheduler, json.loads(Path(args.xstocks_policy).read_text()) if args.xstocks_policy else None))
    while True:
        try:
            plan = json.loads(Path(args.plan).read_text()) if args.plan and Path(args.plan).is_file() else None
            result = scheduler.tick(time.time(), plan) if args.plan else automatic.tick(time.time())
        except Exception as error: result = {'status': 'SUSPENDED', 'errorType': type(error).__name__}
        print(json.dumps(result), flush=True)
        if args.once: break
        time.sleep(args.interval)

if __name__ == '__main__': main()

