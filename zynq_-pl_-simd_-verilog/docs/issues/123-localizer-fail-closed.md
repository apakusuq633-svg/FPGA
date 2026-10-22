# 123：定位丢失计数增加后仍继续发布

状态：已修。

## 症状

SRP阶段长HALT/访存等待触发window_drop后，原状态机仍推进并产生结果；测试报RESULT_AFTER_LOSS。disable中途也未取消原状态机。

## 误判

有raw_drop/window_drop计数不等于错误窗口已隔离；依赖CPU及时轮询错误在HALT时不可行。

## 根因

错误路径只更新计数，未优先取消pending/active窗口、抑制IO与发布；enable只约束启动，未约束整个活动窗口。

## 修法

增加sticky failed；同拍loss优先进入IDLE、清pending并屏蔽后续IO和发布。显式disable取消活动窗口并重新预热，保留错误状态和计数，只有reset清故障。RAW生命周期保护只在仍可能访问RAW的通道准备/FFT阶段生效，已脱离RAW后的等待不假报RAW覆盖。

## 复现指纹

`before_audit/mem_srp_300000_w0_o0_n4_s20261015.log`在1640455拍报损失、1739682拍仍发布；修复后对应场景EXPLICIT_LOSS且观察800000拍无非法发布。`check_localizer12_safety_units.py`包含disable/reenable、sticky故障和reset恢复。
