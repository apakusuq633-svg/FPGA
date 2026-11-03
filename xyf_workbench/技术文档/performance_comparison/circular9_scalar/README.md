# 完整九麦标量与PL加速定位评分对照

正式汇总为`comparison_summary.json`及`comparison.csv`。输入为当前PL夹具的同一首个1024×9 PCM窗口，采用36麦对、64点相关环和1024方向格。标量代码复用生产标量FFT/IFFT，逐级匹配均值／缩放、Hann、互谱、PHAT、相关环和SRP整数规则。

| 版本 | 周期 | 40 MHz时间 |
|---|---:|---:|
| RV32标量`-Os`主行 | 11049372 | 276.234300 ms |
| 当前PL加速同首窗 | 82354 | 2.058850 ms |
| RV32标量`-O2`辅助行 | 9806381 | 245.159525 ms |

主对照为134.1692倍，从输入已驻留到1024评分写完，不含输入预装、峰值／置信度／轨迹／发布、PS传输和其他音频或诊断任务。PL的统计在采集时滚动完成，标量在收窗后统计，属于已披露的架构差异。没有将32窗中最短的PL窗口与标量首窗配对。

首窗45统计词、576频谱词、2304相关值和1024评分全部一致；32窗1440统计词及32768评分全部一致。输入是4096帧周期循环的合成平面波，不是独立真实录音。

## 复现

先运行上一级PL组，生成当前隔离源码镜像、输入和dump，再执行：

```powershell
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/circular9_scalar/run_scalar.py' --all-windows --bench 64
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/circular9_scalar/run_rv.py' --optimization Os
# 复用同一RTL模型查看编译选项或阶段构成
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/circular9_scalar/run_rv.py' --reuse-model --optimization O2
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/circular9_scalar/run_rv.py' --reuse-model --optimization Os --profile
```

脚本在固定目录写结果，重测前完整归档希望保留的版本。最初正确O2正式结果特意保存在`rv_plain_O2_corrected`，新运行O2输出至`rv_plain_O2`，两者应按各自日志引用。

`rv_plain_Os/results.json`是主周期；`rv_profile_Os/results.json`仅解释插桩构建的阶段构成。插桩改变寄存器分配和布局，阶段版总10976268拍，与未插桩主行不同，不能用分阶段数直接拆扣主行。

`results.json`中的宿主计时为Windows x86 QPC：预热3次后9轮、每轮64次，批均值中位0.334117 ms，批均值范围0.328086—0.371066 ms。自动向量化关闭；这里没有逐窗P95/P99，也不能称为Cortex-A9实测。

## 保留内容与边界

`c9_scalar.c/.h`为可移植算法入口，`third_party`保留逐字核对过的生产FFT及常量；`input.pcm`、`srp_lut10.bin`及Hann表是实际输入。`rv_main.c`、`rv_link.ld`、`tb_c9_scalar.sv`和`run_rv.py`构成完整RV32试验，ELF、hex、模型、日志、逐级dump、主／辅助／插桩结果均保留。

初始build-id导致.text VMA偏移36字节而装载仍从0开始的失败，保存在`rv_failed_build_id_vma24`。正式链接关闭build-id并断言入口和.text VMA为0后重新通过，未修改生产源码或调整黄金期望。

同一`c9s_locate()`可供未来A9基准使用；还需DDR输入装载、板上PMU／全局计时器包装及实际板卡。当前没有A9耗时，也没有三架构PS往返全程结果。
