/* DAS 波束形成器 —— 固件定点内核（README §26.1）。
 *
 * 定点口径的**唯一出处**是 scripts/golden/fw_das_model.py；这份头文件只说接口。
 * 两边任何一条移位/取整不一致，TB 就会报指纹不符，而现象是"输出不对"。
 */
#ifndef FW_DAS_H
#define FW_DAS_H

#include <stdint.h>

/* 结果块下标（FW_RES_BASE + idx*4）。21 起 —— 0..20 已被 FFT/GCC/SRP 占用。 */
#define DAS_RES_CYCLES      21   /* 一帧（512 样点、8 通道）的拍数 */
#define DAS_RES_CKSUM       22   /* y_mix 的普通校验和 */
#define DAS_RES_WCKSUM      23   /* y_mix 的加权校验和（第二个独立指纹，抗碰撞） */
#define DAS_RES_P_TARGET    24   /* 定标功率和：目标分量 Σ(y_t>>3)² */
#define DAS_RES_P_OTHER     25   /* 定标功率和：干扰+噪声 Σ(y_o>>3)² */
#define DAS_RES_P_MIC       26   /* 单麦基线：Σ(a_0>>3)²（8 路里第 0 路的目标） */
#define DAS_RES_P_MIC_OTH   27   /* 单麦基线：Σ(其余_0>>3)² */
#define DAS_RES_NDIFF       28   /* 诊断：目标/干扰两路的 D_m 是否真的不同（0=同，1=不同） */

/* 跑一帧（512 样点 × 8 通道），结果写进结果块。
   计时**不在这里做** —— 与 FFT/GCC/SRP 一样由 fw_main.c 用 rdcycle() 包住，
   保证四个内核的计时口径一致（否则差的那几拍会被算进某个内核里）。 */
void fw_das_run(void);

/* 受控那趟：转向方向**由硬件块现场报**（rv32_steer_regs 的 comp'），
   不是 fw_das_scene.h 里编译期钉死的那个方向。comp_now[m] 是块给的第 m 路
   comp'（Q16 样点，块自己的归一化 t_m − t_min）。
   与 fw_das_run 共用同一段累加代码，只换延迟表 —— 两趟才可比。
   结果落 FW_STEER_BASE，**不占 RES 块**。 */
void fw_das_run_steered(const int32_t *comp_now);

#endif /* FW_DAS_H */
