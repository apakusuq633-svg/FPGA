"""Build the production 12-mic profile; geometry stays disabled until the drawing arrives."""
from pathlib import Path
import argparse, hashlib, json, re, shutil, struct, subprocess
from build_live16 import fft_rom
from pdm12_geometry import validate

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/das12/fw'

def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler-prefix', default='riscv64-unknown-elf-')
    parser.add_argument('--march', default=None)
    parser.add_argument('--profile', action='store_true', help='Build cycle instrumentation separately')
    parser.add_argument('--numeric66',action='store_true',help='Geometry-free 66-pair SIMD numerical audit')
    parser.add_argument('--detail',action='store_true',help='Intrusive capture/prepare diagnostics, not baseline timings')
    parser.add_argument('--fused',action='store_true',help='Reuse capture sum and fuse scaling/Hann')
    parser.add_argument('--capture-increment',action='store_true',help='Candidate INDEX loop strength reduction')
    parser.add_argument('--test-srp',action='store_true',help='Isolated synthetic geometry only; requires numeric66')
    parser.add_argument('--mem-profile',action='store_true',help='Stage marker stores for testbench LSU attribution')
    parser.add_argument('--hot-o2',action='store_true',help='Reversible O2 candidate; numerical/performance A-B required')
    parser.add_argument('--transfer',action='store_true',help='TEST-only RV32 compute scheduling with autonomous transfers')
    parser.add_argument('--windows',type=int,default=4,help='Transfer windows; zero runs continuously')
    parser.add_argument('--output',type=Path,help='Isolated build parent directory')
    parser.add_argument('--transfer-source',type=Path,help='Isolated test scheduler source')
    args = parser.parse_args()
    if args.profile: OUT = ROOT / 'build/das12_profile/fw'
    if args.transfer:
        assert args.windows>=0
        OUT=ROOT/'build/localizer12/fw'
    if args.output:
        assert args.transfer or args.profile
        OUT=args.output.resolve()/'fw'
    if args.numeric66:
        assert args.profile,'--numeric66 requires --profile'
    config = json.loads((ROOT/'configs/production_array.json').read_text())
    assert (config['channels'],config['pairs'],config['data_lines']) == (12,66,6)
    assert config['geometry_status'] == 'awaiting_drawing'
    assert config.get('role','PRODUCTION')=='PRODUCTION','Test geometry cannot be a production profile'
    assert not validate(config)['geometry_enabled'], 'Production geometry must remain disabled pending measured coordinates'
    fft_rom(); OUT.mkdir(parents=True,exist_ok=True)
    tools = {name: shutil.which(args.compiler_prefix+name) for name in ('gcc','objcopy','size')}
    if not all(tools.values()): raise RuntimeError('RISC-V toolchain missing; pass --compiler-prefix')
    major=int(subprocess.check_output([tools['gcc'],'-dumpversion'],text=True).split('.')[0])
    march=args.march or ('rv32im_zicsr' if major>=11 else 'rv32im')
    def run(*items): subprocess.run([str(x) for x in items],cwd=ROOT,check=True)
    flags = ['-march='+march,'-mabi=ilp32','-O2' if args.hot_o2 else '-Os','-ffreestanding','-fno-builtin',
             '-nostdlib','-Wall','-Wextra','-Werror','-ffunction-sections','-fdata-sections',
             '-fstack-usage','-DFW_ARRAY_CHANNELS=12','-DFW_GEOMETRY_CONFIRMED=0','-DFW_VFFT_SEEK=1']
    if args.profile: flags.append('-DFW_CYCLE_PROFILE=1')
    if args.numeric66: flags+=['-DFW_NUMERIC66=1','-DFW_SIMD_PHAT=1','-DFW_GCC_AUDIT=1']
    if args.test_srp:
        assert args.numeric66,'--test-srp requires --numeric66'
        flags.append('-DFW_TEST_SRP=1')
    if args.mem_profile: flags.append('-DFW_MEM_PROFILE=1')
    if args.detail:
        assert args.profile
        flags.append('-DFW_DETAIL_PROFILE=1')
    if args.fused: flags.append('-DFW_PREPARE_FUSED=1')
    if args.capture_increment: flags.append('-DFW_CAPTURE_INCREMENT=1')
    if args.transfer:flags.append('-DFW_LOCALIZER_WINDOWS='+str(args.windows))
    objects=[]
    for source in ('start.S','fw_live16.c','fw_fft.c','fw_gcc.c','fw_tables.c'):
        if args.transfer and source=='fw_live16.c':source=str(args.transfer_source.resolve()) if args.transfer_source else 'fw_localizer12.c'
        obj=OUT/(Path(source).stem+'.o');objects.append(obj)
        run(tools['gcc'],*flags,'-c',ROOT/'sw/fw'/source,'-o',obj)
    elf=OUT/'fw_live12.elf'
    run(tools['gcc'],'-march='+march,'-mabi=ilp32','-nostdlib',
        '-T',ROOT/'sw/fw/link_live16.ld','-Wl,--gc-sections,-Map='+str(OUT/'fw_live12.map'),*objects,'-o',elf)
    disassembly=subprocess.check_output([args.compiler_prefix+'objdump','-d',str(elf)],text=True)
    (OUT/'disassembly.txt').write_text(disassembly)
    functions=[(int(m[0],16),m[1]) for m in re.findall(r'^([0-9a-f]+) <([^>]+)>:',disassembly,re.M)]
    tags=[0]*4096
    for index,(begin,name) in enumerate(functions):
        end=functions[index+1][0] if index+1<len(functions) else 16384
        tag=1 if name.startswith('capture_pair') else 2 if name.startswith(('spectrum','prepare_fused')) else 0
        for address in range(begin,min(end,16384),4):tags[address//4]=tag
    (OUT/'function_tags.hex').write_text(''.join(f'{tag:x}\n' for tag in tags))
    header=['#ifndef ACOUSTIC_LIVE12_IMAGE_H','#define ACOUSTIC_LIVE12_IMAGE_H','#include <stdint.h>',
            '#define ACOUSTIC_ARRAY_CHANNELS 12u','#define ACOUSTIC_ARRAY_PAIRS 66u',
            '#define ACOUSTIC_GEOMETRY_CONFIRMED 0u']
    for memory,section in (('itcm','.text'),('dtcm','.data')):
        binary=OUT/(memory+'.bin');run(tools['objcopy'],'-O','binary','--only-section='+section,elf,binary)
        data=binary.read_bytes();data+=b'\0'*((-len(data))%4)
        if not data: data=b'\0'*4
        assert len(data)<=16384, 'TCM overflow'
        values=struct.unpack('<'+'I'*(len(data)//4),data)
        encoded=''.join(f'{v:08x}\n' for v in values).encode()
        (OUT/(memory+'.hex')).write_bytes(encoded)
        header += [f'#define ACOUSTIC_{memory.upper()}_WORDS {len(values)}u',
                   f'#define ACOUSTIC_{memory.upper()}_SHA256 "{hashlib.sha256(encoded).hexdigest()}"',
                   f'static const uint32_t acoustic_{memory}[{len(values)}]={{']
        header += [','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8)]
        header.append('};')
    coeff=re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',(ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
    coefficients=[int(v)&65535 for v in coeff.replace('\n','').split(',') if v.strip()]
    header += ['#define ACOUSTIC_FIR_COEFF_WORDS 32u',
               'static const uint32_t acoustic_fir_coeff[32]={'+','.join(str(v)+'u' for v in coefficients)+'};']
    for name,size in (('srp',66*1024),('steer',12*1024)):
        header += [f'#define ACOUSTIC_{name.upper()}_LUT_WORDS {size}u',
                   f'static const uint32_t acoustic_{name}_lut[{size}]={{0}};']
        (OUT.parent/(name+'_lut.hex')).write_text('0000\n'*size)
    header.append('#endif')
    header_path = OUT.parent/'acoustic_live12_profile_image.h' if args.profile or args.transfer else ROOT/'sw/acoustic_live12_image.h'
    header_path.write_text('\n'.join(header)+'\n')
    (OUT.parent/'profile.json').write_text(json.dumps(config,indent=2)+'\n')
    manifest={'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              'flags':flags,'profile':args.profile,'geometry_enabled':False,
              'test_transfer':args.transfer,'transfer_windows':args.windows if args.transfer else None,
              'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in list((ROOT/'sw/fw').glob('*.[ch]'))+list((ROOT/'rtl').rglob('*.v'))+list((ROOT/'rtl').rglob('*.vh'))+
                         [ROOT/'sw/fw/start.S',ROOT/'sw/fw/link_live16.ld']+
                         [ROOT/'tb/tb_live12_soc.v',ROOT/'configs/production_array.json',
                          ROOT/'scripts/build_live12.py',ROOT/'scripts/check_live16_xsim.ps1',ROOT/'scripts/gen_pdm12_numeric.py']},
              'elf_sha256':hashlib.sha256(elf.read_bytes()).hexdigest()}
    manifest['functions']=functions
    if args.transfer_source:manifest['test_scheduler_source']={'path':str(args.transfer_source.resolve()),'sha256':hashlib.sha256(args.transfer_source.read_bytes()).hexdigest()}
    (OUT.parent/'build_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    run(tools['size'],elf)
    print('LIVE12_BUILD_PASS channels=12 lines=6 pairs=66 grid_slots=1024 geometry_enabled=0')

if __name__=='__main__':
    raise SystemExit('12-microphone production retired; use scripts/build_planar8.py')
