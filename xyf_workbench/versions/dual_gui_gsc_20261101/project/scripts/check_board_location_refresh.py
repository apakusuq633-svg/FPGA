"""Record fresh board HTTP observations, or summarize an existing capture offline."""
import argparse,collections,json,math,statistics,time,urllib.request
from datetime import datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def summarize(samples):
    if not samples:return {'requests':0}
    first,last=samples[0]['status'],samples[-1]['status']
    observations=[];seen=set()
    for row in samples:
        s=row['status'];seq=s.get('loc_seq',0)
        if seq and seq not in seen:
            observations.append(s);seen.add(seq)
    def cloud(field):
        points=[]
        for s in observations:
            w=s.get('loc_grid_w',16);g=s.get(field,s.get('loc_grid',-1))
            if s.get('loc_valid') and w>1 and 0<=g<w*w:
                points.append((-200+400*(g%w)/(w-1),-200+400*(g//w)/(w-1)))
        if not points:return {'observations':0}
        x,y=zip(*points)
        return {'observations':len(points),'range_x_mm':max(x)-min(x),'range_y_mm':max(y)-min(y),
                'std_x_mm':statistics.pstdev(x),'std_y_mm':statistics.pstdev(y)}
    return {'requests':len(samples),'channels':last.get('input_channels'),
      'location_frames':last.get('loc_frame',0)-first.get('loc_frame',0),
      'audio_frames':last.get('frame',0)-first.get('frame',0),
      'unique_location_observations':len(observations),
      'valid_observations':sum(bool(s.get('loc_valid')) for s in observations),
      'reason_bitmasks':dict(collections.Counter(str(s.get('loc_reason',0)) for s in observations if s.get('loc_quality_supported'))),
      'raw_valid_cloud':cloud('loc_raw_grid'),'confirmed_valid_cloud':cloud('loc_grid'),
      'max_http_ms':max(v['ms'] for v in samples),
      'pl_dropped':last.get('pl_dropped',0),'ps_dropped':last.get('ps_dropped',0),
      'discontinuities':last.get('discontinuities',0),
      'cloud_is_accuracy':False,'quality_supported':bool(last.get('loc_quality_supported'))}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',default='http://192.168.2.10')
    parser.add_argument('--seconds',type=float,default=30)
    parser.add_argument('--hz',type=float,default=5)
    parser.add_argument('--output',type=Path,help='Fresh destination; existing files are never overwritten')
    parser.add_argument('--analyze-json',type=Path,help='Summarize saved samples without contacting hardware')
    args=parser.parse_args()
    if args.analyze_json:
        print(json.dumps(summarize(json.loads(args.analyze_json.read_text(encoding='utf-8-sig'))),indent=2));return
    if not (1<=args.seconds<=600 and 1<=args.hz<=10):parser.error('seconds must be 1..600 and hz must be 1..10')
    path=args.output or ROOT/'build'/('board_location_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
    if path.exists():parser.error('output already exists: '+str(path))
    path.parent.mkdir(parents=True,exist_ok=True)
    samples=[];start=time.monotonic();failure=None
    try:
        for i in range(math.ceil(args.seconds*args.hz)):
            delay=start+i/args.hz-time.monotonic()
            if delay>0:time.sleep(delay)
            t=time.monotonic()
            with urllib.request.urlopen(args.host.rstrip('/')+'/api/status',timeout=3) as r:s=json.load(r)
            samples.append({'at_seconds':round(time.monotonic()-start,6),
                            'ms':round((time.monotonic()-t)*1000,2),'status':s})
            if s['input_mode']!=2 or s['input_error'] or s['pl_dropped'] or s['ps_dropped'] or s['discontinuities']:
                raise RuntimeError('Live input or audio continuity check failed; see saved status')
    except Exception as error:
        failure=str(error)
    # Exclusive creation also protects against another process choosing this filename.
    with path.open('x',encoding='utf-8') as stream:json.dump(samples,stream,indent=2)
    report=summarize(samples);report.update(seconds=round(time.monotonic()-start,2),path=str(path),error=failure)
    print(json.dumps(report,indent=2))
    if failure:raise SystemExit(1)
    if args.seconds>=3 and (report['location_frames']<=0 or report['audio_frames']<=0):
        raise SystemExit('Live frame counters did not advance; capture was preserved')

if __name__=='__main__':main()
