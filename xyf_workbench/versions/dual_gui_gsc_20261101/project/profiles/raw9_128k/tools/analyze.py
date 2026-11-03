"""Streaming statistics plus first50ms nine-axis SVG; never changes PCM."""
import argparse,array,sys,json,math
from pathlib import Path
def analyze(path):
 sums=[0]*9;squares=[0]*9;peaks=[0]*9;clips=[0]*9;mins=[32767]*9;maxs=[-32768]*9
 equal=[[True]*9 for _ in range(9)];preview=[];frames=0
 with Path(path).open('rb') as f:
  while b:=f.read(18*4096):
   if len(b)%18:raise ValueError('truncated sample frame')
   x=array.array('h');x.frombytes(b)
   if sys.byteorder!='little':x.byteswap()
   for n in range(0,len(x),9):
    row=x[n:n+9];frames+=1
    if len(preview)<6400:preview.append(list(row))
    for c,v in enumerate(row):
     sums[c]+=v;squares[c]+=v*v;peaks[c]=max(peaks[c],abs(v));clips[c]+=v in (-32768,32767);mins[c]=min(mins[c],v);maxs[c]=max(maxs[c],v)
     for d in range(c):equal[c][d]=equal[c][d] and v==row[d]
 if not frames:raise ValueError("empty capture")
 stats=[]
 for c in range(9):
  mean=sums[c]/frames if frames else 0
  stats.append(dict(channel=c,mean=mean,ac_rms=math.sqrt(max(0,squares[c]/frames-mean*mean)) if frames else 0,peak=peaks[c],clipped=clips[c],minimum=mins[c],maximum=maxs[c]))
 result=dict(frames=frames,bytes=18*frames,nominal_duration=frames/128000,size_matches_target=frames==3840000,channels=stats,
  exact_duplicate_pairs=[[d,c] for c in range(9) for d in range(c) if equal[c][d]],
  limitations='PCM alone cannot prove actual sample rate, physical mapping or absence of acquisition loss; inspect capture report and measure clock.')
 lines=['<svg xmlns="http://www.w3.org/2000/svg" width="1100" height="1000"><rect width="100%" height="100%" fill="white"/>']
 for c in range(9):
  y=45+c*105;lines.append(f'<text x="5" y="{y}">CH{c} (signed16); 0-{len(preview)/128:.3f}ms</text><path stroke="#ccc" d="M100 {y+35}H1080"/>')
  pts=' '.join(f'{100+i*980/max(1,len(preview)-1):.2f},{y+35-row[c]*30/32768:.2f}' for i,row in enumerate(preview) if i%4==0)
  lines.append(f'<polyline points="{pts}" fill="none" stroke="#126c91" stroke-width=".6"/>')
 lines.append('</svg>');return result,'\n'.join(lines)
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('pcm');a.add_argument('--out',required=True);args=a.parse_args()
 out=Path(args.out);out.mkdir(parents=True,exist_ok=False);report,svg=analyze(args.pcm)
 (out/'statistics.json').write_text(json.dumps(report,indent=2));(out/'waveforms.svg').write_text(svg);print(json.dumps(report,indent=2))
