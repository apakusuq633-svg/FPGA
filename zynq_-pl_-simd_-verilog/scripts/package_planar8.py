"""Record matching planar8 configuration evidence; this is not a bitstream release."""
import hashlib
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def main():
    base=ROOT/'build/das8'
    config=json.loads((ROOT/'configs/production_array.json').read_text())
    assert config['channels']==8 and config['din_pins']==['T14','Y17','T15','W16']
    manifest=json.loads((base/'build_manifest.json').read_text())
    for name,digest in manifest['sources'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest, 'Rebuild firmware: '+name
    header=(ROOT/'sw/acoustic_planar8_image.h').read_text()
    for memory in ('ITCM','DTCM'):
        expected=re.search('ACOUSTIC_'+memory+'_SHA256 "([0-9a-f]{64})"',header)[1]
        assert hashlib.sha256((base/'fw'/(memory.lower()+'.hex')).read_bytes()).hexdigest()==expected
    for name,count in [('srp',28672),('steer',8192)]:
        assert len((base/(name+'_lut.hex')).read_text().splitlines())==count
    evidence={'configuration':config,'firmware_manifest':manifest,
              'implementation_verified':False,'board_tested':False,
              'note':'Rebuild and verify matching bit/XSA/ELF before board acceptance'}
    (base/'configuration_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print('PLANAR8_EVIDENCE_PASS implementation_verified=0 board_tested=0')
if __name__=='__main__':main()
