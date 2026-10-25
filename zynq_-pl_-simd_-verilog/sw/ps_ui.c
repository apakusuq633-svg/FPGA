/* Dual-core DAS audio UI: CPU0 receives 512-sample blocks and serves HTTP;
 * CPU1 copies completed DDR segments, releases them, then classifies locally.
 * Default source is a labeled synthetic replay through the same block pipeline.
 * UI_DAS_LIVE=1 requires UI_DAS_WINDOW_PRESENT=1 and a matching PL bitstream.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_mmu.h"       /* NORM_NONCACHE / Xil_SetTlbAttributes（共享页要它） */
#include "xil_cache_l.h"   /* Xil_L1DCacheInvalidate（**只有 L1 的**，见 cpu1_prep） */
#include "xparameters.h"
#include "xscugic.h"       /* SCU GIC —— EMAC 的中断 BSP 不装，得应用自己装 */
#include "xil_exception.h" /* Xil_ExceptionRegisterHandler / Xil_ExceptionEnable */

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "netif/xadapter.h"
#include "netif/xemacpsif.h"  /* emacps_recv_handler / emacps_send_handler —— 中断里由它们干活 */

#include "ps_diag.h"       /* 站 11 -> 12 -> 13 的接缝：dia_frame / dia_synth_frame */
#include "ps_ipc.h"        /* 两个核之间的那一页 OCM：ipc_publish / ipc_consume */
#include "ps_das_mmio.h"
#include "ps_das_replay.h"
#include "ps_das_plots.h"
#include "ps_ui_page.h"    /* 站 15 的本体：ui_route / ui_json / UI_PAGE_HTML */
#include "ps_raw_capture.h"

/* -- 网络参数 ------------------------------------------------------------------------------- */
/* 网段取 192.168.2.0/24，不用更常见的 192.168.1.0/24，原因是**开发机的无线网卡**已经在
 * 192.168.1.101/24 上。板子与 PC 有线直连时，同网段会出现两条路由（有线 + 无线），Windows
 * 按接口跃点数挑一条；跃点数不一定站在有线这边，而挑错时的现象只是"ping 没回音"，
 * 从现象看不出跟 WiFi 有什么关系。换一个不冲突的网段就不用赌这个。 */
#ifndef UI_DAS_LIVE
#define UI_DAS_LIVE 0
#endif
#ifndef UI_DAS_ACTIVE_CHANNELS
#define UI_DAS_ACTIVE_CHANNELS 8
#endif
#ifndef UI_DAS_WINDOW_PRESENT
#define UI_DAS_WINDOW_PRESENT 0
#endif
#ifndef UI_SHAFT_MILLIHZ
#define UI_SHAFT_MILLIHZ 25000u
#endif
#if UI_DAS_LIVE && !UI_DAS_WINDOW_PRESENT
#error "Live DAS requires the matching PL FIFO bitstream"
#endif
#if UI_DAS_LIVE
#include "ps_das_fifo.h"
#include "ps_pl_live.h"
#if UI_DAS_ACTIVE_CHANNELS == 9
#include "ps_circular9_live.h"
#include "ps_circular9_tasks.h"
#include "ps_circular9_control.h"
#include "ps_circular9_gui.h"
#endif
static das_fifo_receiver fifo_receiver;
static uint32_t live_start_tick,live_ready;
static raw_capture_receiver raw_receiver;
#endif
#ifndef UI_SHAFT_MILLIHZ
#define UI_SHAFT_MILLIHZ 25000u
#endif
#if UI_SHAFT_MILLIHZ < 1000 || UI_SHAFT_MILLIHZ > 200000
#error "Shaft rate must be 1..200 Hz; validate model applicability separately"
#endif
#if !UI_DAS_LIVE && UI_SHAFT_MILLIHZ != 25000
#error "The replay fixture uses 25 Hz; custom shaft rate is for live mode"
#endif
/* Whole 1 MB DDR section: no unrelated cached objects share its MMU mapping. */
static union {
    das_segment_queue q;
    unsigned char section[1048576];
} audio_shared __attribute__((aligned(1048576)));
static das_audio_block received_audio;
#if !UI_DAS_LIVE
static double replay_source[DAS_AUDIO_SEGMENT];
#ifndef UI_DYNAMIC_REPLAY
#define UI_DYNAMIC_REPLAY 0
#endif
#if UI_DYNAMIC_REPLAY
static double replay_second[DAS_AUDIO_SEGMENT];
#endif
static uint32_t replay_seq,replay_next_tick;
static uint64_t replay_first;
#endif
static int audio_error;
static uint32_t audio_blocks,pl_dropped;
#ifndef UI_IP_A
#define UI_IP_A    192
#define UI_IP_B    168
#define UI_IP_C    2
#define UI_IP_D    10
#endif
/* 直连的另一端（PC）必须同在这个 /24 里，且不能是 .10 —— 即 PC 有线网卡设 192.168.2.20/24。 */
#define UI_GW_A    192
#define UI_GW_B    168
#define UI_GW_C    2
#define UI_GW_D    1

#define UI_HTTP_PORT       80

/* 两个周期。诊断周期先给 2 s：站 11 一帧的真实耗时板上才知道（每帧打 TIME 行），
 * 它必须明显小于本周期，否则主循环会一直卡在算帧上、网口收不进来。 */
#ifndef UI_FRAME_PERIOD_MS
#define UI_FRAME_PERIOD_MS 2000u
#endif

/* 把每个请求行都打到串口。默认关：浏览器每秒轮询一次，全打出来会把每帧那几行 DIAG
 * 冲掉。第一次上板确认"请求真的到了"时再编成 1（-DUI_LOG_REQ=1）。 */
#ifndef UI_LOG_REQ
#define UI_LOG_REQ 0
#endif

/* -- TCP fast/slow 定时器 -------------------------------------------------------------------
 * 在这里自己声明，不 include：lwIP 2.1.1 把它们放在 lwip/priv/tcp_priv.h 里，那是故意私有
 * 的。厂商自己的 lwip_echo_server 模板也是这么干的（platform_zynq.c），而且 LWIP_TIMERS
 * 关掉之后没有别的办法给 TCP 递拍子。 */
void tcp_fasttmr(void);
void tcp_slowtmr(void);

/* -- HTTP 服务 ------------------------------------------------------------------------------
 * NO_SYS=1 的裸 lwIP。每个连接缓冲**一行请求**：浏览器可能把请求拆成两段发，
 * 半个请求行就应答，就会出现"把 /api/st 当成 404"这种错。
 *
 * 只做 GET，没有请求体要读 —— 这在本项目里是个硬要求，不是简化：留着半个没读完的
 * 请求体，lwIP 会用 RST 收场，浏览器报网络错而不是显示应答。
 */
#include "ps_http_tx.h"

#define HTTP_MAX_CONN   4
#define HTTP_REQ_MAX    512
/* 头的余量 + body 上限。body 的上限由 ps_ui_page.h 定（UI_BODY_MAX），这里只留头的位置。 */
#define HTTP_RESP_MAX   ((RAW_FILE_MAX>UI_BODY_MAX?RAW_FILE_MAX:UI_BODY_MAX) + 256)

typedef struct {
    struct tcp_pcb *pcb;
    u8_t   in_use;
    u8_t   answered;        /* 这条连接已经答过了 —— 见 http_recv 里那段"只答一次" */
    u16_t  req_len;
    u16_t  resp_len;
    u16_t  resp_acked;
    http_tx_state tx;
    char   req[HTTP_REQ_MAX];
    char   resp[HTTP_RESP_MAX];
} http_conn;

static http_conn g_conn[HTTP_MAX_CONN];

static struct netif server_netif;

/* 最新一次结果。**页面读的就是它** —— 请求处理里没有诊断，诊断在 CPU1 上。
 * age_ms 在应答时现算（见 build_response），所以放久了的页面会看到年龄在涨。 */
static struct ui_status g_status;

/* ⚠ age 的基准只有一处能写：poll_frame() 里收到新帧那一刻。**别在应答路径上更新它。**
 *   一更新就会出现"每来一次 HTTP 请求都把基准重置到现在"，页面上年龄永远停在 0，
 *   而帧其实早就断了 —— 这类错在页面上看不出来。 */
static uint32_t        g_frame_tick;
#if UI_DAS_LIVE && (UI_DAS_ACTIVE_CHANNELS == 4 || UI_DAS_ACTIVE_CHANNELS >= 8)
static uint32_t g_location_tick;
#endif
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
static uint32_t g_location_poll_tick;
#endif
static unsigned        g_frame;         /* 第几帧，从 1 起 */
static uint32_t        g_last_seq;      /* ipc_consume 的游标：上一次已经看过的页序号。
                                         * 由本核持有、只增不改 —— ipc_consume 自己无状态，
                                         * 宿主机上才测得了它（见 sw/ps_ipc_test.c）。 */

/* 路由共用的临时 body 不放在栈上；build_response 在返回前复制到各连接的 resp。
 * 后续 TCP 分段发送使用连接自己的 resp，不依赖这块可被下一请求复用的缓冲区。 */
static char g_body[UI_BODY_MAX];

/* 1 ms 的全局计时器拍数（FCLK/2 = 333.333 MHz ⇒ 1 拍 = 3 ns）。与 ps_diag.h 的
 * dia_ticks_to_ms() 是同一个时基，只是方向相反 —— 那边是拍→毫秒，这边是毫秒→拍。 */
#define GTIMER_TICKS_PER_MS  333333u

static inline u32_t gtimer_lo(void) { return dia_gtimer_now(); }

/* 两个全局计时器读数之差就是走过的拍数，低位回绕也不影响（333 MHz 下 12.9 s 才绕一圈，
 * 下面每个间隔都远小于它）。1 拍 3 ns。
 *
 * ⚠ 这里曾经是一个"每次调用都重置 mark、返回间隔"的 elapsed_ms_since()，而调用处写的是
 *   `if (elapsed_ms_since(&t) >= 250u) { ... }` —— 那个判据实际问的是"**这一趟循环自己**
 *   有没有跑满 250 ms"。主循环一趟是微秒级，所以 tcp_fasttmr / tcp_slowtmr /
 *   eth_link_detect / RX 复位规避**四条全是死代码**，2026-10-10 之前一直是（这也是为什么
 *   丢包时 TCP 连一次重传都没有）。要"每 N 毫秒做一次"就得用下面这个：只有真的到期才
 *   重置 mark。别再退回那个写法。 */
static int due_ms(u32_t *mark, u32_t period)
{
    u32_t now = gtimer_lo();

    if (dia_ticks_to_ms(now - *mark) >= period) {
        *mark = now;
        return 1;
    }
    return 0;
}

/* 空转 ms 毫秒。只在**启动那一次**等待里用（等 CPU1 出第一帧），不在主循环里 ——
 * 主循环里空转就等于把网口停了，那正是这次拆核要消掉的东西。 */
#if !UI_DAS_LIVE || UI_DAS_ACTIVE_CHANNELS != 9
static void wait_ms(unsigned ms)
{
    u32_t t0 = gtimer_lo();
    u32_t want = ms * GTIMER_TICKS_PER_MS;

    while ((u32_t)(gtimer_lo() - t0) < want) {
        /* spin */
    }
}
#endif

/* ==========================================================================================
 * A9#1 那一半：站 11 -> 12 -> 13，以及把 CPU1 放出去的那几行
 * ==========================================================================================
 *
 * 这一段与 sw/ps_dualcore.c 的对应段逐行同形 —— 那边的每一行都在自己的文件头里标了出处
 * （BSP 的 boot.S / TRM / 链接脚本），而且 2026-09-19 已经上板量过一次。改这里之前先看那边，
 * 别让两份"同一个启动序列"各自漂。
 */

#define SLCR_UNLOCK_REG   0xF8000008u
#define SLCR_LOCK_REG     0xF8000004u
#define SLCR_UNLOCK_KEY   0xDF0Du
#define SLCR_LOCK_KEY     0x767Bu

#define A9_CPU_RST_CTRL   0xF8000244u
#define A9_RST1           (1u << 1)   /* 把 CPU1 按在复位里   */
#define A9_CLKSTOP1       (1u << 5)   /* 停 CPU1 的时钟       */
#define CPU1_RELEASE_MASK (A9_RST1 | A9_CLKSTOP1)

/* CPU1 起来之后从这个地址取入口。它在 BootROM 那段的顶上，不是一个普通变量。 */
#define CPU1_BOOT_ADDR    0xFFFFFFF0u

/* CPU1 的栈，4 KB，从顶往下长，落在 OCM。放 OCM 不放 .bss：这一段本来就是非缓存的
 * （见 ps_ipc.h 文件头），所以栈上不会有任何东西与 CPU0 的缓存重叠；而且它是 SRAM，
 * 比 DDR 少一个来回。共享页在它下面 32 KB —— 栈要溢到 32 KB 才踩得到那一页。 */
#define CPU1_STACK_TOP    0xFFFF8000u

/* BSP 自己的段表，两个核共用（translation_table.S）。只因为 Xil_SetTlbAttributes 要它
 * 才 extern 出来。 */
extern uint32_t MMUTable;

void cpu1_prep(void);
void cpu1_main(void);

/* CPU1 出复位时是 ARM 态、MMU 与缓存全关、sp 未定义。所以这个桩子**不能用栈** ——
 * naked 就是"别给我生成序言"，先摆好 sp 再 tail-call 进 cpu1_prep。
 *
 * 为什么用 movw/movt 而不是 `ldr sp,=0xFFFF8000`：那个写法会把常量扔进字面量池，而 GAS
 * 只在段尾冲池、ARM 的 PC 相对寻址够不到 4095 字节以外的位置。Vitis 编的是 -O0，
 * 池就会落到够不着的地方、汇编直接报 "pool needs to be closer"。这条是 ps_dualcore.c
 * 上真实踩过的坑（-O2 下碰巧能编过），不是理论顾虑。 */
__attribute__((naked, noinline))
void cpu1_entry(void)
{
    __asm__ __volatile__(
        "movw sp, #0x8000     \n"
        "movt sp, #0xFFFF     \n"
        "b    cpu1_prep       \n"
    );
}

/* VFP 是**每个核各有一份**的，而 CPU1 从不跑 BSP 的 _boot —— 它从上面的 cpu1_entry 进。
 * 所以 BSP 给 CPU0 开好的那个 FPU，CPU1 一点都没有：cpu1_main() 第一件事就是 fea_setup()，
 * 里面全是 double，第一条 VFP 指令就会当成未定义指令陷进去。CPSR 变成 0x1b（UND），
 * PC 停在 Xil_UndefinedExceptionHandler，共享页里的 busy 永远是 0。
 *
 * 2026-10-10 两核版 ui_app 第一次上板就停在这儿（串口那行 "no frame from A9#1 yet (busy=0)"）。
 * ps_dualcore.c 看不出来，因为它的 CPU1 只跑整数 LCG；ps_fft_test.c 的 A9#1 是显式开过的
 * （它的 CPACR 读回 0x00f00000），这里照抄同一份。
 *
 *   CPACR (p15,0,c1,c0,2)：位 20-21 = CP10、位 22-23 = CP11，都写 0b11 才是全权访问。
 *   FPEXC (p10,7,c8,c0,0)：位 30 = EN，管着 FPU 本体。
 *   FPSCR (p10,7,c8,c1,0)：0 = 就近舍入、不陷、**flush-to-zero 关**。FTZ 这条要紧：开着的话
 *                          非规格化中间值会被冲成 0，C 就和 MATLAB 分家了，而 MATLAB 不冲。 */
static void fpu_enable(void)
{
    __asm__ __volatile__(
        "mrc  p15, 0, r0, c1, c0, 2  \n"
        "orr  r0, r0, #(0xF << 20)   \n"
        "mcr  p15, 0, r0, c1, c0, 2  \n"
        "isb                         \n"
        "movw r0, #0                 \n"
        "movt r0, #0x4000            \n"   /* 1 << 30 */
        "fmxr fpexc, r0              \n"
        "mov  r0, #0                 \n"
        "fmxr fpscr, r0              \n"
        ::: "r0", "memory"
    );
}

/* 把 CPU1 拉到与 CPU0 同样的工作点，再交给 cpu1_main()。
 *
 * 为什么不能省：ARM 上 MMU 关着时缓存**根本不参与**，每次访问都当强序处理。CPU1 出复位时
 * 正是这个状态，ps_dualcore.c 上量到 ~23 MIPS（每条指令都去 DDR 取）。下面三处是照抄
 * BSP 启动序列**会做错**的地方：
 *   - 不用 Xil_DCacheInvalidate()：它底下会调 Xil_L2CacheInvalidate()，从 CPU1 作废 L2
 *     会把 CPU0 正在用的缓存内容全扔掉。只用 xil_cache_l.h 的 L1 版本。
 *   - 不碰 SCU：CPU0 已经开过了；从 CPU1 再开一次、或跑它的 "invalidate all"，
 *     会把 CPU0 在那里的重复标签丢掉。
 *   - 不初始化 L2：BSP 自己写着 "For AMP, assume running on CPU1. Don't initialize L2 Cache"。
 *
 * 段表是 BSP 那一份、两个核共用 TTBR0，所以 CPU0 给 OCM 段写的非缓存属性是白捡的，
 * 两个核也不可能对同一段给出两种说法。 */
__attribute__((noreturn, noinline))
void cpu1_prep(void)
{
    Xil_L1DCacheInvalidate();
    Xil_L1ICacheInvalidate();

    __asm__ __volatile__(
        "mov  r0, #0                \n"
        "mcr  p15, 0, r0, c8, c7, 0 \n"   /* 作废 TLB                        */
        "movw r0, #:lower16:_vector_table \n"
        "movt r0, #:upper16:_vector_table \n"
        "mcr  p15, 0, r0, c12, c0, 0\n"   /* VBAR：CPU1 自己的向量基址       */
        "movw r0, #:lower16:MMUTable      \n"
        "movt r0, #:upper16:MMUTable      \n"
        "orr  r0, r0, #0x5B         \n"   /* TTBR0 属性，与 BSP 同           */
        "mcr  p15, 0, r0, c2, c0, 0 \n"
        "mvn  r0, #0                \n"
        "mcr  p15, 0, r0, c3, c0, 0 \n"   /* DACR：所有域 manager            */
        "movw r0, #0x1005           \n"   /* SCTLR：MMU + D$ + I$            */
        "mcr  p15, 0, r0, c1, c0, 0 \n"
        "dsb                        \n"   /* 让 MMU 落定                     */
        "isb                        \n"
        "mrc  p15, 0, r0, c1, c0, 1 \n"   /* ACTLR                           */
        "orr  r0, r0, #(1 << 6)     \n"   /* SMP：加入 SCU 一致性            */
        "orr  r0, r0, #1            \n"   /* 缓存/TLB 维护广播               */
        "mcr  p15, 0, r0, c1, c0, 1 \n"
        ::: "r0", "memory"
    );

    fpu_enable();   /* 必须早于 cpu1_main()：站 11 第一件事就是 double 的 fea_setup */
    cpu1_main();
    __builtin_unreachable();
}

/* CPU1 的主循环：造一帧 -> 站 11 -> 12 -> 13 -> 发布。
 *
 * **一个字节都不往串口写。** 两个核同时写 UART0 会互相插字；这里也没有任何要人判断的东西，
 * 帧号、耗时、方位状态全在共享页里，由 CPU0 那一侧打出来。
 *
 * 帧周期按"上一次该起跑的时刻"推进（next 只在自己身上加），不按"上一次算完的时刻"，
 * 所以站 11 花掉的时间不会被算进周期、越拖越长。 */
void cpu1_main(void)
{
    volatile struct ipc_page *p=(volatile struct ipc_page *)IPC_BASE;
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
    (void)dia_classify_audio; /* Legacy single-beam classifier is not this path. */
    (void)fea_setup;
    for(;;)c9_tasks_cpu1(p);
#else
    static double x[DAS_AUDIO_SEGMENT];
    struct ipc_frame f;
    fea_setup(FRAME_FS,1400.0,4600.0);
    for(;;) {
        das_segment *segment=das_queue_take(&audio_shared.q);
        u32_t t0,t1;
        if(!segment) continue;
        memset(&f,0,sizeof f);
        f.audio.desc=segment->desc;
        memcpy(x,segment->samples,sizeof x);
        das_queue_release(segment); /* CPU0 can receive while DSP works on cached copy. */
        p->busy=1u;
        t0=dia_gtimer_now();
        dia_classify_audio(x,DAS_AUDIO_SEGMENT,UI_SHAFT_MILLIHZ/1000.0,&f.r);
        f.r.grid=(int)f.audio.desc.target_grid;
        f.r.grid_w=(int)f.audio.desc.grid_w;
        if(f.audio.desc.flags&DAS_FLAG_POSITION_UNKNOWN) {
            f.r.grid=-1;f.r.grid_w=0;
        }
        f.dir_ok=(u32_t)out_split_grid(f.r.grid,f.r.grid_w,&f.r.gx,&f.r.gy);
        f.r.azim_pct=out_azim_pct(f.r.gy,f.r.grid_w);
        f.audio.shaft_millihz=UI_SHAFT_MILLIHZ;
        das_export_plots(x,&f.audio);
        f.audio.valid=1u;
        t1=dia_gtimer_now();
        f.frame_ms=dia_ticks_to_ms(t1-t0);
        ipc_publish(p,&f);
        p->busy=0u;
    }
#endif
}

static void init_audio(void)
{
    Xil_SetTlbAttributes((INTPTR)&audio_shared,NORM_NONCACHE);
    das_queue_init(&audio_shared.q);
    audio_error=0;audio_blocks=0;pl_dropped=0;
#if UI_DAS_LIVE
    {
        das_bus bus=das_axi_bus(RV32_BASE);
        das_fifo_init(&fifo_receiver);
        audio_error=pl_live_prepare(&bus);
#if UI_DAS_ACTIVE_CHANNELS == 9
        c9h_init(&c9_health);c9_health.timer=dia_gtimer_now();
        c9_tasks_init();
        if(!audio_error)audio_error=c9_live_init();
        if(!audio_error)bus.write(bus.ctx,0x3c,0xd3000000u);
#endif
        live_ready=0;
    }
#endif
#if !UI_DAS_LIVE
    {
        unsigned i;double peak=0;
        dia_synth_frame(replay_source,DAS_AUDIO_SEGMENT);
        for(i=0;i<DAS_AUDIO_SEGMENT;i++) {
            double v=replay_source[i];if(v<0)v=-v;if(v>peak)peak=v;
        }
        if(peak>0) for(i=0;i<DAS_AUDIO_SEGMENT;i++) replay_source[i]*=0.8/peak;
#if UI_DYNAMIC_REPLAY
        for(i=0;i<DAS_AUDIO_SEGMENT;i++) {
            double t=(double)i/FRAME_FS,sc,cc,sm,cm;
            d_sincos(dia_ph_wrap(6.283185307179586*2000.0*t),&sc,&cc);
            d_sincos(dia_ph_wrap(6.283185307179586*100.0*t),&sm,&cm);
            replay_source[i]=0.5*(1.0+0.8*cm)*cc;
            d_sincos(dia_ph_wrap(6.283185307179586*4000.0*t),&sc,&cc);
            d_sincos(dia_ph_wrap(6.283185307179586*200.0*t),&sm,&cm);
            replay_second[i]=0.5*(1.0+0.8*cm)*cc;
        }
#endif
    }
    replay_seq=0;replay_first=0;replay_next_tick=dia_gtimer_now();
#endif
}

/* Exactly one owner receives location publications, including HTTP requests.
 * Re-reading a retained result must not create another latency observation. */
static void poll_location(void)
{
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
    uint32_t now=dia_gtimer_now();
    if((uint32_t)(now-g_location_poll_tick)<
       (uint64_t)XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ*C9_LOCATION_POLL_US/2000000u)return;
    if(g_location_poll_tick) {
        uint32_t gap=c9_ticks_to_us(now-g_location_poll_tick);
        if(gap>c9_location_poll_gap_max_us)c9_location_poll_gap_max_us=gap;
        if(gap>200u)c9_location_poll_overruns++;
    }
    g_location_poll_tick=now;
    das_bus b=das_axi_bus(RV32_BASE);
    uint32_t sequence=mic_read_word(&b,90);
    if(sequence && !(sequence&1u) && (!c9_location.have||sequence!=c9_location.sequence)){
        mic_levels candidate=g_status.mics;
        mic_location_poll(&b,&candidate);
        uint32_t first=mic_read_word(&b,239),end=mic_read_word(&b,90);
        uint32_t receipt=b.read(b.ctx,0x3e0);
        if(end==sequence&&candidate.loc_seq==sequence&&
           c9_deadline_receive(&c9_location,sequence,candidate.loc_frame,first,receipt,candidate.loc_valid)>0){
            g_status.mics=candidate;g_location_tick=dia_gtimer_now();
        }
    }
    if(c9_deadline_stale(&c9_location,b.read(b.ctx,0x3e0))){
        g_status.mics.loc_valid=0;g_status.mics.loc_reason|=64u;
    }
#endif
}
static void poll_audio(void)
{
    int rc;
    if(audio_error) return;
    poll_location();
#if UI_DAS_LIVE
    das_bus bus=das_axi_bus(RV32_BASE);
    uint32_t mailbox=bus.read(bus.ctx,0x34);
    if(mailbox==0xDA500001u)live_ready=1;
    if(bus.read(bus.ctx,0x30) || (mailbox&0xffff0000u)==0xDA5F0000u ||
       (!live_ready && (uint32_t)(dia_gtimer_now()-live_start_tick)>1666666665u)) {
        audio_error=-5;pl_live_stop(&bus);das_queue_break(&audio_shared.q);return;
    }
#if UI_DAS_ACTIVE_CHANNELS == 9
    rc=c9_live_poll(&received_audio,&pl_dropped);
    poll_location();
#else
    rc=das_fifo_poll(&bus,&fifo_receiver,&received_audio,&pl_dropped);
#endif
    if(rc==DAS_EMPTY)return;
    if(rc!=DAS_OK){audio_error=rc;pl_live_stop(&bus);das_queue_break(&audio_shared.q);return;}
#else
    const uint32_t period=4369066u; /* nominal GTIMER / 39062.5 * 512 */
    uint32_t now=dia_gtimer_now(),skip;
    if((int32_t)(now-replay_next_tick)<0)return;
    skip=(now-replay_next_tick)/period;
    if(skip) {replay_seq+=skip;replay_first+=(uint64_t)skip*512u;pl_dropped+=skip*512u;}
    replay_next_tick+=(skip+1u)*period;
#if UI_DYNAMIC_REPLAY
    das_replay_dynamic_block(replay_source,replay_second,DAS_AUDIO_SEGMENT,
                             replay_seq++,replay_first,&received_audio);
#else
    das_replay_block(replay_source,DAS_AUDIO_SEGMENT,replay_seq++,replay_first,&received_audio);
#endif
    replay_first+=512u;
    received_audio.desc.dropped_samples=pl_dropped;
    if(skip)received_audio.desc.flags|=DAS_FLAG_GAP;
#endif
    audio_blocks++;
    pl_dropped=received_audio.desc.dropped_samples;
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
    /* CPU1 diagnoses independently separated same-snapshot candidates.
     * Continuous chosen-target GSC audio remains available over UDP. */
    return;
#endif
    rc=das_queue_push(&audio_shared.q,&received_audio);
    if(rc==DAS_BAD_BLOCK) { /* invalid startup data resets accumulation, not the whole service */ }
}

#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
/* Safe inside HTTP callbacks: services MMIO/audio only, never re-enters lwIP.
 * Avoid doing a whole audio slice after every tiny heatmap chunk. */
static void c9_realtime_checkpoint(void)
{
    if(c9_ticks_to_us(dia_gtimer_now()-c9_last_poll)>=75u)poll_audio();
    else poll_location();
}
#include "ps_circular9_api.h"
#endif

/* 放 CPU1 出去。三步的次序不能换：
 *   1. 先把共享页所在的 1 MB 段改成非缓存 —— CPU1 一起来就写它，改晚一步两边就可能
 *      各自拿着一份副本（默认是可缓存的，见 ps_ipc.h 文件头）。
 *   2. 再 ipc_reset() 清零。magic 最后写，所以 CPU1 读到 magic 就说明整页已经干净。
 *   3. 最后才指入口 + sev。
 *
 * 为什么 bit1/bit5 照清不误：2026-09-19 量到 A9_CPU_RST_CTRL 读回 0x00000000 —— 这块板上
 * CPU1 从来没被按在复位里，是 BootROM 把它停在 wfe 上，真正叫起它的是"写入口 + sev"。
 * 清这两位在本板上是空操作，留着是因为它不花钱，且覆盖"CPU1 真被按在复位里"的启动流程。 */
static void start_cpu1(void)
{
    u32_t rst = Xil_In32(A9_CPU_RST_CTRL);

    Xil_SetTlbAttributes((INTPTR)IPC_BASE, NORM_NONCACHE);
    ipc_reset((volatile struct ipc_page *)IPC_BASE);

    Xil_Out32(SLCR_UNLOCK_REG, SLCR_UNLOCK_KEY);
    Xil_Out32(CPU1_BOOT_ADDR, (u32_t)cpu1_entry);
    __asm__ __volatile__("dsb" ::: "memory");
    __asm__ __volatile__("sev");
    Xil_Out32(A9_CPU_RST_CTRL, rst & ~CPU1_RELEASE_MASK);
    Xil_Out32(SLCR_LOCK_REG, SLCR_LOCK_KEY);

    xil_printf("   A9#1 entry = cpu1_entry, sp = 0x%x; A9_CPU_RST_CTRL 0x%x -> 0x%x\r\n",
               (unsigned)CPU1_STACK_TOP, (unsigned)rst,
               (unsigned)Xil_In32(A9_CPU_RST_CTRL));
}

/* -- CPU0 这一半：从共享页取一帧 ------------------------------------------------------------- */

/* 有新帧就落进 g_status 并打串口那几行；没有就立刻返回（几十纳秒）。
 *
 * 打串口**不是**顺手：网页上的字段和 FDIAG 那行是同一帧、同一组数，出问题时第一件事
 * 就是拿它们逐字段对拍（见 docs 的上板步骤）。 */
static void poll_frame(void)
{
    volatile struct ipc_page *p = (volatile struct ipc_page *)IPC_BASE;
    struct ipc_frame f;

    if (!ipc_consume(p, &f, &g_last_seq)) {
        return;
    }

    /* 帧号和帧时刻都取本核这一侧的值：age 量的是"页面多久没更新了"，
     * 不是"CPU1 多久没算了"，两回事。 */
    g_frame      = ipc_done(p);
    g_frame_tick = dia_gtimer_now();
    ui_status_put(&g_status, &f.r, g_frame, 0u,
                  (f.audio.desc.flags & DAS_FLAG_SYNTHETIC) != 0u);
    g_status.audio=f.audio;
    g_status.diag_ms=f.frame_ms;   /* 1 = 合成自检帧，页面会标出来 */

#if !UI_DAS_LIVE
    /* UART prints can block for longer than the FIFO's 6.55 ms capacity. */
    xil_printf("FRAME %u (%u ms on A9#1)\r\n", g_frame, (unsigned)f.frame_ms);
    if (!f.dir_ok) {
        xil_printf("PL  : no steering result yet (status=0x%x)\r\n", (unsigned)f.status);
    }
    out_print_human(&f.r);
    if (!out_print_diag(&f.r)) {
        xil_printf("DIAG: class name out of range, the line above is not usable\r\n");
    }
#endif
}

/* -- 应答 ----------------------------------------------------------------------------------- */

static u16_t resp_printf(http_conn *c, u16_t off, const char *fmt, ...)
{
    va_list ap;
    int n;
    int room = (int)HTTP_RESP_MAX - (int)off;

    if (room <= 1) {
        return off;
    }
    va_start(ap, fmt);
    n = vsnprintf(c->resp + off, (size_t)room, fmt, ap);
    va_end(ap);
    if (n < 0) {
        return off;
    }
    if (n >= room) {
        return (u16_t)(HTTP_RESP_MAX - 1);   /* 装不下就停手，让下面的长度检查报 500 */
    }
    return (u16_t)(off + n);
}

static u16_t header(http_conn *c, const struct ui_reply *rep)
{
    return resp_printf(c, 0,
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n",
        rep->code, rep->reason, rep->ctype, rep->len);
}

/* 一行请求 → 一整份应答。**先量 body、再写头**，因为 Content-Length 得知道长度。 */
static u16_t build_response(http_conn *c)
{
    struct ui_reply rep;
    u16_t off;
    const void *body=g_body;

    /* age 在这里现算：放久了页面上的 age 才会涨，而不是冻结在算完那一刻 */
    if (g_status.have_result) {
        g_status.age_ms = dia_ticks_to_ms(dia_gtimer_now() - g_frame_tick);
    }

    g_status.input_mode=UI_DAS_LIVE?2u:1u;
    g_status.input_channels=UI_DAS_LIVE?UI_DAS_ACTIVE_CHANNELS:0u;
    g_status.input_error=audio_error;
    g_status.received_blocks=audio_blocks;
    g_status.pl_dropped=pl_dropped;
    g_status.ps_dropped=audio_shared.q.dropped_samples;
    g_status.discontinuities=audio_shared.q.discontinuities;
    g_status.computing=ipc_busy((volatile struct ipc_page *)IPC_BASE);
#if UI_DAS_LIVE && (UI_DAS_ACTIVE_CHANNELS == 4 || UI_DAS_ACTIVE_CHANNELS >= 8)
    { das_bus bus=das_axi_bus(RV32_BASE);
      mic_levels_poll(&bus,&g_status.mics);
#if UI_DAS_ACTIVE_CHANNELS == 9
      poll_location();
#else
      uint32_t previous=g_status.mics.loc_seq;
      mic_location_poll(&bus,&g_status.mics);
      if(previous!=g_status.mics.loc_seq)g_location_tick=dia_gtimer_now();
#endif
      g_status.mics.loc_age_ms=g_status.mics.loc_seq?dia_ticks_to_ms(dia_gtimer_now()-g_location_tick):0;
    }
#endif
#if UI_DAS_LIVE
#if UI_DAS_ACTIVE_CHANNELS == 9
    if(c9_gui_route(c->req,&rep,g_body,sizeof(g_body))) {
        /* Read-only plots and bounded monitoring; no DSP in HTTP callbacks. */
    } else if(c9_tasks_route(c->req,&rep,g_body,sizeof(g_body))) {
        /* Candidate audio/diagnosis routes never execute DSP on CPU0. */
    } else if(strncmp(c->req,"GET /api/target?grid=",sizeof("GET /api/target?grid=")-1)==0) {
        uint32_t grid;
        if(c9_http_decimal(c->req+sizeof("GET /api/target?grid=")-1,0,1023,&grid)) {
            c9_target_fault_mode=0;c9_fault_track=0;
            das_bus b=das_axi_bus(RV32_BASE);b.write(b.ctx,0x3c,0xd1000000u|grid);
            snprintf(g_body,sizeof(g_body),"{\"mode\":\"manual\",\"requested_grid\":%u,\"geometry_confirmed\":%u}",(unsigned)grid,ACOUSTIC_GEOMETRY_CONFIRMED);
            rep=(struct ui_reply){202,"Accepted","application/json",(int)strlen(g_body)};
        } else {strcpy(g_body,"{\"error\":\"invalid_grid\"}");rep=(struct ui_reply){400,"Bad Request","application/json",(int)strlen(g_body)};}
    } else if(strncmp(c->req,"GET /api/target/auto ",sizeof("GET /api/target/auto ")-1)==0) {
        c9_target_fault_mode=0;c9_fault_track=0;
        das_bus b=das_axi_bus(RV32_BASE);b.write(b.ctx,0x3c,0xd2000000u);
        strcpy(g_body,"{\"mode\":\"automatic_localization\"}");rep=(struct ui_reply){202,"Accepted","application/json",(int)strlen(g_body)};
    } else if(strncmp(c->req,"GET /api/gsc/on ",16)==0||strncmp(c->req,"GET /api/gsc/off ",17)==0||
       strncmp(c->req,"GET /api/gsc/freeze ",20)==0||strncmp(c->req,"GET /api/gsc/adapt ",19)==0) {
        if(strncmp(c->req,"GET /api/gsc/on ",16)==0)c9_requested=1;
        if(strncmp(c->req,"GET /api/gsc/off ",17)==0)c9_requested=0;
        if(strncmp(c->req,"GET /api/gsc/freeze ",20)==0)c9_freeze=1;
        if(strncmp(c->req,"GET /api/gsc/adapt ",19)==0)c9_freeze=0;
        rep=(struct ui_reply){200,"OK","application/json",c9_status(g_body,sizeof(g_body))};
    } else if(strncmp(c->req,"GET /api/gsc ",13)==0) {
        rep=(struct ui_reply){200,"OK","application/json",c9_status(g_body,sizeof(g_body))};
    } else if(strncmp(c->req,"GET /api/heatmap ",17)==0) {
        das_bus b=das_axi_bus(RV32_BASE);uint32_t seq=mic_read_word(&b,90);
        uint32_t accepted=mic_read_word(&b,91),reason=mic_read_word(&b,97),frame=mic_read_word(&b,1);
        uint32_t ptr=mic_read_word(&b,235),first_tick=mic_read_word(&b,239);int32_t values[1024];
        int valid=seq&&!(seq&1u)&&!(ptr&3u)&&ptr+sizeof(values)<=0x2800;
        if(valid) {
            for(unsigned i=0;i<1024;i+=16) {
                /* Audio/location also use the indirect MMIO address. Restore it
                 * for every chunk; the enclosing seqlock rejects mixed maps. */
                b.write(b.ctx,0x80,0x80000000u+ptr/4u+i);
                for(unsigned k=0;k<16;k++)values[i+k]=(int32_t)b.read(b.ctx,0x88);
                c9_realtime_checkpoint();
            }
            valid=seq==mic_read_word(&b,90);
        }
        if(valid) {
            uint32_t map_age_us=(b.read(b.ctx,0x3e0)-first_tick)/C9_PL_TICKS_PER_US;
            if(map_age_us>C9_STALE_AFTER_US){accepted=0;reason|=64u;}
            int n=snprintf(g_body,sizeof(g_body),"{\"sequence\":%u,\"frame\":%u,\"accepted\":%u,\"reason\":%u,\"map_age_us\":%u,\"stale_after_us\":%u,\"width\":32,\"scan_model\":\"far_field_direction\",\"azimuth_min_deg\":-90,\"azimuth_max_deg\":90,\"elevation_min_deg\":-90,\"elevation_max_deg\":90,\"scores\":[",
                (unsigned)seq,(unsigned)frame,(unsigned)accepted,(unsigned)reason,(unsigned)map_age_us,(unsigned)C9_STALE_AFTER_US);
            for(unsigned i=0;i<1024;i++) {
                n=ui_append(g_body,sizeof(g_body),n,"%s%d",i?",":"",(int)values[i]);
                if((i&15u)==15u)c9_realtime_checkpoint();
            }
            n=ui_append(g_body,sizeof(g_body),n,"]}");rep=(struct ui_reply){200,"OK","application/json",n};
        } else {strcpy(g_body,"{\"state\":\"updating\"}");rep=(struct ui_reply){202,"Accepted","application/json",(int)strlen(g_body)};}
    } else if(strncmp(c->req,"GET /api/raw/start ",19)==0) {
        strcpy(g_body,"{\"mode\":\"continuous_udp\",\"port\":1234,\"format\":\"C9C2\"}");
        rep=(struct ui_reply){200,"OK","application/json",(int)strlen(g_body)};
    } else
#endif
    if(strncmp(c->req,"GET /api/raw/start ",19)==0) {
        das_bus bus=das_axi_bus(RV32_BASE);
        int rc=raw_capture_start(&raw_receiver,&bus,dia_ticks_to_ms(dia_gtimer_now()));
        rep.code=rc==0?202:409;rep.reason=rc==0?"Accepted":"Conflict";
        rep.ctype="application/json";
        rep.len=snprintf(g_body,sizeof g_body,"{\"state\":%u,\"id\":%u,\"error\":%d}",
                         (unsigned)raw_receiver.state,(unsigned)raw_receiver.id,rc);
    } else if(strncmp(c->req,"GET /api/raw ",13)==0) {
        rep.code=raw_receiver.state==3?200:raw_receiver.state==4?409:202;
        rep.reason=rep.code==200?"OK":rep.code==202?"Accepted":"Conflict";
        if(rep.code==200) {
            rep.ctype="application/octet-stream";rep.len=(int)raw_receiver.length;
            body=raw_receiver.file;
        } else {
            rep.ctype="application/json";
            rep.len=snprintf(g_body,sizeof g_body,"{\"state\":%u,\"id\":%u,\"error\":%u}",
                             (unsigned)raw_receiver.state,(unsigned)raw_receiver.id,(unsigned)raw_receiver.error);
        }
    } else
#endif
    rep = ui_route(c->req, &g_status, g_body, (int)sizeof g_body);

    off = header(c, &rep);
    if ((int)off + rep.len >= (int)HTTP_RESP_MAX) {
        /* 页面或 JSON 长过了缓冲区。报 500 而不是截断着发 —— 半句 JSON 在浏览器里
         * 表现为整页空白，比一个明确的 500 难查得多。 */
        rep.code = 500;
        rep.reason = "Internal Server Error";
        rep.ctype = "text/plain";
        rep.len = 0;
        off = header(c, &rep);
        return off;
    }
    memcpy(c->resp + off, body, (size_t)rep.len);
    return (u16_t)(off + (u16_t)rep.len);
}

/* -- HTTP 连接 ------------------------------------------------------------------------------ */

static void http_conn_close(http_conn *c)
{
    if (c->pcb != NULL) {
        tcp_arg(c->pcb, NULL);
        tcp_recv(c->pcb, NULL);
        tcp_sent(c->pcb, NULL);
        tcp_err(c->pcb, NULL);
        tcp_close(c->pcb);
        c->pcb = NULL;
    }
    c->in_use = 0;
    c->answered = 0;
    c->req_len = 0;
    c->resp_len = 0;
    c->resp_acked = 0;
    c->tx.length = c->tx.queued = 0;
}

static int http_tcp_write(void *ctx, const char *data, uint16_t length)
{
    err_t rc = tcp_write((struct tcp_pcb *)ctx, data, length, TCP_WRITE_FLAG_COPY);
    return rc == ERR_OK ? 0 : (rc == ERR_MEM ? 1 : -1);
}

static void http_send_pending(http_conn *c)
{
    if (!c->in_use || !c->answered || c->pcb == NULL) return;
    if (http_tx_step(&c->tx, c->resp, tcp_sndbuf(c->pcb), http_tcp_write, c->pcb) < 0) {
        http_conn_close(c);
        return;
    }
    /* lwIP retries transient output failures; keep the response until ACKed. */
    tcp_output(c->pcb);
}

static err_t http_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    http_conn *c = (http_conn *)arg;

    (void)pcb;
    c->resp_acked = (u16_t)(c->resp_acked + len);
    if (c->resp_acked >= c->resp_len) {
        http_conn_close(c);          /* 发完就关：一条连接一个请求，浏览器会自己再连 */
    }
    return ERR_OK;
}

static err_t http_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    http_conn *c = (http_conn *)arg;
    u16_t room, take;

    if (err != ERR_OK) {
        if (p != NULL) {
            pbuf_free(p);
        }
        http_conn_close(c);
        return ERR_OK;
    }
    if (p == NULL) {                 /* 对端关了 */
        http_conn_close(c);
        return ERR_OK;
    }

    /* 只要第一行，而且只要一次：后面的东西一概不看。 */
    if (c->req_len < HTTP_REQ_MAX - 1) {
        room = (u16_t)(HTTP_REQ_MAX - 1 - c->req_len);
        take = p->tot_len < room ? p->tot_len : room;
        pbuf_copy_partial(p, c->req + c->req_len, take, 0);
        c->req_len = (u16_t)(c->req_len + take);
        c->req[c->req_len] = '\0';
    }
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);

    /* 请求行没收全就先不应答。 */
    if (strchr(c->req, '\n') == NULL) {
        return ERR_OK;
    }

    /* ⚠ **一条连接只答一次。** c->req 里那行是一直留着的，所以"请求行是否完整"这个条件
     *   在后面的数据到达时会**再次成立**：浏览器几乎总是把请求行和它后面的头分在两个
     *   TCP 段里发，第二段一到就又答一遍。结果是同一连接上两份应答（第一份还没 ACK 完，
     *   resp_len/resp_acked 就被重置了，连接关不掉也乱套）。
     *   这不是假想：build/scratch/ui_http_check.c 按"行 + 头分两段"喂进去，量到 tcp_write
     *   被调了两次。从 ps_net.c 抄来的那个骨架里同样是这个问题。 */
    if (c->answered) {
        return ERR_OK;              /* 剩下的字节一律不看：应答里写的是 Connection: close */
    }
    c->answered = 1;

    c->resp_len = build_response(c);
    c->resp_acked = 0;
    c->tx.length = c->resp_len;
    c->tx.queued = 0;

#if UI_LOG_REQ
    {
        char *nl = strpbrk(c->req, "\r\n");
        if (nl != NULL) {
            *nl = '\0';
        }
        xil_printf("net: %s -> %u\r\n", c->req, (unsigned)c->resp_len);
    }
#endif

    http_send_pending(c);
    return ERR_OK;
}

static void http_err(void *arg, err_t err)
{
    http_conn *c = (http_conn *)arg;

    (void)err;
    /* lwIP 已经把这个 pcb 释放了，所以不要再对它调 tcp_close()。 */
    c->pcb = NULL;
    c->in_use = 0;
    c->answered = 0;
    c->req_len = 0;
    c->resp_len = 0;
    c->resp_acked = 0;
    c->tx.length = c->tx.queued = 0;
}

static err_t http_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    http_conn *c = NULL;
    int i;

    (void)arg;
    if (err != ERR_OK || newpcb == NULL) {
        return ERR_VAL;
    }

    for (i = 0; i < HTTP_MAX_CONN; i++) {
        if (!g_conn[i].in_use) {
            c = &g_conn[i];
            break;
        }
    }
    if (c == NULL) {
        /* 槽位满了就拒。悄悄丢掉会看起来像板子死了。 */
        xil_printf("net: too many connections, refusing\r\n");
        return ERR_MEM;
    }

    c->pcb = newpcb;
    c->in_use = 1;
    c->answered = 0;
    c->req_len = 0;
    c->resp_len = 0;
    c->resp_acked = 0;
    c->tx.length = c->tx.queued = 0;
    c->req[0] = '\0';

    tcp_arg(newpcb, c);
    tcp_recv(newpcb, http_recv);
    tcp_sent(newpcb, http_sent);
    tcp_err(newpcb, http_err);
    tcp_nagle_disable(newpcb);       /* 应答又小又怕等 */
    return ERR_OK;
}

static int httpd_start(void)
{
    struct tcp_pcb *pcb = tcp_new();

    if (pcb == NULL) {
        return -1;
    }
    if (tcp_bind(pcb, IP_ADDR_ANY, UI_HTTP_PORT) != ERR_OK) {
        tcp_close(pcb);
        return -1;
    }
    pcb = tcp_listen(pcb);
    if (pcb == NULL) {
        return -1;
    }
    tcp_accept(pcb, http_accept);
    return 0;
}

/* -- main ----------------------------------------------------------------------------------- */

/* EMAC 的中断。BSP 只把三个回调挂进驱动（setup_isr），从没 Enable 过中断线，也没装 GIC，
 * 所以这一段必须由应用补 —— 见文件头那两条实测。
 *
 * 指向 XEmacPs_IntrHandler 而不是 emacps_recv_handler：前者读 ISR、写回清位，再按位分发给
 * 驱动里注册的 emacps_recv_handler / emacps_send_handler / emacps_error_handler。没有它，
 * ISR 位没人清、TX 完成的 BD 没人回收、TX underrun 也没人重启发送。
 *
 * 调用时机：**必须在 xemac_add() 之后**。emacps v3.12 的签名是
 * `void XEmacPs_IntrHandler(void *XEmacPsPtr)` —— 第 4 个参数收的是 XEmacPs **实例指针**，
 * 不是基地址，而实例要等 xemac_add 里 low_level_init 才建出来。晚这一步不丢事件：
 * XEmacPs_Start 已经把中断线拉起来了，那一笔在 GIC 里挂着，这里一 Enable 就补上。 */
static XScuGic gic;

static int gic_setup(void)
{
    XScuGic_Config *cfg;
    struct xemac_s *xemac;
    xemacpsif_s *xemacpsif;
    s32_t st;

    xemac     = (struct xemac_s *)server_netif.state;
    xemacpsif = (xemacpsif_s *)xemac->state;

    cfg = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
    if (cfg == NULL) {
        return XST_FAILURE;
    }
    st = XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress);
    if (st != XST_SUCCESS) {
        return st;
    }

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);

    st = XScuGic_Connect(&gic, XPAR_XEMACPS_0_INTR,
                         (Xil_ExceptionHandler)XEmacPs_IntrHandler,
                         (void *)&xemacpsif->emacps);
    if (st != XST_SUCCESS) {
        return st;
    }
    XScuGic_Enable(&gic, XPAR_XEMACPS_0_INTR);
    return XST_SUCCESS;
}

static void print_ip(const char *label, const ip_addr_t *a)
{
    /* u32_t，不是 int：ip4_addr 的字段是无符号的，混着会被 -Wformat=2 挡下来。
     * 四个 %u 连着打是合法的 —— xil_printf 不支持的是宽度修饰符（%08x / %-12s），
     * 不是多个转换（见 ps_output.h 文件头那三条）。 */
    xil_printf("%s%u.%u.%u.%u\r\n", label,
               (unsigned)(ip4_addr1(a) & 0xFFu), (unsigned)(ip4_addr2(a) & 0xFFu),
               (unsigned)(ip4_addr3(a) & 0xFFu), (unsigned)(ip4_addr4(a) & 0xFFu));
}

int main(void)
{
    ip_addr_t ipaddr, netmask, gw;
    /* 每块板子唯一。只有两块板子接同一个交换机时才有意义 —— 和 ps_net.c 的末字节分开，
     * 免得 ARP 表里两条记录长得一样。 */
    unsigned char mac[6] = { 0x00, 0x0a, 0x35, 0x00, 0x02, 0x01 };

    u32_t t_fast = gtimer_lo(), t_slow = gtimer_lo(), t_rx = gtimer_lo(), t_link = gtimer_lo();
#if !UI_DAS_LIVE || UI_DAS_ACTIVE_CHANNELS != 9
    int i;
#endif

    xil_printf("\r\n== ps_ui: A9#0 serves the diagnosis, A9#1 runs 11->12->13 ==\r\n");

    dia_gtimer_start();
    g_frame    = 0;
    g_last_seq = 0u;
    ui_status_clear(&g_status);

    /* 站 11 的 setup 现在归 CPU1（见 cpu1_main）—— 它写的那些缓冲只有它自己读，
     * 所以不用在这里操心两个核的先后。这里只剩共享页的初始化和放它出去。 */
    init_audio();
    start_cpu1();

    IP4_ADDR(&ipaddr,  UI_IP_A, UI_IP_B, UI_IP_C, UI_IP_D);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      UI_GW_A, UI_GW_B, UI_GW_C, UI_GW_D);

    lwip_init();

    if (!xemac_add(&server_netif, &ipaddr, &netmask, &gw, mac,
                   XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("ps_ui: xemac_add failed -- is ENET0 enabled in the BD?\r\n");
        xil_printf("        scripts/ps7_config.tcl turns it on; the XSA must be re-exported\r\n");
        xil_printf("        and the platform updated before this can work.\r\n");
        return -1;
    }
    netif_set_default(&server_netif);
    netif_set_up(&server_netif);

    /* 装 GIC 要在 xemac_add 之后（要 XEmacPs 实例），放行全局中断再往后 —— 见 gic_setup。 */
    if (gic_setup() != XST_SUCCESS) {
        xil_printf("ps_ui: SCU GIC setup failed -- EMAC interrupts would stay masked\r\n");
        return -1;
    }

    if (httpd_start() != 0) {
        xil_printf("ps_ui: could not listen on port %u\r\n", (unsigned)UI_HTTP_PORT);
        return -1;
    }
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
    if(c9_network_start())return -1;
#endif

    /* 到这一步驱动回调、netif、监听口都就位了，才放行全局中断。早了只会让中断落在还没
     * 连上 GIC 的窗口里 —— 那一位没人清，得等下一次事件才补上。 */
    Xil_ExceptionEnable();

    xil_printf("\r\n");
    print_ip("   board IP : ", &ipaddr);
    print_ip("   netmask  : ", &netmask);
    print_ip("   gateway  : ", &gw);
    xil_printf("   set the PC's Ethernet adapter to %u.%u.%u.20 / 255.255.255.0,\r\n",
               UI_IP_A, UI_IP_B, UI_IP_C);
    xil_printf("   then open http://%u.%u.%u.%u/\r\n", UI_IP_A, UI_IP_B, UI_IP_C, UI_IP_D);
    xil_printf("   PHY address is discovered on MDIO at start; link comes up a few seconds\r\n");
    xil_printf("   after that. Until a frame has run, the page says 'waiting'.\r\n");
    xil_printf("   A9#1 runs the chain (11->12->13); it never writes to this UART.\r\n");
    xil_printf("   SOURCE: %s; 512-sample blocks -> DDR segments -> A9#1 diagnosis\r\n",
               UI_DAS_LIVE ? "PL DAS window" : "synthetic audio replay");

#if !UI_DAS_LIVE
    /* Replay starts when reception is ready, after blocking PHY negotiation. */
    replay_next_tick = dia_gtimer_now();
#else
    if(!audio_error) {
        das_bus bus=das_axi_bus(RV32_BASE);
        live_start_tick=dia_gtimer_now();pl_live_start(&bus);
    }
#endif

    /* 等 CPU1 出第一帧再进主循环：页面上先有数比先空着好。**有上限** —— 卡在这里什么都不打，
     * 比页面空着难查得多。4000 x 1 ms = 4 s，等待期间持续接收音频。 */
#if !UI_DAS_LIVE || UI_DAS_ACTIVE_CHANNELS != 9
    for (i = 0; i < 4000 && g_frame == 0u; i++) {
        poll_audio();
        poll_frame();
        if (g_frame == 0u) {
            wait_ms(1u);
        }
    }
    if (g_frame == 0u) {
        /* busy=1 说明 CPU1 在、只是在啃第一帧；busy=0 才说明它压根没起来。
         * 这两种情况的下一步完全不同，所以得分开说。 */
        xil_printf("   no frame from A9#1 yet (busy=%u); the page will say 'waiting'\r\n",
                   (unsigned)ipc_busy((volatile struct ipc_page *)IPC_BASE));
    }
#endif

    for (;;) {
        poll_audio();
#if UI_DAS_LIVE
        { das_bus bus=das_axi_bus(RV32_BASE);
          raw_capture_poll(&raw_receiver,&bus,dia_ticks_to_ms(dia_gtimer_now())); }
#endif
        /* 收包那一趟在中断里（emacps_recv_handler 由 XEmacPs_IntrHandler 调，见 gic_setup）。
         * 这里只把 recv_q 里已经排好的包交给 lwIP —— 没有中断时它自己什么都收不到。 */
        xemacif_input(&server_netif);
        poll_audio();
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
        c9_network_poll();
        poll_audio();
        {das_bus bus=das_axi_bus(RV32_BASE);
         c9_rpm_poll(&bus);c9_tasks_map_poll(&bus);c9_tasks_receive();c9_tasks_schedule();c9_tasks_select_fault(&bus);}
        poll_audio();
#endif
        { int connection;
          for (connection = 0; connection < HTTP_MAX_CONN; ++connection) {
              http_send_pending(&g_conn[connection]);
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
              c9_realtime_checkpoint();
#endif
          }
        }

        /* TCP 要喂拍子。厂商模板把这两个放 250 ms / 500 ms 的定时里。注意是 due_ms：
         * 判据是"距上次真的做这件事"过了多久，不是这一趟循环跑了多久（差别见 due_ms 的注释）。 */
        if (due_ms(&t_fast, 250u)) {
            tcp_fasttmr();
            poll_audio();
        }
        if (due_ms(&t_slow, 500u)) {
            tcp_slowtmr();
            poll_audio();
        }

        /* Xilinx SI #692601 的软件规避：重收流量下 RX 路径可能不再响应，这里把它复位。
         * 厂商模板是每 100 ms 一次，照跟。 */
        if (due_ms(&t_rx, 100u)) {
            xemacpsif_resetrx_on_no_rxdata(&server_netif);
            poll_audio();
        }

        /* 重读 PHY，好让页面上能写"网线到底插没插"。厂商模板每秒一次，照跟。 */
        if (due_ms(&t_link, 1000u)) {
            eth_link_detect(&server_netif);
            poll_audio();
        }

        /* 看一眼共享页有没有新帧。这一次调用是几十纳秒、没有就立刻返回 —— 费时的站 11
         * 在另一个核上跑，所以这一行放在哪里都不影响网口。 */
        poll_audio();
        poll_frame();
#if UI_DAS_LIVE && UI_DAS_ACTIVE_CHANNELS == 9
        c9_gui_poll();
        c9_network_poll();
        poll_location();
#endif
    }
}
