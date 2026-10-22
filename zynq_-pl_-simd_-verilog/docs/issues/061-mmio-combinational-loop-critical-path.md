# 061 —— WNS 最差的一族是「MMIO 组合闭环」，不是 FFT

**发现日期**：2026-10-03（读 `build/timing_zynq.rpt` 逐条路径）
**状态**：修法已实现（MMIO 改隔拍应答），**实测待 flow12 出具**（见 §5）
**相关**：[057](057-first-real-timing-measurement.md)（第一次真实测量）、
[060](060-acoustic-ext-storage-not-inferred.md)（降 LUT 不解决时序）

---

## 1. 症状

上一轮（`WNS = -0.777 ns`，189 个失败端点，2026-10-03 16:06 的报告）
我之前只看了汇总数字就下结论说"是 FFT 或者布线拥塞"。**打开报告看具体路径，
前三条全是同一族、而且和 FFT 无关**：

| # | Slack | 源 | 汇 | 级数 | 逻辑/布线 |
|---|---:|---|---|---:|---|
| 1 | -0.777 | `u_ex_mem_reg/…/q_o_reg[6]` | `…/q_o_reg[108]` | 34 | 11.09 / 14.31 |
| 2 | -0.774 | 同上 `[6]` | `…/q_o_reg[107]` | 34 | 11.02 / 14.43 |
| 3 | -0.752 | 同上 `[6]` | `…/q_o_reg[110]` | 35 | 11.32 / 14.06 |

**源和汇都是同一个寄存器组 `u_ex_mem_reg/u_pipeline_reg/u_payload_dff`** ——
一条从 payload 出发、绕一圈又回到 payload 的组合路径。

## 2. 根因：出核再回来的那条闭环

把第 1 条的中间节点按顺序摊开（`timing_zynq.rpt` 第 208 行起）：

```
q_o_reg[6] ──exmem_mem_read──> misaligned ──> dmem_req
   ──> dmem_mmio ──> dmem_write ──> mmio_read
   ──> rd_anc_q[15]_i_20 ──> rd_anc_q[23]_i_16 ──> rd_anc_q[23]_i_8
   ──> q_o[67]_i_3 ──> dmem_rdata[23]
   ──> selected_half[7] ──> q_o[52]_i_1 ──> mem_forward_data[8]
   ──> ex_div_b[8] ──> DSP48E1 ──> … ──> q_o_reg[108]/D
```

即：

```
ex_mem payload → dmem_req → MMIO 译码 → 外设回读多路选择（rd_anc_q…）
   → dmem_rdata → load 结果 → 转发进 id_ex → 乘法器 → 回到 ex_mem payload
```

**这一段是纯组合的，而且出了核又回来。** 从 `dmem_req`（6.99 ns）到
`dmem_rdata[23]`（14.50 ns）是 **7.5 ns**，占这条 25.4 ns 路径的 **30%**。

为什么以前没被抓到：**`dmem_ready` 恒为 1**（MMIO 一拍应答），
所以核把「发请求」和「收数据」当成同一拍的事 —— 这在功能上没错，
但在物理上把整条外设回读路径塞进了一个时钟周期。

## 3. 修法：MMIO 改隔拍应答

`rtl/soc/rv32_soc.v`：读数据在**请求拍**采样，应答在**下一拍**给出。

```verilog
always @(posedge clk_i or negedge rst_n_i) begin
  if (!rst_n_i) begin
    mmio_ack_q   <= 1'b0;
    mmio_rdata_q <= 32'b0;
  end else begin
    mmio_ack_q   <= dmem_mmio & ~mmio_ack_q;   // ← 一次性，不能只写 dmem_mmio
    mmio_rdata_q <= mmio_rdata;                // ← 在请求拍采样
  end
end
assign dmem_ready = dmem_mmio ? mmio_ack_q   : dtcm_ready;
assign dmem_rdata = dmem_mmio ? mmio_rdata_q : dtcm_rdata;
```

改完组合链被切成两段：

```
拍 0：payload → dmem_req → dmem_mmio → 外设回读 → mmio_rdata_q（寄存器）
拍 1：mmio_rdata_q → 转发 → 乘法器 → payload
```

7.5 ns 那一段整段消失。

**DTCM 那条路不用改**：它本来就是隔拍应答（同一份 `*_ack_q` 形状），
所以这两条路现在协议一致了 —— 是一个**归一化**，不是新增特例。

## 4. 两个误判（都写进代码了）

### 4.1 `mmio_ack_q <= dmem_mmio` 会让下一次访问提前"完成"

第一版写成 `mmio_ack_q <= dmem_mmio`。指纹：`tb_rv32_ps` 里
**`sw` 紧接着 `lw` 时，`lw` 在第一拍就 ready，采到的是 0**
（`DTCM[1] == 0x00000000`，期望 `0x00000002`）。
因为 `mmio_ack_q` 还是上一笔的高电平，泄漏进了下一笔的请求拍。
改成 DTCM 那份现成的 `& ~mmio_ack_q`（一次性）即对。

### 4.2 改协议会波及"假设旧协议"的外设 —— 只有扫全仓才抓得住

`rv32_audio_regs.v:96` 的注释白纸黑字写着
「MMIO 读**每笔访问恰好一拍**（`dmem_ready` 恒 1）」，
RX FIFO 的 `rx_pop` 是**电平**触发、直接拿 `core_rd_i` 去弹指针。
应答晚一拍 ⇒ 弹出会跨两拍发生 ⇒ **弹两次**。

修法是把它限定在**采样拍**：

```verilog
.core_rd_i (mmio_read & mmio_aud_win & ~mmio_ack_q),
```

**教训**：改一个全局协议时，光看"谁产生这个信号"不够，要**反查谁消费了
这个信号的隐含时序假设**。我把全仓 `dmem_ready` / `core_rd_i` / `mmio_read`
三组都扫了一遍，只有音频这一处有**读副作用**；
ANC 那处（`rv32_anc_regs.v:428`）只拿 `core_rd_i` 当读地址多路选择，
它的 `fifo_ovfl_q` 清除是复位/`fifo_clr` 驱动的，**没有读副作用**，不用改。

**⚠ 覆盖缺口**：`tb_audio_loop` 在**加与不加**那个 `& ~mmio_ack_q` 两种情况下
都 PASS（34 帧、24 条检查、0 丢失）—— 说明这个 TB 测不出"弹两次"
（多半是 FIFO 不深、帧率不匹配就撞不上）。**这次是靠读代码抓的，不是靠 TB。**

## 5. 验证

| 项 | 状态 |
|---|---|
| `tb_rv32_soc` | PASS ✓（771 拍 / 66 存 / 17 取） |
| `tb_rv32_ps` | PASS ✓（5153 拍） |
| `tb_led_demo` | PASS ✓（214 拍 / 7 步 / 2 心跳） |
| `tb_audio_loop` | PASS ✓（34 帧解码 / 24 查 / 0 丢失） |
| 时序实测 | **待 flow12**（见下） |

**预测**：前三条（-0.777 / -0.774 / -0.752）应转正，因为被切掉的 7.5 ns
远超需要的 0.78 ns。

**但 WNS 大概不会到 0** —— 报告里还有**第二族**，与 MMIO 无关（见 §6）。

## 6. 还站着的第二族：FFT 蝶形里"一拍串完读+乘+加"

同一份报告第 656 / 786 / 930 条：

| # | Slack | 源 | 汇 | 级数 | 构成 |
|---|---:|---|---|---:|---|
| 4 | -0.738 | `u_fft_bfly/stage_q_reg[1]_replica_3` | `g_bank[6]/mem_reg_r2_0_63_3_5/RAMB` | 24 | CARRY4=10, DSP=2 |
| 5 | -0.722 | `u_fft_bfly/cyc_q_reg[2]` | `g_bank[2]/mem_reg_r2_0_63_15_17/RAMA` | 30 | **CARRY4=17**, DSP=2 |
| 6 | -0.679 | `u_fft_bfly/cyc_q_reg[2]` | `g_bank[3]/mem_reg_r1_0_63_12_14/RAMA` | 29 | CARRY4=16, DSP=2 |

路径形状（第 5 条的节点序列）：

```
cyc_q → u_addr/wa_8[6]（地址进位链）→ wb[7] → bank 读地址
   → RAMD64E 异步读 → bq_b[4][8]
   → i___628 → CARRY4×2 → DSP48E1 → str20_i_* CARRY4 链 → bank 写口
```

对应 `rv32_fft_bfly.v:264-270`：

```verilog
tr  = (wr*br - wi*bi + 8192) >>> 14;   // DSP ×2 + 32 位加减链
a2r = (ar + tr + 1) >>> 1;             // 再一条 32 位加链
```

**这是当初换存储时主动接受的代价**：分布式 RAM 是**异步读**，
省掉了 BRAM 的读延迟（mode4 才能一拍一组），代价是
**异步读被串进了同一拍**，于是「地址 → 读 → 复数乘 → 加 → 写」全在一拍里。

**注意这里有一处不能忘的背景**（见 `rv32_fft_bfly.v:213-222` 的注释）：
地址 mux 的选择端**一律用寄存器 `state_q`，绝不能用组合的 `push_fire`** ——
实测那样会有 32 级逻辑、30.6 ns 打到 `g_bank[*]/RAMC`。
所以修这一族**不能靠"把选择端再往前挪"**，那是已经走过的错路。

> **✅ 2026-10-04 结果**：第二条族最后由
> [062](062-fft-butterfly-read-compute-pipeline.md) 解决 —— 走的是**第 1 条**
> （在读/算之间插一级寄存器），但不是"把 `tr`/`ti` 寄存一拍"那种要加 192 拍的代价，
> 而是**免费**的：枚举证明同级内相邻两组地址不相交，只有级边界要各加 1 拍 ⇒ **+9 拍**。
> 第 2、3 条（DSP MACC 级联、Pblock）**都没用上**。
> 最终 **`WNS = +0.726 ns` / 失败端点 0**。

**当时列的三条（按代价排序；第 1 条即最终采用的那条）**：

1. **把 `tr`/`ti` 寄存一拍**（最稳）。读与乘加分到两拍 ⇒ 链被切断。
   mode4 每级 64 组 × 3 级 = **+192 拍**（900 → 1092，仍远小于标量 198905）。
   代价：`tb_fft_bfly` / `tb_fw_fft` 的**期望拍数要改，但 513 条 bin 值不变**。
2. **让 `wr*br - wi*bi + 8192` 落成 DSP 的 MACC 级联**（PCIN 串接），
   把 8192 与两个积的和挪进 DSP 内部 ⇒ 少掉约 8 个 CARRY4。**不加拍**，
   但依赖综合器是否愿意推（要先写小模板实测，照 [053] 的做法）。
3. **给 `u_fft_bfly` 加 Pblock**。第 5 条的布线占 12.89 ns（50%），
   物理跨度极大（`SLICE_X67Y16 → DSP_X2Y0 → SLICE_X35Y2` —— DSP 被拉到
   离逻辑 30 列以外）。**这条我还没试过**，且不动 RTL、零功能风险。
   ⚠ 但 Pblock 也可能把结果弄得更差，必须先在小规模上量。

## 7. 复现指纹

- **第 1 族（MMIO）**：报告里前几条的**源与汇是同一组 `u_ex_mem_reg` 寄存器**，
  路径中间能看到 `dmem_mmio` / `mmio_read` / `rd_anc_q*` / `dmem_rdata` 这些**核外名字**。
  > 判据：**源和汇都在核里、路径却跑到核外再回来** ⇒ 就是这一类。
- **第 2 族（FFT）**：源是 `u_fft_bfly/cyc_q` 或 `stage_q`，汇是
  `g_bank[*]/mem_reg_*`，级数 24~30 且 **CARRY4 占一多半**、**必有 DSP48E1**。
- **第 3 族（已修，勿重蹈）**：源在核里、汇是 `g_bank[*]/RAMC`、
  逻辑 32 级、30.6 ns ⇒ 那是**拿组合的 `push_fire` 当选址 mux 选择端**，
  见 `rv32_fft_bfly.v:213-222`，**不要"修"，要回退**。
