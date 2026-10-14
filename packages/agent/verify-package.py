"""Read-only verification of the complete extracted backend release."""
import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent
manifest=json.loads((root/'MANIFEST.json').read_text())
for row in manifest:
 path=root/row['path']
 if path.is_symlink() or not path.resolve().is_relative_to(root):raise SystemExit('Unsafe inventory path')
 if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:raise SystemExit('Missing or mismatched file: '+row['path'])
actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
expected={x['path'] for x in manifest}|{'MANIFEST.json'}
if actual!=expected:raise SystemExit('Unexpected/missing package entries; verify a clean staging copy before deployment')
print(json.dumps({'status':'PASS','sha256MatchedFiles':len(manifest),'scope':'FILE_INTEGRITY_NOT_SERVICE_READINESS'}))
