"""Auxiliary-worker integration plus genuine interval-provenance regressions."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
def main():
 for script in ('check_circular9_pipeline.py','check_circular9_tracking.py'):
  subprocess.run([sys.executable,str(ROOT/'scripts'/script)],cwd=ROOT,check=True)
 pipeline=json.loads((ROOT/'build/circular9_pipeline_checks/results.json').read_text())
 tracking=json.loads((ROOT/'build/circular9_tracking_checks/results.json').read_text())
 log=(ROOT/'build/circular9_pipeline_checks/native.log').read_text()
 assert pipeline['passed'] and tracking['passed']
 assert 'AUXILIARY_PIPELINE_PASS' in log and 'no_track_bootstrap=1' in log
 sources={**pipeline['sources'],**tracking['sources']}
 sources['scripts/check_circular9_aux.py']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
 result={'passed':True,'hardware_tested':False,'ps_runtime_measured':False,
  'fixture':'actual CPU1 FFT discovery from synthetic raw9 with no preexisting track; CPU0 negative provenance controls; independent real-window interval coverage simulation',
  'hop_raw_samples':8192,'window_raw_samples':16640,'maximum_feedback_age_samples':31250,
  'raw_sample_rate_hz':156250,'maximum_catchup_windows':1,'CPU0_FFT':False,
  'guards':['actual_per_candidate_support_intervals','three_fresh_observations','no_duplicate_support',
   'session_epoch_generation_geometry_calibration_binding','expired_input_rejected','unobserved_gaps_preserved',
   'full_diagnostic_span_required','coverage_first_origin_neutral_spherical_NMS','independent_aux_ID_namespace'],
  'sources':sources}
 out=ROOT/'build/circular9_aux_checks';out.mkdir(parents=True,exist_ok=True)
 (out/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print('CIRCULAR9_AUX_PASS actualFFT_interval_binding no_ARM_timing_claim')
if __name__=='__main__':main()
