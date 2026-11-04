"""Build stage-1 RV32 image; no localization or steering LUT is executed."""
from pathlib import Path
import hashlib,os,shutil,struct,subprocess,json
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das16/fw'
def tool(name):
    exe=name+('.exe' if os.name=='nt' else '')
    env=os.environ.get('RISCV_TOOL_DIR')
    if env:
        path=Path(env)/exe
        if path.exists():return str(path)
    for prefix in ('riscv-none-elf-','riscv64-unknown-elf-','riscv32-unknown-elf-'):
        path=shutil.which(prefix+name)
        if path:return path
    raise SystemExit('RISC-V toolchain not found: '+name+'. Set RISCV_TOOL_DIR or add riscv-none-elf-gcc to PATH')
config=json.loads((ROOT/'configs/live16_fixed.json').read_text())
assert (config['channels'],config['mics_per_line'],config['data_lines'])==(16,2,8)
assert config['das_delay_samples']==[0]*16 and config['das_average_divisor']==16
assert config['sample_rate_hz']==39062.5 and config['pdm_clock_hz']==2500000
def run(*args):subprocess.run([str(x) for x in args],cwd=ROOT,check=True)
OUT.mkdir(parents=True,exist_ok=True)
objects=[]
for source in ('start.S','fw_live16_fixed.c'):
    obj=OUT/(Path(source).stem+'.o');objects.append(obj)
    run(tool('gcc'),'-march=rv32im_zicsr','-mabi=ilp32','-Os',
        '-ffreestanding','-fno-builtin','-nostdlib','-Wall','-Wextra','-Werror',
        '-fstack-usage','-c',ROOT/'sw/fw'/source,'-o',obj)
elf=OUT/'fw_live16_fixed.elf'
run(tool('gcc'),'-march=rv32im_zicsr','-mabi=ilp32','-nostdlib',
    '-T',ROOT/'sw/fw/link.ld','-Wl,-Map='+str(OUT/'fw_live16_fixed.map'),*objects,'-o',elf)
header=['#ifndef ACOUSTIC_LIVE16_FIXED_IMAGE_H','#define ACOUSTIC_LIVE16_FIXED_IMAGE_H','#include <stdint.h>']
arrays={}
for memory,section in (('itcm','.text'),('dtcm','.data')):
    binary=OUT/(memory+'.bin');run(tool('objcopy'),'-O','binary','--only-section='+section,elf,binary)
    data=binary.read_bytes();data+=b'\0'*((-len(data))%4)
    if not data:data=b'\0'*4
    assert len(data)<0x2800
    values=struct.unpack('<'+'I'*(len(data)//4),data)
    encoded=''.join(f'{v:08x}\n' for v in values).encode();(OUT/(memory+'.hex')).write_bytes(encoded)
    header += [f'#define ACOUSTIC_{memory.upper()}_WORDS {len(values)}u',
               f'#define ACOUSTIC_{memory.upper()}_SHA256 "{hashlib.sha256(encoded).hexdigest()}"']
    arrays['acoustic_'+memory]=values
import re
coeff=re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',(ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
arrays['acoustic_fir_coeff']=[int(v)&65535 for v in coeff.replace('\n','').split(',') if v.strip()]
header += ['#define ACOUSTIC_FIR_COEFF_WORDS 32u','#define ACOUSTIC_STEER_LUT_WORDS 0u']
for name,values in arrays.items():
    header.append(f'static const uint32_t {name}[{len(values)}]={{')
    header += [','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8)]
    header.append('};')
header.append('#endif')
(ROOT/'sw/acoustic_live16_fixed_image.h').write_bytes(('\n'.join(header)+'\n').encode())
print('LIVE16_FIXED_BUILD_PASS')
