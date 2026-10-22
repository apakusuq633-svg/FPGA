# 058 `rv32_fft_addr` 注释写「没有乘法器」，代码里有 9 个

**症状** 修完 [057](057-first-real-timing-measurement.md) 的 VPHAT 之后，最差路径
**整条换到了 `u_fft_bfly`**，源是它自己的 `stage_q`/`cyc_q`，终点是 bank RAM 的
**读地址**：

```
Source:      .../u_fft_bfly/stage_q_reg[2]_replica/C
Destination: .../u_fft_bfly/g_bank[6].mem_reg_r2_0_63_15_17/RAMA/I
Data Path Delay: 28.678ns  (logic 14.708 + route 13.970)
Logic Levels:    26  (CARRY4=13 DSP48E1=3 LUT6=6 ...)
```

**关键线索是 `DSP48E1=3`**：DSP48 长在一条「算地址」的路上，那只可能是**乘法器**。

**误判** 一开始怀疑是 `wa_8`/`a_g` 那一串移位加法太深，或者 LUTRAM 读地址的扇出
（`ADDRA3` 那条网扇出 256）。都不是 —— 那些是 1〜2 级的事。

**根因** `rtl/acoustic/rv32_fft_addr.v` 里 9 处写了乘法：

```verilog
wire [10:0] step  = 11'd1024 >> (stage_i + 4'd1);   // = 2^(9−stage)，是 2 的幂
wire [10:0] tw_8 = j_l * step;                      // 每 lane 一个
assign tw_o[g*10 +: 10] = mode8 ? tw_8[9:0] : (j_g * step);
```

而**同一个文件的头注释**写着：

> 全部是移位与位与，**没有乘法器、没有除法器**（half、len、step 都是 2 的幂）。

**注释描述的是设计意图，代码没有照着写。** `step` 确实是 2 的幂，所以
`j * step` 完全等价于 `j << (9 − stage)` —— 但综合器看不懂「step 是 2 的幂」
这件事（它是运行期算出来的），于是老老实实做了 9 个乘法器。

**它藏了两个星期**：`docs/issues/039` 让这台机器连 4 行 blink 都综合不了，
**代码里所有"综合时会怎样"的断言，在那段时间里一条都没被验证过** ——
包括这条注释。（和 [053](053-fft-storage-not-inferred.md) 是同一个成因。）

**修法** 换成显式移位。`step` 这个信号随之没人用，一并删掉：

```verilog
wire [3:0] sh = 4'd9 - stage_i;                     // ∈ {1..9}
wire [10:0] tw_8 = j_l << sh;                       // j_l ≤ half−1 ⇒ 结果 < 512
```

**等价性不是推的，是量的**：`tb/tb_fft_addr` **384 拍 / 2304 个蝶形逐拍一致**，
`tb/tb_fft_bfly` **513/513 条 bin 保持不变**。

**复现/指纹**
- **路径上出现 `DSP48E1` 而你以为是纯地址运算** ⇒ 去找乘法器。
- **注释里写着"没有乘法器/全是移位"，代码里出现 `*`** ⇒ 以代码为准。
  这类注释比没有注释更危险：它让人**不去看**那一行。
