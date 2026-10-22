# 017 规格里 capture mode 说反

**症状** 无——同样是"照做就默默取错通道"。

**根因** 我写规格时说"mode 2 = 左声道"。实际 `rv32_audio_monitor.v` 里
`mode_q==1` → 符号扩展 `sample_data_i[31:16]`，而 `rv32_audio_regs.v` 的
`sample_data_i = {rx_l, rx_r}` ⇒ **mode 1 = 左**（`ps_capture.c` 的默认值也是 1）。

**修法** 默认改成 `ANC_CAP_MODE=1`，并把这个枚举的含义写进注释。

**复现/指纹** 和 016 同类：**规格里凡是"编号 / 偏移 / 枚举值"，都要对着 RTL 核一遍**，
不能凭记忆写。这两条都是被实现方抓出来的。
