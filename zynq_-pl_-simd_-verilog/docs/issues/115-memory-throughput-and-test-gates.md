# 115：访存延迟、CPU吞吐和测试结束流程必须分别验收

状态：测量与测试门控已修；当前已有CPU优化，2026-10-15仿真连续吞吐复核为2 cycles/access。

新日志为`build/taskbook_20261015/mem/`：1024展开DTCM访问2050拍（包含两条指针调整），
MMIO访问2048拍。同步RAM应答仍隔一个边沿，并未改DTCM/MMIO握手。
以下3 cycles/access及板级结果是此前归档版本；新RTL实现/实板未验收。

## 症状

DTCM/MMIO一次应答等待1拍，但连续独立访存约3 cycles/access；12麦采集9.4ms不能全部归因于MMIO等待。首轮实板微基准出现音频FIFO丢样，同时旧脚本只检查trap/回读就打印PASS。独立FFT测试还出现513个X结果。

## 误判

用RAM两拍占用推定CPU吞吐两拍；把rdcycle整个阶段当LSU Stall；把快照DROP=0等同原始数据连续；把未消费FIFO造成的溢出当作CPU/音频算法损坏；未连接新增SEEK输入的旧TB结果不代表FFT算术变错。

## 根因

memory_stall冻结流水线并使取指req撤销，ITCM ready随req下降，恢复有前端重新取指开销。采集阶段只有37110等待拍，其中MMIO18444，其余大部分为统计/循环指令。DAS FIFO只有256字，慢JTAG读取不消费音频，首轮累计8017 drops。`tb_fft_bfly`未接`io_seek_i`，X通过POP结果组合门控传播；PS旧TB用Verilog模式，强行SV编译有保留字语法冲突。

## 修法

新增真实CPU/SoC微基准，保存请求/接受/响应/退休四事件，逐字节独立golden，严格单次写及退休顺序计数；实板76项rdcycle逐项等于仿真。微基准结束后停止测试输入，阻止JTAG读回阶段溢出；音频丢样进入PASS判据。这仅是有限测试结束流程，不是生产性能方案。完整定位实板测试另由A9连续消费FIFO，四帧66对及SRP完成、drop=0。FFT TB显式接`io_seek_i=0`；PS回归用`-g2005`。未改任何功能RTL。

## 复现指纹

`wsl python3 scripts/check_rv32_mem_perf.py`：76场景28534事务、156音频点，最大101拍；`report_rv32_mem_perf.py`：76项实板/仿真一致。`check_rv32_mem_regression.py`：CPU/PS/向量/FFT/采集六项PASS。旧首轮失败日志`build/rv32_mem_perf/board_fifo_overflow_exploratory.log`保留；完整链及周期见`docs/perf_rv32_bottlenecks.md`与`build/rv32_mem_perf/board_profile*/`。
