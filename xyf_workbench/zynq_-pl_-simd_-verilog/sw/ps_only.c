/* PS-only 基线 —— README §34 的「PS-only vs PS+PL」里的那一半。
 *
 * ── 它是什么，以及它**不是**什么 ────────────────────────────────────────────
 * 把**同一份固件源码**（sw/fw/fw_main.c 与它调用的全部内核）编到 Cortex-A9 上，
 * 让它自己把整条链算完，用 A9 的 PMU 周期计数器计时。
 *
 * ⚠ 不是"另写一版算法"。这一点是本文件唯一的设计约束：`#define main fw_workload`
 *   之后**整个 fw_main.c 原样进来**，所以工作负载的同一性是**编译期**保证的，
 *   不是"我照着抄了一遍"。两边一旦分叉，"加速比"量的就是两件不同的事。
 *
 * 对照怎么读（三个数，别混）：
 *   · PL 标量基线（RV32 核，FW_ACCEL=0，全标量）—— 同一段 main，同一台 RV32
 *   · PL 加速    （RV32 核，VFFT + SIMD-MAC 阵列）
 *   · PS-only    （A9 自己算，本文件）
 *   前两个之比是「PL 内部的加速比」（scripts/test_whole_machine.sh 实测 1.46×）。
 *   第三个与前两个之比才是「为什么需要 PL」——而那个比较**必须**连着讲
 *   README §0.3.3 的结论：A9 跑得动（算力不是问题），PL 换来的不是吞吐，
 *   是**确定性**。⚠ 两者主频差 16.7 倍（A9 667 MHz vs PL 40 MHz），
 *   拿墙钟直接比会把这句话读反。
 *
 * ── 三个平台相关的替换（内核一个字都没改）────────────────────────────────
 *   ① cycle 计数器：核上是 csrr，A9 上是 PMU，host 上是 rdtsc
 *   ② 内存地图：核上是 DTCM 绝对地址，A9/host 上是自己的 .bss 缓冲区，
 *      **四个区的相对位置一字不差** —— 内核里有按偏移量的写法
 *   ③ 转向块：那是 PL 的硬件（rv32_steer_regs），A9 上没有 ⇒ 桩掉，
 *      §9 因此整节跳过。这一节占整轮约 2.6%，报数时要扣掉（见 docs/issues/088）
 *
 * 编译：
 *   A9   scripts/build_ps_only.ps1            （compile/link，不上板）
 *   host gcc -DPSONLY_HOST -I sw/fw -I sw -o build/ps_only_host \
 *            sw/ps_only.c sw/fw/fw_fft.c sw/fw/fw_gcc.c sw/fw/fw_srp.c \
 *            sw/fw/fw_das.c sw/fw/fw_fir.c sw/fw/fw_scene.c sw/fw/fw_tables.c
 *        → 只为**对拍结果**（与 PL 的指纹逐位比），耗时数字不是 A9 的
 */
#include <stdint.h>

/* ══ ① cycle 计数器 ═════════════════════════════════════════════════════
   ⚠ 编译整个 PS-only 目标时都要带 -DFW_RDCYCLE_OVERRIDE（见文件末的编译行）——
     fw_fir.c / fw_das.c 是独立的编译单元，它们也要看到这个开关。 */
/* 本 TU 自己也要这个开关；别的 TU 靠命令行 -D（见上）。命令行已经给了就
   不要重复定义 —— -Werror 下"宏重定义"是一条错。 */
#ifndef FW_RDCYCLE_OVERRIDE
#define FW_RDCYCLE_OVERRIDE
#endif
#include "fw/fw_scene.h"      /* 带 FW_RDCYCLE_OVERRIDE 时它只做声明 */

#ifdef PSONLY_HOST
#include <stdio.h>
#include <sys/mman.h>
/* host 上只为对拍，用 rdtsc 随便给个数 —— **它不是 A9 的周期数**，
   报数时必须标清楚。见 scripts/check_ps_only_results.py。 */
uint32_t rdcycle(void)
{
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return lo;
}
#else
/* Cortex-A9 的 PMU：PMCCNTR 数的是**核心时钟周期**（不是 CPU 频率外的计数）。
   ⚠ 必须先在 PMCR 里把 E 立起来、在 PMCNTENSET 里放行 CCNT，否则读回恒 0 ——
     而那看起来像"这段代码只要 0 个周期"，比报错还坏。 */
static inline uint32_t a9_pmu_init(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15, 0, %0, c9, c12, 0" : "=r"(v));   /* PMCR  */
    v |= (1u << 0);                                             /* E=1   */
    v |= (1u << 2);                                             /* C=1：清 CCNT */
    /* ⚠⚠ bit3 = D（时钟分频）。**复位默认是 1 ⇒ PMCCNTR 每 64 个 CPU 时钟
       才加一**。不清这一位的话读出来的数小 64 倍 —— 而它**看起来完全合理**
       （一个比 PL 快 100 倍的数，你不会觉得是计数器错，只会觉得"PS 果然快"）。
       实测踩过：真板上第一次读到 156,550，×64 之后才是真实的 10,019,200。 */
    v &= ~(1u << 3);                                            /* D=0：每拍加一 */
    __asm__ volatile("mcr p15, 0, %0, c9, c12, 0" :: "r"(v));
    __asm__ volatile("mcr p15, 0, %0, c9, c12, 3" :: "r"(1u << 31)); /* PMOVSR：清溢出 */
    __asm__ volatile("mcr p15, 0, %0, c9, c12, 1" :: "r"(1u << 31)); /* PMCNTENSET */
    __asm__ volatile("mrc p15, 0, %0, c9, c12, 0" : "=r"(v));   /* 回读，落进日志 */
    return v;
}
uint32_t rdcycle(void)
{
    uint32_t c;
    __asm__ volatile("mrc p15, 0, %0, c9, c13, 0" : "=r"(c));   /* PMCCNTR */
    return c;
}
#endif

/* ══ ② 内存地图：整张 DTCM 图平移到自己的缓冲区 ═════════════════════════
   实际做平移的是 fw_mem.h 的 FW_MEM_RELOCATE 分支，它从下面的
   `fw_mem_scratch` 取基址 —— **所有**编译单元（fw_fir.c / fw_das.c 也是）
   都走这一条，不能只在某个 .c 里 #define 四个地址。

   host 上必须落在 **32 位地址以内**：内核把地址当 uint32_t 用
   （`(volatile int16_t *)FW_OUT_BASE`），64 位指针一截断就指到别处去了，
   而那不会崩、只会安静地算错。见 main() 里的 MAP_32BIT。 */
#if defined(PSONLY_HOST)
uint8_t *fw_mem_scratch;                       /* mmap 出来，见 main() */
#else
static uint8_t ps_scratch_mem[0x2000] __attribute__((aligned(64)));
uint8_t *fw_mem_scratch = ps_scratch_mem;
#endif

/* 完成邮箱：核上它是 MMIO 0x4000；这边给个普通缓冲区就行 */
#define FW_MMIO_MBOX  (*(volatile uint32_t *)(fw_mem_scratch + 0x1F00u))

/* ══ ③ 转向块：PL 的硬件，A9 上没有 ════════════════════════════════════
   fw_main.c §9 会调它。返回非 0 = 查询失败 ⇒ 它跳过受控 DAS，
   这与 PL 那边"块没装 LUT"时的行为一致（issues/084）。 */
void fw_steer_init(void) { }
int fw_steer_query(uint32_t grid, int32_t comp[8])
{
    (void)grid; (void)comp;
    return 1;
}

/* ══ 把固件整轮搬进来 ═══════════════════════════════════════════════════
   `#define main` 是关键：不是"照着写一遍"，是**同一份源码**。
   FW_MAIN_RETURNS 让它跑完返回（核上那份以死循环收尾）。 */
#include "fw/fw_plat.h"      /* FW_JITTER_N（逐帧抖动的样本数） */

#define FW_MAIN_RETURNS 1
/* scripts/check_ps_apps.py 会带 -Dmain=app_main 进来（它拿它给所有 PS 源做
   语法检查）。先撤掉它，否则下面这行是"宏重定义"，在 -Werror 下直接失败。 */
#ifdef main
#undef main
#endif
#define main fw_workload
#include "fw/fw_main.c"
#undef main

/* ══ 结果打印与入口 ═════════════════════════════════════════════════════ */
#ifdef PSONLY_HOST
#define P(...)  printf(__VA_ARGS__)
#else
#include "xil_printf.h"
#define P(...)  xil_printf(__VA_ARGS__)
#endif

#include "fw/fw_mem.h"
#define RESW(i)   (*(volatile uint32_t *)(FW_RES_BASE + 4u * (uint32_t)(i)))
#define EXTRW(i)  (*(volatile uint32_t *)(FW_AUDIO_BASE + 4u * (uint32_t)(i)))

/* ══ 逐帧抖动的样本数组（只在 FW_JITTER_N > 0 时）════════════════════════
 * 这段在 **A9 的 DDR** 里，与核上不同 —— 核的 .bss 只剩 16 B，放不下 256 个
 * 样本，所以核上只留 min/max/sum。A9 这边有地方，就能算 P95/P99。
 * 两边**帧内容**完全一样（都在 fw_main.c 的 frame_once 里），所以可比。 */
#if FW_JITTER_N > 0
static int32_t jit_buf[FW_JITTER_N];
#endif

int main(void)
{
#ifdef PSONLY_HOST
    /* MAP_32BIT：内核把 FW_* 地址当 uint32_t 用，缓冲区必须落在 32 位以内。
       截断不崩，只会安静地算到别处 —— 所以这里显式要低地址并**核对**。 */
    fw_mem_scratch = (uint8_t *)mmap(NULL, 0x2000u, PROT_READ | PROT_WRITE,
                                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
    if (fw_mem_scratch == MAP_FAILED ||
        (uintptr_t)fw_mem_scratch + 0x2000u > 0x100000000ull) {
        fprintf(stderr, "PS-only: 拿不到 32 位以内的缓冲区，对拍无意义\n");
        return 2;
    }
#else
    {
        const uint32_t pmcr = a9_pmu_init();
        P("PS_ONLY_PMCR %08x  (bit3 D=%u 必须为 0；bit0 E=%u 必须为 1)\r\n",
          (unsigned)pmcr, (unsigned)((pmcr >> 3) & 1u), (unsigned)(pmcr & 1u));
    }
#endif

    P("\r\n===== PS-only baseline (same source as the PL firmware) =====\r\n");

#if FW_JITTER_N > 0
    fw_jit_trace = jit_buf;          /* 让 fw_main.c 的逐帧循环把样本写进 DDR */
#endif
    const uint32_t t0 = rdcycle();
    fw_workload();
    const uint32_t t1 = rdcycle();

    P("PS_ONLY_CYCLES %u\r\n", (unsigned)(t1 - t0));

#if FW_JITTER_N > 0
    /* ── 逐帧抖动：排序后取百分位（README §35 的单帧延迟 / §36 的 J）────
       插入排序，n 只有几百，不值得引入 qsort。 */
    {
        int i, j;
        for (i = 1; i < FW_JITTER_N; i++) {
            const int32_t key = jit_buf[i];
            for (j = i - 1; j >= 0 && jit_buf[j] > key; j--) jit_buf[j + 1] = jit_buf[j];
            jit_buf[j + 1] = key;
        }
        {
            long long sum = 0;
            for (i = 0; i < FW_JITTER_N; i++) sum += jit_buf[i];
            P("PS_ONLY_JITTER n=%d min=%d p50=%d p95=%d p99=%d max=%d mean=%d\r\n",
              (int)FW_JITTER_N,
              (int)jit_buf[0],
              (int)jit_buf[(FW_JITTER_N * 50) / 100],
              (int)jit_buf[(FW_JITTER_N * 95) / 100],
              (int)jit_buf[(FW_JITTER_N * 99) / 100],
              (int)jit_buf[FW_JITTER_N - 1],
              (int)(sum / FW_JITTER_N));
            P("PS_ONLY_JITTER_J %d  (= max - min, README §36)\r\n",
              (int)(jit_buf[FW_JITTER_N - 1] - jit_buf[0]));
        }
    }
#endif
    /* 逐字回读结果块与 GSC 扩展块 —— 与 PL 那两版的指纹**逐位**比。
       比对脚本：scripts/check_ps_only_results.py */
    P("PS_ONLY_RES");
    for (int i = 0; i < 32; i++) P(" %08x", (unsigned)RESW(i));
    P("\r\nPS_ONLY_EXTRA");
    for (int i = 0; i < 8; i++) P(" %08x", (unsigned)EXTRW(i));
    P("\r\nPS_ONLY_DONE\r\n");
    return 0;
}
