"""Package only matched local nine-mic artifacts. Never accesses a board."""
from pathlib import Path
import argparse,hashlib,json,re,shutil,zipfile
P=Path(__file__).resolve().parent
R=P.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--workspace',type=Path,required=True);a=p.parse_args()
 hw=R/'build/gui9_hw';proof=json.loads((hw/'routed_source_proof.json').read_text())
 assert proof['status']=='ROUTED_SOURCE_AND_XSA_MATCHED'
 for name,digest in proof['source_sha256'].items():assert sha(R/name)==digest,('Hardware source drift',name)
 xsa=hw/'das_fir.xsa';assert sha(xsa)==proof['xsa_sha256']
 bit=Path(proof['project'])/'rv32_zynq.runs/impl_1/ps_pl_wrapper.bit';assert sha(bit)==proof['bit_sha256']
 with zipfile.ZipFile(xsa) as z:
  bits=[name for name in z.namelist() if name.endswith('.bit')];assert len(bits)==1 and hashlib.sha256(z.read(bits[0])).hexdigest()==sha(bit)
 # The hardware imported into the isolated BSP must be the exact new XSA.
 imports=list((a.workspace/'circular9').rglob('*.xsa'));assert any(sha(path)==sha(xsa) for path in imports),'No matching BSP hardware import'
 ps=R/'build/ui_pipeline_circular9';app=json.loads((ps/'build_manifest.json').read_text(encoding='utf-8-sig'))
 assert sha(ps/'ui.elf')==app['elf_sha256']
 for name,digest in app['source_sha256'].items():assert sha(R/name)==digest,('PS source drift',name)
 tests=json.loads((R/'build/gui9_checks/results.json').read_text());assert all(t['status']=='PASS' for t in tests['results'])
 timing=(hw/'timing_zynq.rpt').read_text()
 summary=re.search(r'WNS\(ns\).*?\n\s*-+.*?\n\s*([\d.-]+)\s+([\d.-]+)\s+(\d+)\s+(\d+)\s+([\d.-]+)\s+([\d.-]+)',timing,re.S)
 assert summary, 'Timing summary missing'
 wns,tns,fail,total,whs,ths=summary.groups();assert float(wns)>=0 and float(whs)>=0 and int(fail)==0 and float(tns)==0 and float(ths)==0
 init=a.workspace/'circular9/hw/ps7_init.tcl';assert init.exists()
 out=R/'build/full_gui9_release';out.mkdir(parents=True,exist_ok=True)
 sources={'pl.bit':bit,'ps_ui.elf':ps/'ui.elf','ps7_init.tcl':init,'hardware.xsa':xsa,
 'timing.rpt':hw/'timing_zynq.rpt','utilization.rpt':hw/'util_zynq.rpt','io.rpt':hw/'io_zynq.rpt',
 'routed_source_proof.json':hw/'routed_source_proof.json','ps_build_manifest.json':ps/'build_manifest.json',
 'gui_tests.json':R/'build/gui9_checks/results.json','array.json':R/'configs/circular9_array.json',
 'firmware_manifest.json':R/'build/circular9/build_manifest.json','program.ps1':P/'program.ps1','program.tcl':P/'program.tcl',
 'README.md':P/'README.md','jtag_guard.tcl':R/'scripts/jtag_guard.tcl','check_jtag_owner.ps1':R/'scripts/check_jtag_owner.ps1'}
 for name,src in sources.items():shutil.copy2(src,out/name)
 files={name:{'sha256':sha(out/name),'bytes':(out/name).stat().st_size} for name in sources}
 protected={name:digest for name,digest in proof['source_sha256'].items() if name.startswith(('rtl/','constrs/'))}
 manifest=dict(status='BUILT_TIMING_AND_GUI_CHECKS_PASS_BOARD_UNTESTED',channels=9,pdm_clock_hz=2500000,pcm_sample_rate_hz=156250,
  diagnostic_sample_rate_hz=39062.5,scan_model='far_field_direction',physical_board_tested=False,ps_runtime_measured=False,
  wns_ns=float(wns),tns_ns=float(tns),whs_ns=float(whs),ths_ns=float(ths),files=files,
  protected_pl_source_sha256=protected,gui_source_sha256={p.relative_to(R).as_posix():sha(p) for p in [R/'sw/circular9_health.h',R/'sw/ps_circular9_gui.h',R/'sw/circular9_full_gui.js',P/'page_template.html',P/'make_ui.py']})
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print('FULL_GUI9_RELEASE_PASS',out,'WNS',wns,'WHS',whs,'BIT_SHA256',sha(bit),'ELF_SHA256',sha(ps/'ui.elf'))
if __name__=='__main__':main()
