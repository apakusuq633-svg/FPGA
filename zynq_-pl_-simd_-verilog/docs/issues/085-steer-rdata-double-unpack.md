# 085　`fw_steer_query` 对 `S_RDATA` 做了重复解包（RDATA 本来就是 Q16）

**症状**　装好 LUT（084）之后 §9 能跑完、不再冻结，但拿回来的 `comp_now[]` 是垃圾：
`STEER_RES_CK_NOW` 与 `STEER_RES_CK_REF` 对不上，DAS 受控那趟的延迟改错量。

**误判**　一开始以为"硬件出口是打包的 14 位、固件解包才对"——因为 `fw_steer.h` 里
参照表 `g_steer_comp_ref` 确实是打包的，`fw_steer_query` 也对 RDATA 调了
`fw_steer_unpack14`。**两边看起来一致，其实硬件那边早就解过包了。**

**根因**　`rtl/srp/rv32_steer.v:84-92` 在几何核里就把打包值**还原成 Q16 样点**：

```verilog
// 还原：(signed(idx) << 16) + (frac << 12)
wire signed [IDX_W-1:0] idx_s = lut_r[LUT_W-1:FRAC_W];
wire signed [31:0]      idx_w = {{(32-IDX_W){idx_s[IDX_W-1]}}, idx_s};
wire signed [31:0]      tau_w = (idx_w <<< 16) + $signed(frac_w <<< 12);
```

而 `comp_mem[i] <= tau_q[i] - tmin_q`（`:146`）、`comp_data_o = comp_rd_q`（`:58`）
—— 所以 **`A_RDATA` 出来的是 Q16 样点，不是 14 位打包值**。
硬件实测：`comp_rd_q = 0x0000e000` = 0.875 样点（Q16），正是"两次查表相减"该有的量级。

固件那边 `fw_steer_query` 又解了一次包 ⇒ 双重解包。

**独立佐证**（不依赖 RTL）：`sw/fw/fw_das.c:82` 把两个操作数**直接相减** ——
`adj = fw_steer_unpack14(cr[m]) - cnow[m]`，其中 `cr = g_steer_comp_ref` 是打包表。
两边必须同量纲，所以 `cnow[m]` 必须是**解包后**的 Q16 —— 而它来自 RDATA 再解包一次。

**修法**　（**未做**，本次只定位）把 `fw_steer_query` 里读出 RDATA 后的那次
`fw_steer_unpack14` 去掉，直接 `comp[m] = (int32_t)S_RDATA;`。
改的是 `sw/fw/fw_steer.c`（固件侧），改完要重跑 `build_fw.sh` 并重出 ITCM/DTCM 镜像 ——
而 `.text` 阈值已经压到 0x2400（§6），要顺手核对放得下。

**复现/指纹**　`build/scratch/tb_fw_steer_probe.v` 打印 `CK_REF` 与 `CK_NOW` 两行，
**这两个数不等就是它**。另外 `fw_das.c:82` 那一行是现成的量纲参照：
任何时候只要"从 RDATA 拿到的量与 `g_steer_comp_ref` 解包后的量"直接相减，
它们就必须同量纲。
