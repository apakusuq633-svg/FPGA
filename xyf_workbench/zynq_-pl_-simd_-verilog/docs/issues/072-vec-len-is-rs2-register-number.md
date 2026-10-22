# 072 — 阵列指令的 LEN 是 **rs2 的寄存器号**，不是立即数

**状态**：已修（2026-10-05）

---

## 症状

给阵列版 GSC 写固件时，把趟数写成了**立即数**：

```c
#define VRED(rd, F7, LEN) \
    __asm__ volatile(".insn r 0x0B, 1, " F7 ", %0, x0, %1" : "=r"(rd) : "r"(LEN))
...
VRED(am, VF7_X, VS_PASS - 1);          // 想表达 LEN = 14
```

**编出来的 LEN 不是 14** —— 是 GCC 为 `"r"(LEN)` 随便挑的那个寄存器的编号。
换个编译选项/换个上下文就换一个数，**静默算错**。

## 根因

```
rv32_decoder.v:  imm_o = is_op_v ? {21'b0, instr_i[30], instr_i[29:20]} : imm_gen_out
rv32_core.v:     assign idex_vec_len = idex_imm[5:0];
                 assign idex_vec_acc = idex_imm[6];
                 assign idex_vec_coef= idex_imm[7];
                 assign idex_vec_data= idex_imm[8];
                 assign idex_vec_ch  = idex_imm[10:9];
```

`imm[5:0] = instr[25:20]`，而 **`instr[24:20]` 就是 rs2 字段**。
`.insn r` 的 rs2 操作数是**寄存器名**，汇编器把它的**编号**填进 `instr[24:20]`
⇒ **LEN = 你写的那个寄存器的编号**。

**实证**（`sw/anc_hybrid.h`，0 缺陷的上一版固件）：

| 机器码 | bits[24:20] | LEN | 含义 |
|---|---|---|---|
| `0x08701D0B` | 7 | 7（8 趟） | `vred x26, x0 (S ch0)` |
| `0x28701D0B` | 7 | 7（8 趟） | `vred x26, x0 (S ch1)` |
| `0x0030168B` | 3 | 3（4 趟） | `vred x13, x0 (W, x)` |

⇒ 要 LEN=14，就得写 **`x14`**。

## 为什么单元级 TB 测不出来

`tb/tb_gsc_vec_map.v` 是**直接驱动阵列端口**的：

```verilog
rv32_vec_unit u_dut ( ... .len_i (len), ... );   // len 是 TB 的 reg，不是指令字段
```

端口上给 14 就是 14 ✓ —— **指令编码这一层根本没被覆盖**。
只有把指令**真发给核**才会暴露。

⚠ 这与 [071](071-vupd-shift-15-not-16.md) 是同一类：**TB 覆盖的层次与出问题的层次不一致**。

## 修法

```c
#define VS_LEN_REG "x14"                       /* LEN = 14 ⇒ 编号为 14 的寄存器 */
#define VRED(rd, F7) \
    __asm__ volatile(".insn r 0x0B, 1, " F7 ", %0, x0, " VS_LEN_REG \
                     : "=r"(rd) : : VS_LEN_REG)
#define VUPD(g, F7) \
    __asm__ volatile(".insn r 0x0B, 2, " F7 ", x0, %0, " VS_LEN_REG \
                     :: "r"(g) : VS_LEN_REG)
```

⚠ **x14 的值用不到，只有编号有意义** —— 但仍然要写进 clobber，否则 GCC
会以为它没被动过，可能把别的东西留在里面（现在无害，将来改了就未必）。

## 附带教训：单位要写清楚

`LEN` 这个名字容易被当成"趟数的数值"，而它在**指令编码里**的物理含义是
"rs2 寄存器的编号"。**同一个名字在三个层次上是三个东西**：

| 层次 | "LEN" 是什么 |
|---|---|
| 算法 | 趟数 − 1 = 14（一个数） |
| 指令编码 | `instr[24:20]` = rs2 的**寄存器编号** |
| RTL 端口 | `len_i[5:0]` = 14（一个数，与算法一致） |

**"算法 → RTL 端口"和"算法 → 指令编码"是两条不同的路，中间那层会变形状。**

## 复现指纹

```bash
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding -fno-builtin \
  -nostdlib -I sw/fw -S sw/fw/fw_gsc.c -o - | grep -A1 'insn r 0x0B, 1'
#   ✅ 正确：被引用的是 a4（= x14）
#   ❌ 错误：被引用的是 a0/a5/t0…（任意）
```
