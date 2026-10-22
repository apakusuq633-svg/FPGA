# 051 新引脚没在 BD 里引出 ⇒ 输入被 tie 成 0，一切"正常"只是麦没反应

**症状** 加完 PDM 那 9 根引脚、改完 `rv32_ps_top`、写完全部 xdc 约束之后，
第一次跑通 Zynq 流程（039 解除后），日志里冒出一条：

```
CRITICAL WARNING: [BD 41-759] The input pins (listed below) are either not connected
or do not have a source port, and they don't have a tie-off specified.
These pins are tied-off to all 0's to avoid error in Implementation flow.
/u_rv32_ps/pdm_din_i
```

**`pdm_din_i` 被 tie 成 0 了。**

**危害** 这条**不中断任何流程**：

- BD 照样 validate、综合照样过、位流照样出、引脚约束照样生效（`pdm_clk_o` 是输出，
  不受影响）；
- **RTL 是对的、TB 是全绿的、xdc 是逐脚核过的** —— 三个层面都查不出问题；
- 上板现象是**「8 个麦一点反应都没有」**，而 `pdm_clk_o` 还在正常翻转
  （用户拿示波器看会觉得"时钟有啊，怎么没数据"）。

**与 037/038 的区别**：那两条会在综合日志里指名 RTL 文件行号；
这一条**一句话都不提 RTL**，只说 BD 里某个 pin 没接。

**根因** 我在 `rv32_ps_top.v` 加了端口、在 `constrs/ps_pl_wrapper.xdc` 写了约束，
**但没在 `create_zynq_project.tcl` 里把这个端口引出成 BD 顶层端口**。
BD 里的 module reference（`u_rv32_ps`）自动带上了新端口，
但没人把它接到 BD 的外部端口上，于是 Vivado 给它一个 tie-off。

**这一条仓库自己预警过。** `create_zynq_project.tcl` 里 tacho 那段自检的注释写着：

> ⚠ 加新引脚（比如麦克风阵列那 6 根）时，这里也要照着加一段 —— 否则就是同一个缺口。

**我读了那段代码（为了照抄写法），但没有把这句话用在自己身上。**

**修法** 两处，都照着 tacho/audio 的现成写法：

1. **引端口**：
   ```tcl
   create_bd_port -dir O pdm_clk_o
   connect_bd_net [get_bd_pins u_rv32_ps/pdm_clk_o] [get_bd_ports pdm_clk_o]
   create_bd_port -dir I -from 7 -to 0 pdm_din_i
   connect_bd_net [get_bd_ports pdm_din_i] [get_bd_pins u_rv32_ps/pdm_din_i]
   ```
   ⚠ 8 位必须写 `-from 7 -to 0`（`-from` 是 MSB）。写成 `-from 8 -to 1` 得到 `[8:1]`，
   与 xdc 的 `[7:0]` 静默对不上。

2. **加 wrapper 自检**（这才是能提前一分钟报出来的那道关）：打开生成的
   `ps_pl_wrapper.v`，用正则核 `output pdm_clk_o;` 与 `input [7:0] pdm_din_i;`
   在不在 —— 而且**宽度也要核**。查不到就 `error` 退出。

> 自检**必须在建工程阶段**做：那时候还没有 elaborated design，
> `get_ports` 永远返回空，只会得到一个假失败。所以它读的是 wrapper 源文件。

**复现指纹** 综合日志里出现 **`[BD 41-759]` + 某个自己的端口名** ⇒
先去看 `create_zynq_project.tcl` 里有没有为它写 `create_bd_port`，
**不要去看 RTL**。凡是"RTL/TB/约束三层都对、上板就是没反应"，
优先查 BD 里那个 module reference 的端口有没有被引出。

---

## 补记 2026-10-02：修好之后连撞两次，每次都是"这一趟白跑"

### 其一：改脚本的时机 —— 边跑边改，跑的那趟用的是旧脚本

第一次补上 `create_bd_port` 之后**没有立刻重跑**，而是等正在跑的那一趟结束。
但那一趟是在**改脚本之前**启动的，`create_zynq_project.tcl` 是启动时 source 进去的 ——
**它用的是旧脚本**。于是生成的 wrapper 里没有 pdm 端口，
`ps_pl_wrapper.xdc` 里 9 条约束**全部 `[Vivado 12-584] No ports matched`**：

```
WARNING: [Vivado 12-584] No ports matched 'pdm_din_i[4]'. [...ps_pl_wrapper.xdc:146]
CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object.
```

**这全是 Warning / Critical Warning，一条 ERROR 都没有**，综合照样跑到 `SYNTH_OK`。
而后果是 9 根脚不受约束、位流随便分配，且 PDM 那块没有消费者会被整个优化掉。

**教训**：改建工程脚本之后，**正在跑的那一趟不算数**，必须重跑。
判据不是"它跑完了"，是"它跑的是改完之后的那份"。

### 其二：自检的正则写错了 —— 明明建出来了却报"缺端口"

修好后重跑，这次我加的自检**当场拦下了**（好事，没白等二十分钟）。
但它报的是假失败：`wrapper is missing {pdm_din_i[7:0]}`。

因为 Vivado 生成的 wrapper 写的是

```verilog
  output [2:0]led_o;
  input [7:0]pdm_din_i;
```

**`]` 和端口名之间没有空格**，而我的正则写的是 `\[7:0\]\s+pdm_din_i` ——
要求至少一个空格。改成 `\s*` 就对了。

**教训**：自检要拦的是真问题，所以**它自己的正确性也得验一次** ——
这一次是靠"看一眼生成的 wrapper 里到底有没有那个端口"分开的。
**报"缺件"时先确认那件东西是不是真缺**，否则自检会变成新的坑。
