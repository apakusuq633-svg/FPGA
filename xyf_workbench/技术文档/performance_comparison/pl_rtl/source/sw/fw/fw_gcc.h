/* GCC-PHAT 内核对外接口。实现与定标说明在 fw_gcc.c 头部。 */
#ifndef FW_GCC_H
#define FW_GCC_H

#include <stdint.h>
void gcc_spectrum_windowed(int16_t *x,int16_t *out);
/* Audit-only copy of last PHAT spectrum, absent from production builds. */
#if defined(FW_GCC_AUDIT) && FW_GCC_AUDIT
void gcc_audit_phi(int16_t *out);
#endif

/* 分三步调用：灌 A → 灌 B → 收口。理由见 fw_gcc.c 头部（帧缓冲只有一块）。
 *
 * ⚠ x 是 **1024 点 Q15、未加窗**，而且调用后**会被就地加窗改写**。 */
void gcc_load_a(int16_t *x);   /* 参考通道 */
void gcc_load_b(int16_t *x);   /* 对端通道 */
void gcc_spectrum(int16_t *x, int16_t *out);
void gcc_cached_pair(const int16_t *a, const int16_t *b, volatile int16_t *out);
/* Only lags 0..15 and -16..-1 are defined; other output entries are not consumed. */
void gcc_cached_ring(const int16_t *a, const int16_t *b, volatile int16_t *out);

/*   r_out     1024 点 int16 相关序列，标度 = 输入/1024
 *   peak_lag  峰值滞后（样点），正值 = A 比 B 晚到 */
void gcc_finish(volatile int16_t *r_out, int32_t *peak_lag);

/* 不做白化的互相关（**波束形成 DAS** 用）。Ψ = G>>1，带内保留。
 * 返回峰值滞后，同时把互相关序列写进 r_out。 */
int32_t gcc_finish_raw(volatile int16_t *r_out);

#endif /* FW_GCC_H */
