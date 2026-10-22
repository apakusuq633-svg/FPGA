# 080　缓冲写口放进带异步复位的块 ⇒ BRAM 推断失败、place 装不下（060 的复发）

**症状** 新加的 `rv32_xsp_regs` 功能全对（`tb_xspec_regs` 段段 PASS），
综合也过（`SYNTH_OK`），**实现阶段挂在 place**：

```
ERROR: [Place 30-487] ... 13300 slices in the device, of which 10934 are available,
however, the unplaced instances require 12439 slices.
ERROR: [Place 30-99] Placer failed with error: 'Detail Placement failed'
FLOW_FAIL: impl_1 没到 100%（progress = 40%）
```

要 12439 个 slice，只有 10934 可用 —— 比基线（台账 §2.1 记的 7855）多了 **4584**。

**误判** 第一反应是"两个 wrapper 本身太重"（SRP 那块满配才 ~111 KB BRAM，
小档位才十几 KB）。于是去算 BRAM 够不够 —— 方向就错了：
**问题不是 BRAM 不够，是 BRAM 根本没被用上**。

**根因** `xi_mem` / `xj_mem` / `psi_mem` 三条 513×32 缓冲的**写口被写在了
带 `negedge rst_n_i` 的那个大 always 块里**。**BRAM 没有复位端** ⇒ 推断直接失败
⇒ 退回触发器 + 多路选择：3 × 513 × 32 ≈ **49k 位**，折合约 6k 个 slice ✓
数量级正好对上。

这就是 [060](060-acoustic-ext-storage-not-inferred.md) 写下的那半句：
**「写口减到 1」只是前半句，后半句是「写所在的块不能带异步复位」**。
规则早就在档案里，我没在写新代码时主动套用它。

**修法** 三条缓冲的**读口与写口各自独立成块**，且都**不带异步复位**：

```verilog
always @(posedge clk_i) begin          // 读：地址寄存 + 数据寄存（同步读）
  xi_r_q   <= xi_mem[addr_q];
  xj_r_q   <= xj_mem[addr_q];
  psi_rd_q <= psi_mem[idx_q];
end

always @(posedge clk_i) begin          // 写：host 写 XI/XJ，收数逻辑写 Ψ
  if (wdata_ok) begin
    if (sel_q == S_XI) xi_mem[idx_q] <= wdata;
    else               xj_mem[idx_q] <= wdata;
  end
  if (out_valid_o) psi_mem[bin_o[AW-1:0]] <= {pi_o, pr_o};
end
```

回归：两个 TB（`tb_xspec_regs` / `tb_loc_core`）修复后**仍全绿** ——
改的只是综合结构，行为逐位不变。

**复现/指纹** 「功能全对、综合也过，**卡在 place 且缺口是几千个 slice 量级**」——
立刻去查**哪块存储没被推断成 RAM**（`report_utilization -hierarchical` 看
`LUTRAMs`/`RAMB` 是否为 0），而不是去算 BRAM 够不够。
另一条更值钱的指纹：**TB 全绿 ≠ 装得下** —— 这是第五次同类的"三道关/四道关"提醒
（[039](039-synth-native-crash.md)/[040](040-latch-gate-dead-on-real.md) 是前四次里的两次）。
