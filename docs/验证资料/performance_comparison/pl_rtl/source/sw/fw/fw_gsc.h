/* GSC（广义旁瓣抵消器）—— 固件定点内核（README §26.3）。
 *
 * 定点口径的唯一出处是 scripts/golden/fw_gsc_model.py；这份头文件只说接口。
 */
#ifndef FW_GSC_H
#define FW_GSC_H

#include <stdint.h>

/* 结果块下标。29 起 —— 21..28 已被 DAS 波束形成占用。 */
#define GSC_RES_CYCLES      29   /* 整趟（三条一起算）的拍数 */
#define GSC_RES_E_CKSUM     30   /* e_target 的普通校验和 */
#define GSC_RES_E_WCKSUM    31   /* e_target 的加权校验和（第二个独立指纹） */

/* ⚠ 结果块只有 32 个字（0..31）。加内核之前先看 fw_mem.h —— 已经满了。
   DAS 与 GSC 的**其余**指纹（功率和等）放在 21..28 之后没有位置，
   所以 GSC 这趟只留三个；功率和与 SNR 由 Python 模型给（口径见那边）。 */

/* 阵列通路的第二组结果放 FW_GSC_EXTRA（RES 排满了，见 fw_mem.h）：
     [5] 阵列一趟的拍数     [6] 阵列 p_e_target     [7] 阵列 p_e_other
   [0..4] 归标量通路（p_e_target / p_e_other / mix_cksum / w_ck / 场景拍数）。*/
#define GSC_X_VEC_CYCLES    5
#define GSC_X_VEC_P_TARGET  6
#define GSC_X_VEC_P_OTHER   7

/* 跑一趟。
   mode = 0：**标量基线**（fw_gsc.c 的老路径，指纹与 tb_fw_gsc 一致）
   mode = 1：**阵列路径**（7 路交织进 SIMD-MAC，滤波与更新都由阵列做）

   ⚠ 两条路径共用场景生成/阻塞/范数/校验和 —— 因为 `.text` 装不下两个完整函数
     （见 docs/gsc_vec_design.md §6.1）。
   ⚠ mode=1 要求**阵列的系数 bank 已经是 0**：那块 BRAM 没有复位，而固件够不着
     `coef_*` 端口（SoC 顶层，PS 侧驱动）⇒ **PS 必须在放核前预装成 0**，
     仿真里由 TB 用层次引用捅零。见 docs/gsc_vec_design.md §6.0。 */
void fw_gsc_run(int mode);

#endif /* FW_GSC_H */
