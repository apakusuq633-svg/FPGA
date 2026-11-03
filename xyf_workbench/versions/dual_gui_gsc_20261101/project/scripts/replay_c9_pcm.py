"""Local interleaved9ch int16le replay, no network, no hardware calibration assertion."""
from pathlib import Path
import argparse,hashlib,json,subprocess,os
R=Path(__file__).resolve().parents[1]
a=argparse.ArgumentParser();a.add_argument('--input',required=True,type=Path);a.add_argument('--metadata',required=True,type=Path);a.add_argument('--output',required=True,type=Path);args=a.parse_args()
m=json.loads(args.metadata.read_text(encoding='utf-8-sig'));assert m['channels']==9 and m['sample_rate_num']==156250 and m['sample_rate_den']==1
assert m['format']=='s16le_interleaved' and m.get('source') in ['simulation','captured_pcm','unknown']
raw=args.input.resolve();size=raw.stat().st_size;assert size%18==0 and size//18>=160256
assert hashlib.sha256(raw.read_bytes()).hexdigest()==m['sha256'],'input hash mismatch'
assert not args.output.exists(),'refusing to overwrite prior replay'
args.output.mkdir(parents=True);exe=args.output/'replay.exe'
subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-std=c11','-O2','-DC9_CANDIDATES_TEST','-DC9_NATIVE_GEOMETRY_CONFIRMED=0','-Ibuild/circular9_pipeline_checks/include','-Isw','sw/circular9_candidates.c','sw/circular9_diagnosis.c','sw/circular9_fstf_e2e_test.c','-pthread','-lm','-o',str(exe)],cwd=R,check=True)
env=dict(os.environ,C9_REPLAY_SHAFT_MILLIHZ='0');result=args.output/'result.json'
p=subprocess.run([str(exe.resolve()),str(raw),str(size//18),str(result.resolve())],cwd=R,env=env,text=True,capture_output=True);(args.output/'replay.log').write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout+p.stderr
api=json.loads(result.read_text());assert api['geometry_confirmed']==0 and api['calibration_version']==0 and api['shaft_confirmed']==0 and api['model_validated']==0 and not api['fstf_experiment_enabled']
for c in api['candidates']:assert c['diagnosis']['label']=='unknown' and not c['diagnosis']['fault_direction_valid']
proof={'input_metadata':m,'raw_frames':size//18,'input_sha256':m['sha256'],'hardware_test_performed':False,'board_input_source_claim_is_user_metadata':True,'geometry_forced_unconfirmed':True,'RPM_forced_unconfirmed':True,'model_experiment_disabled':True,'timing_is_host_mock':True,'snapshot_sequence':api['sequence'],'candidate_count':len(api['candidates'])}
(args.output/'provenance.json').write_text(json.dumps(proof,indent=2));print('OFFLINE_PCM_REPLAY_PASS',proof['snapshot_sequence'],proof['candidate_count'])
