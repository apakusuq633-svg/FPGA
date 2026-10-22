# 081　函数里的「常量 / 变量」除法综合成了真除法器 ⇒ 首次进网表就破 19 ns

**症状** 把 `rv32_xspec_phat` 接进 SoC 之后**第一次**跑完整实现：

```
WNS = −19.125 ns，TNS −630，失效端点 80
```

而接进来之前本机是 **+0.461 / 0 端点**。功能侧一切正常（`tb_xspec_phat`、
`tb_xspec_regs` 全绿）。

**误判** 第一反应是"新加的两块太重了"，去算 BRAM 够不够 —— 方向错了
（真正的问题是**别的东西**；BRAM 只从 26 涨到 29，很轻）。
第二个误判是"是不是声学专用指令把时序压坏了" —— 不是：
`git status rtl/acoustic/ rtl/vec/` 是空的，**声学扩展与 VFFT 一个字都没碰**。

**根因** 失效路径全部指向同一处，源/目的地**都在 `rv32_xspec_phat` 内部**：

```
u_xsp/u_xsp/midx2_q_reg[0]  →  pr3_q_reg[*]
46.284 ns，64 级逻辑，38 个 CARRY4 + 2 个 DSP48E1
```

级 3 里只有一样东西能出几十个 CARRY4 —— 倒数 LUT 的函数：

```verilog
function [15:0] inv_lut;
  input [LUT_BITS-1:0] idx;
  reg [31:0] den;
  begin
    den     = (1 << (LUT_BITS + 1)) + 2 * idx + 1;
    inv_lut = (32768 * (1 << (LUT_BITS + 1))) / den;   // ← 分子常量，分母是变量
  end
endfunction
```

作者显然以为这是"常量除法会被折掉"（注释里还讨论了 LUT_BITS≥15 时溢出的边界）。
**但分母 `den` 随 idx 变 ⇒ 这不是常量除法**，Vivado 老老实实综合了一个
32 位除法器（≈32 级 CARRY4 ✓ 数量级正好对上）。

**修法** 同一个公式，改成**在展开期用整型常量求值、运行期只查表**：

```verilog
function [15:0] inv_lut_calc;
  input integer i;                    // **常量**入参
  begin
    inv_lut_calc = (32768 * (1 << (LUT_BITS + 1))) /
                   ((1 << (LUT_BITS + 1)) + 2 * i + 1);
  end
endfunction

localparam integer INV_N = (1 << LUT_BITS);
reg [15:0] inv_tab [0:INV_N-1];
integer it;
initial for (it = 0; it < INV_N; it = it + 1) inv_tab[it] = inv_lut_calc(it);
// 级 3：inv = inv_tab[midx2_q];
```

LUT_BITS=4 ⇒ 16 条，一个 LUT 级。**延迟不变**（仍 3 拍），
`tb_xspec_phat` 仍 **1173 拍**、幅值/共线判据全过 ⇒ 数值**逐位相同**。

**结果**：WNS **−19.125 → +1.051 ns**，失效端点 **80 → 0**，LUT 23077 → 22911
（表比除法器还小）。

**复现/指纹** ①「一个新块的失效端点**全部**集中在它自己内部的一条路径上」⇒
先去找那条路径上**最贵的一个算子**，别去算资源够不够。
②「函数体里有除法/取模，而分母依赖入参」⇒ 它**永远不会**被常量折叠。
RTL 里的除法只有两种安全形态：**常量除法**，或者**查表**。

⚠⚠ 最值得记的一条：**这块 RTL 从没进过网表**（没被任何模块实例化 ⇒ 综合时被剪掉），
所以这个数从写下那天起就存在、却**从没被量到**。
`tb_xspec_phat` 只验功能。这是"**TB 全绿 ≠ 能综合 ≠ 装得下 ≠ 时序收敛**"的第四关，
与 [053](053-fft-storage-not-inferred.md)、[060](060-acoustic-ext-storage-not-inferred.md)、
[080](080-bram-write-in-reset-block-again.md) 同族 —— 那三条都是"综合出来的东西和写的东西不是一回事"。
