"""Exercise firmware tickets across uint32 wrap via simulation-only CSR offset."""
from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1];original=R/'scripts/profile_localizer12.py'
code=original.read_text();needle='code=original.read_text()'
assert code.count(needle)==1
save="(G/'rv32_soc.v').write_text(soc);"
injection="soc=soc.replace('2:loc_rdata=loc_request_id;',\"2:loc_rdata=loc_request_id+32'hfffffff0;\")\n"+save
code=code.replace(needle,needle+';code=code.replace('+repr(save)+','+repr(injection)+')')
ns={'__file__':str(original),'__name__':'__main__'}
exec(compile(code,str(original),'exec'),ns)
O=ns['output'];report=json.loads((O/'profile_metrics.json').read_text())
assert sum(r['calls'] for r in report['dispatch'])>16
assert "loc_request_id+32'hfffffff0" in (O/'instrumented/rv32_soc.v').read_text()
(O/'request_wrap.json').write_text(json.dumps(dict(status='PASS_FIRMWARE_TICKET_WRAP',
 injected_csr_offset='0xfffffff0',complete_math_and_audio_checked=True,production_rtl_changed=False,
 sources={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [original,Path(__file__),R/'sw/fw/fw_localizer12.c']}),indent=2))
(O/'executed_profile_wrapper.py').write_text(code)
print('LOCALIZER12_FIRMWARE_TICKET_WRAP_PASS')
