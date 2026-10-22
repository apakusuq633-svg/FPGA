# PS 对齐现有 PL FIFO

2026-10-12。真实模式改用已实现的 `0x380` FIFO，PL RTL 保持原样。`0x700` 双 bank 协议保留作旧接口参考，当前 GUI 和一次性调试程序不再访问它。

## 数据及运行行为

每次读取 `0x38c` 弹出一个样点：低16位为未滤波 DAS，高16位为 FIR 输出。PS 使用高16位有符号输出，按固定满刻度转换为 double，先积累 512 点块，再组装 40000 点段供 CPU1 诊断。CPU0 独占 FIFO，CPU1 独占 DSP；不能同时运行另一个 FIFO 消费程序。

GUI 初始化加入 RV32 软复位、ITCM/DTCM 写入及回读、FIR 系数回读与转向 LUT 加载。网络初始化及启动提示完成后才开启连续流，避免 PHY 协商和串口打印耗尽 256 点 FIFO。真实模式关闭逐帧串口打印，网页继续提供结果和错误。溢出、硬件错误或 RV32 trap 会停机并清除未完成段，不把不连续数据报告为正常诊断。

PL 没有逐样点时间戳、目标或转向版本，PS 仅提供本次消费会话的相对样点编号。音频段设置 POSITION_UNKNOWN，页面不显示关联位置，不把最新定位结果套到旧段上。同一段可能跨越转向更新，真实模型适配与可接受段策略仍需真实数据验证。

## 构建

```powershell
python scripts/check_ps_apps.py
node scripts/check_ui_page.js
powershell -File scripts/build_ui_pipeline.ps1 -Live -MatchingPlWindow
python scripts/package_ui_live.py
```

真实 GUI ELF 为 `build/ui_pipeline_live/ui.elf`。必须使用新 PL 位流和同次构建的 ps7_init；旧位流不能因开关名称而变成匹配硬件。位流构建在独立 `build/das_fir_zynq` 工程中进行，保留旧工程。

固件 hex 使用 LF，并增加仓库 `.gitattributes`，保持字节哈希校验；没有绕过镜像完整性检查。

## 已验证及上板边界

宿主执行测试覆盖 FIR 高半字、符号、FIFO 部分积累、溢出期间拒绝数据、40000 点拼段及 PL 初始化回读；网页测试验证没有位置关联时隐藏标记。真实及动态回放 GUI 完成 Cortex-A9 编译和 BSP 链接，独立 live_das ELF 也已构建。

新真实通路尚未上板。FIFO 仅有 6.5536 ms 缓冲，CPU0 网络路径及 PHY 状态处理的最坏阻塞须实测，断网恢复可能需要重新开始会话。生成 bit/XSA 和非负 setup/hold 报告后，再运行真实麦克风与网络并发压力验收；回放的 162 ms 结果不能替代这些检查。

## 本机产物结果

Vivado 2020.2 已完成八麦基线综合、实现、位流及 XSA 导出，WNS +0.060 ns、WHS +0.034 ns，建立和保持失效端点均为零。`scripts/package_ui_live.py` 已通过 bit/XSA 一致性、固件哈希和源文件新旧检查，输出 `build/ui_live_release_manifest.json`。它不等于旧 PL 全回归发布包，也不声称真实输入上板通过。

下载所需文件：

- `build/das_fir_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit`
- `build/das_fir_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl`
- `build/ui_pipeline_live/ui.elf`
- `build/das_fir.xsa`


[Four-microphone configuration and current artifacts](debug4_bringup.md). Four-channel implementation and PS build now pass; board validation remains pending wiring confirmation. The eight-channel artifacts above describe the earlier baseline build.
