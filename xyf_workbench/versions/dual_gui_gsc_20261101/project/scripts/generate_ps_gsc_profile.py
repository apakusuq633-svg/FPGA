"""Generate an optional offline PS profile. Never installs geometry into PL."""
from pathlib import Path
import argparse,hashlib,json,zlib
import numpy as np
from pdm12_calibration import parse_json,validate,pack,calibration_luts
p=argparse.ArgumentParser();p.add_argument('--config',type=Path,required=True)
p.add_argument('--fir',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--allow-test',action='store_true');a=p.parse_args()
doc=parse_json(a.config.read_text());v=validate(doc,a.allow_test)
blob=pack(doc,a.allow_test);_,steer=calibration_luts(doc,a.allow_test)
# Match the producer's signed Q10.4 LUT exactly, including negative floors.
tau=steer.astype(np.int32);tau[tau>=8192]-=16384
delays=((tau-tau.min(axis=0))*4096).T.astype('<u4')
assert delays.shape==(1024,12) and int(delays.max())<=int(60.9375*65536)
fir=np.array([int(t,16) for t in a.fir.read_text().split()],np.uint16).view(np.int16)
assert len(fir)==32
text='#ifndef PDM_GENERATED_GSC_PROFILE_H\n#define PDM_GENERATED_GSC_PROFILE_H\n'
text+=f'#define PDM_PROFILE_TEST {int(v["body"]["role"]=="TEST_ONLY")}\n'
text+='static const uint8_t pdm_profile_blob[416]={'+','.join(map(str,blob))+'};\n'
text+='static const int16_t pdm_profile_fir[32]={'+','.join(map(str,fir))+'};\n'
text+='static const uint32_t pdm_profile_delays[1024][12]={\n'+',\n'.join('{'+','.join(map(str,row))+'}' for row in delays)+'};\n'
text+=f'#define PDM_PROFILE_TABLE_CRC 0x{zlib.crc32(delays.tobytes()):08x}u\n#endif\n'
a.output.parent.mkdir(parents=True,exist_ok=True)
with a.output.open('x') as f:f.write(text)
a.output.with_suffix('.json').write_text(json.dumps(dict(status='GENERATED_NOT_INSTALLED',hardware='DEFERRED_HARDWARE',
 config_sha256=hashlib.sha256(a.config.read_bytes()).hexdigest(),fir_sha256=hashlib.sha256(a.fir.read_bytes()).hexdigest(),
 header_sha256=hashlib.sha256(a.output.read_bytes()).hexdigest(),calibration_version=v['body']['calibration_version'],
 role=v['body']['role'],directions=1024,channels=12),indent=2))
