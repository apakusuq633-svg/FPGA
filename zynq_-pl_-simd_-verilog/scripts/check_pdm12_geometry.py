from pathlib import Path
import copy,json
from pdm12_geometry import PAIRS,validate,validate_query
root=Path(__file__).resolve().parents[1]
cfg=json.loads((root/'configs/production_array.json').read_text())
assert len(PAIRS)==66 and len(set(PAIRS))==66
assert not validate(cfg)['geometry_enabled']
for lag in range(-16,16):assert validate_query(lag,0)==lag%32
for lag in range(-16,15):validate_query(lag,15)
for lag,frac in [(-17,0),(16,0),(15,1)]:
    try:validate_query(lag,frac)
    except AssertionError:pass
    else:raise AssertionError('unsafe query accepted')
test=copy.deepcopy(cfg);test.update(role='TEST_GEOMETRY',physical_mapping_confirmed=True,
    channel_to_mic=list(range(12)),mic_xyz=[[i*.001,(i%3)*.001,(i%4)*.001] for i in range(12)])
assert validate(test)['ring_geometry_validated'] and not validate(test)['geometry_enabled']
test['mic_xyz'][11]=[1,0,0]
assert not validate(test)['ring_geometry_validated']
print('PDM12_GEOMETRY_GATE_PASS pairs=66 production_geometry=0 boundary_negatives=3 test_geometry_isolated=1')
