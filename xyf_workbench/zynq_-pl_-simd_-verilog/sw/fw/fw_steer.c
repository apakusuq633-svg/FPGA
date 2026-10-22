/* 转向块（rv32_steer_regs）的固件驱动。接口与寄存器说明在 fw_steer.h。
 *
 * ⚠ 这一份代码是**在 300 B 的预算里写的**：DTCM 里 .text 用到 0x1ED4/0x2000，
 *   .data/.rodata 一点不剩（.bss 尾 0x27F0，离 .fwres 只剩 16 B）。
 *   所以这里没有"先读回来再判断"的漂亮写法，每一步都直接对着寄存器做。
 *   改这个文件前后都要看 build_fw.sh 报的三个闸门，别只看编过没编过。
 */
#include <stdint.h>

#include "fw_steer.h"

/* 核侧 MMIO 页 0xA000（见 rv32_soc.v 的 MMIO_PAGE_STEER）。
   字地址 0..7 → 字节偏移 0x00..0x1C。 */
#define S_CTRL   (*(volatile uint32_t *)0xA000u)
#define S_STATUS (*(volatile uint32_t *)0xA004u)
#define S_ADDR   (*(volatile uint32_t *)0xA008u)
#define S_RDATA  (*(volatile uint32_t *)0xA010u)
#define S_TARGET (*(volatile uint32_t *)0xA014u)
#define S_CFG    (*(volatile uint32_t *)0xA018u)

#define ST_BUSY   0x00000001u
#define ST_LOCKED 0x00000010u

/* 一次更新跑多久不固定（几何核 8 格读 + 迟滞 + 渐变），只能等 BUSY 落。
   ⚠ 这里**不能**靠"读回来的值看着不对再重读"来省事 —— MMIO 的 ack 是隔拍的
     （2026-10-04 起），读到的是寄存器里的旧值也会看着"合法"。 */
static void s_wait_idle(void)
{
    while (S_STATUS & ST_BUSY) {
        /* 空转。每轮一次 MMIO 读，本身就够慢，不需要再插 nop */
    }
}

void fw_steer_init(void)
{
    /* CFG = [23:16]CAND=3 [15:8]HOLD=5 [7:0]RAMP=0
       RAMP 必须是 0：非 0 时渐变要分好几帧才爬到目标值（§26.5.1 是为上板
       不爆音用的），而这里要的是一帧内到位，否则读回来的是渐变途中的中间值。 */
    S_CFG = 0x00030500u;
    /* CTRL 是**整体写**：只要写 0x3（START|EN）就会顺手启动一次更新。
       这里不启动，只把 EN 立起来 —— 写 0x2 即可（wdata[0]=0 不触发）。 */
    S_CTRL = 0x00000002u;
}

int fw_steer_query(uint32_t grid, int32_t comp[STEER_N_MIC])
{
    int m;

    /* ── 1. 让它"认下"这一格 ────────────────────────────────────────────
       迟滞（§26.5.2）不认单次跳变：H_EMPTY→H_CAND→(连着 CAND_FRAMES 次都落在
       同一片区域)→H_ACTIVE。而 Q_FSM 只有在 **committed_q == target_q** 时才换
       渐变目标 —— committed 要第 3 次更新才追上，渐变目标要第 4 次才换。
       所以写 5 次（留一次余量），每次都等它跑完。少写几次的表现是**静默的**：
       读回来的还是上一次方向或全 0，看着像个合法值。 */
    for (m = 0; m < 5; m++) {
        S_TARGET = grid;
        s_wait_idle();
    }
    if (!(S_STATUS & ST_LOCKED)) {
        return 1;                       /* 没锁定：宁可报错，不要拿旧值当真 */
    }

    /* ── 2. 打开 COMP 窗口 ─────────────────────────────────────────────
       SEL=COMP(1) 放 [16:15]，IDX=0 放 [14:0]。 */
    S_ADDR = 0x00008000u;

    /* ⚠ 写 A_ADDR 会置 idx_chg_q，紧接着那次 RDATA 读会被判 reject_rstale
       （不返回数据、IDX 也不动），要等一拍才干净。这里先读两笔**别的**寄存器
       把那一拍耗掉 —— 它们不碰 idx_chg_q，也不受它影响。 */
    (void)S_ADDR;
    (void)S_STATUS;

    /* RDATA is already signed Q16, unpacked by rv32_steer.
       Only the packed reference table needs fw_steer_unpack14(). */
    for (m = 0; m < STEER_N_MIC; m++) {
        comp[m] = (int32_t)S_RDATA;
    }
    return 0;
}
