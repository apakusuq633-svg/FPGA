/* ps_ipc.h —— A9#1 → A9#0 的跨核通道（PS 侧）
 *
 * -- 为什么需要它 ---------------------------------------------------------------------------
 *
 * README §5 把 PS 分成两层：A9#1 跑 包络谱 / 阶次谱 / 特征提取 / 分类，A9#0 跑 UI / 配置 /
 * 日志 / 报警。在写这个头之前，仓库里**没有任何跨核数据通路** —— sw/ps_dualcore.c 和
 * sw/ps_fft_test.c 各有一份手刻的共享页（都是 bring-up 测量），除此之外没有 mailbox、
 * 没有锁、没有硬件信号量、没有 SGI、没有中断（整条接收路径都不走 GIC，见 ps_ui.c 头注）。
 * 所以这一层是从零写的。
 *
 * -- 为什么放 OCM，不放 DDR ----------------------------------------------------------------
 *
 * OCM 是片上的，放 DDR 还要另做两核的一致性维护。地址取 0xFFFF0000，与 sw/ps_dualcore.c
 * 用的是同一个 —— 那条路已经上板量过：**必须**先 Xil_SetTlbAttributes(..., NORM_NONCACHE)，
 * 否则 CPU0 会一直拿自己 D-cache 里的旧副本，CPU1 写多少遍都看不见。
 *
 * ⚠ Xil_SetTlbAttributes() 是按 **1 MB 段**改属性的。0xFFFF0000 落在 0xFFF00000 段里，
 *   所以整段（含 CPU1 的栈 0xFFFF8000）都会变成非缓存。这是照抄 ps_dualcore.c 的做法：
 *   代价是栈访问慢一点，收益是**不需要任何缓存维护操作**（两个核读到的就是内存里的值）。
 *   CPU1 的栈顶因此定在 0xFFFF8000，本页在它下面 32 KB —— 栈要溢到 32 KB 才踩得到这页。
 *
 * -- 握手：seqlock，不是锁 ----------------------------------------------------------------
 *
 * 单生产者（CPU1）单消费者（CPU0），所以不需要 LDREX/STREX 那套独占监视器。规则是：
 *   生产者   序号++ （变奇数，表示"正在写"） → dsb → 写载荷 → dsb → 序号++（变偶数）
 *   消费者   读序号 → 奇数就重来 → 拷载荷 → 再读序号 → 两次不等就重来
 * 好处是**生产者永远不会被消费者挡住**：CPU1 只管埋头写，一次都不会停。
 * "拷到一半被改写"这种撕裂读由两次序号比对抓出来，重试一次即可，下一趟主循环还会再来。
 *
 * -- 这个头能在宿主机上编 -------------------------------------------------------------------
 *
 * 它不碰寄存器、不碰 lwip —— 只是几个纯函数加一个结构体布局，所以能进
 * scripts/check_ps_apps.py 的宿主机闸门（sw/ps_ipc_test.c 拿一个普通变量的地址喂给它，
 * 根本不碰 0xFFFF0000）。板子侧只有 ps_ui.c 把 IPC_BASE 传进来。
 *
 * 约定：运行时字符串全 ASCII；注释按本仓库 sw/ 的习惯写中文。
 */
#ifndef PS_IPC_H
#define PS_IPC_H

#include <stdint.h>

#include "ps_das_report.h"
#include "ps_output.h"     /* struct diag_result —— 过河的就是它 */

/* OCM 里的共享页（见文件头：与 ps_dualcore.c 同一个地址，那条路已上板量过）。
 * 页头四个字（16 B）+ 载荷。整页远小于 ps7_ram_1 声明的 0xFE00。 */
#define IPC_BASE   0xFFFF0000u

/* 页签名。"这一页是活的"这件事得有个证据：CPU0 初始化完才放 CPU1，CPU1 进来先读它。 */
#define IPC_MAGIC  0x49504331u   /* "IPC1" */

/* 撕裂读的重试次数。生产者的写入窗口只有几十纳秒（68 字节的非缓存写），
 * 连撞四次已经不可能；真撞上了也不等 —— 返回"没有新帧"，下一趟主循环再来。 */
#define IPC_RETRY  4

/* 一帧要过河的全部东西。**整个 struct diag_result 一次性发过去**，不切半：
 * 跨核契约于是只有一个结构体，没有"先发一半、再发一半"这种会漂的接口。 */
struct ipc_frame {
    struct diag_result r;      /* 站 11 -> 12 -> 13 的成品，13 个 int = 52 B */
    uint32_t status;           /* dia_read_dir 收到的 DTCM 状态原值（用来解释 dir_ok=0） */
    uint32_t frame_ms;         /* 这一帧在 CPU1 上花掉多少毫秒（站 11 是 24 次 8192 点 FFT） */
    uint32_t dir_ok;           /* 1 = 这一帧带方位 */
    das_audio_report audio;
    uint32_t pad;              /* 凑整字；也让下面的字数是确定的，不随字段增删漂 */
};

/* 字的个数由编译器算，不手写 —— diag_result 加一个字段，手写的数就会悄悄不对，
 * 而且是**少拷一个字的尾巴**，页面上看不出来。下面那个 typedef 兜住"不是整字"的情况。 */
#define IPC_FRAME_WORDS  (sizeof(struct ipc_frame) / sizeof(uint32_t))

/* 载荷若不是整字，IPC_FRAME_WORDS 会把它截断 —— 编译期就拦下来。 */
typedef char ipc_frame_must_be_word_multiple[
    (sizeof(struct ipc_frame) % sizeof(uint32_t) == 0u) ? 1 : -1];

/* 页布局：前四个字是控制区，后面是载荷。消费者只读控制区里那个序号，再拷载荷。 */
struct ipc_page {
    volatile uint32_t magic;   /* = IPC_MAGIC，CPU0 写，用来证明这一页是活的 */
    volatile uint32_t seq;     /* seqlock：偶数 = 载荷稳定，奇数 = 生产者正在写 */
    volatile uint32_t busy;    /* 1 = CPU1 正在算这一帧（CPU0 可以据此说"computing"） */
    volatile uint32_t done;    /* 累计产出帧数（也是帧号）—— 主循环要读，不是调试量 */
    volatile uint32_t w[IPC_FRAME_WORDS];
};

/* 按字拷，靠 union 做类型双关（C 里这是良定义的；直接 cast 指针会有严格别名问题）。
 * 用 word 而不是 byte 拷贝：这片内存是非缓存的，每个字都是一次总线往返。 */
union ipc_words {
    struct ipc_frame f;
    uint32_t         w[IPC_FRAME_WORDS];
};

/* ARM 上的编译屏障 / 访存屏障。宿主机测试是单线程，没有别的事情可做。 */
static inline void ipc_dsb(void)
{
#if defined(__arm__)
    __asm__ __volatile__("dsb" ::: "memory");
#endif
}

static inline void ipc_store(volatile uint32_t *dst, const struct ipc_frame *src)
{
    union ipc_words u;
    unsigned i;

    u.f = *src;
    for (i = 0; i < IPC_FRAME_WORDS; i++) {
        dst[i] = u.w[i];
    }
}

static inline void ipc_load(struct ipc_frame *dst, const volatile uint32_t *src)
{
    union ipc_words u;
    unsigned i;

    for (i = 0; i < IPC_FRAME_WORDS; i++) {
        u.w[i] = src[i];
    }
    *dst = u.f;
}

/* --- 生产者侧（CPU1） ---------------------------------------------------------------------- */

/* CPU1 每次算完一帧调用。**不会阻塞，也不会失败** —— 它不关心消费者在干什么。 */
static inline void ipc_publish(volatile struct ipc_page *p, const struct ipc_frame *f)
{
    p->seq = p->seq + 1u;      /* -> 奇数：这一行之后载荷随时可能被改，别读 */
    ipc_dsb();
    ipc_store(p->w, f);
    ipc_dsb();
    p->done = p->done + 1u;    /* 帧号先落地，再放序号 —— 免得消费者拿到新序号却读到旧的 done */
    p->seq = p->seq + 1u;      /* -> 偶数：载荷稳定 */
}

/* --- 消费者侧（CPU0） ---------------------------------------------------------------------- */

/* CPU0 初始化这一页，在放 CPU1 之前调用。magic 最后写：CPU1 读到 magic 就说明前面都落地了。 */
static inline void ipc_reset(volatile struct ipc_page *p)
{
    unsigned i;

    p->magic = 0u;
    p->seq   = 0u;
    p->busy  = 0u;
    p->done  = 0u;
    for (i = 0; i < IPC_FRAME_WORDS; i++) {
        p->w[i] = 0u;
    }
    ipc_dsb();
    p->magic = IPC_MAGIC;
    ipc_dsb();
}

/* 有新帧就拷进 *out 并返回 1；没有就返回 0（*out 不动，*last_seq 不动）。
 * last_seq 由调用方持有、跨调用保持 —— 本函数无状态，宿主机上才好测。
 * 被生产者撞上时**不等**，直接当"这一趟没有新帧"，下一趟主循环自然会再来。 */
static inline int ipc_consume(volatile struct ipc_page *p, struct ipc_frame *out,
                              uint32_t *last_seq)
{
    uint32_t s1, s2;
    int tries;

    if (p->magic != IPC_MAGIC) {
        return 0;              /* 页没初始化（或 CPU1 还没起）*/
    }

    for (tries = 0; tries < IPC_RETRY; tries++) {
        s1 = p->seq;
        if ((s1 & 1u) != 0u) {
            continue;          /* 生产者正在写 */
        }
        if (s1 == *last_seq) {
            return 0;          /* 序号没动 = 没有新帧 */
        }
        ipc_dsb();            /* acquire: payload reads must follow the first sequence read */
        ipc_load(out, p->w);
        ipc_dsb();
        s2 = p->seq;
        if (s1 == s2) {        /* 拷的过程中没被改写 */
            *last_seq = s1;
            return 1;
        }
    }
    return 0;
}

/* --- 两个只读的量，给 CPU0 的启动等待和页面用 ---------------------------------------------- */

static inline uint32_t ipc_done(const volatile struct ipc_page *p) { return p->done; }
static inline uint32_t ipc_busy(const volatile struct ipc_page *p) { return p->busy; }

#endif /* PS_IPC_H */
