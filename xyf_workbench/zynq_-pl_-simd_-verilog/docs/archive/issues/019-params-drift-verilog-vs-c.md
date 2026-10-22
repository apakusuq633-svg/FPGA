# 019 常量漂移（Verilog 侧 vs C 侧）

**症状** 无——是**风险**，不是故障。

**根因** `sw/anc_params.vh` 是 Verilog `localparam`，**C 里 `#include` 不了**。
于是上板程序把这 8 个常量（4 个相位增量 + RHO/RAMP/NRAMP/DEPTH）**手抄了一份**。
生成器改参数时 C 不会跟着动，**host 上没有任何检查能发现**。

**修法** 让 `gen_anc_hybrid.py` 顺手也吐一个 **`sw/anc_params.h`**（C 侧），
上板程序改成 `#include "anc_params.h"`。值逐位一致。
注意 `anc_hybrid.h` 已经定义了 `ANC_K_SLOTS` / `ANC_FRAMES`，
新头里再定义一遍在 `-Werror` 下是重定义错误 —— **只放那边没有的**。

**复现/指纹** **"两边各写一份常量"是必坏的模式**，无论当下两份是否一致。
判据：如果某个常量在两种语言里各出现一次，就该问"它们怎么保持同步"。
