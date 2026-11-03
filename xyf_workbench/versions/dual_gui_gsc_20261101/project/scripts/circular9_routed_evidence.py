"""Bind a fresh routed implementation to immutable source bytes and artifacts."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():
 files=[*sorted((ROOT/'rtl').rglob('*.v')),*sorted((ROOT/'rtl').rglob('*.vh')),
        *sorted((ROOT/'constrs').rglob('*.xdc')),*sorted((ROOT/'scripts').glob('*.tcl')),
        ROOT/'scripts/filelist.f',Path(__file__).resolve()]
 return {p.relative_to(ROOT).as_posix():sha(p) for p in files}
def main():
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['begin','finish']);p.add_argument('--project',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True);record=a.output/'routed_source_begin.json'
 if a.mode=='begin':
  record.write_text(json.dumps({'source_sha256':snapshot()},indent=2)+'\n');print('C9_ROUTED_SOURCE_BEGIN');return
 begin=json.loads(record.read_text());current=snapshot()
 if begin['source_sha256']!=current:raise RuntimeError('Sources changed during synthesis/implementation')
 bit=a.project/'rv32_zynq.runs/impl_1/ps_pl_wrapper.bit';xsa=a.output/'das_fir.xsa'
 with zipfile.ZipFile(xsa) as archive:
  paths=[s for s in archive.namelist() if s.endswith('.bit')]
  if len(paths)!=1 or hashlib.sha256(archive.read(paths[0])).hexdigest()!=sha(bit):raise RuntimeError('XSA does not contain routed bit')
 proof={'status':'ROUTED_SOURCE_AND_XSA_MATCHED','hardware_tested':False,'source_sha256':current,
        'bit_sha256':sha(bit),'xsa_sha256':sha(xsa),'project':str(a.project),'output':str(a.output)}
 (a.output/'routed_source_proof.json').write_text(json.dumps(proof,indent=2)+'\n');print('C9_ROUTED_SOURCE_FINISH_PASS')
if __name__=='__main__':main()
