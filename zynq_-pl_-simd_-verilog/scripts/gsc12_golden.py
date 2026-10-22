"""Independent M8 batch signal reference and integer NLMS (no DUT output feedback)."""
import numpy as np

def sat16(x):return np.clip(x,-32768,32767).astype(np.int16)
def trunc_div(x,d):return np.where(x>=0,x//d,-((-x)//d))

def frontend(raw,delays_q16,fir,integrate_refs=False):
    """raw: N x 12 int16; exact production cubic and FIR arithmetic."""
    raw=np.asarray(raw,dtype=np.int64);n=len(raw);aligned=np.zeros((n,12),dtype=np.int64)
    for ch in range(12):
        delay=int(delays_q16[ch]);age=delay>>16;f=(delay>>12)&15
        # Exact integer evaluation of the third-order Lagrange polynomial.
        c=[-2*f*(16-f)*(32-f)//3,2*(16+f)*(16-f)*(32-f),
           2*(16+f)*f*(32-f),-2*(16+f)*f*(16-f)//3]
        total=np.zeros(n,dtype=np.int64)
        for k,co in enumerate(c):
            if age+k<n:total[age+k:]+=raw[:n-age-k,ch]*co
        value=np.where(total>=0,(total+8192)//16384,-((-total+8192)//16384))
        aligned[:,ch]=sat16(value)
    das=((aligned.sum(axis=1)+6)//12).astype(np.int16)
    beam=sat16(np.convolve(das.astype(np.int64),np.asarray(fir,dtype=np.int64))[:n]//32768)
    blocking=trunc_div(aligned[:,:11]-aligned[:,11:12],2)
    if integrate_refs:
        # A compact differential array has a spatial zero at DC. A bounded,
        # leaky integrator conditions these derivative-like references before
        # the short adaptive FIR; it is not applied to the target beam.
        conditioned=np.zeros_like(blocking);state=np.zeros(11,dtype=np.int64)
        for i in range(n):
            decay=np.sign(state)*((abs(state)+63)//64)
            state=state-decay+blocking[i]
            conditioned[i]=sat16(trunc_div(state,4))
        blocking=conditioned
    refs=np.array([sat16(np.convolve(blocking[:,ch],np.asarray(fir,dtype=np.int64))[:n]//32768) for ch in range(11)]).T
    return das,beam,refs

def nlms(beam,refs,mu=8192,epsilon=1<<20,warmup=128,freeze=False,weights=None):
    beam=np.asarray(beam,dtype=np.int64);refs=np.asarray(refs,dtype=np.int64)
    w=np.zeros((11,4),dtype=np.int64) if weights is None else np.array(weights,dtype=np.int64).copy()
    history=np.zeros((11,4),dtype=np.int64);out=np.empty(len(beam),dtype=np.int16)
    clips=0;divergence=0;norm_peak=0
    for n in range(len(beam)):
        history[:,1:]=history[:,:-1];history[:,0]=refs[n]
        if n<warmup:out[n]=beam[n];continue
        prediction=int((w*history).sum())//32768
        e=int(beam[n])-prediction;out[n]=max(-32768,min(32767,e))
        if e>32767 or e< -32768:clips+=1;continue
        if not freeze:
            energy=int((history*history).sum())+epsilon
            numerator=mu*e*history
            delta=trunc_div(numerator,energy)
            w=np.clip(w+delta,-32768,32767)
            norm=int(abs(w).sum());norm_peak=max(norm_peak,norm)
            # Correlated blocking references can legitimately have high L1 norm;
            # bound coefficient energy, in addition to per-tap saturation.
            if int((w*w).sum())>16*32768**2:
                w[:]=0;history[:]=0;out[n]=beam[n];divergence+=1
    return out,w,{'saturations':clips,'divergence':divergence,'weight_l1_peak_q15':norm_peak}

def fixed_output(beam,refs,weights):
    predicted=np.zeros(len(beam),dtype=np.int64)
    for ch in range(11):predicted+=np.convolve(refs[:,ch].astype(np.int64),np.asarray(weights[ch],dtype=np.int64))[:len(beam)]
    return sat16(np.asarray(beam,dtype=np.int64)-predicted//32768)
