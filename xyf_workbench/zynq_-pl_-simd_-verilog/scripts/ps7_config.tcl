# 正点原子领航者 ZYNQ 的 PS7 配置，由 scripts/gen_ps7_config.py 从厂商例程导出。
# 勿手改：要改请改生成器或换源工程，然后重新生成。
#
# 来源：build/ZYNQ_Vitis_7010/1_hello_world/hello_world.srcs/sources_1/bd/system/system.bd
#       里的 processing_system7_0 单元。
#       那是厂商验证过、能在这块板上跑的配置（DDR 型号/时序、MIO 分配、时钟全都在内）。
#
# ⚠⚠ **本文件是从 7010 的厂商例程导出的，而当前板子已换成 7020。**
#   Zynq-7000 全系的 **PS 是同一套**（双 Cortex-A9、MIO、外设、时钟源都一样），
#   7010 与 7020 的差别只在 PL —— 所以 MIO / QSPI / SD / UART / USB 那些**照用没问题**。
#
#   **但 DDR 那一块依赖的是核心板，不是器件**，本文件里 DDR 相关参数有 **77 条**。
#
#   ✅ **这条风险已应验、并已于 2026-10-04 修好**（实测，见 docs/issues/067）：
#   原来配的是 MT41K128M16（2Gb / 512MB），而板上实际是
#   **NT5CC256M16（256M×16 = 4Gb，两颗 = 1GB）**（从核心板原理图第 8 页抽出）。
#   行地址少一根（14 vs 15）+ tRCD/tRP/tRFC/tRAS 整套不对
#   ⇒ **写 DDR 约 9% 丢掉，且只有低 16 位落盘**（同一套循环写 OCM 是 0 错）。
#
#   后果不是"PS 起不来"，而是**更隐蔽的一种**：`ps7_init` 的 DDR PHY 校准
#   **照样通过**（`build/` 全日志 grep `Mask poll`/`Timeout Reached` 零命中），
#   于是 DDR 看起来是好的；但 `dow` 写进 DDR 的 app 已经是坏的，
#   A9 取到坏指令 → 执行到野生地址 → **PS 互连同 DAP 一起锁死，只能断电重上电**。
#   很容易误判成"板子坏了"/"位流坏了"/"JTAG 被占了"。
#
# ---------------------------------------------------------------------------
# **2026-10-04：DDR 两条已按 7020 厂商例程改掉并实测通过**
#   （判据：DDR 写 11/128 错 → **0/128**；DDR 版 app 端到端 `PASS (0 failures)`）
#   改的是下面 CONFIG.PCW_DDR_RAM_HIGHADDR 和 CONFIG.PCW_UIPARAM_DDR_PARTNO 两行：
#
#   来源：D:\BaiduNetdiskDownload\ZYNQ_Vitis_7020\ZYNQ_Vitis_7020\
#         20_pl_rw_ddr\pl_rw_ddr.srcs\sources_1\bd\system\system.bd
#         （选它是因为在 44 个 7020 例程里它与本文件的差异**最小**，只有 13 条）
#
#       PCW_DDR_RAM_HIGHADDR  0x1FFFFFFF -> 0x3FFFFFFF     （512 MB -> 1 GB）
#       PCW_UIPARAM_DDR_PARTNO MT41K128M16 JT-125 -> MT41K256M16 RE-125  （2Gb -> 4Gb）
#
#   ⚠ **只改了这两条，其余 322 条保持 7010 例程原值，这是刻意的。**
#   那个 7020 例程除 DDR 外还有 13 条差异（FCLK0 频率、CLK0/RST0 端口、S_AXI_HP0、
#   CPU_6X4X_MAX_RANGE 667->767）。其中 FCLK0/CLK0/RST0/M_AXI_GP0/IRQ_F2P 那几条
#   `create_zynq_project.tcl` 本来就会覆盖，**但 `USE_S_AXI_HP0` 和
#   `CPU_6X4X_MAX_RANGE` 不覆盖** —— 整份采用就会引入两条与本问题无关的变量，
#   出问题时无法归因。所以按仓库 §0「改之前先量」，这里做最小改动。
#
#   ⇒ **DDR 已实测通过**（见上）。若以后要让本文件与 7020 例程完全对齐
#     （比如要开 HP0 或 QSPI/SD），再重跑
#     `python3 scripts/gen_ps7_config.py <那个 .bd>` 整份换掉，
#     并把上面这段说明删掉 —— 不要让它变成第三套口径。
#
#   ⚠ 改完本文件之后必须走的完整动作（少一步就白跑，见 docs/issues/067 §4.2）：
#     1) create_zynq_project.tcl 重建 BD —— **先把 vivado_zynq/*.bit 备份出去**，
#        它用 create_project -force，会把已实现的位流一起删掉
#     2) 对 **BD** 跑 generate_target all（不是对 PS7 IP：它的 SUPPORTED_TARGETS
#        里没有 handoff，只有 instantiation_template/synthesis/simulation/misc/changelog）
#     3) 把 .gen/.../ip/ps_pl_u_ps7_0/ps7_init.tcl 与 .c 拷到 D:/Vitis/PS-PL/hw/
#     4) 用 scripts/probe_write_drop_ocm_vs_ddr.tcl 判 DDR 是否 0 错，再跑 app
# ---------------------------------------------------------------------------
#
# 已滤掉派生只读的 PCW_ACT_* 项，其余原样照抄，不做任何"整理" —— 这些值的含义只有厂商
# 和 Vivado 清楚，改动任何一条的风险都远大于收益。
#
# 本文件只管 PS 自己。PL 相关的那几项（USE_M_AXI_GP0 / USE_FABRIC_INTERRUPT /
# IRQ_F2P_INTR / FPGA0 频率）在厂商的纯 PS 例程里都是 0，由 create_zynq_project.tcl
# 在本文件之后覆盖 —— **不要在下面改它们**。

proc apply_ps7_config {cell} {
    set_property -dict [list \
        CONFIG.PCW_APU_CLK_RATIO_ENABLE {6:2:1} \
        CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
        CONFIG.PCW_CAN0_PERIPHERAL_CLKSRC {External} \
        CONFIG.PCW_CAN0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_CAN1_PERIPHERAL_CLKSRC {External} \
        CONFIG.PCW_CAN1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_CAN_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_CAN_PERIPHERAL_VALID {0} \
        CONFIG.PCW_CLK0_FREQ {10000000} \
        CONFIG.PCW_CLK1_FREQ {10000000} \
        CONFIG.PCW_CLK2_FREQ {10000000} \
        CONFIG.PCW_CLK3_FREQ {10000000} \
        CONFIG.PCW_CPU_CPU_6X4X_MAX_RANGE {667} \
        CONFIG.PCW_CPU_PERIPHERAL_CLKSRC {ARM PLL} \
        CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
        CONFIG.PCW_DCI_PERIPHERAL_CLKSRC {DDR PLL} \
        CONFIG.PCW_DCI_PERIPHERAL_FREQMHZ {10.159} \
        CONFIG.PCW_DDR_PERIPHERAL_CLKSRC {DDR PLL} \
        CONFIG.PCW_DDR_RAM_BASEADDR {0x00100000} \
        CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
        CONFIG.PCW_DM_WIDTH {4} \
        CONFIG.PCW_DQS_WIDTH {4} \
        CONFIG.PCW_DQ_WIDTH {32} \
        CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_ENET1_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_ENET_RESET_POLARITY {Active Low} \
        CONFIG.PCW_EN_4K_TIMER {0} \
        CONFIG.PCW_EN_CAN0 {0} \
        CONFIG.PCW_EN_CAN1 {0} \
        CONFIG.PCW_EN_CLK0_PORT {0} \
        CONFIG.PCW_EN_CLK1_PORT {0} \
        CONFIG.PCW_EN_CLK2_PORT {0} \
        CONFIG.PCW_EN_CLK3_PORT {0} \
        CONFIG.PCW_EN_CLKTRIG0_PORT {0} \
        CONFIG.PCW_EN_CLKTRIG1_PORT {0} \
        CONFIG.PCW_EN_CLKTRIG2_PORT {0} \
        CONFIG.PCW_EN_CLKTRIG3_PORT {0} \
        CONFIG.PCW_EN_DDR {1} \
        CONFIG.PCW_EN_EMIO_CAN0 {0} \
        CONFIG.PCW_EN_EMIO_CAN1 {0} \
        CONFIG.PCW_EN_EMIO_CD_SDIO0 {0} \
        CONFIG.PCW_EN_EMIO_CD_SDIO1 {0} \
        CONFIG.PCW_EN_EMIO_ENET0 {0} \
        CONFIG.PCW_EN_EMIO_ENET1 {0} \
        CONFIG.PCW_EN_EMIO_GPIO {0} \
        CONFIG.PCW_EN_EMIO_I2C0 {0} \
        CONFIG.PCW_EN_EMIO_I2C1 {0} \
        CONFIG.PCW_EN_EMIO_MODEM_UART0 {0} \
        CONFIG.PCW_EN_EMIO_MODEM_UART1 {0} \
        CONFIG.PCW_EN_EMIO_PJTAG {0} \
        CONFIG.PCW_EN_EMIO_SDIO0 {0} \
        CONFIG.PCW_EN_EMIO_SDIO1 {0} \
        CONFIG.PCW_EN_EMIO_SPI0 {0} \
        CONFIG.PCW_EN_EMIO_SPI1 {0} \
        CONFIG.PCW_EN_EMIO_SRAM_INT {0} \
        CONFIG.PCW_EN_EMIO_TRACE {0} \
        CONFIG.PCW_EN_EMIO_TTC0 {0} \
        CONFIG.PCW_EN_EMIO_TTC1 {0} \
        CONFIG.PCW_EN_EMIO_UART0 {0} \
        CONFIG.PCW_EN_EMIO_UART1 {0} \
        CONFIG.PCW_EN_EMIO_WDT {0} \
        CONFIG.PCW_EN_EMIO_WP_SDIO0 {0} \
        CONFIG.PCW_EN_EMIO_WP_SDIO1 {0} \
        CONFIG.PCW_EN_ENET0 {0} \
        CONFIG.PCW_EN_ENET1 {0} \
        CONFIG.PCW_EN_GPIO {0} \
        CONFIG.PCW_EN_I2C0 {0} \
        CONFIG.PCW_EN_I2C1 {0} \
        CONFIG.PCW_EN_MODEM_UART0 {0} \
        CONFIG.PCW_EN_MODEM_UART1 {0} \
        CONFIG.PCW_EN_PJTAG {0} \
        CONFIG.PCW_EN_PTP_ENET0 {0} \
        CONFIG.PCW_EN_PTP_ENET1 {0} \
        CONFIG.PCW_EN_QSPI {0} \
        CONFIG.PCW_EN_RST0_PORT {0} \
        CONFIG.PCW_EN_RST1_PORT {0} \
        CONFIG.PCW_EN_RST2_PORT {0} \
        CONFIG.PCW_EN_RST3_PORT {0} \
        CONFIG.PCW_EN_SDIO0 {0} \
        CONFIG.PCW_EN_SDIO1 {0} \
        CONFIG.PCW_EN_SMC {0} \
        CONFIG.PCW_EN_SPI0 {0} \
        CONFIG.PCW_EN_SPI1 {0} \
        CONFIG.PCW_EN_TRACE {0} \
        CONFIG.PCW_EN_TTC0 {0} \
        CONFIG.PCW_EN_TTC1 {0} \
        CONFIG.PCW_EN_UART0 {1} \
        CONFIG.PCW_EN_UART1 {0} \
        CONFIG.PCW_EN_USB0 {0} \
        CONFIG.PCW_EN_USB1 {0} \
        CONFIG.PCW_EN_WDT {0} \
        CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_FCLK1_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_FCLK2_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_FCLK3_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
        CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {50} \
        CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {50} \
        CONFIG.PCW_FPGA3_PERIPHERAL_FREQMHZ {50} \
        CONFIG.PCW_GP0_EN_MODIFIABLE_TXN {1} \
        CONFIG.PCW_GP0_NUM_READ_THREADS {4} \
        CONFIG.PCW_GP0_NUM_WRITE_THREADS {4} \
        CONFIG.PCW_GP1_EN_MODIFIABLE_TXN {1} \
        CONFIG.PCW_GP1_NUM_READ_THREADS {4} \
        CONFIG.PCW_GP1_NUM_WRITE_THREADS {4} \
        CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {0} \
        CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {0} \
        CONFIG.PCW_GPIO_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_I2C_RESET_POLARITY {Active Low} \
        CONFIG.PCW_IMPORT_BOARD_PRESET {None} \
        CONFIG.PCW_INCLUDE_ACP_TRANS_CHECK {0} \
        CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
        CONFIG.PCW_MIO_14_IOTYPE {LVCMOS 3.3V} \
        CONFIG.PCW_MIO_14_PULLUP {enabled} \
        CONFIG.PCW_MIO_14_SLEW {slow} \
        CONFIG.PCW_MIO_15_IOTYPE {LVCMOS 3.3V} \
        CONFIG.PCW_MIO_15_PULLUP {enabled} \
        CONFIG.PCW_MIO_15_SLEW {slow} \
        CONFIG.PCW_MIO_PRIMITIVE {54} \
        CONFIG.PCW_MIO_TREE_PERIPHERALS {unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#UART 0#UART 0#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned} \
        CONFIG.PCW_MIO_TREE_SIGNALS {unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#rx#tx#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned} \
        CONFIG.PCW_NAND_CYCLES_T_AR {1} \
        CONFIG.PCW_NAND_CYCLES_T_CLR {1} \
        CONFIG.PCW_NAND_CYCLES_T_RC {11} \
        CONFIG.PCW_NAND_CYCLES_T_REA {1} \
        CONFIG.PCW_NAND_CYCLES_T_RR {1} \
        CONFIG.PCW_NAND_CYCLES_T_WC {11} \
        CONFIG.PCW_NAND_CYCLES_T_WP {1} \
        CONFIG.PCW_NAND_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_NOR_CS0_T_CEOE {1} \
        CONFIG.PCW_NOR_CS0_T_PC {1} \
        CONFIG.PCW_NOR_CS0_T_RC {11} \
        CONFIG.PCW_NOR_CS0_T_TR {1} \
        CONFIG.PCW_NOR_CS0_T_WC {11} \
        CONFIG.PCW_NOR_CS0_T_WP {1} \
        CONFIG.PCW_NOR_CS0_WE_TIME {0} \
        CONFIG.PCW_NOR_CS1_T_CEOE {1} \
        CONFIG.PCW_NOR_CS1_T_PC {1} \
        CONFIG.PCW_NOR_CS1_T_RC {11} \
        CONFIG.PCW_NOR_CS1_T_TR {1} \
        CONFIG.PCW_NOR_CS1_T_WC {11} \
        CONFIG.PCW_NOR_CS1_T_WP {1} \
        CONFIG.PCW_NOR_CS1_WE_TIME {0} \
        CONFIG.PCW_NOR_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_NOR_SRAM_CS0_T_CEOE {1} \
        CONFIG.PCW_NOR_SRAM_CS0_T_PC {1} \
        CONFIG.PCW_NOR_SRAM_CS0_T_RC {11} \
        CONFIG.PCW_NOR_SRAM_CS0_T_TR {1} \
        CONFIG.PCW_NOR_SRAM_CS0_T_WC {11} \
        CONFIG.PCW_NOR_SRAM_CS0_T_WP {1} \
        CONFIG.PCW_NOR_SRAM_CS0_WE_TIME {0} \
        CONFIG.PCW_NOR_SRAM_CS1_T_CEOE {1} \
        CONFIG.PCW_NOR_SRAM_CS1_T_PC {1} \
        CONFIG.PCW_NOR_SRAM_CS1_T_RC {11} \
        CONFIG.PCW_NOR_SRAM_CS1_T_TR {1} \
        CONFIG.PCW_NOR_SRAM_CS1_T_WC {11} \
        CONFIG.PCW_NOR_SRAM_CS1_T_WP {1} \
        CONFIG.PCW_NOR_SRAM_CS1_WE_TIME {0} \
        CONFIG.PCW_OVERRIDE_BASIC_CLOCK {0} \
        CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY0 {0.080} \
        CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY1 {0.063} \
        CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY2 {0.057} \
        CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY3 {0.068} \
        CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_0 {-0.047} \
        CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_1 {-0.025} \
        CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_2 {-0.006} \
        CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_3 {-0.017} \
        CONFIG.PCW_PACKAGE_NAME {clg400} \
        CONFIG.PCW_PCAP_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_PCAP_PERIPHERAL_FREQMHZ {200} \
        CONFIG.PCW_PERIPHERAL_BOARD_PRESET {None} \
        CONFIG.PCW_PJTAG_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_PLL_BYPASSMODE_ENABLE {0} \
        CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
        CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
        CONFIG.PCW_PS7_SI_REV {PRODUCTION} \
        CONFIG.PCW_QSPI_INTERNAL_HIGHADDRESS {0xFCFFFFFF} \
        CONFIG.PCW_QSPI_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_SD0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_SD1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_SDIO_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_SDIO_PERIPHERAL_VALID {0} \
        CONFIG.PCW_SMC_CYCLE_T0 {NA} \
        CONFIG.PCW_SMC_CYCLE_T1 {NA} \
        CONFIG.PCW_SMC_CYCLE_T2 {NA} \
        CONFIG.PCW_SMC_CYCLE_T3 {NA} \
        CONFIG.PCW_SMC_CYCLE_T4 {NA} \
        CONFIG.PCW_SMC_CYCLE_T5 {NA} \
        CONFIG.PCW_SMC_CYCLE_T6 {NA} \
        CONFIG.PCW_SMC_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_SMC_PERIPHERAL_VALID {0} \
        CONFIG.PCW_SPI0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_SPI1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_SPI_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_SPI_PERIPHERAL_VALID {0} \
        CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
        CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {64} \
        CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64} \
        CONFIG.PCW_S_AXI_HP3_DATA_WIDTH {64} \
        CONFIG.PCW_TPIU_PERIPHERAL_CLKSRC {External} \
        CONFIG.PCW_TRACE_INTERNAL_WIDTH {2} \
        CONFIG.PCW_TRACE_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_TTC0_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC0_CLK0_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC0_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC0_CLK1_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC0_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC0_CLK2_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_TTC1_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC1_CLK0_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC1_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC1_CLK1_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC1_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_TTC1_CLK2_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_TTC1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_UART0_BASEADDR {0xE0000000} \
        CONFIG.PCW_UART0_BAUD_RATE {115200} \
        CONFIG.PCW_UART0_GRP_FULL_ENABLE {0} \
        CONFIG.PCW_UART0_HIGHADDR {0xE0000FFF} \
        CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
        CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
        CONFIG.PCW_UART1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_UART_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_UART_PERIPHERAL_FREQMHZ {100} \
        CONFIG.PCW_UART_PERIPHERAL_VALID {1} \
        CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
        CONFIG.PCW_UIPARAM_DDR_ADV_ENABLE {0} \
        CONFIG.PCW_UIPARAM_DDR_AL {0} \
        CONFIG.PCW_UIPARAM_DDR_BL {8} \
        CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.25} \
        CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.25} \
        CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2 {0.25} \
        CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3 {0.25} \
        CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_0_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PACKAGE_LENGTH {54.563} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_1_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PACKAGE_LENGTH {54.563} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_2_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PACKAGE_LENGTH {54.563} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_3_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PACKAGE_LENGTH {54.563} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_CLOCK_STOP_EN {0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_0_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_0_PACKAGE_LENGTH {101.239} \
        CONFIG.PCW_UIPARAM_DDR_DQS_0_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQS_1_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_1_PACKAGE_LENGTH {79.5025} \
        CONFIG.PCW_UIPARAM_DDR_DQS_1_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQS_2_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_2_PACKAGE_LENGTH {60.536} \
        CONFIG.PCW_UIPARAM_DDR_DQS_2_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQS_3_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_3_PACKAGE_LENGTH {71.7715} \
        CONFIG.PCW_UIPARAM_DDR_DQS_3_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0 {0.0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1 {0.0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2 {0.0} \
        CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3 {0.0} \
        CONFIG.PCW_UIPARAM_DDR_DQ_0_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQ_0_PACKAGE_LENGTH {104.5365} \
        CONFIG.PCW_UIPARAM_DDR_DQ_0_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQ_1_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQ_1_PACKAGE_LENGTH {70.676} \
        CONFIG.PCW_UIPARAM_DDR_DQ_1_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQ_2_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQ_2_PACKAGE_LENGTH {59.1615} \
        CONFIG.PCW_UIPARAM_DDR_DQ_2_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_DQ_3_LENGTH_MM {0} \
        CONFIG.PCW_UIPARAM_DDR_DQ_3_PACKAGE_LENGTH {81.319} \
        CONFIG.PCW_UIPARAM_DDR_DQ_3_PROPOGATION_DELAY {160} \
        CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
        CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.333333} \
        CONFIG.PCW_UIPARAM_DDR_HIGH_TEMP {Normal (0-85)} \
        CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3 (Low Voltage)} \
        CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
        CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
        CONFIG.PCW_UIPARAM_GENERATE_SUMMARY {NA} \
        CONFIG.PCW_USB0_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_USB1_PERIPHERAL_ENABLE {0} \
        CONFIG.PCW_USB_RESET_POLARITY {Active Low} \
        CONFIG.PCW_USE_AXI_FABRIC_IDLE {0} \
        CONFIG.PCW_USE_AXI_NONSECURE {0} \
        CONFIG.PCW_USE_CORESIGHT {0} \
        CONFIG.PCW_USE_CROSS_TRIGGER {0} \
        CONFIG.PCW_USE_CR_FABRIC {1} \
        CONFIG.PCW_USE_DDR_BYPASS {0} \
        CONFIG.PCW_USE_DEBUG {0} \
        CONFIG.PCW_USE_DMA0 {0} \
        CONFIG.PCW_USE_DMA1 {0} \
        CONFIG.PCW_USE_DMA2 {0} \
        CONFIG.PCW_USE_DMA3 {0} \
        CONFIG.PCW_USE_EXPANDED_IOP {0} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
        CONFIG.PCW_USE_HIGH_OCM {0} \
        CONFIG.PCW_USE_M_AXI_GP0 {0} \
        CONFIG.PCW_USE_M_AXI_GP1 {0} \
        CONFIG.PCW_USE_PROC_EVENT_BUS {0} \
        CONFIG.PCW_USE_PS_SLCR_REGISTERS {0} \
        CONFIG.PCW_USE_S_AXI_ACP {0} \
        CONFIG.PCW_USE_S_AXI_GP0 {0} \
        CONFIG.PCW_USE_S_AXI_GP1 {0} \
        CONFIG.PCW_USE_S_AXI_HP0 {0} \
        CONFIG.PCW_USE_S_AXI_HP1 {0} \
        CONFIG.PCW_USE_S_AXI_HP2 {0} \
        CONFIG.PCW_USE_S_AXI_HP3 {0} \
        CONFIG.PCW_USE_TRACE {0} \
        CONFIG.PCW_VALUE_SILVERSION {3} \
        CONFIG.PCW_WDT_PERIPHERAL_CLKSRC {CPU_1X} \
        CONFIG.PCW_WDT_PERIPHERAL_DIVISOR0 {1} \
        CONFIG.PCW_WDT_PERIPHERAL_ENABLE {0}
    ] [get_bd_cells $cell]
}
