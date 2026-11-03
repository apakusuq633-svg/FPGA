"""Create isolated firmware candidates; never edits the production firmware."""
from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1];O=R/'build/m10_20261016'
original=(R/'sw/fw/fw_localizer12.c').read_text()
assert original==(O/'before/fw_localizer12.c').read_text()
old='        uint32_t id=LOC(2),kind=(LOC(1)>>1)&7u;\n        if(id!=LOC(2))continue;'
new='''        uint32_t id=LOC(2),kind=0;
        if(id!=ticket) {
            kind=(LOC(1)>>1)&7u;
            if(id!=LOC(2))continue;
        }'''
assert original.count(old)==1
id_first=original.replace(old,new)
no_table=original.replace('int main(void) {','__attribute__((optimize("no-jump-tables")))\nint main(void) {')
combined=id_first.replace('int main(void) {','__attribute__((optimize("no-jump-tables")))\nint main(void) {')
(O/'candidates').mkdir(exist_ok=False)
values={'baseline':original,'id_first':id_first,'no_jump_table':no_table,'combined':combined}
for name,value in values.items():(O/'candidates'/f'{name}.c').write_text(value)
(O/'candidate_inputs.json').write_text(json.dumps({name:hashlib.sha256(value.encode()).hexdigest() for name,value in values.items()},indent=2))
print('M10_CANDIDATES_PREPARED production_source_unchanged=1')
