# 2026-10-29 独立录音交付验证

本次仅新增 profiles/raw9_128k；保留原始latest4全部未提交修改。没有执行烧录、网络录音、远程Git操作。

## 已执行
- XSim时钟：400000个40MHz周期（10ms），A/B各20480次，抽取1280次；连续PCM节拍312/313拍。
- XSim接收：512帧，00/01/10/11计数2121/1975/1974/2122；共同valid，禁用槽清零，九路刺激不被复制。测试不是物理麦克风独立性证明。
- 原CIC模块复用，未改数学实现。没有重新做完整模拟麦克风噪声整形/模拟频响仿真。
- C核心完整3840000帧、69120000字节计数与九路已知整样点偏移逐样核对；缺帧、背压、写失败测试通过。
- PC接收器合成60000包、3840000帧、69120000字节通过；九路排序/已知延时、乱序、缺包、截断及不完整结束拒绝通过。
- 离线分析工具8192合成帧、9路统计/非复制检查、SVG生成通过。
- 新XSA生成匹配BSP后ARM -Wall -Wextra -Werror 编译链接通过；不是PS实机性能验收。
- Vivado实现：WNS +7.027ns，WHS +0.015ns，TNS/THS0；5024 LUT、4281 FF、0DSP、0BRAM。不是生产九麦计算系统的资源数。
- 实现网表IO核查：DIN0..4=T14/Y17/W16/T15/Y16，LVCMOS33、PULLDOWN；CLK=V16。报告build/raw9_128k_pl_try3/io.rpt。
- 默认program.ps1运行仅做文件哈希检查，通过；未访问JTAG。

## 构建产物
- build/raw9_128k_pl_try3/raw9.xsa、timing.rpt、utilization.rpt、io.rpt、drc.rpt。
- build/raw9_128k_bsp：匹配硬件平台。
- build/raw9_128k_ps/raw9.elf、raw9.map：DMA区域0x08000000，1MiB，应用链接区限制64MiB以内。
- build/raw9_128k_release：位流、ELF、XSA对应ps7_init.tcl、哈希清单、显式加载入口。清单状态BOARD_UNTESTED。

## 验收边界
尚未取得真实69.12MB录音。不能声称九路电气独立性、实物时钟精度、麦克风输出窗口、真实网络/磁盘吞吐、CPU占用或30秒零丢帧已经通过。UDP没有重传；出现网络丢包会报告失败，而不是隐藏缺口。物理输入false_path未覆盖外部源同步时序。128kHz是标称PCM输出速率，不是64kHz模拟声学带宽。
暂不增加Web界面，独立命令行作为第一版控制入口。未提供WAV，因为交织PCM为主交付。需要SD独立落盘、重传/可靠流、更多抗混叠滤波或GUI时可在实测瓶颈确定后增量开发，不能把这些写作本次已实现。

## 上板最小流程
先运行发布包program.ps1（不带-Program）核验。用户准备好后加-Program加载独立模式；它会替换板上当前易失运行程序，磁盘生产包不变。PC设192.168.2.20/24，显式运行tools/receive.py --out新的实验目录，开始30秒录音。查看metadata与statistics，并核对九颗分别近场响应、固定/移动宽带声源的TDOA。完成后用原生产指令恢复定位诊断模式。

## 首次实板失败与发送队列修复
用户第一次实板报告：PC3264帧/58752字节，源首末时间戳12929851671/12931131359，对应4096源样点；DMA丢弃/错误/超时/源缺口为0，旧overflow_count=1。旧sink在一块1024帧内连续发送16包，其中任一发送返回非OK即失败；flush失败被重复计为overflow。该报告定位到发送块中途失败，尚未取得具体lwIP错误码，不能认定是特定一种硬件资源耗尽。
修复：8个1024帧输出块队列（147456字节PCM，约64ms），每主循环最多发送4包，返回网络输入服务回收资源。发送失败保持同一包和序号，2秒无发送进展则终止失败；队列满仍失败，不修改采样、CIC、PL、DMA。新状态包含write_errors、tx_retries、tx_queue_peak_blocks、tx_sent_frames、tx_last_error、tx_queue_full，暂时发送错误恢复后不等于录音失败。
完整30秒规模发送队列模拟测试覆盖周期性暂时失败、精确字节及不重复/不跳包、队列满拒绝，通过。扩展结束报告接收测试通过。ARM严格编译链接通过。修复版未上板验收。新发布路径build/raw9_128k_release_txq；旧包保留。UDP在网络中丢失的数据仍无法重传，该修复针对本机发送暂时背压。

## 6.93秒发送队列满：分配前回收修复
用户提供新实板报告：源896000帧，PC/发送887040帧，DMA drop/error/timeout和源gap均0，tx_retries=115554、tx_queue_peak_blocks=8、tx_queue_full=1、write_errors=1、tx_last_error=0。根据该ELF的send_packet实现，UDP返回非OK一定赋值非零tx_error，但pbuf_alloc失败直接返回而未赋值，因此这些计数强烈指向pbuf申请失败。尚不能直接断言底层是中断、堆碎片或驱动泄漏。
已有BSP low_level_output在发送描述符少于阈值时调用process_sent_bds；该调用位于pbuf申请之后。新PS程序在pbuf申请前主动调用同一驱动函数，使用SYS_ARCH_PROTECT串行化，只回收GEM已经标记完成的描述符，避免申请失败绕过回收路径。未修改BSP、PL、采样或缓存大小。
新增tx_alloc_failures/tx_reclaimed_descriptors/tx_free_descriptors。新的112字节结束报告兼容原76/100字节解析。完整离线回归、扩展状态解析与匹配BSP ARM严格编译通过；未上板或主动开始录音。新发布build/raw9_128k_release_txreclaim；仍需用户30秒测试确认，不承诺仅此修复即可完成实板验收。
