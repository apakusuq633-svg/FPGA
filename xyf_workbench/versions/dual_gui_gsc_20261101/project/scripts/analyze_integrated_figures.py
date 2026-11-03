"""Standalone engineering figures and fractional-delay frequency error metrics."""
from pathlib import Path
import argparse,csv,json,re
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from integrated_acoustics import FS,coefficients
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
w=2*np.pi*np.linspace(300,8000,1000)/FS;rows=[]
for mode in ['integer','linear','cubic']:
    phase=[];amps=[];times=[]
    for f in range(16):
        if mode=='integer':h=np.ones(len(w),complex);d=f/16
        elif mode=='linear':h=(1-f/16)+(f/16)*np.exp(-1j*w);d=f/16
        else:h=np.exp(-1j*w[:,None]*np.arange(4))@(coefficients(f)/16384);d=1+f/16
        ph=np.angle(h*np.exp(1j*w*d));phase.extend(ph);amps.extend(20*np.log10(abs(h)));times.extend(-ph/w)
    times=np.array(times);phase=np.array(phase);amps=np.array(amps)
    rows.append({'mode':mode,'phase_rms_deg':float(np.sqrt(np.mean(phase**2))*180/np.pi),
      'delay_error_rms_samples':float(np.sqrt(np.mean(times**2))), 'delay_error_max_abs_samples':float(abs(times).max()),
      'delay_error_max_abs_us':float(abs(times).max()/FS*1e6),'worst_amplitude_db':float(amps.min()),
      'extra_common_delay_samples':1 if mode=='cubic' else 0})
(O/'fractional_delay_metrics.json').write_text(json.dumps(rows,indent=2))
with(O/'fractional_delay_metrics.csv').open('w',newline='')as f:x=csv.DictWriter(f,fieldnames=rows[0]);x.writeheader();x.writerows(rows)
fig,axes=plt.subplots(2,1,figsize=(8,6),sharex=True)
for mode in ['integer','linear','cubic']:
    f=5/16
    if mode=='integer':h=np.ones(len(w),complex);d=f
    elif mode=='linear':h=(1-f)+f*np.exp(-1j*w);d=f
    else:h=np.exp(-1j*w[:,None]*np.arange(4))@(coefficients(5)/16384);d=1+f
    axes[0].plot(w*FS/(2*np.pi),20*np.log10(abs(h)),label=mode)
    axes[1].plot(w*FS/(2*np.pi),np.angle(h*np.exp(1j*w*d))*180/np.pi,label=mode)
axes[0].set_ylabel('Amplitude (dB)');axes[1].set_ylabel('Residual phase (degrees)');axes[1].set_xlabel('Frequency (Hz)')
for ax in axes:ax.grid();ax.legend()
fig.suptitle('Fractional delay 5/16: common causal delay removed');fig.tight_layout();fig.savefig(O/'das_response.png',dpi=160);fig.savefig(O/'das_response.svg');plt.close(fig)
with(R/'build/zynq12_integrated_plan/m1_release/scenarios.csv').open()as f:scenes=list(csv.DictReader(f))
fig,ax=plt.subplots(figsize=(8,4))
for name in ['clean','snr0','dual_source','nearfield_mismatch','polarity_fault','synthetic_speech']:
    v=sorted(float(x['angle_error_deg']) for x in scenes if x['scenario']==name);ax.plot(v,np.arange(1,len(v)+1)/len(v),label=name)
ax.set(xlabel='Unit-vector angular error (degrees)',ylabel='Empirical CDF',xlim=(0,18),ylim=(0,1));ax.grid();ax.legend();fig.tight_layout();fig.savefig(O/'angular_error_cdf.png',dpi=160);fig.savefig(O/'angular_error_cdf.svg');plt.close(fig)
log=(R/'build/zynq12_integrated_plan/m3_smooth_ab/integrated_direction.log').read_text()
audio=[dict((k,int(v))for k,v in re.findall(r'(\w+)=(-?\d+)',line))for line in log.splitlines()if line.startswith('DIRECTION_AUDIO')]
fig,axes=plt.subplots(2,1,figsize=(8,5))
for ax,lo,hi in [(axes[0],80,130),(axes[1],230,280)]:
    data=[x for x in audio if lo<=x['seq']<=hi];ax.plot([x['seq']for x in data],[x['pcm']for x in data],'.-');ax.set(xlabel='Input sample sequence',ylabel='DAS signed16');ax.grid()
fig.suptitle('Sample-continuous direction changes, 1/16 sample slew');fig.tight_layout();fig.savefig(O/'direction_audio.png',dpi=160);plt.close(fig)
print(json.dumps(rows,indent=2));print('INTEGRATED_FIGURES_PASS')
