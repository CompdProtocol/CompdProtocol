"""Read persistent supervisor health; optionally check the loopback observer."""
import argparse,json,time,urllib.request
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--state',default='/home/compd/compd/state');p.add_argument('--http',action='store_true');a=p.parse_args()
try:
 h=json.loads((Path(a.state)/'health.json').read_text())
 if h.get('productionExecutionEnabled') is not False or time.time()-h['time']>180 or h.get('supervisor')=='STOPPED':raise ValueError('Stale/stopped/unsafe supervisor')
 states={k:v['state'] for k,v in h['workers'].items()}
 if any(v in ('QUARANTINED','FAILED','STOPPED') for v in states.values()):raise ValueError('Unhealthy worker')
 result={'supervisor':'RESPONDING','workers':states,'productionExecutionEnabled':False,'observer':'NOT_CHECKED'}
 if a.http:
  with urllib.request.urlopen('http://127.0.0.1:4174/status',timeout=40) as f:data=json.load(f)
  snapshot=data.get('publicSnapshot',{})
  if snapshot.get('chainId')!=56 or not snapshot.get('blockHash') or data.get('xstocks',{}).get('mode')!='OBSERVE_ONLY':raise ValueError('Unverified API observation')
  result['observer']='VERIFIED_SNAPSHOT_RESPONSE_NOT_TRADING_CLEARANCE'
 print(json.dumps(result))
except Exception:
 print(json.dumps({'status':'NOT_VERIFIED','reason':'HEALTH_UNAVAILABLE_OR_UNSAFE'}));raise SystemExit(1)
