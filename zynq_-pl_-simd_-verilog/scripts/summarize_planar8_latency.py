"""Summarize measured cycles; keep profiling and experimental overlap separate."""
from pathlib import Path
import json
import re
import statistics

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/planar8_latency'


def records(text,prefix):
    return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',line))
            for line in text.splitlines() if line.startswith(prefix+' ')]


def span(values):
    return {'min':min(values),'max':max(values),'mean':statistics.mean(values),'count':len(values)}


def ms(values):
    s=span(values)
    return f"{s['min']/40000:.6f}–{s['max']/40000:.6f}"


def main():
    logs={v:(OUT/(v+'.log')).read_text() for v in ['baseline','profile','overlap']}
    runs={v:json.loads((OUT/(v+'_run.json')).read_text()) for v in logs}
    assert len({r['pcm_sha256'] for r in runs.values()})==1
    assert len({r['bench_sha256'] for r in runs.values()})==1
    assert all(r['baseline_matches_production_words'] for r in runs.values())
    for v,s in logs.items():
        assert 'PLANAR8_LATENCY_PASS' in s
        engines=records(s,'FFT_ENGINE')
        assert sum(r['inverse']==0 for r in engines)==24
        assert sum(r['inverse']==1 for r in engines)==84
    frames=records(logs['baseline'],'FRAME')
    phases=records(logs['profile'],'PHASE')
    channels=records(logs['profile'],'CHANNEL')
    overlap=records(logs['overlap'],'OVERLAP_RESULT')
    assert len(frames)==len(overlap)==3
    assert all(r['audio_drop']==0 for r in frames)
    assert all(r['interval']==524288 for r in overlap[1:]),overlap
    engine=records(logs['baseline'],'FFT_ENGINE')
    result={'scope':'40MHz cycle-accurate RTL simulation; 3 windows per variant; no board run',
            'baseline_matches_production_words':True,'sample_rate_hz':39062.5,
            'baseline_frames':frames,'profile_phases':phases,'profile_channels':channels,
            'overlap_results':overlap,'audio':records(logs['baseline'],'AUDIO'),
            'fft_engine':span([r['cycles'] for r in engine if r['inverse']==0]),
            'ifft_engine':span([r['cycles'] for r in engine if r['inverse']==1]),
            'srp_engine':span([r['cycles'] for r in records(logs['baseline'],'SRP_ENGINE')]),
            'steer_geometry':records(logs['baseline'],'STEER_GEOMETRY'),
            'rx_startup':records(logs['baseline'],'RX_FIRST')}
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['# 平面8麦延时实测（2026-10-21）','',
           '40 MHz、39062.5 Hz PCM、8路/28对、1024点窗、32×32格。以下为周期精确RTL仿真，非板卡实测。每种调度运行3个完整定位窗、24次正FFT、84次逆FFT；测试同时连续输入PCM并消费DAS/FIR音频。',
           '', '生产基线的ITCM逐字等于当前 `build/das8/fw/itcm.hex`。分段分析使用独立插桩固件；自主搬运使用原测试调度器，未替换生产固件。三个运行的输入和测试台哈希一致。定位/音频从通道对齐后的边界注入合成PCM；PDM首帧门控在独立接收器实例测量，因此这些数字不是从真实麦克风到网络输出的完整端到端实测。',
           '', '| 测量项 | 延时（ms，最小–最大） | 口径 |','|---|---:|---|']
    def row(name,values,note):lines.append(f'| {name} | {ms(values)} | {note} |')
    row('生产：纯定位计算',[r['compute'] for r in frames],'固件 rdcycle，含搬运、预处理和结果处理')
    row('生产：采集等待＋计算',[r['total'] for r in frames],'固件一次主循环，未包含PDM冷启动')
    row('生产：连续结果间隔',[r['interval'] for r in frames[1:]],'外部观测结果发布，两次间隔')
    for phase,name in [(1,'插桩：等1024点窗'),(2,'插桩：四对读取/统计＋八路预处理/FFT'),(3,'插桩：28对GCC-PHAT/IFFT及相关环写入'),(4,'插桩：SRP发起到完成'),(5,'插桩：1024分数读取与找峰'),(6,'插桩：可信度/跟踪处理')]:
        row(name,[r['cycles'] for r in phases if r['id']==phase],'独立插桩，含边界写入开销')
    row('硬件正FFT内核',[r['cycles'] for r in engine if r['inverse']==0],'单次RUN到done，不含装入和取回')
    row('硬件逆FFT内核',[r['cycles'] for r in engine if r['inverse']==1],'单次RUN到done，不含装入和取回')
    row('SRP硬件扫描',[r['cycles'] for r in records(logs['baseline'],'SRP_ENGINE')],'28对×1024格 busy持续时间')
    row('转向几何核',[r['cycles'] for r in records(logs['baseline'],'STEER_GEOMETRY')],'独立8路LUT查表/补偿服务时间，不含跟踪确认和渐变')
    row('DAS到FIR请求',[r['input_to_emit'] for r in result['audio']],'未锁定、线性模式，前4样点')
    row('FIR计算服务',[r['fir_service'] for r in result['audio']],'32抽头调度、测试用单位冲激系数')
    row('PCM输入到音频FIFO',[r['input_to_fifo'] for r in result['audio']],'含DAS与FIR调度，非滤波群延迟')
    row('自主搬运实验：纯计算',[r['compute'] for r in overlap],'窗口就绪到计算完成')
    row('自主搬运实验：末点就绪到发布',[r['latency'] for r in overlap],'固定发布相位393216周期')
    row('自主搬运实验：发布间隔',[r['interval'] for r in overlap[1:]],'硬件loc_done，不是软件轮询间隔')
    lines+=['','## 数据窗口与群延迟','',
            '- 单个PCM采样周期：25.6 μs；512点时长：13.1072 ms；1024点时长：26.2144 ms。首点到第1024点的时间跨度为26.1888 ms。',
            '- 三阶64倍CIC的理论群延迟为94.5个PDM位周期，即37.8 μs；32抽头对称输出FIR的理论群延迟为15.5个PCM样点，即396.8 μs。它们不是上表的计算服务时间，也不能用计算耗时替代。',
            f"- 接收器从使能计数到首个有效PCM：{result['rx_startup'][0]['since_reset']/40000:.6f} ms，包含默认50 ms启动门控、4帧CIC清除及采样相位对齐；数字输入为固定码型，未测真实麦克风启动。",'',
            '## 连续性与限制','',
            f"- 生产窗起点：{[r['first_sample'] for r in frames]}；相邻起点推进{[b['first_sample']-a['first_sample'] for a,b in zip(frames,frames[1:])]}点，未实现512点Hop连续定位。固件重新使能采集，采集DROP寄存器为0不能证明定位没有窗口空档。",
            f"- 实验自主搬运窗起点：{[r['first_sample'] for r in overlap]}，保持512点Hop；三窗raw/window/audio drop均为0。只是短程实验，不是长跑或生产验收。",
            f"- 生产测试的定位拒绝原因码为{[r['reason'] for r in frames]}；结果发布延时不等于首次可信方向锁定延时。未测真实声源角度、声学精度、PS网络传输和UI刷新。",
            '- 转向几何核使用实际8麦LUT独立触发；软件可信度确认、迟滞和音频平滑的完整转向响应未由该项覆盖。自主搬运调度器仍是测试固件，本轮未做两条定位路径逐位声学数值等价验证。',
            '', '## 复现与原始证据','',
            '运行 `python -X utf8 scripts/measure_planar8_latency.py`，随后 `python -X utf8 scripts/summarize_planar8_latency.py`。',
            '证据：`build/planar8_latency/{baseline,profile,overlap}.log`、各自 `_run.json`、`results.json` 和 `manifest.json`。脚本不修改生产固件或执行板卡下载。','']
    (ROOT/'docs/planar8_latency_20261021.md').write_text('\n'.join(lines),encoding='utf-8')
    print(json.dumps({'production_compute_ms':ms([r['compute'] for r in frames]),
                      'production_update_ms':ms([r['interval'] for r in frames[1:]]),
                      'overlap_compute_ms':ms([r['compute'] for r in overlap]),
                      'overlap_publish_ms':ms([r['latency'] for r in overlap])},indent=2))


if __name__=='__main__':main()
