# 001 iverilog 敏感表死循环

**症状** 整个 SoC 验证瘫掉：`tb_rv32_soc`、`tb_led_demo` 跑起来**一行输出都没有**，
被超时杀掉。换 VCS/Vivado 仿真看不出来。

**误判** 一开始以为是新加的 ANC 外设把设计搞挂了，或者 TB 例化漏了端口导致 X 传播。

**根因** 为了在组合读口里按槽号索引数组，把读译码写成了：

```verilog
task anc_read; input [6:0] a; output [31:0] d; ... endtask
always @(*) anc_read(core_addr_i, core_rdata_q);
always @(*) anc_read(ps_addr_i,   ps_rdata_q);
```

task 的 output 实参 + 内部的**变址数组读**（`freq_q[a[3:2]]` 之类）会让 iverilog 的
敏感表自激，仿真时间不再推进。同一个 task 被两个 `@(*)` 调用会加重这个问题。

附带第二个毛病：`@(*)` 对 task 只列实参，地址不变时 `core_rdata_q` 不更新 ——
PS 轮询 STATUS 永远读到旧值。

**修法** 摊成一个普通 `always` 块 + 地址预选（`wire [6:0] raddr = core_rd_i ? core_addr_i : ps_addr_i`），
不用 task。两个读口共用一份译码。

**复现/指纹** TB **零输出**且超时 —— 不是"跑错"，是"没跑"。任何"仿真卡住但编译干净"
的情况，先怀疑敏感表，别怀疑逻辑。
