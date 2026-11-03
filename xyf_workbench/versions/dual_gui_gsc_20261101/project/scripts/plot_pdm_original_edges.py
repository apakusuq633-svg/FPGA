"""Plot only the current receiver and screenshot-matching PDM reference.

Render measured digital ILA samples; slot labels are expected SELECT mapping,
not a claim that either observed bit is physically identified as a microphone.
"""
import json
from pathlib import Path
import numpy as np
from analyze_pdm_ila import read_csv

OUT=Path(__file__).resolve().parents[1]/'build/pdm_ila_20261021'


def current(path):
    h,rows=read_csv(path)
    ri=h.index('raw_1[13:4]')
    din=[r[h.index('pdm_din_i_IBUF[3:0]')]&1 for r in rows]
    clock=[r[h.index('pdm_clk_o_OBUF')] for r in rows]
    a=[i for i,r in enumerate(rows[:-1]) if r[ri]>>8&1]
    b=[i for i,r in enumerate(rows[:-1]) if r[ri]>>9&1]
    av=[rows[i+1][ri]&1 for i in a]
    bv=[rows[i+1][ri]>>4&1 for i in b]
    pairs=[(rows[i][ri]&1,rows[i+1][ri]>>4&1) for i in b]
    return dict(name='Current receiver defaults: nominal 125 ns sample, PDM 2.5 MHz, ILA 40 MHz',dt_ns=25,
                din=din,clock=clock,sync=None,a=a,b=b,av=av,bv=bv,pairs=pairs)


def reference(path):
    h,rows=read_csv(path)
    col=next(i for i,n in enumerate(h) if 'edge_trace' in n)
    trace=[r[col] for r in rows]
    din=[t&1 for t in trace]
    clock=[t>>3&1 for t in trace]
    sync=[t>>2&1 for t in trace]
    a=[i for i,t in enumerate(trace) if t>>4&1]
    b=[i for i,t in enumerate(trace) if t>>5&1]
    av=[sync[i] for i in a];bv=[sync[i] for i in b]
    pairs=[];held=None
    for i,t in enumerate(trace):
        if t>>4&1:held=sync[i]
        if t>>5&1 and held is not None:
            pairs.append((held,sync[i]));held=None
    half=np.diff([i for i in range(1,len(clock)) if clock[i]!=clock[i-1]])
    cycles=[t>>54&0xffffffff for t in trace]
    assert all((y-x)&0xffffffff==1 for x,y in zip(cycles,cycles[1:]))
    assert all(bool(t>>4&1)==((t>>8&63)==1 and not(t>>3&1)) for t in trace)
    assert all(bool(t>>5&1)==((t>>8&63)==1 and bool(t>>3&1)) for t in trace)
    return dict(name='Screenshot reference PDM: PDM 3.072 MHz, ILA 200 MHz',dt_ns=5,
                din=din,clock=clock,sync=sync,a=a,b=b,av=av,bv=bv,pairs=pairs,
                clock_half_cycles=sorted(set(map(int,half))))


def main():
    datasets=[current(OUT/'current_default_for_pdm_named_take1_raw.csv'),
              reference(OUT/'original_pdm_edge_named_take1_edge0.csv')]
    report=[]
    for data in datasets:
        changes=[[0,0] for _ in range(1)]
        for i in range(1,len(data['din'])):
            if data['din'][i]!=data['din'][i-1]:changes[0][data['clock'][i]]+=1
        report.append(dict(name=data['name'],resolution_ns=data['dt_ns'],
            paired_cycles=len(data['pairs']),sample_a_ones=float(np.mean(data['av'])),
            sample_b_ones=float(np.mean(data['bv'])),
            paired_bits_equal_fraction=float(np.mean([a==b for a,b in data['pairs']])),
            raw_transitions_clock_low=changes[0][0],raw_transitions_clock_high=changes[0][1],
            half_cycles=data.get('clock_half_cycles'),
            limitation='Slot A/B identities assume actual SELECT low/high; these traces do not independently identify U1/U2.'))
    (OUT/'original_pdm_edge_comparison.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(2,1,figsize=(15,8))
    for ax,data in zip(axes,datasets):
        clk=np.array(data['clock']);din=np.array(data['din']);dt=data['dt_ns']
        fall=np.flatnonzero((clk[1:]==0)&(clk[:-1]==1))+1
        rise=np.flatnonzero((clk[1:]==1)&(clk[:-1]==0))+1
        # Choose a window with DATA changes, not merely a flat clock segment.
        start=next((f for f in fall[2:] if f+250<len(din) and np.any(np.diff(din[f:f+100]))),int(fall[1]))
        period=(400 if dt==25 else 1e9/3072000)
        end=min(len(din),start+int(3.2*period/dt))
        begin=max(0,start-int(35/dt))
        xx=(np.arange(begin,end)-start)*dt
        ax.step(xx,4+clk[begin:end]*.65,where='post',c='black',lw=1.4)
        ax.step(xx,3+din[begin:end]*.65,where='post',c='tab:blue',lw=1.3)
        if data['sync'] is not None:
            ax.step(xx,2+np.array(data['sync'])[begin:end]*.65,where='post',c='tab:cyan',lw=1.1)
        else:
            ax.text(30,2.3,'Direct input sampling; no two-FF synchronizer',color='gray',fontsize=9)
        for inds,vals,base,color in [(data['a'],data['av'],1,'tab:green'),(data['b'],data['bv'],0,'tab:purple')]:
            pts=[(i,v) for i,v in zip(inds,vals) if begin<=i<end]
            for i,v in pts:
                x=(i-start)*dt
                ax.plot([x,x],[base-.08,base+.75],color=color,lw=.8,alpha=.5)
                ax.scatter([x],[base+v*.65],color=color,s=35,zorder=5)
                ax.annotate(str(v),(x,base+v*.65),xytext=(4,4),textcoords='offset points',color=color,fontsize=8)
        for edges,color,mark in [(fall,'tab:blue','fall'),(rise,'tab:orange','rise')]:
            for i in edges:
                if begin<=i<end:
                    x=(i-start)*dt
                    ax.axvspan(x-dt,x,color=color,alpha=.08,lw=0)
                    ax.axvline(x,color=color,ls='--',alpha=.45,lw=.8)
                    ax.text(x,4.82,mark,rotation=0,ha='center',fontsize=8,color=color)
        ax.set_yticks([4.3,3.3,2.3,1.3,.3],['PDM CLOCK','DATA1 raw','DATA1 sync2','U1 expected slot A','U2 expected slot B'])
        ax.set_ylim(-.3,5.15);ax.set_xlim(xx[0],xx[-1]);ax.set_title(data['name'])
        ax.set_xlabel('Time relative to first observed falling CLOCK transition (ns)');ax.grid(axis='x',alpha=.18)
    fig.suptitle('Real board ILA samples: shared DATA1 and actual sampling events\nDots = consumed bits; U1/U2 = expected SELECT slots. Separate captures aligned to observed CLOCK.\nShaded edge bands = one-sample edge uncertainty; these are digital samples, not analog scope traces.',fontsize=12)
    fig.tight_layout(rect=(0,0,1,.93))
    fig.savefig(OUT/'current_vs_original_pdm_edges.png',dpi=170);plt.close(fig)


if __name__=='__main__':main()
