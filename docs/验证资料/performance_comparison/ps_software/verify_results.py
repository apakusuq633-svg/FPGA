"""Read-only validation of timing CSV, recorded hashes and numerical artifacts.

Writes only verification.json alongside the selected results.json, below this folder.
"""
import argparse
import array
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys

HERE=Path(__file__).resolve().parent
WORKSPACE=HERE.parent.parent

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def percentile(x,q):
    x=sorted(x);p=(len(x)-1)*q;a=int(p);b=min(a+1,len(x)-1)
    return x[a]+(x[b]-x[a])*(p-a)
def read_array(path,code):
    a=array.array(code);a.frombytes(path.read_bytes())
    if sys.byteorder!='little':a.byteswap()
    return a

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('results',type=Path);args=p.parse_args()
    path=args.results.resolve();assert path.is_relative_to(HERE),'results must be below ps_software'
    r=json.loads(path.read_text(encoding='utf-8'));assert r['passed'] and r['source_unchanged'];base=path.parent
    checked=0
    for name,digest in r['artifact_hashes'].items():
        target=(base/name).resolve();assert target.is_relative_to(base) and sha(target)==digest,('artifact',name);checked+=1
    for name,digest in r['source_hashes_after'].items():assert sha(WORKSPACE/name)==digest,('current production source',name)
    for name,digest in r['benchmark_sources'].items():assert sha(HERE/name)==digest,('benchmark source',name)
    for name,tool in r['tools'].items():assert sha(Path(tool['path']))==tool['sha256'],('tool',name)
    with (base/'raw_timings.csv').open(encoding='utf-8',newline='') as f:rows=list(csv.DictReader(f))
    groups={}
    for row in rows:
        value=float(row['wall_ms']);assert math.isfinite(value) and value>0
        groups.setdefault((row['benchmark'],row['fixture'],row['variant']),[]).append(value)
    summaries=[]
    for scene,variants in r['search']['summary'].items():
        for variant,s in variants.items():summaries.append((('search',scene,variant),s))
    for variant,s in r['division']['summary'].items():summaries.append((('division','4096_batches_of_32',variant),s))
    if 'envelope' in r:
        for variant,s in r['envelope']['summary'].items():summaries.append((('envelope','AM_600rpm_3400Hz',variant),s))
    assert len(groups)==len(summaries)
    for key,s in summaries:
        x=groups[key];assert len(x)==s['repeats']
        expected={'mean':statistics.mean(x),'p50':statistics.median(x),'p95':percentile(x,.95),'max':max(x),'min':min(x)}
        for name,value in expected.items():assert abs(value-s[name])<1e-12,(key,name,value,s[name])
    for scene in r['search']['summary']:
        reference=read_array(base/'numeric'/f'{scene}_reference_scores.bin','i')
        feedback=(base/'numeric'/f'{scene}_reference_feedback.bin').read_bytes()
        for variant in r['search']['summary'][scene]:
            actual=read_array(base/'numeric'/f'{scene}_{variant}_scores.bin','i')
            assert list(actual)==list(reference)
            assert (base/'numeric'/f'{scene}_{variant}_feedback.bin').read_bytes()==feedback
    ns=read_array(base/'inputs/division_numerators.i64le','q');ds=read_array(base/'inputs/division_denominators.u64le','Q')
    expected=[(-1 if n<0 else 1)*(abs(n)//ds[i//32]) for i,n in enumerate(ns)]
    for name in ('signed_division_reference','production_shared_reciprocal'):
        assert list(read_array(base/'numeric'/(name+'.i64le'),'q'))==expected
    if 'envelope' in r:
        checks=json.loads((base/'numeric/envelope_dft_checks.json').read_text(encoding='utf-8'))
        assert max(abs(c['expected']-c['actual']) for c in checks)<2e-4
    verification={'passed':True,'scope':'read-only artifact/statistics/numerical check; no performance rerun',
                  'timing_rows':len(rows),'timing_groups':len(groups),'artifact_hashes_checked':checked,
                  'production_source_hashes_checked':len(r['source_hashes_after']),
                  'division_quotients_checked':len(expected),'results_sha256':sha(path)}
    (base/'verification.json').write_text(json.dumps(verification,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(verification,indent=2))

if __name__=='__main__':main()
