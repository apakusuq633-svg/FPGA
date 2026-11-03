/* ps_ipc_test.c —— A9#1 → A9#0 那一页 OCM 的宿主机自检（站 11/12/13 的搬运层）
 *
 * 这个文件是 sw/ps_ipc.h **唯一能在板外验的地方**。板子上的两个使用者
 * （sw/ps_ui.c 里的 start_cpu1/cpu1_main 与 poll_frame）只有上板才跑得到，而跨核握手写错的
 * 现象是"偶尔报出一帧错的诊断"或者"页面永远停在 waiting" —— 两种都很难查。所以这里把
 * ps_ipc.h 拆开逐条走一遍。它只碰内存：不碰寄存器、不碰 lwip，所以宿主机上能真跑（不是
 * 编译一遍而已，sw/ps_diag_test.c 那种"只编不跑"在这里不适用）。
 *
 * -- 覆盖什么 --------------------------------------------------------------------------------
 *
 *   1. ipc_reset() 之后整页是干净的：magic 对、seq/done/busy 归零、载荷归零。
 *   2. 页没初始化时 ipc_consume() 什么都不给（CPU0 先跑、CPU1 还没起时就是这一态）。
 *   3. 发一帧、收一帧：struct ipc_frame 的每一个字段都逐位回得来。这一条盯的是
 *      IPC_FRAME_WORDS 少算一个字 —— 那会悄悄丢掉结构体尾巴上的一段，页面上看不出来。
 *   4. 收过的帧不重复收（last_seq 生效）。
 *   5. seq 是奇数（生产者正在写）时**拒绝读载荷**，而且不动调用方的游标。
 *   6. 生产者写完之后，那一帧正常到手（守卫不是把帧永久挡住）。
 *   7. struct diag_result 无填充（13 个 int）。按字拷只在无填充时才逐位精确；
 *      谁给那个结构体加了 short/char 成员，这一条会先响。
 *   8. ipc_done() / ipc_busy() 读到的是写进去的值。
 *
 * -- **不**覆盖什么 ----------------------------------------------------------------------------
 *
 * 真并发下"拷到一半被改写"能不能被抓出来。那是时序，宿主机是单线程，只能验**守卫在**，
 * 验不了**守卫够用** —— 前者是本文件的事，后者要上板跑起来看（板上可看的间接证据：
 * 帧号连续、每帧 frame_ms 合理、页面上不出现乱码字段）。
 *
 * -- 怎么跑 ----------------------------------------------------------------------------------
 *
 * scripts/check_ps_apps.py 只编它（-fsyntax-only），**不跑**（那个脚本的约定就是"不链接、
 * 不执行任何东西"）。而这里面的 seq 算术只有跑起来才算数，所以手动跑一次：
 *
 *     # xil_printf 的宿主机替身（build/ 是 gitignored，所以要现造）
 *     cat > build/scratch/ipc_host_main.c <<'EOF'
 *     #include <stdio.h>
 *     #include <stdarg.h>
 *     void xil_printf(const char *fmt, ...)
 *     { va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); }
 *     EOF
 *
 *     gcc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -Isw/cstub -Isw \
 *         -c build/scratch/ipc_host_main.c -o build/scratch/ipc_main.o
 *     gcc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -Isw/cstub -Isw \
 *         -c sw/ps_ipc_test.c -o build/scratch/ipc_test.o
 *     gcc build/scratch/ipc_test.o build/scratch/ipc_main.o -o build/scratch/ipc_host_check.exe
 *     ./build/scratch/ipc_host_check.exe
 *
 * 两个坑，都不是随手能想到的：
 *   - **别加 -Dmain=app_main**（闸门里的公共 flags 带着它）。那是给 -fsyntax-only 用的，
 *     真链接时它会把 main 改名，ld 转头去找 WinMain。
 *   - **-Wno-unused-function 是必需的**：ps_ipc.h 要 include ps_output.h 拿 diag_result，
 *     而那个头里 out_split_grid 等四个是**非 inline 的 static**，本文件一个都不用。
 *     -fsyntax-only 不跑代码生成、所以看不到这条，一真编就 -Werror 报错。
 *     （也就是说：只过闸门 ≠ 能编。这个文件是"闸门绿了但编不出来"的一个真实例子。）
 */

#include <stdint.h>
#include <string.h>

#include "xil_printf.h"

#include "ps_ipc.h"

static int g_fail;

static void check(int cond, const char *what)
{
    xil_printf("%s %s\r\n", cond ? "OK  " : "FAIL", what);
    if (!cond) {
        g_fail++;
    }
}

/* 一页放在普通内存里。板子上是 (struct ipc_page *)IPC_BASE，这里是一块 .bss ——
 * ps_ipc.h 的函数都收指针，就是为了这一条。 */
static struct ipc_page page_buf;

/* 造一帧每个字段都不一样的载荷。用 tag 把每个字段错开，这样"某两个字拷反了"
 * 或者"尾巴被截掉了"都会在逐位比里露出来，而不是碰巧相等。 */
static struct ipc_frame make_frame(uint32_t tag)
{
    struct ipc_frame f;
    int i;

    memset(&f, 0, sizeof f);          /* 填充字节也定下来，memcmp 才是确定的 */

    f.r.cls       = (int)(tag + 1u);
    for (i = 0; i < CLF_N_CLASS; i++) {
        f.r.votes[i] = (int)(tag * 10u + (uint32_t)i);
    }
    f.r.conf_pct  = (int)(tag + 20u);
    f.r.grid      = (int)(tag + 30u);
    f.r.grid_w    = (int)(tag + 31u);
    f.r.gx        = (int)(tag + 32u);
    f.r.gy        = (int)(tag + 33u);
    f.r.azim_pct  = (int)(tag + 34u);
    f.r.sev_pct   = (int)(tag + 35u);
    f.r.med_milli = (int)(tag + 36u);
    f.status      = tag + 100u;
    f.frame_ms    = tag + 200u;
    f.dir_ok      = tag + 300u;
    f.pad         = 0x600Du ^ tag;    /* 故意非 0：漏拷 pad 也会被抓出来 */

    return f;
}

int main(void)
{
    volatile struct ipc_page *p = &page_buf;
    struct ipc_frame a, b, sentinel;
    uint32_t seq;

    g_fail = 0;

    xil_printf("ps_ipc_test: the A9#1 -> A9#0 shared page\r\n");

    /* 布局先钉死：按字拷只在无填充时才逐位精确，而 diag_result 全是 int 正是为了这一条。
     * 谁给那个结构体加了 short/char 成员，或者插了个需要对齐的成员，第一条会先响。 */
    check(sizeof(struct diag_result) == 13u * sizeof(uint32_t),
          "struct diag_result is 13 words with no padding");
    check(sizeof page_buf.w >= sizeof(struct ipc_frame),
          "the page's payload region holds a whole frame");

    /* 1. 清页。检查前先把载荷写脏，否则"归零"可能只是因为本来就是 0。 */
    memset((void *)&page_buf, 0xA5, sizeof page_buf);
    ipc_reset(p);
    check(p->magic == IPC_MAGIC, "ipc_reset() leaves the magic in place");
    check(p->seq == 0u && p->done == 0u && p->busy == 0u,
          "ipc_reset() zeroes seq, done and busy");
    check(p->w[0] == 0u && p->w[IPC_FRAME_WORDS - 1u] == 0u,
          "ipc_reset() zeroes the whole payload (first and last word)");

    /* 2. 页活着但还没有帧：CPU0 先跑起来、CPU1 还在 fea_setup 的那几百毫秒就是这一态。 */
    seq = 0u;
    b = make_frame(0u);
    check(ipc_consume(p, &b, &seq) == 0, "no frame yet -> nothing is handed over");
    check(seq == 0u, "an empty read does not advance the cursor");

    /* 3. 发一帧、收一帧，逐位比。 */
    a = make_frame(1u);
    ipc_publish(p, &a);
    check(p->seq == 2u, "one publish moves seq by two (odd while writing, even when done)");
    check(ipc_done(p) == 1u, "ipc_done() reports one frame published");
    check(ipc_consume(p, &b, &seq) == 1, "a published frame is handed over");
    check(memcmp(&a, &b, sizeof a) == 0,
          "every field came back bit for bit (the word count is not short)");
    check(seq == 2u, "a successful read advances the cursor to the frame's seq");

    /* 4. 同一帧不收第二次。 */
    check(ipc_consume(p, &b, &seq) == 0, "the same frame is not handed over twice");

    /* 5. 生产者写到一半：seq 是奇数。序号已经和游标不同了，但载荷一个字都不能读。 */
    a = make_frame(2u);
    ipc_publish(p, &a);                 /* seq 2 -> 4 */
    check(ipc_consume(p, &b, &seq) == 1, "the second frame is handed over");
    check(seq == 4u, "the cursor follows the second frame's seq");

    p->seq = p->seq + 1u;               /* 手动做成"正写到一半"的样子 */
    b = make_frame(0u);
    sentinel = b;
    check(ipc_consume(p, &b, &seq) == 0,
          "a frame whose seq is odd is refused (the producer is mid-write)");
    check(seq == 4u, "a refused read does not advance the caller's cursor");
    check(memcmp(&b, &sentinel, sizeof b) == 0,
          "a refused read does not touch the caller's buffer");

    /* 6. 生产者写完了：奇数 -> 偶数，这一帧要到手。守卫是等一次，不是永久挡住。 */
    a = make_frame(3u);
    a.status = 0x5A5A5A5Au;
    ipc_store(p->w, &a);
    p->done = 3u;
    p->seq = p->seq + 1u;               /* 5 -> 6，偶数 */
    check(ipc_consume(p, &b, &seq) == 1, "once the producer finishes, the frame arrives");
    check(b.status == 0x5A5A5A5Au, "this time it is the frame that was actually written");
    check(ipc_done(p) == 3u, "ipc_done() follows the manually advanced frame count");

    /* 7. 两个只读量。busy 是 CPU1 自己置/清的，CPU0 只读，所以这里手工摆一次。 */
    p->busy = 1u;
    check(ipc_busy(p) == 1u, "ipc_busy() reads back what the producer set");
    p->busy = 0u;
    check(ipc_busy(p) == 0u, "ipc_busy() reads back the cleared value");

    /* 8. 没初始化过的样子：CPU0 还在 main() 开头、start_cpu1() 还没跑。 */
    memset((void *)&page_buf, 0, sizeof page_buf);
    seq = 0u;
    check(ipc_consume(p, &b, &seq) == 0, "a page with no magic hands nothing over");

    xil_printf("IPC_RESULT_%s (%d failures)\r\n", g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail;
}
