"""Explicit opt-in observer. No board access without --record."""
import argparse,json,time,urllib.request
from pathlib import Path
from collections import Counter
p=argparse.ArgumentParser();p.add_argument('--record',action='store_true');p.add_argument('--out',type=Path);p.add_argument('--seconds',type=float,default=30);p.add_argument('--base-url',default='http://192.168.2.10');p.add_argument('--summarize',type=Path);a=p.parse_args()
if a.summarize:
 counts=Counter();seen=set()
 for line in a.summarize.read_text(encoding='utf-8').splitlines():
  row=json.loads(line)
  if row.get('endpoint')!='/api/candidates?debug=1' or 'data' not in row:continue
  aux=row['data']['auxiliary'];key=(aux['session'],aux['epoch'],aux['sequence'],aux['first'],aux['end'])
  if key in seen:continue
  seen.add(key)
  for q in aux['peaks_after_nms']:counts[(q['band'],round(q['az']/1000),round(q['el']/1000))]+=1
 print(json.dumps({'observed_unique_aux_windows':len(seen),'peaks_by_band_az_el':[{'band':k[0],'az':k[1],'el':k[2],'windows':v} for k,v in counts.items()],'limitation':'Latest-only polling misses intermediate windows; NMS output absence does not prove raw peak absence.'},indent=2));raise SystemExit
if not a.record:p.error('No network accessed. Pass --record --out NEW_FILE.jsonl explicitly.')
if not a.out or a.seconds<=0:p.error('out and positive seconds required')
if not a.base_url.startswith('http://192.168.2.10'):p.error('This observer is restricted to the configured board address')
with a.out.open('x',encoding='utf-8') as f:
 start=time.monotonic();tick=0
 try:
  while time.monotonic()-start<a.seconds:
   endpoints=['/api/candidates?debug=1']+(['/api/candidates','/api/status','/api/gsc'] if tick%4==0 else [])
   for endpoint in endpoints:
    row={'endpoint':endpoint,'request_utc_ns':time.time_ns(),'elapsed_s':time.monotonic()-start}
    try:
     req=urllib.request.Request(a.base_url+endpoint,headers={'Cache-Control':'no-store'})
     with urllib.request.urlopen(req,timeout=2) as res:row['data']=json.load(res)
    except Exception as e:row['error']=str(e)
    row['response_utc_ns']=time.time_ns();f.write(json.dumps(row,ensure_ascii=False)+'\n');f.flush()
   tick+=1;time.sleep(max(0,start+tick*.25-time.monotonic()))
 except KeyboardInterrupt:pass
print('OBSERVATION_SAVED',a.out)
