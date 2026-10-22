# 047 TB 在时钟沿用阻塞赋值驱动输入 ⇒ 组合逻辑竞争，DUT 走错分支

**症状** `tb_pdm_capture` 段 4：RELEASE 写入后 bank 的就绪位**没有被清掉**，
而且错误计数 `ack_errors_q` 涨了 1 —— 说明 DUT 走进了 `else`（拒绝）分支。

在写脉冲**当中**（`#0.5` 采样）打出判据信号，结果是：

```
PROBE rel_ok=1 ready=01 sel=0 ack=0 sseq=0 cr=0
DBG after release: ready=01 ack_err=1
```

**判据 `release_ok` 明明是 1，DUT 却拒绝了。** 这两个观测直接矛盾。

**误判** 先怀疑 `selected_ready` / `ack_seq_q == selected_seq` 在那一拍不成立，
于是去查 `ready_q`、`select_q`、序号语义，来回推了两轮时序。方向错了 ——
信号值本身是对的，错的是**它们被采样到的时刻**。

**根因** TB 的 `cfg_write` 把 `awr/aaddr/awdata` 用**阻塞赋值**贴着 `posedge clk` 写：

```verilog
@(posedge clk);
awr = 1'b1; aaddr = a; awdata = d;   // ← 和 DUT 的 always 块抢同一个时刻
```

`release_ok` 是**连续赋值**（`assign`），它要等 `cfg_wr_i` 变化之后才重算。
在同一时刻里，DUT 的 always 块可能先读到 `cfg_wr_i = 1`（所以外层 `if` 成立、
`ack_errors` 照样涨），但读 `release_ok` 时那个连续赋值**还没重算**，拿到旧值 0。
两个观测因此互相矛盾 —— 而波形上完全看不出来，因为都是同一时刻的值。

**修法** 所有激励改成**沿之后 1 ns 再改**：

```verilog
@(posedge clk); #1;
awr = 1'b1; aaddr = a; awdata = d;
```

这样到下一个时钟沿时信号早已稳定，DUT 与本 TB 看到的是同一组值。
改完段 4/5/7 一起转绿。

**复现指纹** 「判据在脉冲当中读出来是对的，DUT 却走了另一条分支」——
**一律先怀疑 TB 的驱动时刻，不要怀疑 DUT**。
凡是 TB 用阻塞赋值贴着时钟沿驱动输入、而被驱动模块里有连续赋值参与判断，
就有这个洞。
