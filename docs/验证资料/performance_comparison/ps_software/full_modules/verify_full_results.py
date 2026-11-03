"""Verify saved full-module results without running another timing experiment."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import statistics

HERE=Path(__file__).resolve().parent
WORKSPACE=HERE.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def p95(v):
 x=sorted(v);p=(len(x)-1)*.95;i=int(p);j=min(i+1,len(x)-1);return x[i]+(x[j]-x[i])*(p-i)
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('results',type=Path);a=ap.parse_args()
 path=a.results.resolve();assert path.is_relative_to(HERE);r=json.loads(path.read_text(encoding='utf-8'));base=path.parent
 assert r['passed'] and r['source_unchanged'] and not r['probe_only']
 for name,d in r['artifact_hashes'].items():assert sha(base/name)==d,name
 for name,d in r['source_hashes_after'].items():assert sha(WORKSPACE/name)==d,name
 for name,d in r['benchmark_sources'].items():assert sha(HERE/name)==d,name
 assert sha(HERE.parent/'run_benchmarks.py')==r['shared_runner_sha256']
 with (base/'raw_timings.csv').open(newline='',encoding='utf-8') as f:rows=list(csv.DictReader(f))
 groups={}
 for row in rows:groups.setdefault((row['module'],row['mode']),[]).append(float(row['wall_ms']))
 assert len(groups)==3
 for (module,mode),v in groups.items():
  s=r['gsc']['summary'][mode] if module=='gsc' else r['separation']['summary'];assert len(v)==s['repeats']
  for k,e in [('mean',statistics.mean(v)),('p50',statistics.median(v)),('p95',p95(v)),('max',max(v))]:assert abs(e-s[k])<1e-12,(module,mode,k)
 g=r['gsc']['validation']['adaptive_enabled'];assert g['active']==32768 and any(g['weights']) and not g['update_frozen']
 for k in ['bad_format','seq_errors','meta_mismatch','transitions','align_errors','divergence','target_guard_samples']:assert g[k]==0
 for mode,expected in [('disabled_bypass','gsc_expected_bypass.i16le'),('adaptive_enabled','gsc_expected_active.i16le')]:
  assert (base/'numeric'/f'gsc_{mode}.i16le').read_bytes()==(base/'inputs'/expected).read_bytes()
 s=r['separation']['validation'];assert s['ready_mask']==3 and s['invalid_input']==0 and s['covariance_frames']==8 and s['covariance_used_bins']>0
 proof={'passed':True,'scope':'read-only hashes/CSV/statistics/recorded validity; no timing rerun','rows':len(rows),
        'groups':len(groups),'artifact_hashes_checked':len(r['artifact_hashes']),
        'production_source_hashes_checked':len(r['source_hashes_after']),'results_sha256':sha(path)}
 (base/'verification.json').write_text(json.dumps(proof,indent=2)+'\n',encoding='utf-8');print(json.dumps(proof,indent=2))
if __name__=='__main__':main()
