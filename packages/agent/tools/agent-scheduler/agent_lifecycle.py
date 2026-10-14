"""Canonical lifecycle planner. No default trading or loss-finality policy."""
import hashlib
import json
from agent_scheduler import AGENT, CYCLE, address, hash32, uint

def digest(*parts):
    return '0x' + hashlib.sha256(json.dumps(parts, separators=(',', ':')).encode()).hexdigest()

def policy_check(policy, config):
    if policy is None: return None
    fields = {'approvalReference', 'adapter', 'adapterCodeHash', 'entryRule', 'allocationBps',
              'holdSeconds', 'settlementRule'}
    if set(policy) != fields or not isinstance(policy['approvalReference'], str) or not policy['approvalReference'].strip():
        raise ValueError('Explicit standing policy approval required')
    if policy['entryRule'] != 'ADMITTED_ADAPTER_EACH_8H_SLOT': raise ValueError('Undefined entry rule')
    if policy['settlementRule'] != 'FULL_PRINCIPAL_NO_PENDING_CLAIM': raise ValueError('Undefined settlement rule')
    if type(policy['allocationBps']) is not int or not 0 < policy['allocationBps'] <= 1000:
        raise ValueError('Position fraction exceeds canonical 10% limit')
    if type(policy['holdSeconds']) is not int or policy['holdSeconds'] <= 0:
        raise ValueError('Explicit approved holding period required')
    if address(policy['adapter']) not in [address(a) for a in config['approvedAdapters']]:
        raise ValueError('Policy adapter outside owner allowlist')
    hash32(policy['adapterCodeHash'])
    return policy

class ChainView:
    def __init__(self, scheduler, block): self.s=scheduler; self.block=block
    def words(self, target, signature, args=(), count=1):
        selector=self.s.cast.run(['sig', signature])
        encoded=''.join((address(a)[2:].rjust(64,'0') if isinstance(a,str) and len(a)==42 else f'{uint(a):064x}') for a in args)
        result=self.s.rpc.call('eth_call',[{'to':address(target),'data':selector+encoded},self.block])
        if not isinstance(result,str) or len(result)!=2+count*64 or not result.startswith('0x'):
            raise ValueError('Unexpected canonical ABI result')
        return [int(result[2+i*64:2+(i+1)*64],16) for i in range(count)]
    def one(self,target,signature,args=()): return self.words(target,signature,args)[0]
    def run(self, rid):
        w=self.words(self.s.c['settlement'],'run(uint256)',(rid,),15)
        if w[0] >= 2**160 or w[10]>6 or w[13] not in (0,1): raise ValueError('Malformed run state')
        return dict(id=str(rid),adapter='0x'+f'{w[0]:040x}',principal=w[1],credited=w[2],returned=w[3],
                    openedAt=w[4],allocation=hash32('0x'+f'{w[6]:064x}') if w[6] else None,
                    exitId='0x'+f'{w[7]:064x}',state=w[10],attempts=w[14],actualLoss=w[12],lossBoundBreached=bool(w[13]))

class AutoLifecycle:
    def __init__(self, scheduler, policy=None):
        self.s=scheduler; self.policy=policy_check(policy,scheduler.c)
        self.s.db.execute('CREATE TABLE IF NOT EXISTS auto_runs (id TEXT PRIMARY KEY, state INTEGER)')
        self.s.db.execute('CREATE TABLE IF NOT EXISTS auto_plans (cycle INTEGER, action_key TEXT, plan TEXT, PRIMARY KEY(cycle,action_key))')
        self.s.db.execute('CREATE TABLE IF NOT EXISTS auto_records (id INTEGER PRIMARY KEY, cycle INTEGER, stage TEXT, evidence TEXT)')
        fingerprint=digest('COMPD_STANDING_POLICY_V1',policy)
        old=self.s.db.execute("SELECT value FROM metadata WHERE key='auto_policy'").fetchone()
        if old and old[0]!=fingerprint: raise ValueError('Standing policy changed; explicit state reconciliation required')
        self.s.db.execute("INSERT OR IGNORE INTO metadata VALUES ('auto_policy',?)",(fingerprint,))
        self.s.db.execute("INSERT OR IGNORE INTO metadata VALUES ('history_cursor','0')")
        self.s.db.commit()

    def record(self,slot,stage,evidence):
        # Only record meaningful transitions, not every idle poll.
        encoded=json.dumps(evidence,sort_keys=True)
        last=self.s.db.execute('SELECT cycle,stage,evidence FROM auto_records ORDER BY id DESC LIMIT 1').fetchone()
        if not last or tuple(last)!=(slot,stage,encoded):
            self.s.db.execute('INSERT INTO auto_records(cycle,stage,evidence) VALUES (?,?,?)',(slot,stage,encoded))

    def snapshot(self,block):
        v=ChainView(self.s,block); c=self.s.c; k=c['kernel']; m=c['settlement']
        b=self.s.rpc.call('eth_getBlockByNumber',[block,False])
        if not b or 'timestamp' not in b: raise ValueError('Pinned block timestamp required')
        snap=dict(block=block,blockHash=hash32(b['hash']),timestamp=int(b['timestamp'],16),
            lifecycle=v.one(k,'lifecycle()'),capital=v.one(k,'strategyCapital()'),
            active=v.one(k,'activePrincipal()'),accounted=v.one(k,'accountedQuote()'),
            runCount=v.one(k,'activeRunCount()'),halted=v.one(k,'strategyAllocationHalted()'),
            risk=v.one(m,'riskLatched()'),runs=[])
        if snap['lifecycle']>4 or snap['runCount']>3 or snap['active']>snap['capital']:
            raise ValueError('Inconsistent canonical accounting')
        length=v.one(m,'historyLength()')
        cursor=int(self.s.db.execute("SELECT value FROM metadata WHERE key='history_cursor'").fetchone()[0])
        if length<cursor: raise ValueError('Append-only history rolled back; reconcile')
        # Bounded ingestion: never make one poll scale with lifetime history.
        end=min(length,cursor+64)
        for i in range(cursor,end):
            rid=v.one(m,'historyAt(uint256)',(i,)); r=v.run(rid)
            if r['state'] not in (0,6):self.s.db.execute('INSERT OR IGNORE INTO auto_runs VALUES (?,?)',(str(rid),r['state']))
        self.s.db.execute("UPDATE metadata SET value=? WHERE key='history_cursor'",(str(end),))
        snap['historyComplete']=end==length
        for row in self.s.db.execute('SELECT id FROM auto_runs ORDER BY rowid').fetchall():
            r=v.run(int(row[0])); self.s.db.execute('UPDATE auto_runs SET state=? WHERE id=?',(r['state'],row[0]))
            if r['state']==6:
                self.record(snap['timestamp']//CYCLE,'SETTLED',r)
                self.s.db.execute('DELETE FROM auto_runs WHERE id=?',(row[0],))
            elif r['state']==0:raise ValueError('Known run disappeared; reconcile')
            else:snap['runs'].append(r)
        if len(snap['runs'])>3:raise ValueError('Too many outstanding runs')
        after=self.s.rpc.call('eth_getBlockByNumber',[block,False])
        if not after or after['hash'].lower()!=snap['blockHash']:raise ValueError('Snapshot block changed; suspend')
        return snap,v

    def decide(self,snap,view,slot,allow_entry=True):
        # Emergency/terminated states require their separate operational recovery authority.
        if snap['lifecycle'] in (3,4):return None,'EMERGENCY_OR_TERMINATED_STOP'
        if not snap['historyComplete']:return None,'HISTORY_SYNC_PENDING'
        p=self.policy
        for r in snap['runs']:
            rid=int(r['id']); state=r['state']
            if state==5:return None,'BLOCKED_RUN_REQUIRES_REVIEW'
            if state!=1 and int(r['exitId'],16)==0:return None,'INVALID_EXIT_STATE_REQUIRES_REVIEW'
            admitted=view.one(self.s.c['executor'],'isApprovedStrategy(address)',(r['adapter'],))
            if admitted!=1:return None,'DISABLED_ADAPTER_REQUIRES_REVIEW'
            if state==1:
                if not p or address(r['adapter'])!=address(p['adapter']):return None,'EXIT_POLICY_UNDEFINED'
                if snap['timestamp']<r['openedAt']:return None,'INVALID_TIMESTAMP_ORDER'
                if snap['timestamp']-r['openedAt']>=p['holdSeconds']:
                    return dict(method='requestExit',runId=rid,reference=digest('COMPD_EXIT_V1',self.s.scope,rid)),'EXIT_DUE'
                continue
            status,recoverable,claim=view.words(self.s.c['executor'],'observe(uint256)',(rid,),3)
            if status>3:raise ValueError('Invalid adapter observation')
            if r['credited']>r['principal']:raise ValueError('Invalid principal credit')
            # Informational observation NEVER credits funds or changes liabilities.
            if r['credited']<r['principal'] and recoverable>0 and state in (2,3,4):
                return dict(method='collectRun',runId=rid,reference=digest('COMPD_COLLECT_V1',self.s.scope,rid,slot,r['attempts'])),'RECOVERY_AVAILABLE'
            if r['credited']==r['principal']:
                if not p or address(r['adapter'])!=address(p['adapter']):return None,'SETTLEMENT_POLICY_UNDEFINED'
                code=self.s.rpc.call('eth_getCode',[r['adapter'],snap['block']])
                if self.s.cast.code_hash(code)!=hash32(p['adapterCodeHash']):return None,'ADAPTER_CODE_CHANGED'
                if claim==0 and status in (2,3):
                    return dict(method='closeRun',runId=rid,reference=digest('COMPD_CLOSE_V1',self.s.scope,rid)),'SETTLEMENT_READY'
                return None,'PENDING_CLAIM_NOT_FINAL'
        if not allow_entry:return None,'WAITING_PHYSICAL_SETTLEMENT'
        if snap['lifecycle']!=0:return None,'PAUSED_NO_NEW_ENTRY'
        if snap['halted'] or snap['risk']:return None,'RISK_BREAKER'
        if not p:return None,'ENTRY_POLICY_UNDEFINED'
        adapter=address(p['adapter'])
        if view.one(self.s.c['executor'],'isApprovedStrategy(address)',(adapter,))!=1:return None,'ADAPTER_NOT_ADMITTED'
        code=self.s.rpc.call('eth_getCode',[adapter,snap['block']])
        if self.s.cast.code_hash(code)!=hash32(p['adapterCodeHash']):return None,'ADAPTER_CODE_CHANGED'
        # Fresh IDs are deterministic and domain-bound, including the standing-policy commitment.
        rid=int(digest('COMPD_RUN_V1',self.s.scope,digest(p),slot),16)
        if view.run(rid)['state']!=0:return None,'ENTRY_ALREADY_USED_THIS_CYCLE'
        amount=min(snap['capital']*p['allocationBps']//10000,self.s.c['maxPrincipalWei'],
            snap['capital']-snap['active'],snap['accounted'],max(0,snap['capital']*3000//10000-snap['active']))
        if amount<=0 or snap['runCount']>=3:return None,'INSUFFICIENT_CAPITAL_OR_RUN_CAP'
        return dict(method='startRun',runId=rid,adapter=adapter,amountWei=str(amount),
            reference=digest('COMPD_ALLOCATION_V1',self.s.scope,rid)),'ENTRY_READY'

    def tick(self,now):
        s=self.s;slot=int(now)//CYCLE
        # Pending/unknown/reverted receipts are always reconciled before generating a new action.
        blocking=s.db.execute("SELECT 1 FROM jobs WHERE mode LIKE 'EXECUTE%' AND state IN ('SUBMITTING','PENDING','REVERTED') LIMIT 1").fetchone()
        if blocking:
            result=s.tick(now)
            self.record(slot,'CONFIRMATION_'+result['status'],result);s.db.commit()
            return result
        s.db.execute('BEGIN IMMEDIATE')
        try:
            # Resume exact frozen plan before reevaluating changing capital/observations.
            mode='EXECUTE' if s.execute else 'DRY_RUN'
            retry=s.db.execute("SELECT j.plan,j.mode FROM jobs j WHERE cycle=? AND mode LIKE ? AND state='RETRY' ORDER BY rowid LIMIT 1",(slot,mode+':%')).fetchone()
            block=s.preflight();snap,view=self.snapshot(block)
            # Clock disagreement never manufactures a chain cycle or executes stale intentions.
            if snap['timestamp']//CYCLE!=slot:
                s.db.commit();return {'status':'CLOCK_OR_RPC_LAG','cycle':slot}
            action,reason=self.decide(snap,view,slot)
            self.record(slot,'EVALUATED',dict(status=reason,block=snap['block'],blockHash=snap['blockHash']))
            if retry:
                frozen=json.loads(retry['plan']);key=retry['mode'].split(':',1)[1]
                old=frozen['action']
                # Keep amount/IDs stable, but never let a queued intention bypass fresh lifecycle/policy checks.
                if action is None or action['method']!=old['method'] or action['runId']!=old['runId']:
                    s.db.commit();return {'status':'QUEUED_ACTION_NO_LONGER_ELIGIBLE','cycle':slot,'reason':reason}
                s.db.commit();return s.tick(now,frozen,key)
            if action is None:
                s.db.commit();return {'status':reason,'cycle':slot}
            key=digest('COMPD_STEP_V1',action['method'],action['runId'])[2:]
            frozen=s.db.execute('SELECT plan FROM auto_plans WHERE cycle=? AND action_key=?',(slot,key)).fetchone()
            if frozen:plan=json.loads(frozen[0])
            else:
                plan=dict(cycle=slot,approvalReference=getattr(self,'approval_reference',self.policy['approvalReference'] if self.policy else 'CANONICAL_PERMISSIONLESS_PRINCIPAL_RECOVERY'),action=action)
                s.db.execute('INSERT INTO auto_plans VALUES (?,?,?)',(slot,key,json.dumps(plan,sort_keys=True)))
                self.record(slot,'PLANNED',plan)
            s.db.commit()
            result=s.tick(now,plan,key)
            self.record(slot,result['status'],result);s.db.commit()
            return result
        except BaseException:s.db.rollback();raise
