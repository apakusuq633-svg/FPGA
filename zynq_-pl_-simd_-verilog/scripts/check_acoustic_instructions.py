"""Compile real custom instructions and test the CPU bridge for every lane configuration."""
from pathlib import Path
import struct
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/system_optimization/instruction_fw'
RV=Path('D:/riscv/riscv-none-elf-gcc/bin')

def main():
    OUT.mkdir(parents=True,exist_ok=True);objects=[]
    flags=['-march=rv32im_zicsr','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-nostdlib','-ffunction-sections','-fdata-sections']
    for name in ['start.S','fw_acoustic_instruction_test.c']:
        obj=OUT/(Path(name).stem+'.o');objects.append(str(obj))
        subprocess.run([str(RV/'riscv-none-elf-gcc.exe'),*flags,'-c',str(ROOT/'sw/fw'/name),'-o',str(obj)],check=True)
    elf=OUT/'instructions.elf'
    subprocess.run([str(RV/'riscv-none-elf-gcc.exe'),*flags,'-T',str(ROOT/'sw/fw/link_live16.ld'),'-Wl,--gc-sections',*objects,'-o',str(elf)],check=True)
    for memory,section in [('itcm','.text'),('dtcm','.data')]:
        p=OUT/(memory+'.bin')
        subprocess.run([str(RV/'riscv-none-elf-objcopy.exe'),'-O','binary','--only-section='+section,str(elf),str(p)],check=True)
        data=p.read_bytes();data+=b'\0'*((-len(data))%4)
        if not data:data=b'\0'*4
        (OUT/(memory+'.hex')).write_text(''.join(f'{v:08x}\n' for v in struct.unpack('<'+'I'*(len(data)//4),data)))
    files=[str(p.relative_to(ROOT)) for p in (ROOT/'rtl').rglob('*.v') if p.name not in ['rv32_ps_top.v','rv32_ps_regs.v','rv32_ps_memif.v','rv32_axi_lite_slave.v']]
    for lanes in [4,8,16]:
        exe=OUT/f'core{lanes}.vvp'
        subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-Irtl','-s','tb_acoustic_instruction_core',f'-Ptb_acoustic_instruction_core.LANES={lanes}',
                        '-o',str(exe),*files,'tb/tb_acoustic_instruction_core.v'],cwd=ROOT,check=True)
        result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],cwd=ROOT,capture_output=True,text=True)
        (OUT/f'core{lanes}.log').write_text(result.stdout+result.stderr)
        assert result.returncode==0 and 'ACOUSTIC_INSTRUCTION_CORE_PASS' in result.stdout,result.stdout+result.stderr
        print(result.stdout.strip(),flush=True)
    print('ACOUSTIC_REAL_INSTRUCTIONS_PASS')

if __name__=='__main__':main()
