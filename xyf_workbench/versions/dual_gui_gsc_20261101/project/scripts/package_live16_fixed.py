"""Validate stage-1 artifacts; this does not certify a physical array."""
from pathlib import Path
import hashlib,json,re,zipfile
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
names=['build/ui_pipeline_live16/ui.elf','build/das16/fw/fw_live16_fixed.elf',
 'build/das16/das_fir.xsa','build/das16/das_fir_routed.dcp',
 'build/das16_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',
 'build/das16_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl',
 'build/das16/timing_zynq.rpt','build/das16/util_zynq.rpt','build/das16/io_zynq.rpt']
for name in names:
 if not (ROOT/name).is_file():raise SystemExit('Missing artifact: '+name)
log=(ROOT/'build/das16_console.log').read_bytes()
flow=log.decode('utf-16' if log.startswith(b'\xff\xfe') else 'utf-8',errors='replace')
if 'FLOW_PASS:' not in flow:
 raise SystemExit('16-channel implementation did not pass')
rpt=(ROOT/names[6]).read_text()
m=re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s',rpt,re.M)
if not m or float(m[1])<0 or float(m[5])<0 or int(m[3]) or int(m[7]):raise SystemExit('Timing failed')
with zipfile.ZipFile(ROOT/names[2]) as z:
 bits=[p for p in z.namelist() if p.endswith('.bit')]
 assert len(bits)==1 and hashlib.sha256(z.read(bits[0])).hexdigest()==sha(ROOT/names[4])
wrapper=(ROOT/'build/das16_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_rv32_ps_0/synth/ps_pl_u_rv32_ps_0.v').read_text()
for binding in ('.DAS_ACTIVE_CHANNELS(16)','.PDM_CHANNELS(16)','.PDM_MICS_PER_LINE(2)'):
 assert binding in wrapper,binding
io=(ROOT/names[8]).read_text()
config=json.loads((ROOT/'configs/live16_fixed.json').read_text())
for ch,pin in enumerate(config['din_pins']):
 assert re.search(r'\|\s*'+pin+r'\s*\|\s*pdm_din_i\['+str(ch)+r'\]\s*\|',io),pin
sources=['ps_ui.c','ps_ui_page.h','ps_mic_levels.h','ps_pl_live.h','ps_das_fifo.h',
 'ps_das_audio.h','ps_das_plots.h','ps_das_report.h','ps_features.h','ps_http_tx.h','acoustic_live16_fixed_image.h']
assert all((ROOT/'sw'/p).stat().st_mtime_ns<=(ROOT/names[0]).stat().st_mtime_ns for p in sources)
checkpoint=(ROOT/names[3]).stat().st_mtime_ns
assert all(p.stat().st_mtime_ns<=checkpoint for p in (ROOT/'rtl').rglob('*.v'))
image=(ROOT/'sw/acoustic_live16_fixed_image.h').read_text()
for memory in ('ITCM','DTCM'):
 expected=re.search('ACOUSTIC_'+memory+'_SHA256 "([0-9a-f]{64})"',image)[1]
 assert expected==sha(ROOT/f'build/das16/fw/{memory.lower()}.hex')
manifest={'stage':'16 microphones / fixed broadside DAS / localization disabled',
 'board_tested':False,'config':config,'setup_ns':float(m[1]),'hold_ns':float(m[5]),
 'artifacts':[{'path':p,'sha256':sha(ROOT/p)} for p in names],
 'ui_sources':[{'path':'sw/'+p,'sha256':sha(ROOT/'sw'/p)} for p in sources]}
(ROOT/'build/das16/live16_fixed_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('LIVE16_FIXED_PACKAGE_PASS')
