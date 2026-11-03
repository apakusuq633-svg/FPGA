"""Conditional split-budget analysis; all board numbers are assumptions."""
from pathlib import Path
import json,re
R=Path(__file__).resolve().parents[1];O=R/'build/pdm_shared_remediation/timing';O.mkdir(parents=True,exist_ok=True)
c=json.loads((R/'configs/pdm_interface_timing.json').read_text());rows=[]
assert c['system_period_ns']==25 and c['pdm_period_cycles']==16
assert c['fpga_input_max_ns']==5 and c['clock_output_max_ns']==10
for filename in ['rv32_pdm_clkgen.v','rv32_pdm_array_rx.v']:
    source=(R/'rtl/array'/filename).read_text()
    for parameter,key in [('HOLD_TICK','hold_tick'),('CONSUME_TICK','consume_tick')]:
        assert int(re.search(r'parameter integer '+parameter+r'\s*=\s*(\d+)',source)[1])==c[key]
source=(R/'rtl/array/rv32_pdm_array_rx.v').read_text()
for parameter,key in [('MIC_STARTUP_CYCLES','mic_startup_cycles'),('CIC_SETTLE_FRAMES','cic_settle_frames')]:
    assert int(re.search(r'parameter integer '+parameter+r'\s*=\s*(\d+)',source)[1])==c[key]
for name,tick,drive in [('A',c['hold_tick'],0),('B',c['consume_tick'],200)]:
    capture=(tick+1)*c['system_period_ns'];relative=capture-drive
    setup=relative-c['clock_output_max_ns']-max(c['pcb_clock_ns'])-c['mic_data_valid_max_ns']-max(c['pcb_data_ns'])-c['fpga_input_max_ns']-c['ff_setup_budget_ns']-c['relative_clock_skew_jitter_budget_ns']
    # No hold credit for retaining the previous electrical level after high-Z.
    hold=200+min(c['pcb_clock_ns'])+min(c['mic_high_z_ns'])+min(c['pcb_data_ns'])-relative-c['ff_hold_budget_ns']-c['relative_clock_skew_jitter_budget_ns']
    rows.append(dict(phase=name,capture_ns=capture,relative_drive_ns=relative,setup_margin_ns=setup,hold_margin_ns=hold))
    assert relative==125 and setup>=0 and hold>=0
xdc=(R/'constrs/ps_pl_wrapper.xdc').read_text()
assert 'set_false_path -from [get_ports {pdm_din_i[*]}]' not in xdc
assert 'set_max_delay -datapath_only 5.000 -from [get_ports {pdm_din_i[*]}]' in xdc
assert 'set_max_delay -datapath_only 10.000 -from [all_registers -clock_pins] -to [get_ports pdm_clk_o]' in xdc
assert c['mic_drive_ns'][0]>max(c['mic_high_z_ns'])
# Counterexample: exceeding the assumed round-trip envelope must fail.
assert rows[0]['setup_margin_ns']-1<0
result={'status':'PASS_CONDITIONAL_BUDGET','hardware':'UNVERIFIED_HARDWARE','phases':rows,'negative_extra_1ns':'FAIL_AS_EXPECTED','config':c}
(O/'budget.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
