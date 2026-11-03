"""Actual 9-channel DAS/SIMD/tap RTL -> independent integer model -> PS GSC."""
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/gsc9_checks'

def clip(v):return max(-32768,min(32767,v))
def trunc(v,d):return v//d if v>=0 else -((-v)//d)

def frontend(raw,delays,fir):
    n=len(raw);aligned=[[0]*9 for _ in raw]
    for ch,d in enumerate(delays):
        age=d>>16;f=(d>>12)&15
        coeff=[-2*f*(16-f)*(32-f)//3,2*(16+f)*(16-f)*(32-f),
               2*(16+f)*f*(32-f),-2*(16+f)*f*(16-f)//3]
        for k in range(n):
            v=sum(raw[k-age-j][ch]*c for j,c in enumerate(coeff) if k>=age+j)
            aligned[k][ch]=clip((v+8192)//16384 if v>=0 else -((-v+8192)//16384))
    das=[];beam=[];refs=[];blocking=[];integ=[0]*8
    for k,x in enumerate(aligned):
        total=sum(x);das.append((total+4)//9 if total>=0 else -((-total+4)//9))
        beam.append(clip(sum(das[k-j]*c for j,c in enumerate(fir) if k>=j)//32768))
        row=[]
        for ch in range(8):
            old=integ[ch];decay=(old+255)//256 if old>=0 else -((-old+255)//256)
            integ[ch]=old-decay+trunc(x[ch]-x[8],2)
            row.append(clip(trunc(integ[ch],16)))
        blocking.append(row)
        refs.append([clip(sum(blocking[k-j][ch]*c for j,c in enumerate(fir) if k>=j)//32768) for ch in range(8)])
    return das,beam,refs

def adaptive(beam,refs):
    weights=[[0]*4 for _ in range(8)];hist=[[0]*16 for _ in range(8)];out=[]
    for n,(y,row) in enumerate(zip(beam,refs)):
        for ch in range(8):hist[ch]=[row[ch]]+hist[ch][:15]
        if n<512:out.append(y);continue
        error=y-sum(weights[c][t]*hist[c][t*4] for c in range(8) for t in range(4))//32768
        out.append(clip(error))
        if error>32767 or error< -32768 or y in [-32768,32767] or n%4!=3:continue
        energy=(1<<20)+sum(hist[c][t*4]**2 for c in range(8) for t in range(4))
        for c in range(8):
            for t in range(4):weights[c][t]=clip(weights[c][t]+trunc(8192*error*hist[c][t*4],energy))
        if sum(v*v for row in weights for v in row)>16*32768**2:
            weights=[[0]*4 for _ in range(8)];hist=[[0]*16 for _ in range(8)];out[-1]=y
    return out

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH'];env['MAKE']='mingw32-make'
    def run(name,cmd):
        with (OUT/(name+'.log')).open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        log=(OUT/(name+'.log')).read_text(errors='replace')
        if q.returncode:raise RuntimeError(name+'\n'+log[-4000:])
        return log
    rng=random.Random(20261022);raw=[[rng.randrange(-1000,1001) for _ in range(9)] for _ in range(2048)]
    delays=[(c%6)*65536+((c*7)%16)*4096 for c in range(9)]
    import re
    fir=[int(v,16) for v in re.findall(r'0x([0-9a-f]+)u',re.search(r'acoustic_fir_coeff\[32\]=\{([^}]+)',(ROOT/'sw/acoustic_circular9_image.h').read_text())[1])];fir=[v-65536 if v>=32768 else v for v in fir]
    for name,values,width in [('pcm',[v&65535 for row in raw for v in row],4),('delay',delays,8),('fir',[v&65535 for v in fir],4)]:
        (OUT/(name+'.hex')).write_text(''.join(f'{v:0{width}x}\n' for v in values))
    tb=(ROOT/'tb/tb_gsc12_frontend.v').read_text(encoding='utf-8')
    tb=tb.replace('tb_gsc12_frontend','tb_gsc9_frontend').replace('GSC12_FRONTEND','GSC9_FRONTEND')
    tb=tb.replace('[287:0]','[215:0]').replace('[383:0]','[287:0]').replace("384'b0","288'b0")
    tb=tb.replace('ACTIVE_CHANNELS(12)','ACTIVE_CHANNELS(9)').replace('rv32_gsc_tap tap','rv32_gsc_tap #(.ACTIVE_CHANNELS(9)) tap')
    tb=tb.replace('g<12','g<9').replace('ch<12','ch<9').replace('n*12+ch','n*9+ch')
    tb=tb.replace('wire[191:0]raw;','wire[191:0]raw; assign raw[191:144]=48\'hffffffffffff;')
    tb=tb.replace('[0:3071]','[0:18431]').replace('[0:11]','[0:8]').replace('n<256','n<2048').replace('packets!=256','packets!=2048')
    tb=tb.replace('repeat(900)','repeat(200)').replace('repeat(122)','repeat(54)')
    tb=tb.replace('VECTOR_DIR',OUT.as_posix()).replace('OUTPUT_FILE',(OUT/'packets.hex').as_posix())
    (OUT/'tb.v').write_text(tb)
    log=run('rtl_compile',['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator','--binary','--timing','-Wno-fatal','-j','4',
        '-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc','-Irtl','--top-module','tb_gsc9_frontend',
        '--Mdir',OUT/'model',*sorted((ROOT/'rtl').rglob('*.v')),OUT/'tb.v'])
    assert 'GSC9_FRONTEND_RTL_PASS' in run('rtl', [OUT/'model/Vtb_gsc9_frontend.exe'])
    words=[[int.from_bytes(int(line,16).to_bytes(64,'little')[4*i:4*i+4],'little') for i in range(16)] for line in (OUT/'packets.hex').read_text().split()]
    das,beam,refs=frontend(raw,delays,fir)
    assert len(words)==len(raw)
    for n,w in enumerate(words):
        assert w[0]==0x47534302 and w[1]==n and w[13]==0x000a0009 and w[12]>>16==0
        assert w[7]==(das[n]&65535)|((beam[n]&65535)<<16),(n,'independent DAS/FIR mismatch')
        for ch in range(9):assert (w[8+ch//2]>>(16*(ch%2)))&65535==raw[n][ch]&65535
    run('c_compile',['gcc','-shared','-O2','-Wall','-Wextra','-Werror','-DGSC9_TEST','sw/gsc9.c','-o',OUT/'gsc9.dll'])
    dllpath=os.add_dll_directory('C:/msys64/ucrt64/bin') if hasattr(os,'add_dll_directory') else None
    lib=C.CDLL(str(OUT/'gsc9.dll'));lib.gsc9_state_size.restype=C.c_size_t
    class Config(C.Structure):
        _fields_=[('version',C.c_uint32),('epoch',C.c_uint32),('direction_id',C.c_uint16),('mu_q15',C.c_uint16),
                  ('epsilon',C.c_uint32),('delay_q16',C.c_uint32*9),('fir_q15',C.c_int16*32)]
    c=Config(1,0,7,8192,1<<20,(C.c_uint32*9)(*delays),(C.c_int16*32)(*fir))
    lib.gsc9_configure.argtypes=[C.c_void_p,C.POINTER(Config)]
    lib.gsc9_process.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.c_int,C.c_int];lib.gsc9_process.restype=C.c_int16
    lib.gsc9_model_beam.argtypes=[C.c_void_p];lib.gsc9_model_beam.restype=C.c_uint32
    lib.gsc9_reason.argtypes=[C.c_void_p];lib.gsc9_reason.restype=C.c_uint32
    def state():
        s=C.create_string_buffer(lib.gsc9_state_size());assert lib.gsc9_configure(s,C.byref(c))==0;return s
    def process(s,w,on=1,freeze=0):return lib.gsc9_process(s,(C.c_uint32*16)(*w),on,freeze)
    s=state();out=[]
    for n,w in enumerate(words):
        out.append(process(s,w));assert lib.gsc9_model_beam(s)==w[7],(n,'PS alignment')
    assert out==adaptive(beam,refs),'PS NLMS differs from independent integer model'
    assert lib.gsc9_reason(s)==0
    for on,freeze in [(0,0),(1,1)]:
        s=state();assert [process(s,w,on,freeze) for w in words]==beam
    # Warm filter, then inject independent transport/direction/alignment faults.
    guards=[]
    for field,value,reason in [(0,0,3),(1,999,4),(2,2,5),(6,(7<<8)|3,6),(7,0,7),(13,0,3),(12,65536,3),(15,1,4)]:
        s=state()
        for w in words[:600]:process(s,w)
        w=words[600].copy();w[field]=value
        original=(w[7]>>16)&65535;original=original-65536 if original>=32768 else original
        assert process(s,w)==original and lib.gsc9_reason(s)==reason,(field,lib.gsc9_reason(s))
        guards.append(field)
    # Ideal broadside target + spatially varying tonal interference. Evaluate
    # both components through the SAME learned, frozen weights (not two fits).
    length=8192
    target=[[int(900*math.sin(2*math.pi*3000*n/156250))]*9 for n in range(length)]
    noise=[[int((1+.6*math.cos(ch*math.pi/4) if ch<8 else 1)*
                  (1100*math.sin(2*math.pi*2200*n/156250)+800*math.sin(2*math.pi*4700*n/156250))) for ch in range(9)] for n in range(length)]
    mixed=[[a+b for a,b in zip(t,v)] for t,v in zip(target,noise)]
    identity=[32767]+[0]*31;d0=[0]*9
    md,mb,mr=frontend(mixed,d0,identity)
    c.delay_q16=(C.c_uint32*9)(*d0);c.fir_q15=(C.c_int16*32)(*identity)
    s=state()
    for n,row in enumerate(mixed):
        w=[0]*16;w[0]=0x47534302;w[1]=n;w[2]=1;w[5]=65536;w[6]=(7<<8)|1;w[7]=(md[n]&65535)|((mb[n]&65535)<<16);w[13]=0x000a0009
        for ch,v in enumerate(row):w[8+ch//2]|=(v&65535)<<(16*(ch%2))
        process(s,w)
    assert lib.gsc9_reason(s)==0
    weights=(C.c_int32*32)();lib.gsc9_get_weights.argtypes=[C.c_void_p,C.POINTER(C.c_int32)];lib.gsc9_get_weights(s,weights)
    def component(raw):
        _,beam,refs=frontend(raw,d0,identity);out=[]
        for n,y in enumerate(beam):
            prediction=sum(weights[ch*4+t]*refs[n-4*t][ch] for ch in range(8) for t in range(4) if n>=4*t)//32768
            out.append(clip(y-prediction))
        return sum(y*y for y in beam[4096:]),sum(y*y for y in out[4096:])
    ti,to=component(target);ni,no=component(noise)
    sir_gain=10*math.log10((to/no)/(ti/ni));target_gain=10*math.log10(to/ti)
    assert sir_gain>=3 and abs(target_gain)<=.1,(sir_gain,target_gain)
    result={'status':'PASS_DIGITAL','board_tested':False,'rtl_samples':len(words),'ps_matches_independent_nlms':True,
            'disabled_and_frozen_bypass':True,'guard_fields':guards,
            'ideal_aligned_scene_sir_gain_db':sir_gain,'ideal_aligned_scene_target_gain_db':target_gain,
            'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'sw/gsc9.c',ROOT/'sw/gsc9.h',Path(__file__)]}}
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('GSC9_RTL_PS_GOLDEN_PASS packets=2048 guards=8 hardware=UNVERIFIED',flush=True)

if __name__=='__main__':main()
