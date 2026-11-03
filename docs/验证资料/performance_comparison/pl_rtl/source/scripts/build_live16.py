"""Build localization profile and LUTs; fixed DAS uses build_live16_fixed.py."""
from pathlib import Path
import hashlib,itertools,json,math,re,struct,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das16_loc/fw'
TOOL=Path('D:/riscv/riscv-none-elf-gcc/bin')
def run(*args):subprocess.run([str(x) for x in args],cwd=ROOT,check=True)
def fft_rom():
    tables=(ROOT/'sw/fw/fw_tables.c').read_text()
    values=[]
    for name in ('g_tw_re','g_tw_im'):
        body=re.search(r'const int16_t '+name+r'\[[^]]+\]\s*=\s*\{([^}]+)',tables)[1]
        values.append([int(v) for v in re.findall(r'-?\d+',body)])
    assert all(len(v)>=512 for v in values)
    encoded=''.join(f'{((values[1][k]&65535)<<16)|(values[0][k]&65535):08x}\n' for k in range(512))
    path=ROOT/'build/fft_tw.hex';path.parent.mkdir(parents=True,exist_ok=True)
    if path.exists():
        assert path.read_text()==encoded,'FFT ROM differs from firmware tables; rebuild matching ROM/bitstream'
    else:path.write_text(encoded)
    return path
def geometry():
    mics=[(0.05*math.cos(k*math.pi/8),0.05*math.sin(k*math.pi/8)) for k in range(16)]
    grids=[(-0.2+0.4*x/31,-0.2+0.4*y/31,0.3) for y in range(32) for x in range(32)]
    delays=[[math.sqrt((x-mx)**2+(y-my)**2+z*z)*39062.5/343 for mx,my in mics] for x,y,z in grids]
    pairs=list(itertools.combinations(range(16),2));srp=[];steer=[]
    maxlag=0
    for a,b in pairs:
        for d in delays:
            tau=d[a]-d[b];maxlag=max(maxlag,abs(tau));q=math.floor(tau*16)
            assert -16<q/16<15
            srp.append(q&511)
    for m in range(16):
        for d in delays:steer.append(math.floor((d[0]-d[m])*16)&16383)
    return mics,grids,pairs,srp,steer,maxlag
def main():
    fft_rom()
    OUT.mkdir(parents=True,exist_ok=True);objects=[]
    for source in ('start.S','fw_live16.c','fw_fft.c','fw_gcc.c','fw_tables.c'):
        obj=OUT/(Path(source).stem+'.o');objects.append(obj)
        run(TOOL/'riscv-none-elf-gcc.exe','-DFW_ARRAY_CHANNELS=16','-DFW_GEOMETRY_CONFIRMED=1','-march=rv32im_zicsr','-mabi=ilp32','-Os',
            '-ffreestanding','-fno-builtin','-nostdlib','-Wall','-Wextra','-Werror',
            '-ffunction-sections','-fdata-sections','-fstack-usage','-c',ROOT/'sw/fw'/source,'-o',obj)
    elf=OUT/'fw_live16.elf'
    run(TOOL/'riscv-none-elf-gcc.exe','-march=rv32im_zicsr','-mabi=ilp32','-nostdlib',
        '-T',ROOT/'sw/fw/link_live16.ld','-Wl,--gc-sections,-Map='+str(OUT/'fw_live16.map'),*objects,'-o',elf)
    header=['#ifndef ACOUSTIC_LIVE16_IMAGE_H','#define ACOUSTIC_LIVE16_IMAGE_H','#include <stdint.h>']
    arrays={}
    for memory,section in (('itcm','.text'),('dtcm','.data')):
        binary=OUT/(memory+'.bin');run(TOOL/'riscv-none-elf-objcopy.exe','-O','binary','--only-section='+section,elf,binary)
        data=binary.read_bytes();data+=b'\0'*((-len(data))%4)
        if not data:data=b'\0'*4
        assert len(data)<=16384
        values=struct.unpack('<'+'I'*(len(data)//4),data)
        encoded=''.join(f'{v:08x}\n' for v in values).encode();(OUT/(memory+'.hex')).write_bytes(encoded)
        header += [f'#define ACOUSTIC_{memory.upper()}_WORDS {len(values)}u',
                   f'#define ACOUSTIC_{memory.upper()}_SHA256 "{hashlib.sha256(encoded).hexdigest()}"']
        arrays['acoustic_'+memory]=values
    coeff=re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',(ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
    arrays['acoustic_fir_coeff']=[int(v)&65535 for v in coeff.replace('\n','').split(',') if v.strip()]
    mics,grids,pairs,srp,steer,maxlag=geometry()
    arrays['acoustic_srp_lut']=srp;arrays['acoustic_steer_lut']=steer
    header+=['#define ACOUSTIC_FIR_COEFF_WORDS 32u',f'#define ACOUSTIC_SRP_LUT_WORDS {len(srp)}u',f'#define ACOUSTIC_STEER_LUT_WORDS {len(steer)}u']
    for name,values in arrays.items():
        header.append(f'static const uint32_t {name}[{len(values)}]={{')
        header += [','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8)]
        header.append('};')
    header.append('#endif');(ROOT/'sw/acoustic_live16_image.h').write_text('\n'.join(header)+'\n')
    for name,values in [('srp_lut',srp),('steer_lut',steer)]:
        (OUT.parent/(name+'.hex')).write_text(''.join(f'{v:04x}\n' for v in values))
    config={'channels':16,'mics_per_line':2,'data_lines':8,'sample_rate_hz':39062.5,
      'grid_w':32,'grid_half_m':0.2,'plane_z_m':0.3,'radius_m':0.05,'sound_speed_m_s':343,
      'channel_positions_m':mics,'pairs':pairs,'r_len':32,'srp_index_bits':17,
      'max_lut_abs_delay_samples':maxlag,'mapping':'CH2k DINk GND, CH2k+1 DINk VDD; slots in increasing angle from +X',
      'physical_slot_mapping_confirmed':False,'board_tested':False}
    (ROOT/'configs/live16_geometry.json').write_text(json.dumps(config,indent=2)+'\n')
    run(TOOL/'riscv-none-elf-size.exe',elf)
    print(f'LIVE16_BUILD_PASS pairs={len(pairs)} grid={len(grids)} max_abs_lag={maxlag:.6f} r_len=32')
if __name__=='__main__':main()
