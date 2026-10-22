"""阵列几何与延迟 LUT —— 对应 README §7.2 / §23 / §24。

本模块保留早期8麦参考，禁止在HDL写死位置（§7.2）。
当前16麦配置与LUT由scripts/build_live16.py生成；不应将本模块默认8麦用于16麦验收。

坐标约定
--------
- 阵列在 z = 0 平面，均匀圆阵（UCA），从 +x 起逆时针
- 扫描平面在 z = PLANE_Z，一张 GRID_W × GRID_H 的 2D 网格
- 声速取 20°C 的 343 m/s，改温度要改这里，不要改别处

单位
----
- 长度一律米，时间一律样点（除以 fs），角度一律弧度
"""
import numpy as np

# ── 全局常量（README §0.2）────────────────────────────────────
FS = 39062.5          # Hz — BCLK 2.5 MHz ÷ 64，见 README §9
C = 343.0             # m/s @ 20°C
N_MIC = 8
R_UCA = 0.050         # m — 均匀圆阵半径，无混叠上限 ≈ 224/r = 4.48 kHz

PLANE_Z = 0.300       # m — 扫描平面距阵列
GRID_HALF = 0.200     # m — 扫描半宽
GRID_W = GRID_H = 32  # 32×32 = 1024 个候选位置（README §24）

# 麦克风对：C(8,2) = 28
N_PAIR = N_MIC * (N_MIC - 1) // 2


def uca_positions(n=N_MIC, r=R_UCA, z=0.0):
    """均匀圆阵坐标，返回 (n, 3)。"""
    a = 2.0 * np.pi * np.arange(n) / n
    return np.stack([r * np.cos(a), r * np.sin(a), np.full(n, float(z))], axis=1)


def scan_grid(w=GRID_W, h=GRID_H, half=GRID_HALF, z=PLANE_Z):
    """扫描网格。返回 (点集 (w*h,3), x 轴 (w,), y 轴 (h,))。

    点集按 C 序展开（y 外层、x 内层），reshape((h, w)) 即可还原成热力图。
    """
    xs = np.linspace(-half, half, w)
    ys = np.linspace(-half, half, h)
    X, Y = np.meshgrid(xs, ys, indexing="xy")
    pts = np.stack([X.ravel(), Y.ravel(), np.full(X.size, float(z))], axis=1)
    return pts, xs, ys


def pair_list(n=N_MIC):
    """28 个麦克风对 (i, j)，i < j。"""
    return [(i, j) for i in range(n) for j in range(i + 1, n)]


def pair_index_array(n=N_MIC):
    """同上，但返回 (28, 2) 的 numpy 数组，便于向量化。"""
    return np.array(pair_list(n), dtype=np.int64)


def tdoa_samples(pts, mics, fs=FS, c=C):
    """每个网格点 × 每个麦克风的绝对到达延迟，单位**样点**。返回 (P, N)。"""
    d = np.linalg.norm(pts[:, None, :] - mics[None, :, :], axis=2)
    return d / c * fs


def delay_lut(pts, mics=None, pairs=None, nfft=1024, fs=FS, c=C):
    """SRP 延迟 LUT（README §24）。

    对每个网格点 r、每个麦克风对 (i,j)：

        τ_ij(r) = (d_i(r) − d_j(r)) / c

    单位样点，可为负。返回 (P, NPAIR) 的**浮点**样点延迟 —— 整数部分是
    IFFT 数组下标，小数部分供线性插值用（见 expand_lut）。

    保留浮点而不是直接取整，是因为 1 个样点 = 8.78 mm 声程，
    取整误差会直接变成定位误差，必须能插值。
    """
    if mics is None:
        mics = uca_positions()
    if pairs is None:
        pairs = pair_list(len(mics))

    tau = tdoa_samples(pts, mics, fs, c)                 # (P, N) 样点
    pa = np.array(pairs, dtype=np.int64)
    return tau[:, pa[:, 0]] - tau[:, pa[:, 1]]           # (P, NPAIR)


def quantize_lut(tau, nfft=1024):
    """把浮点延迟 LUT 拆成 (整数下标, 小数权重)，供线性插值查表。

    返回 (idx (P,NPAIR) int32, frac (P,NPAIR) float32)。
    """
    lo = np.floor(tau)
    frac = (tau - lo).astype(np.float32)
    idx = np.mod(lo.astype(np.int64), nfft).astype(np.int32)
    return idx, frac


def aliasing_limit(r=R_UCA, c=C):
    """UCA 无空间混叠上限频率：相邻间距 d = 2r·sin(π/N)，要求 d < c/(2f)。"""
    d = 2.0 * r * np.sin(np.pi / N_MIC)
    return c / (2.0 * d)


def tdoa_span(mics=None, c=C, fs=FS):
    """阵列能产生的 TDOA 跨度（样点），用来判断整数取整误差的量级。"""
    if mics is None:
        mics = uca_positions()
    d = np.linalg.norm(mics[:, None, :] - mics[None, :, :], axis=2)
    return d.max() / c * fs


if __name__ == "__main__":
    mics = uca_positions()
    pts, xs, ys = scan_grid()
    pairs = pair_list()
    tau = delay_lut(pts, mics, pairs)

    print("=== 阵列几何（README §0.2 / §7）===")
    print(f"  麦克风数        {N_MIC}")
    print(f"  圆阵半径        {R_UCA*1000:.1f} mm")
    print(f"  相邻间距        {2*R_UCA*np.sin(np.pi/N_MIC)*1000:.2f} mm")
    print(f"  阵列孔径        {2*R_UCA*1000:.1f} mm")
    print(f"  无混叠上限      {aliasing_limit():.0f} Hz")
    print(f"  麦克风对数      {len(pairs)}")
    print()
    print("=== 采样与延迟 ===")
    print(f"  fs              {FS} Hz  (= 2.5 MHz / 64)")
    print(f"  声速            {C} m/s @20C")
    print(f"  1 样点 =        {C/FS*1000:.3f} mm 声程")
    print(f"  TDOA 跨度       {tdoa_span(mics):.2f} 样点")
    print()
    print("=== 扫描网格 ===")
    print(f"  平面            z = {PLANE_Z*1000:.0f} mm")
    print(f"  范围            ±{GRID_HALF*1000:.0f} mm")
    print(f"  分辨率          {GRID_W}×{GRID_H} = {len(pts)} 点")
    print(f"  格距            {2*GRID_HALF/(GRID_W-1)*1000:.2f} mm")
    print()
    print("=== 延迟 LUT ===")
    print(f"  形状            {tau.shape}  ({len(pts)}×{len(pairs)})")
    print(f"  延迟范围        {tau.min():+.3f} .. {tau.max():+.3f} 样点")
    print(f"  取整误差上界    ±{0.5*C/FS*1000:.3f} mm 声程")
    print(f"  LUT 大小        {tau.size} 项，int16 索引 = {tau.size*2/1024:.1f} KB")
