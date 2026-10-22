# 038 `$readmemh` 写相对路径 ⇒ 综合出一张空 ROM（而且资源数更好看）

**症状** 综合日志里两条 CRITICAL WARNING，**不中断流程**：

```
CRITICAL WARNING: [Synth 8-4445] could not open $readmem data file 'build/fft_tw.hex'
  [rtl/acoustic/rv32_fft_bfly.v:63]
CRITICAL WARNING: [Synth 8-4445] could not open $readmem data file 'sw/nco_table.hex'
  [rtl/anc/rv32_anc_regs.v:131]
```

**误判** 这条是 **CRITICAL WARNING 不是 ERROR**，综合照跑、`synth_1` 能到 100%，
所以很容易被当成噪音划过去。而且它**在 TB 里永远复现不了** ——
iverilog 从仓库根跑，相对路径是对的，24 个 TB 全绿。

**根因** 相对路径是相对**进程工作目录**解析的，而 Vivado 综合时的工作目录是
**run 目录**（`vivado/rv32_pipeline.runs/synth_1/`），不是仓库根。
所以 `build/fft_tw.hex` 一定找不到。

**代价特别阴**，两个方向都很难发现：

| ROM | 空了的后果 |
|---|---|
| 旋转因子（`fft_tw.hex`） | 乘 0 ⇒ **乘法器被综合优化掉** ⇒ **资源数反而好看**，而 FFT 是错的 |
| NCO 正弦表（`nco_table.hex`） | NCO 出来的正弦恒为 0 |

「资源数反而好看」这一条是关键：它会让人**误以为新单元很便宜**。

**这一条不是 VFFT 引入的** —— `sw/nco_table.hex` 那处在 `rtl/anc/rv32_anc_regs.v`
（⚠ 那个文件连同整条 ANC 通路已于 2026-10-06 移除，所以下面**只剩旋转因子这一处**
还在树里，而它正是需要 `FFT_TW_FILE` 那条 `verilog_define` 的原因 —— 这条教训**今天照样**
要按它办），
是**既有代码**。也就是说裸 PL 流程此前产出的设计里，NCO 表一直是空的。

**修法** 照本项目**已有**的既定做法：`rtl/soc/rv32_itcm.v` 的 `MEM_FILE`、
`gen_synth_top.tcl` 把**绝对路径**烘进去 —— 那条路是好的。给两个 ROM 加
`ifdef` 覆盖，综合脚本传绝对路径，没定义时退回相对路径给 TB 用：

```verilog
initial begin
`ifdef FFT_TW_FILE
  $readmemh(`FFT_TW_FILE, tw_rom);
`else
  $readmemh("build/fft_tw.hex", tw_rom);   // TB / iverilog：从仓库根跑
`endif
end
```

新增 `scripts/rom_preload.tcl`（两个建工程脚本都 source 这一份，保证裸 PL 与
Zynq 口径一致），里面 `set_property verilog_define {FFT_TW_FILE="<绝对路径>" ...}`。

TB **一行都不用改** —— 走 `else` 分支。复跑 `tb_fft_bfly` / `tb_anc_nco` /
`tb_anc_notch` / `tb_acoustic_ext` 仍全 PASS。

**验收** 综合日志里那两条 CRITICAL WARNING 消失。
（**注意：不是「TB 过了」** —— 这条问题 TB 本来就发现不了。）

**复现指纹** 综合日志里的 `could not open $readmem data file` **一律当 error 处理**。
凡是要在**综合**里用到的 init 文件，路径必须由脚本传绝对路径，
**不能只写相对路径**。看到「资源数比预期少」时，先回来查这一条。
