"""Original SRP numerical/throughput regressions against isolated banked mapping."""
from pathlib import Path
import argparse,json,subprocess
R=Path(__file__).resolve().parents[1];p=argparse.ArgumentParser();p.add_argument('--overlay',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--localizer',action='store_true',help='Original four-window standalone numerical TB');a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
source=a.overlay.resolve()/'rv32_srp_scan.v';rows=[]
if a.localizer:
 text=(R/'tb/tb_overlap_localizer.v').read_text()
 text=text.replace(' initial begin\n',' reg[8:0] bank_lut_init[0:67583];integer bank_load;\n initial begin\n',1)
 old='$readmemh("build/strict_overlap/vectors/lut.hex",srp.lut_mem);'
 assert text.count(old)==1
 text=text.replace(old,'''$readmemh("build/strict_overlap/vectors/lut.hex",bank_lut_init);
  for(bank_load=0;bank_load<67584;bank_load=bank_load+1)begin
    if(bank_load<32768)srp.g_banked.lut_lo[bank_load]=bank_lut_init[bank_load];
    else if(bank_load<65536)srp.g_banked.lut_mid[bank_load-32768]=bank_lut_init[bank_load];
    else srp.g_banked.lut_tail[bank_load-65536]=bank_lut_init[bank_load];
  end''')
 tb=O/'tb_overlap_localizer.v';tb.write_text(text)
 files=[a.overlay.resolve()/'rv32_overlap_localizer.v',source,*[R/'rtl/acoustic'/f for f in ['rv32_fft_bfly.v','rv32_fft_addr.v','rv32_acoustic_ext.v']],tb]
 commands=[['iverilog','-g2012','-Irtl','-s','tb_overlap_localizer','-o',str(O/'sim'),*map(str,files)],['vvp',str(O/'sim')]]
 for i,cmd in enumerate(commands):
  q=subprocess.run(cmd,cwd=R,capture_output=True,text=True,timeout=300);(O/f'run_{i}.log').write_text(q.stdout+q.stderr);assert q.returncode==0,(q.stdout[-2000:],q.stderr)
 assert 'OVERLAP_LOCALIZER_NUMERIC_PASS windows=4' in q.stdout and 'STRICT_REALTIME_MODULE_PASS' in q.stdout
 (O/'results.json').write_text(json.dumps(dict(status='PASS',commands=commands,summary=q.stdout),indent=2));print('PDM_RAM_ORIGINAL_LOCALIZER_NUMERIC_PASS windows=4');raise SystemExit(0)
for cmd in [['python3','scripts/golden/gen_srp_vectors.py'],['python3','scripts/golden/gen_srp_vectors.py','--pairs','4','--grid-w','16','--out-prefix','srp4x256']]:
 q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);assert q.returncode==0,q.stderr
for top in ['tb_srp_scan','tb_srp_regs','tb_srp_throughput']:
 text=(R/'tb'/f'{top}.v').read_text()
 # Original generic numerical TBs use direct memory inspection (28/4 pairs).
 text=text.replace('.lut_mem','.g_original.lut_mem')
 tb=O/(top+'.v');tb.write_text(text)
 commands=[['iverilog','-g2012','-s',top,'-o',str(O/top),str(source),str(R/'rtl/srp/rv32_srp_regs.v'),str(tb)],['vvp',str(O/top)]]
 for i,cmd in enumerate(commands):
  q=subprocess.run(cmd,cwd=R,capture_output=True,text=True,timeout=240);(O/f'{top}_{i}.log').write_text(q.stdout+q.stderr);assert q.returncode==0,(top,q.stderr,q.stdout[-2500:])
 assert 'PASS' in q.stdout and 'FAIL:' not in q.stdout and 'FATAL' not in q.stdout
 rows.append(dict(top=top,status='PASS',commands=commands,summary=q.stdout[-1200:]))
(O/'results.json').write_text(json.dumps(rows,indent=2));print('PDM_RAM_ORIGINAL_NUMERIC_PASS cases=3')
