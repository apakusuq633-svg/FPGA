"""Verify retained evidence and report consistency without rerunning timed workloads."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PROD = ROOT / 'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def read(p):
    return json.loads(p.read_text(encoding='utf-8'))

def verify_hashes(base, mapping):
    for name, expected in mapping.items():
        if isinstance(expected, dict):
            expected = expected['sha256']
        assert sha(base / name) == expected, str(base / name)
    return len(mapping)

def main():
    report = {'scope': 'Read-only artifact, arithmetic and document checks; no timing rerun'}
    integrity = read(HERE / 'pl_rtl/production_integrity.json')
    assert integrity['status'] == 'PASS' and not integrity['changed_production_sources']
    report['PL_production_hashes'] = verify_hashes(PROD, integrity['before_sha256'])
    report['PL_artifacts'] = verify_hashes(HERE / 'pl_rtl', read(HERE / 'pl_rtl/artifact_hashes.json'))
    report['PL_drivers'] = verify_hashes(HERE / 'pl_rtl', read(HERE / 'pl_rtl/experiment_driver_hashes.json'))
    report['scalar_artifacts'] = verify_hashes(ROOT, read(HERE / 'circular9_scalar/artifact_hashes.json'))
    primitive = HERE / 'rtl_primitives/measured_20261028'
    report['primitive_artifacts'] = verify_hashes(primitive, read(primitive / 'retention_manifest.json')['files'])
    summary = read(HERE / 'results_summary.json')
    report['summary_evidence'] = verify_hashes(HERE, summary['evidence_sha256'])
    report['summary_rows'] = len(summary['rows'])
    pl = read(HERE / 'pl_rtl/results.json')['tests']
    scalar = read(HERE / 'circular9_scalar/rv_plain_Os/results.json')
    comparison = read(HERE / 'circular9_scalar/comparison_summary.json')
    first = pl['circular9']['score_completion_boundary'][0]
    assert first['first_sample'] == comparison['same_first_sample'] == 0
    ratio = scalar['scalar_call_cycles'] / first['raw_ready_to_scores']
    assert abs(ratio-comparison['primary_speedup']) < 1e-12
    assert comparison['PL_results_sha256'] == sha(HERE / 'pl_rtl/results.json')
    assert pl['circular9']['windows'] == 32
    for field in ('frames', 'window_latency', 'post', 'score_completion_boundary', 'stage_aggregates'):
        assert len(pl['circular9'][field]) == 32
    report['same_window_score_speedup'] = ratio
    for script, result in [
        ('ps_software/verify_results.py', 'ps_software/measured_20261028_host_quiet/results.json'),
        ('ps_software/full_modules/verify_full_results.py', 'ps_software/full_modules/measured_20261028_full_quiet/results.json'),
    ]:
        proc = subprocess.run([sys.executable, '-X', 'utf8', str(HERE/script), str(HERE/result)],
                              text=True, encoding='utf-8', capture_output=True, check=True)
        report[script] = json.loads(proc.stdout)
    part_path = ROOT / '第一部分_作品概述_重写稿_2026-10-28.md'
    part = part_path.read_text(encoding='utf-8').strip()
    full = (ROOT / '技术文档初稿_九麦声学故障定位与诊断_2026-10-28.md').read_text(encoding='utf-8')
    front = (ROOT / '.codex_work/technical_doc_20261028/front.md').read_text(encoding='utf-8')
    assert full[full.index('# 第一部分'):full.index('# 第二部分')].strip() == part
    assert front[front.index('# 第一部分'):].strip() == part
    assert len(re.findall(r'^## 1\.[1-6] ', part, re.M)) == 6
    assert not re.search(r'^```(?!mermaid)', part, re.M | re.ASCII) or part.count('```') == 2
    links = re.findall(r'\]\(([^)]+)\)', part)
    for link in links:
        if not link.startswith(('https://', 'http://', '#')):
            assert (ROOT/link).exists(), link
            assert not link.endswith('.md'), 'Competition overview must not depend on temporary repository prose'
    for text in ('11049372', '82354', '134.17', '179036', '6602', '276774', '15138',
                 '147458', '9307', '9.172325', '9.176225', '6.1932', '5.9606', '56.866', '23.696'):
        assert text in part, text
    svg = ET.parse(ROOT / '技术文档配图/第一部分_声学算子加速对比.svg')
    bars = [float(e.attrib['data-normalized-percent']) for e in svg.iter() if 'data-normalized-percent' in e.attrib]
    expected = [pl['fft']['hardware_total_cycles']/pl['fft']['scalar_cycles']*100,
                pl['fir']['simd_cycles']/pl['fir']['scalar_cycles']*100, 9307/147458*100]
    assert len(bars) == 3 and all(abs(x-y)<1e-8 for x,y in zip(bars, expected))
    report['document'] = {'first_part_synced': True, 'template_top_sections': 6,
                          'local_links_checked': len(links), 'other_markdown_document_links': 0,
                          'source_code_excerpts': 0, 'chart_bars_match_measured_cycles': True}
    report['passed'] = True
    (HERE/'bundle_verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
