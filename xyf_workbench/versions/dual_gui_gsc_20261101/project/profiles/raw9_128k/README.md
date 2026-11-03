# 九路128kHz原始录音实验配置

状态：独立开发配置；没有上板验收。生产代码、入口和发布包未修改。

## 阶段一审查
当前生产架构是40MHz /16 PDM=2.5MHz，CIC R16输出156250Hz。10个逻辑槽、5根DIN，active mask0x1ff；CH0..CH8=U1..U9，第10槽禁用。共享线A低半周期保存、B高半周期读取，统一CIC节拍输出。它保证共同输出节拍，不能证明物理模块输出独立、LR实接正确或电气采点安全。
现有DMA每帧128字节，具有所有权计数、CRC、源样点序号、64位系统时钟时间戳、FIFO/DMA丢弃统计。pdm_stream.c负责复制、校验及归还。原有短窗口导出上限160256帧，不能反复拼接为无缝30秒。
现有平台无可复用SD/FatFs文件写入链路，采用独立裸机程序与PC接收程序；不运行CPU1、定位、DAS、GSC、诊断或Web。PC流式保存，板端1024帧PCM块+4096槽DMA环，环约32ms，必须实测服务预算。网络故障不补零、不复制，立即认定本次录音失败。UDP不保证重传，当前实现以严格检测失败为原则，不承诺网络丢包时仍能成功。

## 数据流和采样时刻
独立raw9_clkgen：40MHz相位累加器，quarter平均8.192MHz，PDM平均2.048MHz，16倍CIC=128000Hz。quarter间隔4/5拍，PCM间隔312/313拍。没有重采样和插值。量化节拍抖动小于1个系统周期；频率准确度仍取决于实物时钟。不能将标称频率称为频率计实测值。
CLK下降沿后下一quarter锁存A，上升沿后下一quarter消费B；采样点约100/125ns后，A保持到B消费。CIC输入打一拍后消费；两路CIC均同节拍。A/B物理时隙约相差244ns，保留此硬件固有偏差，不添加跨通道补偿。CIC相同ORDER3/ACC24/R16；24位PCM统一取[23:8]为signed16，未做增益、归一化、极性修改、空间对齐。CIC的通带下垂与阻带需按研究频带评价，128kHz不代表麦克风有64kHz模拟带宽。
raw9_rx是生产接收模块的独立命名副本，改动仅时钟模块名，源哈希见source_manifest.json。raw9_frontend直接打包CIC输出，绕开原生产DAS等待的rv32_gsc_tap；沿用传输格式是为了复用校验器，包中方向及DAS字段为0，不表示运行了这些算法。

## 通道映射
按当前configs/circular9_array.json：DIN0=T14、DIN1=Y17、DIN2=W16、DIN3=T15、DIN4=Y16，CLK=V16；同DIN的2k/2k+1分配A/B；CH0=U1直至CH8=U9。LR实际接法、电气独立性仍须实物核对。保持LVCMOS33、弱下拉。输入false_path仅为内部STA范围声明，绝非外部输入时序验收。

## 构建及运行
从仓库根执行：
```
powershell -NoProfile -ExecutionPolicy Bypass -File profiles/raw9_128k/build_ps.ps1
vivado -mode batch -source profiles/raw9_128k/build_pl.tcl
```
PL脚本拒绝覆盖已有构建目录；重跑应选择新的独立out目录。PS默认使用本次独立XSA生成的匹配BSP，已完成重新链接。
录音程序仅接受身份寄存器0x52393132匹配的专用位流，不能在生产位流上运行。独立program.ps1已提供，默认仅核验哈希；加-Program才加载位流及ELF。不会自动开始录音。
准备电脑IP192.168.2.20/24，板端192.168.2.10，UDP1235。加载匹配录音位流和ELF后，电脑命令：
```
python profiles/raw9_128k/tools/receive.py --out D:/captures/experiment_001
python profiles/raw9_128k/tools/analyze.py D:/captures/experiment_001/recording_9ch_128k_s16le.pcm --out D:/captures/experiment_001/analysis
```
接收器显式发送START，自动结束30s；Ctrl+C停止，或手动UDP发送STOP。仅完整收到3840000帧与板端无错终止报告才改名为recording_9ch_128k_s16le.pcm；失败保留recording.partial.pcm和metadata.json。目录不能预先存在。每帧CH0..8小端有符号16位交织，共18字节。分析输出JSON统计、九轴SVG；大小/统计不能替代连续性证据。

## 必须完成的实板验收
1. 位流及IO报告确认五DIN、CLK、电平偏置与生产实际接线一致；频率计测平均CLK2.048MHz及占空比；示波器确认有效DATA采点。
2. 九颗分别近场激励检查通道对应；共同固定宽带声源检查同DIN非复制、非异常反相，必要时记录原始时隙。不能从数字仿真推断模块健康。
3. 连续30s录音，帧数3840000、字节69120000、包号/源样点/时间戳连续、CRC无错、DMA/FIFO/写入计数0。检查末首时间戳差约1199999687/1199999688个40MHz周期。
4. 对比已知位置声源的互相关延时，验证移动产生连续合理TDOA。同步输出不等于声学相位已校准。
5. 接收器停收、断网、不可写目录、拔线，必须报告失败，不能输出完整成功状态。实测PS服务时间、网络接收丢包、磁盘开销。
6. 录音配置退出后重新加载原生产发布包，检查定位诊断功能；不混用位流/ELF。

## 当前离线证据
XSim clock：10ms 20480 PDM/1280 PCM节拍；RX512帧，四种双相组合均出现、共同valid、CH9屏蔽通过。它不是独立实物验证。
C录音核心：3840000合成帧计69120000字节，已测缺帧、写错、背压；接收器合成测试已测九路已知延时、缺包、乱序、截断及不完整结束。ARM严格编译链接通过。Vivado完整实现与实际IO核查已完成，WNS+7.027ns/WHS+0.015ns，详见VERIFICATION.md；没有上板验收。
