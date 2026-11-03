from pathlib import Path
import json,re
import numpy as np
R=Path(__file__).resolve().parents[1];O=R/'build/zynq12_integrated_plan/m3_smooth_ab';result={}
for name,file in [('smooth','integrated_direction.log'),('step','direction_step.log')]:
    text=(O/file).read_text();audio=np.array([int(re.search(r'pcm=(-?\d+)',line)[1]) for line in text.splitlines() if line.startswith('DIRECTION_AUDIO')],float)
    a=audio[64:400];s=np.fft.rfft(a*np.hanning(len(a)));freq=np.fft.rfftfreq(len(a),1/39062.5)
    result[name]={'peak_first_difference':float(abs(np.diff(a)).max()),'peak_second_difference':float(abs(np.diff(a,n=2)).max()),
      'high_frequency_energy_db':float(10*np.log10(np.sum(abs(s[freq>4000])**2)/np.sum(abs(s)**2)))}
out=O/'transient_comparison.json';assert not out.exists();out.write_text(json.dumps(result,indent=2));print(result)
