# 111：双阵列重复搬运、备用核lane参数和FFT乘法位宽

状态：已修，数字功能与两套完整40MHz实现均已验收；真实阵列/12麦三维几何待验收。日期：2026-10-14。

## 症状

8麦定位周期约98.56ms；12麦几何关闭仍计算/缓存无消费者频谱。备用复数核LANES改成4或16后输出不符。缩小备用核后8麦时序虽通过，WNS一度只有+0.015ns。

## 误判

不能因为模块叫FFT就把所有时间算作FFT算术，不能因LANES是参数就认为更改后数据布局正确，不能因12麦有1024评分容量就认为三维定位已上线。此次没有把旧百分比、历史综合报告或单元正WNS当作新整机证据。

## 根因

缓存被逐对复制，1024点TDOA峰值未被SRP使用，带外互谱算完又清零；12麦关闭几何后没有频谱或原始帧消费者。复数核pass计数和POP word/bank索引写死8路。FFT虚旋转因子16位扩32位后乘法形成DSP/加法长链，17位即可完整保存共轭最小值。

## 修法

只读频谱直接计算，保持传统API语义；合并SRP索引推进；复数核计数、bank、word和容量参数化，生产备用核用4 lane，连续FIR保留8 lane；12麦按几何开关跳过无用途FFT/FRAME写入；FFT共轭系数安全缩为17位。保留两个工程独立默认值、真实几何和接线，不迁入假12麦角度表。

## 复现指纹

`CACHED_GCC_EQUIVALENCE_PASS`（89组/91136样点）；`SYSTEM_KERNELS_PASS`；4/8/16的`ACOU_LANE_PASS`；`FFT_MULTIPLIER_WIDTH_PASS cases=100000`；正常/满幅正逆变换全部匹配。8麦`LIVE8_NATURAL_PASS frames=8 samples=23327 steered_samples=11791 settled_samples=256 drops=0`，平均计算1904857拍、采集加计算2953021.429拍。8麦完整实现LUT22505/FF13826/DSP111/BRAM57.5，WNS+0.913ns、WHS+0.024ns。12麦实际固件无几何测试2轮/3257点/丢样0，第二轮1668609拍，FFT I/O和scratch写入均0；完整实现LUT26134/FF15588/DSP119/BRAM84.5，WNS+0.306ns、WHS+0.035ns。两套TNS/THS=0，最终SHA256见[系统报告](../system_optimization_20261014.md)及`build/system_optimization/summary.json`。
