# 当前接收器与截图对应 PDM 工程的边沿对照（2026-10-22）

本页只比较当前工程接收器与用户新指定的 `C:/Users/lenovo/Desktop/FPGA/PDM`，
不使用 PDM_48K 或 PDM_48K_8ch 的结果代替这份参考。
`PDM/src/pdm_top.v` 及原位流 LTX 中的 `pcm_0l/pcm_0r`、`valid_pack`、
`pdm_data_s2`、`pdm_clk_r` 与用户截图一致，已找到对应工程。

## 两侧实际配置

| 项目 | 当前接收器默认配置的 ILA 观察版本 | 截图对应 PDM 原始采集代码 |
|---|---|---|
| 系统时钟 | 40 MHz | 200 MHz |
| PDM | 2.5 MHz | 3.072 MHz，半周期 32/33 个系统拍 |
| 采样方法 | 默认 HOLD=4、CONSUME=12，名义边沿后 125 ns | 两级输入同步，half_cnt=1 时分低/高相采样 |
| 滤波 | 三阶 CIC、64 倍抽取、PCM24 | 四阶 CIC、64 倍抽取、PCM16 截位 |
| ILA 详细观察 | 40 MHz，25 ns 分辨率 | 新增 200 MHz，5 ns 分辨率 |
| DATA1 / CLOCK | T14 / V16 | T14 / V16 |

当前侧不是整个 PS/SoC 的重新下载，而是相同接收器和默认采点的独立 ILA 观察版本。
本轮最终图使用默认 125 ns 配置；此前 175 ns 排障配置不混入最终对照图。
采用已布线的默认 4/12 采点 checkpoint，将 CLOCK 驱动设为与生产默认相符的
12 mA SLOW，保持 DATA 弱下拉与生产约束一致；抓取后由记录的 HOLD/CONSUME 再次验证采点。

参考侧先审计原始 `pdm_top_routed.dcp` 的全部 8 个 IO，确认 4 根 DATA 为输入、
V16 CLOCK 和板载 H15 LED 为输出，均 LVCMOS33；随后原样下载已有 bit/ltx 并抓取
`original_pdm_stock_take1_stock0/1/2`，包含与截图相同的原 25 MHz ILA 探针。
原 ILA 分辨率不足以细看 200 MHz 域边沿，故再增加一个被动同步记录包装层。
参考 `pdm_top.v` 与 XDC 原文件/快照哈希一致，采集源码未修改；高速版完成内部时序与 IO 审计。
新增记录总线整体延迟一个 200 MHz 拍，各字段仍同拍，保留原 ILA。

## 最终波形与读法

图：`build/pdm_ila_20261021/current_vs_original_pdm_edges.png`，
由实际 ILA CSV 绘制，不是仿真、示意图或示波器模拟电压。

- 上图：当前默认接收器；下图：本次指定的 PDM 参考采集器。
- 黑线：内部观察到的 PDM CLOCK；蓝线：DATA1 原始数字输入；青线：参考同步器第二级。
- 绿点：低半周期实际采到的位，按预期接线称 U1/低相时隙。
- 紫点：高半周期实际采到的位，按预期接线称 U2/高相时隙；点旁数字是实际 0/1。
- 虚线：ILA 首次观察到的 CLOCK 跳变；浅色带表示一采样拍的边沿位置不确定性。
  例如当前名义 125 ns 由 RTL 推导，在以首次观测低电平为零点的图上可以相差一个 ILA 拍。
- 两侧顺序上板抓取，分别对齐到各自观察到的下降沿，不是同时记录的同一段声音。

**U1/U2 行是预期 SELECT 映射下的采样时隙，不是直接测出了两颗器件各自的物理输出。**
同线电气驱动是否符合预期仍需验证，不能把一根 DATA 重画成两根已独立识别的数据线。

## 实测观察

参考高速 ILA 三个窗口分别有 125、126、125 组完整低/高相配对，
这 376 对采样位全部相同，三个窗口 DATA1 的原始跳变均只发生在 CLOCK 低半周期。
当前默认配置的三个窗口每段 256 对，配对相同比例约 75.8%、78.5%、80.1%；
两侧的当前实测结果均不能作为真实双麦独立采集成功的证据。

原参考 ILA 中左右 PCM 确实不同，与用户截图现象一致；但是两个独立 CIC 的相位计数
及初始样本对齐不同，且输出直接取 25 位结果的 [20:5] 位，因此 PCM 数值差异不能
替代原始低/高相输入位的独立性判断，也不能与当前 PCM24 直接按满刻度比直流大小。
本轮只观察并对照，不修改参考或当前生产接收器算法，不据此认定具体 PCB/器件故障。

## Vivado 中直接查看

已打开四个视图，仅来自上述两个工程：

1. `current_default_for_pdm_named_take1_raw`：当前默认采点和 DATA1。
2. `original_pdm_edge_named_take1_edge0`：参考 200 MHz 边沿观察。
3. `current_default_for_pdm_named_take1_pcm0`：当前 PCM。
4. `original_pdm_stock_take1_stock0`：参考原始位流的原 ILA，探针名与截图一致。

两个原始边沿视图都有可读的虚拟探针 `CLK_PDM`、`DATA1_RAW`、
`U1_LOW_SLOT_EN`、`U2_HIGH_SLOT_EN`；参考另有 `DATA1_SYNC1/SYNC2` 和两路 PCM。
虚拟探针仅重新命名已有 ILA 位，不改变硬件采样或生成额外物理信号。

统计为 `original_pdm_edge_comparison.json` 和 `original_pdm_edge_replicates.json`；
复算/绘图脚本为 `scripts/plot_pdm_original_edges.py`。
最后一轮 11:02:37 自动恢复停钟，未写 Flash。用户无需因查看保存波形重新上电或改线。
