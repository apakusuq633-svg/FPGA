"""Attribute routed physical BRAM primitives; proposals are not implemented savings."""
from pathlib import Path
from collections import Counter,defaultdict
import csv,json,re
R=Path(__file__).resolve().parents[1];O=R/'build/pdm_convergence/resources';O.mkdir(parents=True,exist_ok=True)
cells=list(csv.DictReader((R/'build/pdm_convergence/probe/bram_cells.csv').open()))
groups=defaultdict(Counter);memories=defaultdict(Counter)
for row in cells:
    name=row['name'];tail=name.split('/u_soc/')[-1];owner=tail.split('/')[0]
    parent,leaf=tail.rsplit('/',1);memory=parent+'/'+re.split(r'_reg(?:_|$)',leaf)[0]
    groups[owner][row['primitive']]+=1;memories[memory][row['primitive']]+=1
def records(counter):
    result=[]
    for name,counts in counter.items():
        tiles=counts['RAMB36E1']+counts['RAMB18E1']/2
        result.append({'name':name,'RAMB36':counts['RAMB36E1'],'RAMB18':counts['RAMB18E1'],'BRAM36_equiv':tiles})
    return sorted(result,key=lambda x:-x['BRAM36_equiv'])
owners=records(groups);mem=records(memories)
assert sum(x['RAMB36'] for x in owners)==98
assert sum(x['RAMB18'] for x in owners)==27
assert sum(x['BRAM36_equiv'] for x in owners)==111.5
report=(R/'build/pdm_convergence/probe/ram_utilization.rpt').read_text()
logical=[]
for line in report.splitlines():
    fields=[f.strip() for f in line.strip().strip('|').split('|')]
    if len(fields)>=3 and fields[0].startswith('ps_pl_') and fields[1].isdigit() and fields[2].startswith('RAM_'):
        logical.append({'name':fields[0],'declared_bits':int(fields[1]),'memory_type':fields[2]})
result={'scope':'CURRENT_FULL_SOC_ROUTED_CHECKPOINT','BRAM36_equiv':111.5,'available':140,'utilization_percent':111.5/140*100,'remaining_tiles':28.5,'owners':owners,'memories':mem,'logical_memories':logical}
(O/'attribution.json').write_text(json.dumps(result,indent=2))
for item in owners:print(item)
print('MEMORY_DETAIL')
for item in mem:print(item)
print('PDM_RESOURCE_ATTRIBUTION_PASS')
