"""Disposable supervisor fixture qualification; no RPC, signing or HTTP service."""
import argparse,json,sys,tempfile,time
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tools/operations'))
from supervisor import Supervisor

def qualify(temp_root=None):
    c=json.loads((ROOT/'config-examples/operations.json').read_text())
    c.update(offlineFixture=True,readOnlyServicesApproved=False,productionExecutionEnabled=False)
    for w in c['workers']:
        w.update(enabled=True,fixtureBehavior='healthy',configs={})
    cycles=[]
    with tempfile.TemporaryDirectory(prefix='compd-offline-fixture-',dir=temp_root) as temp:
        c['stateRoot']=temp
        for attempt in range(2):
            supervisor=Supervisor(c);processes={}
            try:
                deadline=time.monotonic()+15
                while time.monotonic()<deadline:
                    supervisor.poll()
                    if all(s['state']=='RUNNING' for s in supervisor.states.values()):break
                    time.sleep(.1)
                states={n:s['state'] for n,s in supervisor.states.items()}
                assert states=={n:'RUNNING' for n in ('holder','fees','agent','public')},states
                assert all(s['restarts']==0 and s['exitCode'] is None for s in supervisor.states.values()),supervisor.states
                processes={n:child['process'] for n,child in supervisor.children.items()}
                assert len(processes)==4
            finally:supervisor.close()
            exits={n:p.returncode for n,p in processes.items()}
            assert exits=={n:0 for n in ('holder','fees','agent','public')},exits
            assert (Path(temp)/'supervisor-state.json').is_file()
            health=json.loads((Path(temp)/'health.json').read_text())
            assert health['supervisor']=='STOPPED'
            cycles.append({'cycle':attempt+1,'workers':states,'exitCodes':exits,'controlStatePreserved':True})
    return {'status':'PASS','scope':'DISPOSABLE_FIXTURE_NOT_PRODUCTION_OBSERVER','cycles':cycles,'startedWorkerProcesses':8,'noRPC':True,'noHTTPListener':True,'productionExecutionEnabled':False}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--temp-root');a=p.parse_args()
    if a.temp_root and Path(a.temp_root).resolve().is_relative_to(ROOT):raise SystemExit('Temporary state must be outside backend')
    print(json.dumps(qualify(a.temp_root),indent=2))

