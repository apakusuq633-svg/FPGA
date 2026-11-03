"""Compare board captures by physical pin and normalized full scale."""
import json
from pathlib import Path
import numpy as np

OUT=Path(__file__).resolve().parents[1]/'build/pdm_ila_20261021'
CONFIGS=[('current','all_mics_current_take1',['T14','Y17','W16','T15'],8388608),
         ('reference','reference768_all_take1',['T14','Y17','T15','W16'],32768),
         ('reference_pulldown','reference768_pd_all_take1',['T14','Y17','T15','W16'],32768)]


def main():
    results=[]
    for role,label,pins,fullscale in CONFIGS:
        source=OUT/(label+'_analysis.json')
        if not source.exists():continue
        data=json.loads(source.read_text(encoding='utf-8'))
        rows=[]
        for line,pin in enumerate(pins):
            means=[[c['channels'][2*line+k]['mean']/fullscale for k in range(2)] for c in data['pcm']]
            rms=[[c['channels'][2*line+k]['ac_rms']/fullscale for k in range(2)] for c in data['pcm']]
            equality=[c.get('pair_equal_fraction',c.get('same_line_equal_fraction'))[line] for c in data['pcm']]
            rows.append(dict(pin=pin,source_line=line,mean_full_scale=np.mean(means,axis=0).tolist(),
                             ac_rms_full_scale=np.mean(rms,axis=0).tolist(),pair_equal_fraction=equality))
        results.append(dict(role=role,label=label,lines=rows))
    report=dict(installation='User reports all microphones installed for all captures in this comparison',
                source_identity='PDM_48K original acquisition source snapshot; supplied screenshot source version unconfirmed',
                physical_dual_microphone_accepted=False,results=results)
    (OUT/'reference_comparison_20261022.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    for r in results:
        print(r['role'])
        for row in sorted(r['lines'],key=lambda x:['T14','Y17','W16','T15'].index(x['pin'])):
            print(row['pin'],'DC/fullscale',np.round(row['mean_full_scale'],4).tolist(),'PCM pair equality',row['pair_equal_fraction'])
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(4,1,figsize=(11,9),sharex=True,sharey=True)
    for ax,pin in zip(axes,['T14','Y17','W16','T15']):
        for i,r in enumerate(results):
            row=next(x for x in r['lines'] if x['pin']==pin)
            ax.bar(np.arange(2)+(i-(len(results)-1)/2)*.24,row['mean_full_scale'],width=.24,label=r['role'])
        ax.set_ylabel(pin+' DC/FS');ax.set_ylim(-1,1);ax.axhline(0,c='black',lw=.6);ax.grid(axis='y',alpha=.25)
    axes[0].legend();axes[-1].set_xticks([0,1],['Phase A PCM','Phase B PCM'])
    fig.suptitle('Same installed array: original reference versus current acquisition')
    fig.tight_layout();fig.savefig(OUT/'reference_comparison_20261022.png',dpi=160);plt.close(fig)


if __name__=='__main__':main()
