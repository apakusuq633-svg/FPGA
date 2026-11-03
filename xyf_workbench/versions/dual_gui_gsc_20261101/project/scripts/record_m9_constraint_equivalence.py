"""Bind a comment-only XDC edit to the actual generated twelve-channel profile."""
from pathlib import Path
import argparse,hashlib,json,re
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
template=R/'constrs/ps_pl_wrapper.xdc'
used=R/'build/zynq12_integrated_plan/m9_merge_impl_20261016_project/generated_constraints/ps_pl_wrapper.xdc'
def commands(text,select=False):
 result=[]
 for line in text.splitlines():
  line=line.strip()
  if not line or line.startswith('#'):continue
  match=re.search(r'pdm_din_i\[(\d+)\]',line)
  if select and match and int(match[1])>=6:continue
  result.append(line)
 return result
old=commands(used.read_text());new=commands(template.read_text(),True)
assert old==new,'Active XDC commands changed: implementation must be rebuilt'
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
proof=dict(status='EXACT_ACTIVE_PROFILE_COMMANDS_EQUAL',scope='12ch / 6 DATA only',
 template='constrs/ps_pl_wrapper.xdc',current_template_sha256=sha(template),
 generated_profile=str(used.relative_to(R)),generated_profile_sha256=sha(used),
 commands_sha256=hashlib.sha256(('\n'.join(old)+'\n').encode()).hexdigest(),commands=old,
 note='Source manifest retains the original input hash. This proof does not replace it.')
with a.output.open('x')as f:json.dump(proof,f,indent=2)
print(proof['status'])
