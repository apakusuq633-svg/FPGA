# 055 verify 第 22 项的 `$(find ...)` 穿过三层引号后散架

**症状** `scripts/verify.ps1` 报 **24/25**，唯一失败的是第 22 项：

```
== 22. generated tops compile
  [FAIL] generated tops compile (synth + board)
         build/gen_synth.v:25: error: Unknown module type: rv32_soc
```

**误判** `Unknown module type: rv32_soc` 看起来像**RTL 真的坏了** ——
换存储那次改动动的正是 `rv32_fft_bfly.v`，而 `rv32_soc` 实例化它。
第一反应是"我改坏了 rtl/soc/rv32_soc.v 或者文件列表"。

**不是**：把同两条 iverilog 命令**手工**跑一遍（`build/check22b.sh`），
两个顶层都干净编过、`EXPAND_AND_COMPILE_OK`。**同一条命令、同一个工作目录，
手跑过、脚本里不过。**

**根因** 第 22 项的命令写成：

```powershell
Invoke-Posix '... build/gen_synth.v $(find rtl -name "*.v") && ...'
```

这条字符串要穿过**三层引号解析**：PowerShell → `wsl.exe`（Windows 参数解析）
→ `sh -lc`。内层的 `"*.v"` 在 Windows 参数解析那一层就把外层引号**提前闭合**了，
`sh` 拿到的是被截断的命令，`$(find ...)` 的分词随之散架 ——
实测的表现是**文件列表被当成命令去执行**：

```
rtl/soc/rv32_soc.v: 1: module: not found
rtl/soc/rv32_soc.v: 2: parameter: not found
```

于是 iverilog 只拿到 `build/gen_synth.v` 一个文件，自然报 `Unknown module type`。

**指纹** **「同一条命令手跑过、在 verify 里不过」＋ 失败信息里出现
`<某个 .v 文件>: 1: xxx: not found`** ⇒ 是引号/分词问题，不是源码问题。
另一半指纹：**只有这一项失败**，因为 25 项里只有它用了 `$( )` 和嵌套双引号。

**修法** 改成一个不含 `$( )`、不含嵌套引号的 glob：

```powershell
... build/gen_synth.v rtl/*/*.v && ... build/gen_board.v rtl/*/*.v
```

先量过等价性：`find rtl -name '*.v'` 与 `rtl/*/*.v` **都是 58 个**，
且 `find rtl -mindepth 3 -name '*.v'` 为 **0**（没有更深的目录）。

**复现** `& scripts\verify.ps1`，看第 22 项。
