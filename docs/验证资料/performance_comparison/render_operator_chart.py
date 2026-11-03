"""Generate the standalone SVG from validated cycle results, without hand-entered bar lengths."""
from pathlib import Path
import html
import json

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

def main():
    pl = json.loads((HERE / 'pl_rtl/results.json').read_text(encoding='utf-8'))['tests']
    srp = json.loads((HERE / 'rtl_primitives/measured_20261028/srp/results.json').read_text(encoding='utf-8'))
    scans = {x['fast_scan']: x['start_to_done_cycles'][0] for x in srp['cases'] if x['r_len'] == 64 and x['idx_w'] == 6}
    cases = [
        ('1024点实FFT', 'PL标量', '声学扩展', pl['fft']['scalar_cycles'], pl['fft']['hardware_total_cycles'], '完整调用，含装载／运行／取回'),
        ('512点、32抽头FIR', 'PL标量', 'SIMD', pl['fir']['scalar_cycles'], pl['fir']['simd_cycles'], '同输入／同系数，原函数执行'),
        ('36对×1024格SRP', '串行RTL', '四麦对并行', scans[0], scans[4], '64点相关环，START至DONE'),
    ]
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<svg xmlns="http://www.w3.org/2000/svg" width="1100" height="820" viewBox="0 0 1100 820" role="img" aria-labelledby="title description">',
             '<title id="title">本次RTL声学算子加速对比</title>',
             '<desc id="description">2026年10月28日实际运行，各组独立基线；FFT含数据装载取回，SRP不含装载取回。毫秒按40 MHz换算，不是实板数据。</desc>',
             '<style>text{font-family:"Microsoft YaHei","Noto Sans CJK SC",sans-serif;fill:#172b4d;} .small{font-size:14px;fill:#526479;} .label{font-size:16px;}</style>',
             '<rect width="1100" height="820" fill="#fff"/>',
             '<text x="42" y="47" font-size="28" font-weight="700">声学算子与定位扫描阶段加速对比</text>',
             '<text class="label" x="42" y="79">本次RTL实测 · 2026-10-28 · 相同输入逐项核对 · 各组独立归一化</text>',
             '<rect x="42" y="103" width="20" height="12" rx="3" fill="#7694b7"/><text class="small" x="72" y="114">基线实现</text>',
             '<rect x="176" y="103" width="20" height="12" rx="3" fill="#df8a39"/><text class="small" x="206" y="114">加速实现</text>']
    for index, (name, base_label, fast_label, base, fast, scope) in enumerate(cases):
        y = 139 + index * 180
        pct = 100 * fast/base
        def text(x, yy, content, size=16, anchor='start', color='#172b4d', weight='400'):
            return f'<text x="{x}" y="{yy}" font-size="{size}" text-anchor="{anchor}" style="fill:{color}" font-weight="{weight}">{html.escape(content)}</text>'
        lines.extend([
            f'<rect x="30" y="{y}" width="1040" height="160" rx="12" fill="#f8fafc" stroke="#dbe3ec"/>',
            text(48,y+32,name,21,weight='700'), text(320,y+32,f'{base} → {fast} 拍',14),
            text(840,y+32,scope,14,'end','#526479'), text(975,y+32,'加速比',14,'middle'),
            text(48,y+72,base_label),
            f'<rect x="235" y="{y+51}" width="650" height="29" rx="5" fill="#7694b7"/>',
            text(870,y+71,'100%',14,'end','#fff'), text(1060,y+72,f'{base/40000:.6f} ms',16,'end'),
            text(48,y+119,fast_label),
            f'<rect x="235" y="{y+98}" width="650" height="29" rx="5" fill="#e8edf3"/>',
            f'<rect x="235" y="{y+98}" width="{650*fast/base:.9f}" height="29" rx="5" fill="#df8a39" data-normalized-percent="{pct:.9f}"/>',
            text(300,y+119,f'{fast/40000:.6f} ms'), text(470,y+119,f'约{pct:.4f}%',14),
            text(975,y+121,f'{base/fast:.2f}×',28,'middle','#b45309','700'),
        ])
    lines.extend([
        '<text class="small" x="42" y="687">横条以每组基线归一为100%；加速比＝基线周期／加速周期。不同组的横条不表示相同绝对时间。</text>',
        '<rect x="30" y="710" width="1040" height="89" rx="10" fill="#fff8ed" stroke="#ecd9bc"/>',
        '<text x="48" y="736" font-size="16" font-weight="700">局部算子与扫描对照；完整九麦评分阶段另列，不代替三架构实板全程</text>',
        '<text class="small" x="48" y="760">FFT/FIR：实际RV32程序周期，TB为40 MHz；FIR逐样结果与独立整数参考一致。</text>',
        '<text class="small" x="48" y="784">SRP：同输入串行与并行RTL，TB周期10 ns；图中ms按40 MHz解析换算，不含装载／读回。</text>',
        '</svg>',
    ])
    target = ROOT / '技术文档配图/第一部分_声学算子加速对比.svg'
    target.write_text('\n'.join(lines)+'\n', encoding='utf-8')
    print(target)

if __name__ == '__main__':
    main()
