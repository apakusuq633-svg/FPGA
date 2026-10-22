# 124：RAW组计数回卷后静默跳过两个窗口

状态：已修。

## 症状

控制器回卷专项FIRST从512跳到2048，预期1024；raw_drop/window_drop都未报告丢窗。

## 误判

2048点RAM地址环绕测试不能替代32位组计数器回卷测试；有限窗口正常跑过多个RAM环不代表30.54小时计数边界安全。

## 根因

`sample_count>=1024`兼作预热状态。32位计数回到0后重新进入预热，漏掉FIRST 1024与1536对应的两个窗口，后续又正常产生窗口而计数不报错。

## 修法

一位window_primed记录首次1024点已齐备，之后按低9位512Hop调度；disable/reset清预热。数组容量和采样节拍不变。

## 复现指纹

`check_localizer12_safety_units.py --before`得到ROLLOVER_SILENT_WINDOW_JUMP失败日志（实际文本SILENT_WINDOW_JUMP）；当前同一专测六窗RAW序号和值一致，FIRST 0、512、1024、1536、2048、2560。数据/计数平移不改变环地址，算子为握手桩，范围明确。
