"""Real RV32/SoC microbenchmarks. Test-only assembly, no functional RTL edits."""
from pathlib import Path
import subprocess, struct, json, csv, hashlib,argparse
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/rv32_mem_perf'

def run(*args):
    return subprocess.run(list(map(str,args)),cwd=ROOT,check=True,capture_output=True,text=True).stdout

def main():
    global OUT
    p=argparse.ArgumentParser();p.add_argument('--mmio-unrolled',action='store_true');p.add_argument('--output',type=Path);args=p.parse_args()
    if args.output:OUT=ROOT/args.output
    if args.mmio_unrolled:OUT=OUT/'mmio_unrolled'
    OUT.mkdir(parents=True,exist_ok=True)
    cases=[]; code=['.section .text.start,"ax"',' .globl _start','_start:','li sp,0x3ff0','li s0,0x2800']
    patterns={
      'EMPTY':('0x1000',['nop']),
      'D1_LW':('0x1000',['lw t3,0(t0)']),
      'D2_SW':('0x1000',['sw t3,0(t0)']),
      'D3_MIX':('0x1000',['lw t3,0(t0)','addi t3,t3,1','sw t3,0(t0)']),
      'D5_DEP':('0x1000',['lw t3,0(t0)','add t4,t3,t3']),
      'D5_INDEP':('0x1000',['lw t3,0(t0)','add t4,t5,t5']),
      'D4_LB':('0x1000',['lb t3,0(t0)']),
      'D4_LBU':('0x1000',['lbu t3,0(t0)']),
      'D4_LH':('0x1000',['lh t3,0(t0)']),
      'D4_LHU':('0x1000',['lhu t3,0(t0)']),
      'D4_SB':('0x1000',['sb t3,1(t0)']),
      'D4_SH':('0x1000',['sh t3,2(t0)']),
      'M1_READ':('0x4004',['lw t3,0(t0)']),
      'M2_WRITE':('0x5000',['sw t3,0(t0)']),
      'M2_MIX':('0x5000',['sw t3,0(t0)','lw t4,0(t0)']),
      'M3_DATA':('0xc020',['lw t3,0(t0)']),
      'M3_INDEX_DATA':('0xc000',['sw t2,28(t0)','lw t4,4(t0)','lw t3,32(t0)'])}
    for name,(base,ops) in ({} if args.mmio_unrolled else patterns).items():
      for n in (1,16,256,1024):
        k=len(cases)+1; cases.append({'id':k,'name':name,'n':n,'ops':ops})
        code += [f'li t0,{base}',f'li t1,{n}','li t2,0','li t3,0x89abcdef','li t5,7','rdcycle s1',f'begin_{k}:']
        code += ops+[('addi t0,t0,4' if name.startswith('D') or name=='EMPTY' else 'addi t2,t2,1'),'addi t1,t1,-1',f'bnez t1,begin_{k}',f'end_{k}:','rdcycle s2','sub s2,s2,s1','sw s2,0(s0)','addi s0,s0,4']
    for name,op in ([('U_MMIO_LW','lw'),('U_MMIO_SW','sw')] if args.mmio_unrolled else [('U_LW','lw'),('U_SW','sw')]):
      for n in (1,16,256,1024):
        k=len(cases)+1;cases.append({'id':k,'name':name,'n':n,'ops':[op]})
        base=('0x4004' if op=='lw' else '0x5000') if args.mmio_unrolled else '0x1000'
        code+=[f'li t0,{base}','rdcycle s1',f'begin_{k}:']
        for i in range(n):
          if i==512 and not args.mmio_unrolled:code+=['addi t0,t0,1024','addi t0,t0,1024']
          code+=[f'{op} t3,{0 if args.mmio_unrolled else (i%512)*4}(t0)']
        code += [f'end_{k}:','rdcycle s2','sub s2,s2,s1','sw s2,0(s0)','addi s0,s0,4']
    # Test endpoint only: stop the source after measuring, so JTAG readback cannot
    # overflow the 256-word audio FIFO. Production firmware is never changed.
    code+=['li t0,0xc000','sw zero,0(t0)','li t0,0x4000','li t1,0x600dcafe','sw t1,0(t0)','stop: j stop']
    src=OUT/'bench_mem_access.S'; src.write_text('\n'.join(code)+'\n')
    elf=OUT/'bench_mem_access.elf'
    run('riscv64-unknown-elf-gcc','-march=rv32im','-mabi=ilp32','-nostdlib','-Ttext=0','-Wl,-Map='+str(OUT/'bench_mem_access.map'),src,'-o',elf)
    dis=run('riscv64-unknown-elf-objdump','-d',elf); (OUT/'disassembly.txt').write_text(dis)
    symbols={line.split()[-1]:int(line.split()[0],16) for line in run('riscv64-unknown-elf-nm',elf).splitlines() if len(line.split())==3}
    tags=[0]*4096; ends=[0]*4096
    for c in cases:
      c['begin']=symbols[f"begin_{c['id']}"];c['end']=symbols[f"end_{c['id']}"]
      for p in range(c['begin'],c['end'],4): tags[p//4]=c['id']
      ends[c['end']//4]=c['id']
    for name,values in [('tags',tags),('ends',ends)]: (OUT/(name+'.hex')).write_text(''.join(f'{v:08x}\n' for v in values))
    run('riscv64-unknown-elf-objcopy','-O','binary','--only-section=.text',elf,OUT/'itcm.bin')
    b=(OUT/'itcm.bin').read_bytes();b+=b'\0'*((-len(b))%4)
    assert len(b)<=16384,'ITCM overflow'
    (OUT/'itcm.hex').write_text(''.join(f'{v[0]:08x}\n' for v in struct.iter_unpack('<I',b)))
    source_files=list((ROOT/'rtl').rglob('*.v'))+[ROOT/'tb/tb_rv32_mem_perf.v',Path(__file__).resolve()]
    (OUT/'manifest.json').write_text(json.dumps({'commit':run('git','rev-parse','HEAD').strip(),'clock_ns':25,'cases':cases,'elf_sha256':hashlib.sha256(elf.read_bytes()).hexdigest(),
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}},indent=2))
    files=[p for p in (ROOT/'rtl').rglob('*.v') if not p.name.startswith('rv32_ps') and p.name!='rv32_axi_lite_slave.v']
    tb=ROOT/'tb/tb_rv32_mem_perf.v'
    if OUT!=ROOT/'build/rv32_mem_perf':
      temp=OUT/'tb_rv32_mem_perf.v';temp.write_text(tb.read_text().replace('build/rv32_mem_perf/',str(OUT.relative_to(ROOT))+'/'));tb=temp
    run('iverilog','-g2012','-I',ROOT/'rtl','-s','tb_rv32_mem_perf','-Ptb_rv32_mem_perf.CASE_COUNT='+str(len(cases)),'-o',OUT/'sim.vvp',*files,tb)
    log=run('vvp',OUT/'sim.vvp');(OUT/'simulation.log').write_text(log)
    assert 'RV32_MEM_PERF_PASS' in log,log[-4000:]
    rows=list(csv.DictReader((OUT/'counters.csv').open()))
    raw={int(r['id']):int(r['rdcycle']) for r in csv.DictReader((OUT/'raw_rdcycle.csv').open())}
    byid={int(r['id']):r for r in rows}
    baseline={c['n']:int(byid[c['id']]['elapsed']) for c in cases if c['name']=='EMPTY'}
    for c in cases:
      r=byid[c['id']];r['name']=c['name'];r['n']=c['n'];r['baseline_cycles']=baseline.get(c['n'],'NA_unrolled_no_loop')
      r['elapsed_minus_empty']=int(r['elapsed'])-baseline[c['n']] if not c['name'].startswith('U_') else 'NA_unrolled_no_loop'
      r['cycles_per_iteration']=int(r['elapsed'])/c['n']
      r['raw_rdcycle']=raw[c['id']];r['rdcycle_minus_empty']=raw[c['id']]-raw[next(x['id'] for x in cases if x['name']=='EMPTY' and x['n']==c['n'])] if not c['name'].startswith('U_') else 'NA_unrolled_no_loop'
      assert int(r['dtcm_wait'])+int(r['mmio_wait'])+int(r['scratch_wait'])==int(r['lsu_stall'])
      assert int(r['accept'])==int(r['complete'])
    for dest in ('mem_access_baseline.csv','stall_breakdown.csv'):
      with (OUT/dest).open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    print(log[-1800:]);print('MEM_ACCESS_BASELINE_PASS cases='+str(len(cases)))

if __name__=='__main__':main()
