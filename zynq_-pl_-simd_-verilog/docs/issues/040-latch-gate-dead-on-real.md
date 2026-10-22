# 040 「no latches」门禁是死的 —— yosys 在第 43 个文件就中止了

**症状**

`scripts/verify.ps1` 第 6 项「no latches」长期 FAIL，信息是：

```
[FAIL] no latches
       yosys assertion failed, see build/verify_latch.log (0 'Latch inferred' lines)
```

「0 条 Latch inferred」按该项自己的判据（`$latchLines -gt 0` 才失败）本该是**通过**，
却报了失败。两个信号互相矛盾。

**误判**

容易往三个方向查，全是错的：

1. 以为设计里真出现了 latch，去翻 RTL 找不完整的 `if`/`case`
2. 以为 yosys 版本或参数问题，去调 `-g2005` / 换 `select` 写法
3. 以为 `$dlatch` 那组断言写错了，去改断言本身

真正的线索是那句 `(0 'Latch inferred' lines)` —— **它不是"没有 latch"，是"根本没跑到能推断 latch 的那一步"**。

**根因**

`rtl/gcc/rv32_xspec_phat.v` 的倒数 LUT 生成函数里用了 `real`：

```verilog
function [15:0] inv_lut;
  input [LUT_BITS-1:0] idx;
  real x;                                  // ← yosys 前端解析不了
  x = 1.0 + (idx + 0.5) / (1 << LUT_BITS);
  inv_lut = $rtoi(1.0 / x * 32768.0);
endfunction
```

yosys 直接：

```
43. Executing Verilog-2005 frontend: rtl/gcc/rv32_xspec_phat.v
rtl/gcc/rv32_xspec_phat.v:149: ERROR: syntax error, unexpected TOK_REAL
```

`read_verilog` 读的是 `scripts/filelist.f` 里 52 个 rtl 文件中的**第 43 个**，
于是后面 9 个文件从没被读进来。而 `hierarchy -top` 要 elaborate 的两个顶层
—— `rtl/soc/rv32_soc.v` 与 `rtl/soc/rv32_ps_top.v` —— **正好排在第 51、52 位**。

所以 `select -assert-none t:$dlatch ...` 从来没执行过：

> **这条门禁既不可能通过，也什么都没检查。** 它自 `rv32_xspec_phat.v` 进 filelist
> 起就是死的，一直报红。看惯了红就不再看了 —— 这才是它能藏这么久的原因。

`latchLines` 为 0 不是因为设计干净，是因为 yosys 在能推断 latch 之前就死了。

**修法**

把 LUT 生成从 `real`/`$rtoi` 改成整数运算：

```verilog
den     = (1 << (LUT_BITS + 1)) + 2 * idx + 1;
inv_lut = (32768 * (1 << (LUT_BITS + 1))) / den;
```

推导：`1 / (1 + (idx+0.5)/2^L) = 2^(L+1) / (2^(L+1) + 2*idx + 1)`。全是正数，
整数除法的向零截断与 `$rtoi` 行为一致。

**逐值等价已核对**：LUT_BITS = 1..10 的**全部条目**，实数写法与整数写法 0 处不一致
（LUT_BITS=4 时是 16 个条目，如 `idx=0 → 31775`、`idx=15 → 16644`）。
`tb/tb_xspec_phat.v` PASS（1173 拍）。

顺带清掉一个毛病：合成 RTL 里本来就不该出现 `real`。
注意 `32768*2^(LUT_BITS+1)` 在 LUT_BITS ≥ 15 时溢出 32 位；实用值是 4。

**复现指纹**

- `yosys build/verify_latch.ys` 退出码非 0，日志里有 `unexpected TOK_REAL`
- 日志里 `read_verilog` 只执行到第 43 步（`filelist.f` 共 52 个 rtl 文件）
- `grep -rn "real " rtl/` 有命中（只查 `rtl/`，TB 里用 `real` 是允许的）
- 判据本身：**报 FAIL 但 `Latch inferred` 计数为 0** —— 这个组合只可能来自
  "yosys 没跑完"，不可能来自"真的推不出 latch"
