# 125：EX接受计算操作后过早移交数据所有权

状态：已修，通用CPU算子接口保留。

## 症状

中间版在SRP入口后偏移31拍注入200724拍HALT，算术结果正确，但SRP退休数仍0时窗口已发布；细化压力报告CUSTOM_COUNT，不能算PASS。

## 误判

EX侧commit代表操作被接受，不等于已达到WB架构退休；只检查HALT当拍compute_done门控仍不足以覆盖SRP自主完成阶段。

## 根因

定位端FFT/GCC完成跟随EX握手，SRP门铃也在EX后发出。最后一个算子可以在CPU退休受阻时自行完成，窗口状态机没有退休依赖。

## 修法

定位FFT/GCC完成由实际retire_valid和对应原始指令译码产生；定位SRP启动在实际退休后寄存发出。常规非定位门铃维持原路径。不改变opcode、运算规模、音频SIMD或RAM容量。

## 复现指纹

`validated/halt_srp_200724_w0_o31_n6_s20261015_b0.log`保留原COUNT_ERROR srp=0；release目录重新执行多阶段粗测、相邻拍边界和后续窗口偏移测试，并保留每场景JSON/日志。时序必须采用final_implementation，不能拿中间implementation的正余量替代。
