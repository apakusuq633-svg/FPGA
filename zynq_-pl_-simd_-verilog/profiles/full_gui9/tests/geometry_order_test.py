"""Regression for the channel order explicitly supplied on 2026-10-26."""
from pathlib import Path
import json,math,re,hashlib
R=Path(__file__).resolve().parents[3]
c=json.loads((R/'configs/circular9_array.json').read_text(encoding='utf-8'))
order=[5,6,7,3,2,1,0,4]
assert c['ring_channel_order_ccw_from_right']==order
for angle,ch in enumerate(order):
 expected=[.03*math.cos(angle*math.pi/4),.03*math.sin(angle*math.pi/4),0]
 assert all(abs(a-b)<1e-12 for a,b in zip(c['channel_positions_m'][ch],expected)),ch
assert c['channel_positions_m'][8]==[0,0,0]
html=(R/'build/gui9_checks/compiled_gui.html').read_text(encoding='utf-8')
gui=json.loads(re.search(r'var c9ChannelPositions=(.*?);',html)[1])
assert gui==c['channel_positions_m'],'GUI geometry must match SRP/steering configuration'
h=(R/'sw/acoustic_circular9_image.h').read_text()
for name,file,length in [('acoustic_srp_lut','srp_lut.hex',36864),('acoustic_steer_lut','steer_lut.hex',9216)]:
 block=re.search(r'static const uint32_t '+name+r'\[\d+\]=\{(.*?)\};',h,re.S)[1]
 values=[int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)u',block)]
 assert len(values)==length
 assert values==[int(v,16) for v in (R/'build/circular9'/file).read_text().split()]
 old=(R/'build/gui9_before_geometry_20261026/sw/acoustic_circular9_image.h')
 if old.exists():
  oldblock=re.search(r'static const uint32_t '+name+r'\[\d+\]=\{(.*?)\};',old.read_text(),re.S)[1]
  assert block!=oldblock,'Old spatial table was not regenerated'
m=json.loads((R/'build/circular9/build_manifest.json').read_text())
assert hashlib.sha256((R/'configs/circular9_array.json').read_bytes()).hexdigest()==m['config_sha256']
assert m['geometry_confirmed'] is False and m['calibration_status']=='unmeasured'
print('GEOMETRY_ORDER_PASS channels=9 ring=5,6,7,3,2,1,0,4 center=8 srp=36864 steering=9216 GUI_MATCH; calibration not fabricated')
