# 上板看 GUI 的最短路径（站 15 网页）

> 这份只讲一件事：**怎么让浏览器里出现那张诊断页面**。
> 算法口径看 `README.md`，板级 IO 看 `board_io.md`，本次页面做到哪一步看 `gui_das_progress.md`。

整条链是四段，缺任何一段浏览器都打不开：

```
① 板子活着（JTAG 扫得到）→ ② ELF 是你要的那份 → ③ 烧进去跑起来 → ④ PC 网卡同网段 → 浏览器
```

下面每一步都写了「怎么知道这一步成功了」，因为这条链上**失败的表现全一样**：浏览器打不开。
不写清楚通过标准，就会在最后一步反复试浏览器，而问题其实在第一段。

---

## 0. 前提（一次性）

| 东西 | 值 | 备注 |
|---|---|---|
| Vitis 2020.2 | `E:\Vivado2020.2\Vitis\2020.2` | `xsct` 在 `bin\xsct.bat`。仓库里几处文档只写 `xsct ...`，没写它装在哪 |
| Vitis 工作区 | `D:\Vitis` | 平台 `PS-PL` 必须已经建过（由 XSA 建，见 `create_ps_apps.tcl` 头部） |
| 板子 | 上电 + JTAG-HS1 一头插电脑、一头插板上 JTAG 排针 | |
| 网线 | 板子 PS 网口 ↔ PC 有线网卡，直连即可 | 板载 PHY 支持 auto-MDIX，不用交叉线 |
| 串口 | UART0，115200 8N1 | 只看启动横幅的话可选，但排障时很有用 |

---

## 1. 先确认板子活着

```bash
cat > /tmp/probe.tcl <<'EOF'
connect
foreach t [targets] { puts $t }
exit 0
EOF
"E:\Vivado2020.2\Vitis\2020.2\bin\xsct.bat" /tmp/probe.tcl
```

- ✅ **通过**：输出里有 `Cortex-A9 #0` / `Cortex-A9 #1`（或 `APU`）。
- ❌ **不通过**：只有 `1 whole scan chain (DR shift through all zeroes)`。

那一条的含义是**下载器认到了、板子那头一个字都不回** —— 也就是断在下载器到 SoC 之间。
按可能性查：板子有没有上电 → 排线是不是插在板子上（而不是只插在下载器那头）→ 启动模式跳线。

> 这一条实际踩过（2026-10-11）：`run_board.tcl` 一路跑到
> `no targets found with "name =~ "APU""` 才停，前面 `-check` 三个路径全是 OK。
> 路径齐不齐和板子在不在，是两件事。

**这一步过不了就别往下走**，后面全是白费。

---

## 2. 确认 ELF 是你要的那份

**只在刚改过 `sw/` 下的源码时才需要做。** 三步：

```bash
# 2a. 把仓库 sw/ 的源码拷进 Vitis app 的 src/
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_ps_app.ps1 \
    -AppSrc "D:\Vitis\ui_app\src" -App ui -Force

# 2b. 编译
cat > /tmp/build_ui.tcl <<'EOF'
setws D:/Vitis
app build -name ui_app
exit 0
EOF
"E:\Vivado2020.2\Vitis\2020.2\bin\xsct.bat" /tmp/build_ui.tcl
```

- ✅ **通过**：`app build` 不报错，且 `D:\Vitis\ui_app\Debug\ui_app.elf` 的时间戳变成刚刚。
- ⚠ **`-Force` 必须有**：`sw/` 才是真值源。不带 `-Force` 时，脚本发现 app 里那份和仓库不一致会**拒绝覆盖**（故意的保护，别绕过）。

**怎么不看源码就确认 ELF 里是新页面**（页面标志串）：

```bash
grep -qa "Runtime measurements" "D:/Vitis/ui_app/Debug/ui_app.elf" \
  && echo "新页面在 ELF 里" || echo "还是旧的"
```

> 这条之所以有用：`ps_ui_page.h` 里页面是**编译进 ELF 的字符串常量**，
> 没有文件系统、没有外部资源。所以"页面上线了吗"这个问题，
> 等价于"ELF 里有没有那几个串"。

**上板前的整树一致性闸门**（不碰硬件，纯查文件）：

```bash
python scripts/check_board_ready.py
```

它比的是「Vitis 里的 ELF / Vitis src / 位流 / XSA / RTL 是不是同一次构建」。
⚠ 它报的 **"RTL 比位流新"** 那一类**不影响本页面上板**（本页面只要位流里有 GEM0），
但**改过 `rtl/` 之后想跑新逻辑就必须先 `scripts/export_xsa.tcl` 重出位流**。

---

## 3. 烧进去跑起来

```bash
"E:\Vivado2020.2\Vitis\2020.2\bin\xsct.bat" scripts/run_board.tcl -app ui_app
```

这一条按顺序干四件事，**次序不能换**：

1. `rst -system` 复位整个 Zynq（这样 A9#1 从 BootROM 的等待循环起来，两核分工才成立）
2. `fpga -file .../ps_pl_wrapper.bit` 烧 PL
3. `source ps7_init.tcl` + `ps7_init` + `ps7_post_config` 把 PS 配起来
4. `dow ui_app.elf` 下载，`con` 放它跑

- 想先**不接硬件**验路径齐不齐：加 `-check`，只打印三个路径然后退出。
- ✅ **通过**：最后一行是 `==> Running ui_app. Read PS UART0 at 115200 8N1.`

> ⚠ 这一步会把**整个 Zynq 复位一遍**。板子上如果还有别的东西在跑，先确认不需要它了。
> `scripts/jtag_guard.tcl` 会在开头查 JTAG 有没有被别的进程占着。

到这一步板子**已经在跑了**，不需要再动 Vitis GUI（Vitis 的 "Run As → Launch Hardware" 是另一条路，做的事一模一样）。

---

## 4. PC 网卡设成同网段

`Win+R` → `ncpa.cpl` → 右键那块**有线**网卡 → 属性 → 双击「Internet 协议版本 4 (TCP/IPv4)」：

| 字段 | 值 |
|---|---|
| IP 地址 | `192.168.2.20` |
| 子网掩码 | `255.255.255.0` |
| 网关 / DNS | **留空**（直连，链路上没有路由器） |

板子固定在 `192.168.2.10`，写死在 `sw/ps_ui.c` 的 `UI_IP_A..D` / `UI_GW_*`。
要换地址就改那几个宏**重新编译**（不用重出位流）。

> PC 同时连着 WiFi 时一般不用管：`192.168.2.0/24` 是直连网段，Windows 会走有线。
> 真出问题就在那块有线网卡上把「跃点数」调低。

**这一步设一次就一直有效**，以后重编重烧都不用再动。

---

## 5. 打开

```bash
ping -n 4 192.168.2.10                   # 先确认链路
curl -s http://192.168.2.10/api/status   # 再看有没有数
```

然后浏览器打开 **`http://192.168.2.10/`**。

页面每秒轮询 `/api/status` 一次。`/api/status` 的字段含义见 `sw/ps_ui_page.h`
的 `ui_json()`；它不是串口那行 `FDIAG` 的复制 —— 格式串只有 `ps_output.h` 那一处。

---

## 只改页面时的最短路径

日常改 `sw/ps_ui_page.h` 之后：

```
改源码 → 2a 拷源码 → 2b 重编 → 3 重烧 → 浏览器刷新
```

**第 4 步不用重做**（网卡设一次就够）。

⚠ **不用重出位流。** 位流里装的是 GEM0 这类硬件配置；页面是 ELF 里的字符串常量。
只有改了 `rtl/` 或 BD 才要重出位流 + 重导 XSA。

---

## 打不开时按症状查

| 症状 | 大概率原因 | 怎么办 |
|---|---|---|
| `no targets found with "name =~ "APU""`，扫描链全 0 | 板子没上电 / JTAG 排线没插到板上 | 回 §1 |
| `Build artifact missing: <path>` | 那个路径的文件不在 | 看它打的是哪个：ELF 没编（§2）还是位流没导出（`export_xsa.tcl`） |
| ping 不通 | PC 网卡没设 / 设错网段 | 回 §4，`ipconfig` 看那块网卡是不是 `192.168.2.20` |
| 浏览器空白 | 页面在，但 `/api/status` 没数 | `curl .../api/status`，看是不是 `{"have":0}` |
| `/api/status` 一直 `{"have":0}` | A9#1 还没出第一帧 | 串口看 `no frame from A9#1 yet (busy=?)`：`busy=1` 是在啃第一帧，`busy=0` 是它压根没起来 |
| 页面能开，但 Direction 显示 unavailable | **这是正常的，不是坏了** | `"grid_w":0` —— 方位要读 PL 固件的 SRP 结果（DTCM `0x3C60` 状态位），而 PL 那份是一次性 benchmark，没在跑 |
| 连不上 80 端口 | 别的程序占了端口 | 关掉再试；板上端口由 `UI_HTTP_PORT` 定，默认 80 |

---

## 页面现在显示的是什么（诚实条款）

- **Diagnosis 面板有真数**：类别 / 置信度 / 四类票数，来自站 11→12→13 整条链。
- **来源是合成自检帧**，不是真 PDM 波形 —— JSON 里 `"synthetic":1`，页面顶部会标出来。
  接真数据时只需换 `sw/ps_ui.c` 里 `cpu1_main()` 取波形那一行。
- **Localization 只有一个位置标记点**，整张 SRP 热力图的数组**没有通到 PS**。
- **两个频谱面板是空占位**，**Runtime measurements 是 "not connected"**。

页面**不会**在没有数据时生成演示曲线 —— 缺什么就显示什么在等。所以"看起来空"是设计，不是故障。
