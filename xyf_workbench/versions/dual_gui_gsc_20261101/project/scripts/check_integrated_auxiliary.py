"""Existing active RTL tests, with every generated output redirected to a new run."""
from pathlib import Path
import argparse,contextlib,io,json,subprocess,sys,shutil,struct,hashlib
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--start-at');a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
rows=[]
source_hashes={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (R/'rtl').rglob('*') if f.is_file()}
(O/'source_manifest.json').write_text(json.dumps(source_hashes,indent=2))
def test(top,params=()):
    tag=top+('_'+'_'.join(str(v) for v in params) if params else '')
    text=(R/'tb'/f'{top}.v').read_text()
    import re
    # Historical Verilog benches use identifiers reserved by SystemVerilog.
    text=re.sub(r'\bexpect\b','expected_value',text)
    text=re.sub(r'\bbefore\b','prior_value',text)
    text=re.sub(r'\bref\b','reference_value',text)
    if top=='tb_phat_reciprocal':
        from golden.fw_acou_model import LUT
        values=[]
        for mag in range(65536):
            e=max(0,mag.bit_length()-1);mant=mag>>(e-14) if e>=14 else mag<<(14-e)
            values.append(16384 if not mag else LUT[(mant>>10)&15])
        path=O/'reciprocal.hex';path.write_text(''.join(f'{v:04x}\n' for v in values))
        text=text.replace('build/phat_reciprocal.hex',str(path))
    if top=='tb_acoustic_instruction_core':
        fw=O/'instruction_fw'
        if not fw.exists():
            fw.mkdir();gcc=shutil.which('riscv64-unknown-elf-gcc');objcopy=shutil.which('riscv64-unknown-elf-objcopy');assert gcc and objcopy
            major=int(subprocess.check_output([gcc,'-dumpversion'],text=True).split('.')[0])
            flags=['-march=rv32im_zicsr' if major>=11 else '-march=rv32im','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-nostdlib','-ffunction-sections','-fdata-sections']
            objects=[];buildlog=[]
            for source in ['start.S','fw_acoustic_instruction_test.c']:
                obj=fw/(Path(source).stem+'.o');objects.append(str(obj))
                q=subprocess.run([gcc,*flags,'-c',str(R/'sw/fw'/source),'-o',str(obj)],capture_output=True,text=True);buildlog.append(q.stdout+q.stderr);assert q.returncode==0,q.stderr
            q=subprocess.run([gcc,*flags,'-T',str(R/'sw/fw/link_live16.ld'),'-Wl,--gc-sections',*objects,'-o',str(fw/'instructions.elf')],capture_output=True,text=True);buildlog.append(q.stdout+q.stderr);assert q.returncode==0,q.stderr
            for memory,section in [('itcm','.text'),('dtcm','.data')]:
                subprocess.run([objcopy,'-O','binary','--only-section='+section,str(fw/'instructions.elf'),str(fw/(memory+'.bin'))],check=True)
                data=(fw/(memory+'.bin')).read_bytes();data+=b'\0'*((-len(data))%4);data=data or b'\0'*4
                (fw/(memory+'.hex')).write_text(''.join(f'{v:08x}\n' for v in struct.unpack('<'+'I'*(len(data)//4),data)))
            (fw/'build.log').write_text(''.join(buildlog))
        text=text.replace('build/system_optimization/instruction_fw/',str(fw)+'/')
    text=re.sub(r'\$dumpfile\("[^"]+"\)',f'$dumpfile("{O/tag}.vcd")',text)
    (O/(tag+'.v')).write_text(text)
    cmd=['iverilog','-g2005' if top in ['tb_chan_align','tb_steer','tb_xspec_phat'] else '-g2012','-Irtl','-s',top,'-o',str(O/tag)]
    if params:cmd+=['-P',f'{top}.'+('LANES' if top=='tb_acoustic_instruction_core' else 'ACTIVE_CHANNELS')+f'={params[0]}']
    cmd+=[str(f) for f in (R/'rtl').rglob('*.v')]+[str(O/(tag+'.v'))]
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/(tag+'_compile.log')).write_text(q.stdout+q.stderr)
    assert q.returncode==0,q.stderr
    q=subprocess.run(['vvp',str(O/tag)],cwd=R,capture_output=True,text=True)
    (O/(tag+'.log')).write_text(q.stdout+q.stderr)
    ok=q.returncode==0 and 'PASS' in q.stdout and 'FAIL' not in q.stdout
    rows.append({'test':tag,'status':'PASS' if ok else 'FAIL'});print(rows[-1],flush=True)
    (O/'metrics.json').write_text(json.dumps(rows,indent=2));assert ok,q.stdout[-2000:]
tops=['tb_chan_align','tb_pdm_array_rx','tb_steer','tb_steer_regs','tb_vec_core','tb_xspec_phat','tb_phat_weak_bins','tb_phat_reciprocal','tb_acoustic_instruction_core','tb_das_config','tb_recovery_policy']
if a.start_at:tops=tops[tops.index(a.start_at):]
for top in tops:
    if top=='tb_acoustic_instruction_core':
        for lanes in [4,8,16]:test(top,(lanes,))
    else:test(top)
for channels in [8,12,16]:test('tb_das_stream',(channels,))
# Controller-only checks retain their original compile inputs, but own their logs.
script=R/'scripts/check_localizer12_safety_units.py';code=script.read_text().replace("O=R/'build/localizer12_safety'/('before_units' if a.before else 'final_units')",f'O=Path({str(O/"controller")!r})')
old=sys.argv;sys.argv=[str(script)];log=io.StringIO()
with contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):exec(compile(code,str(script),'exec'),{'__name__':'__main__','__file__':str(script)})
sys.argv=old;(O/'controller_driver.log').write_text(log.getvalue())
rows+=json.loads((O/'controller/summary.json').read_text());(O/'metrics.json').write_text(json.dumps(rows,indent=2))
assert all(hashlib.sha256((R/k).read_bytes()).hexdigest()==v for k,v in source_hashes.items())
print('INTEGRATED_AUXILIARY_PASS',flush=True)
