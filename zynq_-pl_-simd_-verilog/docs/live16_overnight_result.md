# 16麦本次完成记录

> 历史版本：本页记录2026-10-13本次防漂移修改之前的配置与产物。当时显式开启定位；当前16麦默认已改为1024格，固件增加质量确认并修正采集同步读。下列7帧/周期数/文件哈希不能作为新固件验收，当前结果见[定位稳定性](localization_stability.md)与[配置记录](live16_localization.md)。

2026-10-13：16麦数字仿真、生产自动转向持续验收、40MHz位流和匹配PS程序已完成；四麦板保留原程序，没有下载16麦配置。

- 连续7轮均定位到预期网格773，第三轮自行锁定；全部16路延迟收敛到独立几何参考。
- 连续DAS/FIR 75564个样点逐位通过，转向状态43288点；另确认256个连续稳定增强样点，末尾丢样0。
- 时序WNS +0.164ns、WHS +0.022ns，setup/hold/pulse-width失效端点均0。
- 位流：`build/das16_loc_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit`。
- PS程序：`build/ui_pipeline_live16_loc/ui.elf`；硬件导出：`build/das16_loc/das_fir.xsa`。
- 最终清单：`build/das16_loc/live16_manifest.json`，匹配位流/XSA、固件、LUT、PS源码、ROM和仿真日志已检查。
- 第2～7轮周期按40MHz折算约3.63Hz，尚未达到20～50Hz；16麦实阵列及声学效果尚未验收，音频FIFO与定位的精确时间关联也待完成。

完成指纹：`LIVE16_NATURAL_PASS frames=7 samples=75564 steered_samples=43288 settled_samples=256 drops=0`、`LIVE16_XSIM_NATURAL_PASS`、`LIVE16_PACKAGE_PASS`。

按用户授权，在最终检查和记录保存后发起正常关机；关机进程记录在 `build/das16_loc/shutdown_status.json`。未使用强制关闭应用选项。详细参数、复现命令和每轮周期见 [定位配置](live16_localization.md)。
