"""Local-only package. No board connections. Refuse overwriting release."""
from pathlib import Path
import hashlib,json,shutil,zipfile
root=Path(__file__).resolve().parents[2];profile=Path(__file__).resolve().parent
build=root/'build/raw9_128k_pl_try3';out=root/'build/raw9_128k_release_txreclaim'
if out.exists():raise SystemExit('release exists; refuse overwrite')
assert 'RAW9_IMPLEMENTED_IO_PASS' in Path(__import__('os').environ['TEMP'],'raw9_io.log').read_text(errors='replace')
assert 'All user specified timing constraints are met.' in (build/'timing.rpt').read_text()
out.mkdir()
shutil.copy2(build/'raw9.runs/impl_1/raw9_wrapper.bit',out/'raw9.bit')
shutil.copy2(root/'build/raw9_128k_ps/raw9.elf',out/'raw9.elf')
with zipfile.ZipFile(build/'raw9.xsa') as z:(out/'ps7_init.tcl').write_bytes(z.read('ps7_init.tcl'))
for name in ['jtag_guard.tcl','check_jtag_owner.ps1']:shutil.copy2(root/'build/gui_heatmap_display_20261027'/name,out/name)
for name in ['program.tcl','program.ps1']:shutil.copy2(profile/name,out/name)
files={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.is_file()}
sources={str(f.relative_to(root)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest() for f in profile.rglob('*') if f.is_file() and '__pycache__' not in str(f)}
for rel in ['rtl/array/rv32_pdm_cic.v','rtl/transport/rv32_stream_dma.v','rtl/soc/rv32_axi_lite_slave.v','sw/pdm_stream.c','sw/pdm_stream.h','scripts/ps7_config.tcl']:
 sources[rel]=hashlib.sha256((root/rel).read_bytes()).hexdigest()
manifest=dict(status='OFFLINE_TESTS_AND_IMPLEMENTATION_PASS_BOARD_UNTESTED',physical_board_tested=False,
 channels=9,sample_rate=128000,pdm_clock_average=2048000,system_clock=40000000,decimation=16,
 frames=3840000,pcm_bytes=69120000,files=files,sources=sources,
 wns_ns=7.027,whs_ns=.015,tns_ns=0,ths_ns=0,lut=5024,ff=4281,dsp=0,bram=0,
 limitations=['UDP loss causes failed recording; no retransmission','external DATA timing not measured','physical channel independence not certified','nominal clock frequency not physical frequency measurement'])
(out/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
print(out)
