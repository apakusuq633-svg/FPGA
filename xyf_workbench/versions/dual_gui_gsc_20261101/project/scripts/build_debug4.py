"""Native Windows RV32 build and matching SRP/steering geometry for four microphones."""
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das4/fw'
TOOL=Path('D:/riscv/riscv-none-elf-gcc/bin')

def run(*args):
    subprocess.run([str(a) for a in args],cwd=ROOT,check=True)

def geometry():
    config=json.loads((ROOT/'configs/debug4_geometry.json').read_text())
    assert config['scan_grid_width']==16 and config['scan_half_mm']==200 and config['scan_z_mm']==300, 'Grid must match fw_srp.c constants'
    coords=[tuple(math.floor(v/1000*16384+0.5) for v in xy) for xy in config['microphones_mm']]
    coords+= [coords[0]]*4  # inactive channels cannot enlarge the steering delay range
    lines=[f'{{{x},{y}}}' for x,y in coords]
    (OUT/'fw_debug4_geometry.h').write_text('#include <stdint.h>\nstatic const int16_t fw_mic_xy_q14[8][2]={'+','.join(lines)+'};\n')
    grid_by_cell=[]
    for gy in range(16):
        for gx in range(16):
            x=-3277+(gx*6554)//15;y=-3277+(gy*6554)//15
            distances=[math.isqrt((x-mx)**2+(y-my)**2+4915**2) for mx,my in coords]
            taus=[(distances[0]-d)*456 for d in distances]
            grid_by_cell.append([(((t>>16)&1023)<<4)|((t>>12)&15) for t in taus])
    # Hardware address is microphone * N_GRID + cell.
    grid=[grid_by_cell[g][ch] for ch in range(8) for g in range(256)]
    (OUT/'steer_lut.hex').write_bytes(''.join(f'{v:08x}\n' for v in grid).encode())
    return grid

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    steer=geometry()
    gcc=TOOL/'riscv-none-elf-gcc.exe';oc=TOOL/'riscv-none-elf-objcopy.exe'
    flags=['-march=rv32im_zicsr','-mabi=ilp32','-ffreestanding','-fno-builtin','-nostdlib',
           '-Wall','-Wextra','-Werror','-Wno-unused-parameter','-fno-strict-aliasing','-fstack-usage',
           '-DFW_ACCEL=1','-DFW_BENCH_ROUND=1','-DFW_JITTER_N=0','-DFW_DEBUG4=1',
           '-DFW_MIC_GEOMETRY_HEADER="fw_debug4_geometry.h"','-I'+str(OUT),'-Isw/fw']
    objects=[]
    for source in ['start.S','fw_live.c','fw_tables.c','fw_fft.c','fw_gcc.c','fw_srp.c']:
        obj=OUT/(Path(source).stem+'.o');objects.append(obj)
        run(gcc,*flags,'-Os' if source=='fw_live.c' else '-O2','-c',ROOT/'sw/fw'/source,'-o',obj)
    elf=OUT/'fw_debug4.elf'
    run(gcc,'-march=rv32im_zicsr','-mabi=ilp32','-nostdlib','-T',ROOT/'sw/fw/link.ld',
        '-Wl,-Map='+str(OUT/'fw_debug4.map'),*objects,'-o',elf)
    sections={}
    for memory,section in [('itcm','.text'),('dtcm','.data')]:
        binary=OUT/(memory+'.bin');run(oc,'-O','binary','--only-section='+section,elf,binary)
        data=binary.read_bytes();data+=b'\0'*((-len(data))%4)
        if len(data)>(16384 if memory=='itcm' else 0x2800):raise RuntimeError('Image exceeds TCM')
        values=list(struct.unpack('<'+'I'*(len(data)//4),data))
        encoded=''.join(f'{v:08x}\n' for v in values).encode();(OUT/(memory+'.hex')).write_bytes(encoded)
        sections[memory]=(values,hashlib.sha256(encoded).hexdigest())
    frame_sizes=[]
    for path in OUT.glob('*.su'):
        for line in path.read_text().splitlines():
            columns=line.split('\t');frame_sizes.append(int(columns[1]))
    if max(frame_sizes)>=440:raise RuntimeError('Firmware stack frame exceeds half of reserved stack')
    header=['#ifndef ACOUSTIC_DEBUG4_IMAGE_H','#define ACOUSTIC_DEBUG4_IMAGE_H','#include <stdint.h>']
    for memory,(values,digest) in sections.items():
        header += [f'#define ACOUSTIC_{memory.upper()}_WORDS {len(values)}u',
                   f'#define ACOUSTIC_{memory.upper()}_SHA256 "{digest}"']
    coeff=re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',(ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
    fir=[int(v)&65535 for v in coeff.replace('\n','').split(',') if v.strip()]
    arrays={'acoustic_itcm':sections['itcm'][0],'acoustic_dtcm':sections['dtcm'][0],
            'acoustic_fir_coeff':fir,'acoustic_steer_lut':steer}
    header += ['#define ACOUSTIC_FIR_COEFF_WORDS 32u','#define ACOUSTIC_STEER_LUT_WORDS 2048u']
    for name,values in arrays.items():
        header.append(f'static const uint32_t {name}[{len(values)}]={{')
        header += [','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8)]
        header.append('};')
    header.append('#endif')
    (ROOT/'sw/acoustic_debug4_image.h').write_bytes(('\n'.join(header)+'\n').encode())
    print(f'DEBUG4_BUILD_PASS: pairs (0,1),(0,2),(0,3),(1,3); stack frame max={max(frame_sizes)}')

if __name__=='__main__':main()
