"""Compare production and ILA constraints against the actual reference XDC."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('reference', type=Path)
    args = p.parse_args()
    ref = args.reference.read_text(encoding='utf-8')
    expected = {}
    for i in range(4):
        pin = re.search(r'PACKAGE_PIN\s+(\w+)\s+\[get_ports\s+\{pdm_data\['+str(i)+r'\]\}', ref)
        assert pin, f'Reference DATA{i} missing'
        assert re.search(r'IOSTANDARD LVCMOS33 \[get_ports \{pdm_data\['+str(i)+r'\]\}', ref)
        expected[i] = pin[1]
    clock = re.search(r'PACKAGE_PIN\s+(\w+)\s+\[get_ports pdm_clk\]', ref)[1]
    config = json.loads((ROOT/'configs/production_array.json').read_text())
    assert config['din_pins'] == list(expected.values())
    assert config['clock_pin'] == clock
    results = {}
    for filename in ('ps_pl_wrapper.xdc', 'pdm_ila_top.xdc'):
        text = (ROOT/'constrs'/filename).read_text(encoding='utf-8')
        rows = re.findall(r'PACKAGE_PIN (\w+)([^\n]+)\[get_ports \{pdm_din_i\[(\d+)\]\}', text)
        assert len(rows) == 4, (filename, rows)
        assert {int(i): pin for pin, props, i in rows} == expected
        assert all('IOSTANDARD LVCMOS33' in props for pin, props, i in rows)
        assert re.search(r'PACKAGE_PIN '+clock+r'[^\n]*IOSTANDARD LVCMOS33[^\n]*\[get_ports pdm_clk_o\]', text)
        results[filename] = 'PASS'
    out = ROOT/'build/pdm_ila_20261021'
    out.mkdir(parents=True, exist_ok=True)
    report = dict(reference=str(args.reference.resolve()), data_pins=expected,
                  clock_pin=clock, iostandard='LVCMOS33', checks=results,
                  physical_voltage_measured=False)
    (out/'reference_pin_audit.json').write_text(json.dumps(report, indent=2))
    print('PDM_REFERENCE_PINS_PASS', report)


if __name__ == '__main__':
    main()
