# 037 iverilog 收下 SystemVerilog，Vivado 拒绝整个文件

**症状** `launch_runs synth_1` 在读文件阶段就失败，整个 run 没开始综合：

```
ERROR: [Synth 8-2301] loop variable declaration is not allowed in this mode of verilog
  [rtl/acoustic/rv32_acoustic_ext.v:192]
WARNING: [Synth 8-6901] identifier 'k' is used before its declaration [...:234]
Failed to read verilog '.../rtl/acoustic/rv32_acoustic_ext.v'
```

**误判** 我先把 **24 个 testbench 全绿**当成了「这份 RTL 是好的」，于是把
「资源与时序」当成一件纯跑腿的事排到最后。**TB 全绿只证明仿真语义对，
不证明这份源码是 Vivado 收得下的 Verilog。** 这两件事没有因果关系
（CLAUDE.md §0 那句「testbench 通过 ≠ 时序修好」的另一个面）。

**根因** `for` 的初始化式里声明变量是 **SystemVerilog** 语法，不是 Verilog-2001/2005：

```verilog
for (integer b = 15; b >= 0; b = b - 1) begin   // ← SV
```

- `iverilog -g2005` **宽容地收下了**（所以 TB 一路全绿，什么都不会报）
- Vivado 的默认 Verilog 模式（非 `-sv`）直接拒绝**整个文件**

附带第二条：`integer k;` 声明在**使用它的 `always` 之后**。这条 Vivado 只给
warning（下一条同类的会变成 error），但同一类毛病，一起修了。

**修法** 两处都改成 Verilog-2001 写法（`rtl/acoustic/rv32_acoustic_ext.v`）：

1. `recip_q14` 里把 `integer b;` 挪到函数声明区，循环写成 `for (b = 15; ...)`
2. 把 `integer k;` 挪到那个组合 `always` **之前**

复跑 `tb_acoustic_ext` 仍然 **PASS**（改的是声明位置，不是语义）——
但**这一条不算验收**，验收是 `synth_design` 能过（下一段）。

**顺手排掉的一类**：全项目 grep `for (integer|int|genvar) ... =` 只有这一处；
`rv32_fft_bfly.v` 与 `rv32_fft_addr.v` 本来就是规范写法
（`genvar g;` / `integer b;` 都在使用之前声明）。

**复现指纹** **TB 全绿 + `synth_design` 在读文件阶段就报错** ⇒ 先查
SV-only 语法（`for` 里声明变量、`logic`、`always_ff`、`typedef`）。
把「能综合」当成一道独立的验收项，别拿 TB 全绿替代它。
