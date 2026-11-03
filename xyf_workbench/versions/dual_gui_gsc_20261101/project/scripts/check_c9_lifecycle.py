from pathlib import Path
import json,sys
from c9_scene_evaluation import angle
R=Path(__file__).resolve().parents[1];O=R/'build/offline_closure_20261027';root=O/'lifecycle';cases=json.loads((root/'e2e_results.json').read_text())['cases'];out=[]
for c in cases:
 rows=[json.loads(s) for s in Path(str(root/(c['scene']+'.json'))+'.trace.jsonl').read_text().splitlines()]
 assert len(rows)>350 and rows[-1]['end']>1048576*2
 assert all(rows[i]['snapshot_sequence']>=rows[i-1]['snapshot_sequence'] for i in range(1,len(rows)))
 entry={'scene':c['scene'],'windows':len(rows),'final_sequence':c['snapshot_sequence'],'final_sources_localized':c['all_sources_localized'],'final_labels_correct':c['all_sources_classified']}
 if c['scene']=='all_sources_off_and_return':
  quiet=[r for r in rows if 6<=r['end']/156250<=9];assert quiet
  assert all(not r['selected'] and not r['fresh_snapshot_count'] and all(not t['id'] for t in r['tracks']) for r in quiet)
  assert len(set(r['snapshot_sequence'] for r in quiet))==1
  recovered=next(r for r in rows if r['end']/156250>10 and r['fresh_snapshot_count']>=2)
  entry.update(quiet_old_snapshot_not_fresh=True,no_new_diagnosis_in_quiet=True,recovery_after_resume_s=recovered['end']/156250-10)
 if c['scene']=='restart_fault_source':
  groups=[]
  for a,b in [(1.5,3.5),(9.5,11.5),(17.5,19.5)]:
   ids={t['id'] for r in rows if a<r['end']/156250<b for t in r['tracks'] if t['id'] and t['state']==1 and angle({'azimuth_deg':t['az']/1000,'elevation_deg':t['el']/1000},{'azimuth_deg':50})<12}
   assert ids;groups.append(ids)
  assert not groups[0]&groups[1] and not groups[1]&groups[2]
  entry['reappeared_fault_has_new_angular_track_ids']=[sorted(x) for x in groups]
 assert c['snapshot_sequence']>0 and c['all_sources_localized'] and c['all_sources_classified']
 out.append(entry)
(O/'lifecycle_checks.json').write_text(json.dumps({'passed':True,'hardware_tested':False,'full_motion_identity_guaranteed':False,'training_data_overlap':True,'cases':out},indent=2));print('LIFECYCLE_CHECKS_PASS',out)
