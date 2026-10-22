# 121：Hann初始化路径随仿真工作目录失效

状态：已修。

## 症状

XSim从独立运行目录启动时Hann ROM未正确初始化，prepared数据出现X或黄金不匹配。

## 误判

源目录可读的相对路径不代表综合、XSim快照目录和独立Verilator目录都可读；不能用最终score为0掩盖未初始化。

## 根因

初始化文件依赖未跟踪的build路径，仿真及综合的当前目录不同。

## 修法

将1024字Hann表纳入rtl/rom/pdm_hann_q14.hex；预加载脚本传入PDM_HANN_FILE绝对路径，XSim源适配器同步处理，默认路径供仓库根运行。表纳入仿真及实现源码哈希。

## 复现指纹

`build/pdm12_runs/transfer_final4_drained/simulation.log`原生XSim四窗PASS，audio2944/2944/drop0；Verilator256窗prepared逐点及完整黄金PASS。新表与既有参考表逐字节一致。
