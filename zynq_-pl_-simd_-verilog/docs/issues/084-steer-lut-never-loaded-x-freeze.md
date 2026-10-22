# 084　转向几何 LUT 无人装载 ⇒ §9 拿 X 做分支 ⇒ 整核永久冻结

**症状**　MMIO 写口修好之后，所有跑整固件的 TB 全部**硬冻结**：退休数停在一个固定值，
此后一条都退休不了，一直趴到 `MAXC` 才被 TB 的循环放出来。

| TB | 冻结点 | 备注 |
|---|---|---|
| `tb_fw_gsc`、`tb_fw_steer_probe` | 退休 **7782978** 条 | 这两个做了 vec 系数 bank 的 poke |
| `tb_fw_fft` / `gcc` / `srp` / `das` | 退休 **6471367** 条 | 没做 poke，先在阵列 GSC 那段被 X 拦下 |

「零退休」是关键特征：**不是算得慢，是核真的不动了**。
把 `MAXC` 从 13M 改到 14M 也一样停，与仿真时长无关。

**误判**　先怀疑刚改的 MMIO 写通路（`rv32_soc.v` 里把三处 `core_wr_i` 的
`& ~mmio_ack_q` 去掉）。**不是。** MMIO 逐笔流水显示 §9 之前的读写每一笔都正常 ack，
冻结发生在 §9 的某次读之后。

**根因**　三层叠起来才炸的，前两层是"设计如此"，第三层才是放大器：

1. `rtl/srp/rv32_steer.v:53` 的 `lut_mem` **故意不带复位、不带初值**
   （写口放进带 `negedge rst_n_i` 的块会让 BRAM 推断失败，issue 060 / 080 踩过两次）。
2. **生产路径上没有任何地方装它。** `fw_steer.c` 连 `S_WDATA` 宏都没有；
   `sw/ps_main.c` 只清 GSC 的系数 bank（`zero_coef_bank()`），完全不碰 steer 窗口 0x600；
   所有 SoC 级 TB 把 `steer_cfg_*` 接 0；`scripts/gen_synth_top.tcl` 也接 0。
   全仓库唯二会装表的是专用块 TB `tb/tb_steer.v` / `tb/tb_steer_regs.v`。
   ⇒ §9 那一趟读回的 `comp_out[]` 全是 X。
3. X 通过取指阶段污染整个核：`rv32_fetch_stage.v:48` 是
   `assign pc_d = redirect_i ? redirect_pc_i : ...`。固件在 `fw_steer_query` 的
   `0x2108 beqz a3, 2110` 上**拿 X 做分支** ⇒ `redirect_i` 变 X ⇒ 三元式做
   **按位 X 合并**（不是"选一路"）⇒ `pc_d` 变 X；而 `pc_enable` 仍是 1
   ⇒ `pc_q` 被写进 X ⇒ 取指指令字 X ⇒ 译码与所有流水线使能变 X
   ⇒ Verilog 里 `if (X)` 判假 ⇒ **所有寄存器永不更新 = 零退休的永久冻结**。

硅上不会出现这一条（真值总是确定的），它是被「LUT 没装」引爆的**仿真失效**；
但引爆它的那个缺口是真的：**芯片上电后到 PS 装表之前，转向块读出来的就是垃圾。**

**修法**　两处，归属不同：

- **真机（还没做）**：`sw/ps_main.c` 加 `load_steer_lut()`，照 `zero_coef_bank()`
  的样子放在 `wr(R_CTRL, 0)` 放核**之前**，带回读校验。
- **TB（本次已做）**：六个 TB 在 `rst_n = 1'b1;` 之后调一次 `load_steer_lut()`，
  经 `steer_cfg_*`（= 壳的 `ps_*` 口，即真机上 PS 走的同一条路）灌 2048 条：
  `CTRL=2 → ADDR=0(SEL=LUT) → 2048× WDATA`。写法照抄 `tb/tb_steer_regs.v:131-134`。

**复现/指纹**　不用跑整固件。`build/scratch/gen_steer_repro.py` 把 `sw/fw/fw.elf` 里
`fw_steer_init`(0x2070) / `fw_steer_query`(0x2090) 的**原机器码**搬到 ITCM，配一个驱动，
20k~33k 拍内出结果：

| TB | 结局 |
|---|---|
| `build/scratch/tb_steer_repro.v`（不装 LUT） | 死在 `0x2108`，`fetch_pc = xxxxxxxx`，退休 32932 |
| `build/scratch/tb_steer_lut.v`（经 PS 窗口装 2048 条） | `rc = 0`，退休 33032 / 33030 拍，`fetch_pc = 0x3C` |

⇒ 下次认这个病：**「退休数停在一个固定值 + `fetch_pc` 读出 x」**，先去看那块
没有复位的 BRAM 有没有人装。


---

## 复跑确认（2026-10-06 21:28）

把 `load_steer_lut()` 补进六个 TB（`build/scratch/patch_tb_steerlut.py`，改的是
`tb/` 下五个 + 这次新写的探针）之后，**五个固件 TB 全部跑完**：

| TB | 结局 | 用时 |
|---|---|---|
| `tb_fw_fft` | **PASS** | 3456 s |
| `tb_fw_gcc` | **PASS** | 3432 s |
| `tb_fw_srp` | **PASS** | 3441 s |
| `tb_fw_das` | **PASS** | 3469 s |
| `tb_fw_gsc` | **PASS** | 3443 s |

五份输出**一字不差地**停在 `11,678,233 拍 / 退休 8,178,695 条指令`——同一个固件
整轮，确定性复现。对照冻结时的指纹（做过 vec-bank poke 的停在 **7782978**、
没做的停在 **6471367**）：可以确认**冻结就是本条**，不是 072 那次 MMIO 写通路
的连带。

**其中 `tb_fw_srp` 正是 2026-10-06 早些时候报"红"的那个**，而且**验收数一个没变**
（延迟转储 `0/256` 不符、累加器 `0/256` 不符、峰值格号固件 224 / 参照 224、
DAS 校验和 固件 23766 / 参照 23766）。也就是说：**固件镜像没错、判据没错，
红的就是这条 084** —— §9 把核冻死后走不到后面的 GSC 段，了结标记因此不再出现。

⚠ **真机侧仍未修**：`sw/ps_main.c` 里 `grep steer` 一个结果都没有，生产路径上
依然没有任何地方装那张 LUT。TB 里的预装是**替真机模拟 PS 的上电时序**，
不等于板子上就有人喂它。
