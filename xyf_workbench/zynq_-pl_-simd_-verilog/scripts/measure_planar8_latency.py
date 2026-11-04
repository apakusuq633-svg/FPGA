"""Reproducible 40 MHz SoC latency measurement with continuous synthetic PCM."""
from pathlib import Path
import hashlib
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import argparse

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/planar8_optimized'
def _toolchain_prefix():
    env=os.environ.get('RISCV_PREFIX')
    if env:return env
    for prefix in ('riscv-none-elf-','riscv64-unknown-elf-','riscv32-unknown-elf-'):
        if shutil.which(prefix+'gcc'):return prefix
    raise SystemExit('RISC-V toolchain not found: set RISCV_PREFIX or add riscv-none-elf-gcc to PATH')
PREFIX=_toolchain_prefix()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--variants',nargs='+',choices=['baseline','profile','overlap','production'],default=['production'])
    parser.add_argument('--output',type=Path)
    parser.add_argument('--windows',type=int,default=3)
    parser.add_argument('--case',type=int,default=0)
    args=parser.parse_args()
    global OUT
    if args.output:OUT=args.output.resolve()
    OUT.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
    env['MAKE']='mingw32-make'
    config=json.loads((ROOT/'configs/production_array.json').read_text())
    rng=random.Random(20261021)
    tones=[(k,rng.random()*2*math.pi) for k in range(24,820,7)]
    point=(.08,.12,.3)
    delay=[math.dist(point,m)*config['sample_rate_hz']/343 for m in config['mic_xyz']]
    pcm=[round(sum(200*math.sin(2*math.pi*k*(n-d)/4096+p) for k,p in tones))
         for n in range(4096) for d in delay]
    (OUT/'pcm.hex').write_text(''.join(f'{x&65535:04x}\n' for x in pcm))
    original=(ROOT/'sw/fw/fw_live16.c').read_text(encoding='utf-8')
    measured=original
    changes=[('uint32_t start=cycles();CAP(0)=7;', 'REG(0x2bf0u,0)=1;uint32_t start=cycles();CAP(0)=7;'),
             ('for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch+=2)channel_pair(ch);','REG(0x2bf0u,0)=2;for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch+=2)channel_pair(ch);'),
             ('unsigned pair=0;', 'REG(0x2bf0u,0)=3;unsigned pair=0;'),
             ('SRP(0)=3;', 'REG(0x2bf0u,0)=4;SRP(0)=3;'),
             ('SRP(2)=0x40000u;', 'REG(0x2bf0u,0)=5;SRP(2)=0x40000u;'),
             ('uint32_t contrast;int32_t nonlocal;', 'REG(0x2bf0u,0)=6;uint32_t contrast;int32_t nonlocal;'),
             ('STEER(5)=grid;', 'REG(0x2bf0u,0)=7;STEER(5)=grid;'),
             ('RESULT(4)=cycles()-compute;RESULT(5)=cycles()-start;', 'REG(0x2bf0u,0)=8;RESULT(4)=cycles()-compute;RESULT(5)=cycles()-start;')]
    for a,b in changes:
        assert a in measured,a
        measured=measured.replace(a,b)
    (OUT/'fw_latency.c').write_text(measured,encoding='utf-8')
    for variant in args.variants:
        fw=OUT/variant;fw.mkdir(exist_ok=True)
        objects=[]
        flags=['-march=rv32im_zicsr','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin',
               '-nostdlib','-Wall','-Wextra','-Werror','-ffunction-sections','-fdata-sections',
               '-DFW_ARRAY_CHANNELS=8','-DFW_GEOMETRY_CONFIRMED=1','-DFW_VFFT_SEEK=1',
               '-I'+str(ROOT/'sw/fw')]
        if variant=='profile':flags+=['-DFW_CYCLE_PROFILE=1']
        if variant=='overlap':flags+=['-DFW_LOCALIZER_WINDOWS=0']
        for source in ['start.S','fw_live16.c','fw_fft.c','fw_gcc.c','fw_tables.c']:
            src=OUT/'fw_latency.c' if source=='fw_live16.c' and variant=='profile' else ROOT/'sw/fw'/source
            if source=='fw_live16.c' and variant=='overlap':src=ROOT/'sw/fw/fw_localizer12.c'
            if source=='fw_live16.c' and variant=='production':src=ROOT/'sw/fw/fw_planar8.c'
            obj=fw/(Path(source).stem+'.o');objects.append(obj)
            subprocess.run([PREFIX+'gcc',*flags,'-c',str(src),'-o',str(obj)],check=True)
        elf=fw/'fw.elf'
        subprocess.run([PREFIX+'gcc','-march=rv32im_zicsr','-mabi=ilp32','-nostdlib','-T',str(ROOT/'sw/fw/link_live16.ld'),'-Wl,--gc-sections',*map(str,objects),'-o',str(elf)],check=True)
        for memory,section in [('itcm','.text'),('dtcm','.data')]:
            binary=fw/(memory+'.bin')
            subprocess.run([PREFIX+'objcopy','-O','binary','--only-section='+section,str(elf),str(binary)],check=True)
            data=binary.read_bytes();data+=b'\0'*(-len(data)%4)
            if not data:data=b'\0'*4
            assert len(data)<=16384
            words=struct.unpack('<'+'I'*(len(data)//4),data)
            (fw/(memory+'.hex')).write_text(''.join(f'{v:08x}\n' for v in words))
    sources=sorted((ROOT/'rtl').rglob('*.v'))
    model=OUT/'model_abi0'
    cmd=['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator','--binary','--timing',
         '-Wno-fatal','-j','4','-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc','--top-module','tb_planar8_latency','-Irtl','--Mdir',str(model),
         *map(str,sources),str(ROOT/'tb/tb_planar8_latency.v')]
    with (OUT/'compile.log').open('w') as f:
        q=subprocess.run(cmd,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
    if q.returncode:raise RuntimeError((OUT/'compile.log').read_text()[-5000:])
    for variant in args.variants:
        print('Running '+variant,flush=True)
        with (OUT/(variant+'.log')).open('w') as f:
            q=subprocess.run([str(model/'Vtb_planar8_latency.exe'),'+FW='+str(OUT/variant).replace('\\','/'),'+PCM='+str(OUT/'pcm.hex').replace('\\','/'),'+WINDOWS='+str(args.windows),'+CASE='+str(args.case),'+DUMP='+str(OUT/variant).replace('\\','/'),*(['+OVERLAP'] if variant=='overlap' else []),*(['+PRODUCTION'] if variant=='production' else [])],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        log=(OUT/(variant+'.log')).read_text()
        print(log[-2500:],flush=True)
        assert q.returncode==0 and 'PLANAR8_LATENCY_PASS' in log
        (OUT/(variant+'_run.json')).write_text(json.dumps({
            'variant':variant,'windows':args.windows,'scope':'synthetic PCM, not board measurement',
            'firmware_hex_sha256':hashlib.sha256((OUT/variant/'itcm.hex').read_bytes()).hexdigest(),
            'pcm_sha256':hashlib.sha256((OUT/'pcm.hex').read_bytes()).hexdigest(),
            'bench_sha256':hashlib.sha256((ROOT/'tb/tb_planar8_latency.v').read_bytes()).hexdigest(),
            'matches_production_words':(OUT/variant/'itcm.hex').read_text().splitlines()==(ROOT/'build/das8/fw/itcm.hex').read_text().splitlines()
        },indent=2)+'\n')
    manifest={'clock_hz':40000000,'sample_rate_hz':39062.5,'input':'synthetic far-field-like multitone; nominal point 0.08/0.12/0.3m',
              'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sources+[ROOT/'tb/tb_planar8_latency.v',Path(__file__),ROOT/'sw/fw/fw_live16.c']}}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('PLANAR8_LATENCY_MEASUREMENT_PASS',flush=True)


if __name__=='__main__':main()
