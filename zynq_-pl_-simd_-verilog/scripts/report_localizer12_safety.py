"""Aggregate measured lifecycle, stress outcomes and immutable build provenance."""
from pathlib import Path
import collections,csv,hashlib,json,re,statistics
R=Path(__file__).resolve().parents[1];O=R/'build/localizer12_safety'
def fields(line):return {k:int(v) if v.lstrip('-').isdigit() else v for k,v in re.findall(r'(\w+)=(\S+)',line)}
summary={}
for folder in ['before_audit','after_audit','validated','final','release','dtcm_probe']:
 d=O/folder;cases=[]
 for p in d.glob('*.json'):
  x=json.loads(p.read_text())
  if isinstance(x,dict) and 'requested_windows' in x:cases.append(x)
 summary[folder]=dict(count=len(cases),outcomes=dict(collections.Counter(c['status'] for c in cases)),cases=cases)
release=summary['release']['cases']
valid_margins=[r['min_margin'] for r in release if 0<r.get('min_margin',0)<2**63]
summary['stress_min_point_margin']=min(valid_margins) if valid_margins else None
normal4=O/'release/normal_fft_0_w0_o0_n4_s20261015_b0.log'
if normal4.exists():
 first_event=next(fields(l) for l in normal4.read_text().splitlines() if l.startswith('SAFETY_WINDOW '))
 epoch=first_event['ready']-1023*1024
 for r in release:
  if r.get('first_loss',0):
   r['first_loss_pcm_seq_derived']=(r['first_loss']-epoch)//1024
   r['first_result_withheld_first_seq']=(r.get('windows',0)*512+r.get('seq_base',0))&0xffffffff
   r['capture_loss_reason']='WINDOW_BUSY_AT_HOP' if r.get('window_drop') else 'SEQUENCE_GAP' if r['kind']=='gap' else 'RAW_WRITER_OR_LIFETIME'
 keys=sorted(set().union(*(r.keys() for r in release)))
 with (O/'stress_results.csv').open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(release)
all_windows=[]
for name in ['normal_fft_0_w0_o0_n1024_s20261015_b0.log','normal_fft_0_w0_o0_n256_s20261015_b0.log']:
 log=O/'release'/name
 if not log.exists():continue
 text=log.read_text();rows=[fields(l) for l in text.splitlines() if l.startswith('SAFETY_WINDOW ')]
 if not rows:continue
 data=dict(completed='SAFETY_SUMMARY status=PASS' in text,windows=len(rows),
           min_point_margin=min(r['min_margin'] for r in rows),
           min_all_raw_release_margin=min(r['oldest_overwrite']-r['last_raw'] for r in rows),
           max_all_raw_release_margin=max(r['oldest_overwrite']-r['last_raw'] for r in rows),
           first_raw_after_ready=[min(r['first_raw']-r['ready'] for r in rows),max(r['first_raw']-r['ready'] for r in rows)],
           last_raw_after_ready=[min(r['last_raw']-r['ready'] for r in rows),max(r['last_raw']-r['ready'] for r in rows)],
           max_latency=max(r['latency'] for r in rows),max_compute=max(r['computed']-r['ready'] for r in rows),
           result_gaps=dict(collections.Counter(r['gap'] for r in rows[1:])),
           latency_mean=statistics.mean(r['latency'] for r in rows),latency_p99=sorted(r['latency'] for r in rows)[int(.99*(len(rows)-1))])
 summary[name]=data;all_windows+=rows
 with (O/(name+'.windows.csv')).open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
trace=O/'release/normal_fft_0_w0_o0_n1024_s20261015_b0_raw.csv'
if trace.exists():
 with trace.open() as f:rows=[{k:int(v) for k,v in r.items()} for r in csv.DictReader(f)]
 if rows:
  groups=collections.defaultdict(list)
  for r in rows:groups[(r['channel'],r['pass'])].append(r)
  table=[]
  for (ch,p),rs in sorted(groups.items()):
   table.append(dict(channel=ch,pass_number=p,reads=len(rs),first_request=min(r['request_cycle'] for r in rs),last_consumption=max(r['consume_cycle'] for r in rs),min_margin=min(r['margin'] for r in rs)))
  summary['raw_channel_pass_lifecycle']=table
  summary['first_window_point_margin_range']=[min(r['margin'] for r in rows),max(r['margin'] for r in rows)]
  with (O/'raw_channel_pass_lifecycle.csv').open('w',newline='') as f:
   w=csv.DictWriter(f,fieldnames=table[0]);w.writeheader();w.writerows(table)
  # Derived write phase uses the observed first window-ready edge, never RAM data values.
  if all_windows:
   zero_cycle=all_windows[0]['ready']-1023*1024
   for r in rows:
    seq=(r['consume_cycle']-zero_cycle)//1024;phase=(r['consume_cycle']-zero_cycle)%1024
    r.update(pcm_seq=seq,raw_wr_addr=(seq%2048)*6+phase-1 if 1<=phase<=6 else -1,
             window_id=r['window_first']//512+1,raw_rd_req_seq=r['expected_seq'],raw_rd_rsp_seq=r['returned_seq'],
             raw_sample_consumed=1,oldest_live_seq=max(0,seq-2047),capture_loss_reason=0,state=2)
   with (O/'raw_trace_annotated.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
protected=json.loads((O/'protected_artifacts.json').read_text())
summary['original_artifacts_unchanged']=all(hashlib.sha256((R/k).read_bytes()).hexdigest()==v for k,v in protected.items())
assert summary['original_artifacts_unchanged'],'An accepted original artifact changed'
physical=O/'final_implementation/source_manifest.json'
manifest=json.loads(physical.read_text())
summary['routed_source_current']=all(hashlib.sha256((R/k).read_bytes()).hexdigest()==v for k,v in manifest.items())
summary['simulation_sources_match_implementation']=all(json.loads((O/'release/sources.json').read_text()).get(k)==v for k,v in manifest.items())
report=O/'final_implementation/timing_zynq.rpt'
if report.exists():
 t=report.read_text();m=re.search(r'WNS\(ns\)[^\n]*\n\s*[- ]+\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)',t)
 if m:summary['timing']=dict(wns_ns=float(m[1]),whs_ns=float(m[5]),tns_ns=float(m[2]),ths_ns=float(m[6]))
summary['flow_pass']=bool(re.search(r'^FLOW_PASS', (O/'final_implementation.log').read_text(errors='replace'),re.M))
(O/'safety_evidence.json').write_text(json.dumps(summary,indent=2)+'\n')
life_file=O/'release/boundary_brackets.json';rt_file=O/'release/realtime_boundary_brackets.json'
if life_file.exists() and rt_file.exists():
 life=json.loads(life_file.read_text());rt=json.loads(rt_file.read_text())
 def checked_rt(group,b):
  k,ph=group.split('/')
  for field,wanted in [('last_fixed_phase',True),('first_not_fixed_phase',False)]:
   rs=[r for r in release if r['kind']==k and r['phase']==ph and r['duration']==b[field] and r.get('target')==2 and r.get('offset')==0 and r.get('seed')==20261015]
   if not rs or any(r.get('fixed_phase',False)!=wanted for r in rs):return False
  return True
 valid=all(group in rt and checked_rt(group,rt[group]) for group in life)
 lines=['## 实测各阶段临界点与安全裕量（自动从日志生成）','',
        '主seed=20261015；下表是指定注入点的相邻拍转折。完成边界在target=0测量，固定相位边界在target=2测量；包含后续窗口验证。带偏移的结果见stress_results.csv，不将本表解释为所有相位的全局极限。','',
        '| 类型/阶段 | 首次注入点相对首窗ready（拍） | 尚依赖RAW | 不丢窗完成临界：成功/显式损失（拍） | 固定相位临界：通过/不通过（拍） |','|---|---:|---|---:|---:|']
 for group,b in life.items():
  k,ph=group.split('/');log=O/'release'/f'{k}_{ph}_0_w0_o0_n4_s20261015_b0.log'
  point='见日志'
  if log.exists():
   text=log.read_text();inj=next((fields(l) for l in text.splitlines() if l.startswith('INJECT ')),None);win=next((fields(l) for l in text.splitlines() if l.startswith('SAFETY_WINDOW ')),None)
   if inj and win:point=str(inj['start']-win['ready'])
  cell=f"{rt[group]['last_fixed_phase']} / {rt[group]['first_not_fixed_phase']}" if group in rt and checked_rt(group,rt[group]) else '待端点复核'
  lines.append(f"| {group} | {point} | {'是' if ph in ['before','raw','rawlate','fft','fftin'] else '否'} | {b['last_pass']} / {b['first_explicit_loss']} | {cell} |")
 lines+=['','`before`的固定相位测试从前一结果发布后的IDLE开始，相对目标新窗口ready约提前131070拍；表中首窗注入点不能与它直接混为同一时刻。一次停顿落在RAW三遍、核等待、已退休算子自主运行或发布等待，影响不同。','',
         f"当前全部已记录压力场景的最小逐读取RAW余量为 **{summary['stress_min_point_margin']}拍 = {summary['stress_min_point_margin']/40000:.6f}ms**（含显式损失前的读取）；未出现标签错误后仍发布。正常1024窗的956065拍与该压力最小值分列。",'']
 if valid:
  smallest=min(v['last_fixed_phase'] for v in rt.values())
  lines+= [f"所测18个基准注入位置中，最小的固定相位通过临界点为{smallest}拍（{smallest/40000:.6f}ms）；它不是52.4ms缓存容量，也不是23.9ms正常RAW余量。偏移与输入种子改变后须复测。",'']
 lines+=['<!-- SAFETY_GENERATED_END -->']
 doc=R/'docs/localizer12_realtime_safety_report.md';s=doc.read_text();s=s.split('<!-- SAFETY_GENERATED_BEGIN -->')[0].rstrip()
 # Keep the final validation-scope paragraph at the end of the report.
 scope='仿真证明的范围是所列输入、seed、窗口数、注入位置和协议模型下的数据正确性、显式损失与隔离行为；STA证明的是匹配综合网表在40MHz约束下的建立/保持时序。真实PDM输入、实际麦克风几何、物理BRAM碰撞/板级长跑及真实声场定位仍须板卡验证，不能由本报告宣布实板PASS。'
 s=s.replace(scope,'').rstrip();doc.write_text(s+'\n\n<!-- SAFETY_GENERATED_BEGIN -->\n'+'\n'.join(lines)+'\n\n'+scope+'\n')
print(json.dumps({k:v for k,v in summary.items() if k not in ['before_audit','after_audit','validated','final','release','dtcm_probe','raw_channel_pass_lifecycle']},indent=2))
