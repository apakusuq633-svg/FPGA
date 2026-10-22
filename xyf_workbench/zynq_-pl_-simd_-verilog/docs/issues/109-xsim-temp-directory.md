# 109 XSim 临时目录变量指向不存在的目录

状态：已修。

**症状**：12麦RTL已通过Verilog分析，但XSim报`XSIM 43-3409`，生成的`xsim_2.c`编译失败。

**误判**：仅从报错位置不能认定是RTL或12通道的非2次幂配置造成。

**根因**：脚本把TEMP/TMP指定到`build/xilinx_temp`，新工作区没有这个目录。

**修法**：在调用xelab之前创建该目录；沿用已有声明适配逻辑，增加`-Twelve`入口而不复制第二套XSim脚本。

**复现指纹**：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve`打印`LIVE12_XSIM_PASS`；实际固件2轮快照、4412个连续音频样点与Icarus结果相同，丢样0。Icarus并未依赖这个临时目录。
