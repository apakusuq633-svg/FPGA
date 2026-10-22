# 118：完整重叠候选模块LUTRAM超限，不能布局

状态：已修。用户“进行修改”授权后，BRAM流水与SoC算子复用已完成；256窗SoC严格PASS，40MHz实现WNS +0.622ns / WHS +0.030ns。以下失败数字保留为修复前证据。

## 症状

独立完整localizer/FFT/FAST_SCAN SRP的16窗RTL数值与节拍通过，
但Vivado2020.2在xc7z020clg400-1的place_design前报两项UTLZ-1错误。

## 误判

不能由449582拍模块延迟推断可在7020集成，也不能只看总LUT没有超过53200。
只有具备存储能力的SLICEM位置可实现LUTRAM；总LUT余量不能替代该子资源。
不得设置drc.disableLUTOverUtilError绕过验收。

## 根因

综合结果29573LUT/2496FF/29BRAM/78DSP，分布式RAM需要17468个LUT，
器件只有17400个兼容位置。报告将srp/lut_mem_reg映射为128K×9、3168 RAM64M，
srp/r_mem_reg也为分布式RAM，另有FFT分布式存储。不能把阵列有效67584字
直接当成工具最终实现的存储深度或BRAM数量。

## 修法

按[A-RTL-118](../pdm12_taskbook_execution_20261015.md)选项3实施同步BRAM LUT/R/P、分级插值累加、BRAM输入预取和软Pblock，SoC复用核FFT/GCC及SRP。当前完整整机29752 LUT/16824 FF/111.5 BRAM/132 DSP，LUTRAM2884；不能把旧独立模块总LUT与当前整机作同范围对比。
256窗无丢样、无跳窗、完整黄金比对及当前综合网表布局布线均PASS；详见[实现报告](../pdm12_transfer_bram_implementation_20261015.md)。

## 复现指纹

`vivado.bat -mode batch -source scripts/check_overlap_localizer_synth.tcl`退出1。
`build/strict_overlap/ooc_vivado.log`包含：
`ERROR: [DRC UTLZ-1] ... requires 17468 ... only 17400 compatible sites`及
`OVERLAP_OOC_FAIL`。综合资源见`build/strict_overlap/ooc/utilization_synth.rpt`。

修复后：`build/localizer12/final256/strict_summary.json`为PASS，
`build/localizer12_final/implementation.log`含FLOW_PASS；实现报告及manifest与当前RTL/ROM哈希一致。未做实板定位验收。
