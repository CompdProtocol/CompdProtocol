"""Package guard: no signing lane, local fixture or live execution via this service."""
import argparse,json,sys,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tools/operations'))
from supervisor import validate

def check(c):
    if c.get('offlineFixture') is not False:raise ValueError('This VPS service never runs transaction fixtures')
    if c.get('productionExecutionEnabled') is not False:raise ValueError('Execution forbidden')
    if c.get('stateRoot')!='/home/compd/compd/state':raise ValueError('Persistent state path must be outside backend')
    if c.get('notifications',{}).get('enabled') is not False:raise ValueError('Notifications disabled in this package')
    expected={'holder':'holder','fees':'fee','agent':'agent','public':'public'}
    if {w['name']:w['kind'] for w in c['workers']}!=expected:raise ValueError('Exactly four known workers required')
    public=next(w for w in c['workers'] if w['kind']=='public')
    if public.get('healthPort')!=4174:raise ValueError('Fixed observer port')
    for w in c['workers']:
        for p in w['configs'].values():
            if not isinstance(p,str) or str(Path(p).parent).replace('\\','/')!='/home/compd/compd/config':raise ValueError('Fixed external config directory')
        if w['enabled']:
            for p in w['configs'].values():
                cfg=json.loads(Path(p).read_text())
                if cfg.get('productionExecutionEnabled') is True or cfg.get('offlineFixture') is True:raise ValueError('Worker execution/fixture forbidden')
                if w['kind']=='agent' and any(x.get('enabled') is True for x in cfg.get('assets',[]) if isinstance(x,dict)):raise ValueError('Agent assets must remain disabled')
    validate(c)
    return {'status':'PASS_CONFIG_ONLY','enabledWorkers':[w['name'] for w in c['workers'] if w['enabled']], 'executionEnabled':False,'http':'NOT_STARTED_NOT_HEALTH_VERIFIED'}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--config',required=True);a=p.parse_args()
    print(json.dumps(check(json.loads(Path(a.config).read_text()))))
