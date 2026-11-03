"""Record the optimized production measurements without overwriting the old baseline."""
from pathlib import Path
import hashlib
import json
import re
import statistics

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/planar8_optimized'


def rows(text,prefix):
    return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',line))
            for line in text.splitlines() if line.startswith(prefix+' ')]


def main():
    validation=json.loads((OUT/'production_validation.json').read_text())
    assert all(v['passed'] for v in validation['tests'].values())
    assert validation['firmware_sha256']==hashlib.sha256((ROOT/'build/das8/fw/itcm.hex').read_bytes()).hexdigest()
    assert validation['model_manifest_sha256']==hashlib.sha256((OUT/'manifest.json').read_bytes()).hexdigest()
    text=(OUT/'continuous32.log').read_text()
    f=rows(text,'FRAME');post=rows(text,'PRODUCTION_POST')
    old=rows((ROOT/'build/planar8_latency/baseline.log').read_text(),'FRAME')
    assert len(f)==32 and all(r['first_sample']==i*512 for i,r in enumerate(f))
    ready=[r['tick']-r['first_input']-(r['first_sample']+1023)*1024 for r in f]
    def bounds(values):return {'min_ms':min(values)/40000,'max_ms':max(values)/40000,'mean_ms':statistics.mean(values)/40000}
    result={'clock_hz':40000000,'windows':32,'board_tested':False,
            'compute_including_post':bounds([r['compute'] for r in f]),
            'hardware_compute':bounds([r['compute'] for r in post]),
            'cpu_post':bounds([r['post'] for r in post]),
            'last_pcm_to_publication':bounds(ready),
            'publication_interval':bounds([r['interval'] for r in f[1:]]),
            'old_compute':bounds([r['compute'] for r in old]),
            'old_interval':bounds([r['interval'] for r in old[1:]]),
            'custom_instructions_final':post[-1],'frames':f,'validation':validation}
    (OUT/'production_results.json').write_text(json.dumps(result,indent=2)+'\n')
    def fmt(key):
        v=result[key];return f"{v['min_ms']:.6f}–{v['max_ms']:.6f}"
    report=f'''# 平面8麦生产调度降延时报告（2026-10-21）

生产构建已从 `fw_live16.c` 的CPU逐项搬运切换到 `sw/fw/fw_planar8.c`：CPU仍通过自定义指令发起FFT、互谱、PHAT、IFFT和SRP，状态机负责缓存读写与数据搬运。40 MHz、39062.5 Hz PCM、8通道/28对、1024点窗、512点Hop、1024格。

| 测量项 | 优化前（ms） | 当前生产（ms） |
|---|---:|---:|
| 定位计算，含结果后处理 | {fmt('old_compute')} | {fmt('compute_including_post')} |
| 连续结果发布间隔 | {fmt('old_interval')} | {fmt('publication_interval')} |
| 窗口末点到软件结果发布 | 约36.15 | {fmt('last_pcm_to_publication')} |
| 搬运/预处理/FFT/GCC/PHAT/IFFT/SRP硬件调度子链 | — | {fmt('hardware_compute')} |
| CPU统计读取、评分读取、可信度和跟踪等后处理 | — | {fmt('cpu_post')} |

当前生产统计来自连续32窗RTL仿真，前窗起点0、512、1024，末窗起点15872；保持512点Hop。软件发布间隔有少量轮询和数据相关抖动，不能误写成每窗严格固定524288周期。窗口采集时长仍为26.2144 ms，采用重叠采集；计算约5 ms并不表示从首个样点起5 ms就有结果。

## 功能和架构

- 去掉8麦路径原固定393216周期的结果发布等待，计算完成即通知CPU；12麦历史配置仍保留原参数。
- CPU读取40字原始统计及1024个完整评分，继续执行原有输入质量、非局部峰值对比、方向确认和转向流程；没有降低可信度阈值换速度。
- 新增局部寄存器：D04C统计索引、D050统计值、D054评分索引、D058评分值。评分读口为同步RAM，固件设置索引后先读回索引，确保流水完成再读取评分。
- D05C写 `0x52535438` 只允许在定位停用且空闲、无故障时重启窗口计数，供原始录音暂停后恢复；不能清除故障恢复状态机的粘滞故障。
- D060返回 `0x50384f31`（P8O1）。新固件启动时检查该能力标识，防止配套旧bitstream而读取缺失的评分/统计接口。
- 原有原始录音请求/释放协议保留，暂停期间明确停止定位，释放后重新收窗并恢复连续调度。
- 音频DAS/SIMD FIR通路继续运行；本轮连续测试无音频drop。

## 验证证据

`check_planar8_production.py` 已通过：

1. 生产镜像与测试镜像ITCM逐字一致。
2. 对同一输入的3窗，生产路径与自主搬运实验路径的3072个评分、120字电平统计逐字相等。这不代表与旧标量PHAT实现或真实声学结果完全等价。
3. 连续32窗，raw/window/audio drop均为0，评分和统计读回逐字核对；每窗始终为512点Hop。
4. 静音、削顶输入拒绝转向。
5. 注入明确评分峰值，验证软件重复确认、迟滞和最终转向锁定。该测试是控制链验证，不是声学定位精度证明。
6. 原始录音暂停、释放后，生产定位继续发布结果。

32窗共由CPU退休256条正FFT启动、896条逆FFT启动、896条互谱启动、896条PHAT启动和32条SRP启动自定义指令。32窗约覆盖0.44秒仿真，不能替代长时间板卡验收。

生产构建入口仍为 `scripts/build_planar8.py`，输出 `build/das8/fw` 和 `sw/acoustic_planar8_image.h`。复现：

```text
python -X utf8 scripts/build_planar8.py --compiler-prefix <目录>/riscv64-unknown-elf-
python -X utf8 scripts/measure_planar8_latency.py --variants production overlap --windows 3
python -X utf8 scripts/check_planar8_production.py
python -X utf8 scripts/summarize_planar8_production.py
```

日志、逐窗结果和源文件哈希位于 `build/planar8_optimized/`。旧顺序调度测量保留在 `build/planar8_latency/`。

## 限制

以上为对齐后注入合成PCM的RTL周期测量。自然合成场景仍被质量门限拒绝，尚不能声称实际声源方向已可靠锁定。本次没有运行新的Vivado综合/布局布线或上板下载；更新的MMIO和统计读口需要重新生成匹配的bit/XSA后使用。PS网络、UI延时、板卡时序和实际声学效果不由本报告证明。
'''
    (ROOT/'docs/planar8_optimization_20261021.md').write_text(report,encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k in ['compute_including_post','publication_interval','last_pcm_to_publication']},indent=2))


if __name__=='__main__':main()
