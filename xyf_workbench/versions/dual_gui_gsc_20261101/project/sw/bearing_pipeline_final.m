%% bearing_pipeline_final.m
%  A4.1-5  定稿：链路固化 + 导出 C 用的输入与期望
%  2026-09-19
%
%  产出到 ./a4_c_data/，两帧各一对：
%     frame_input.h    / frame_expect.h     帧 A：BPFO = 4*df = 187.5 Hz（整数 bin）
%     frame_b_input.h  / frame_b_expect.h   帧 B：BPFO = 103.56 Hz（2.21 bin）
%
%  链路（这就是 C 要实现的，共 6 步）：
%     (1) X   = fft(x)
%     (2) H   = 单边带 ∩ 共振带 ;  xa = ifft(X .* H)
%     (3) env = |xa|
%     (4) m   = sum(env.*w)/sum(w) ;  eac = env - m
%     (5) E   = fft(eac .* w) / sum(w)
%     (6) feat[k] = max|E| 在 k*BPFO ± hw bin 内,  k = 1..K
%
%  两帧只差 BPFO，其余参数逐字相同，并且共用同一次噪声实现
%  （每轮 rng(seed) 重置），所以两帧的差异只来自冲击串本身。
%
%  为什么要有帧 B：帧 A 的 BPFO 故意取整数 bin，是为了把扇贝损失这个混淆因素先排除
%  掉、把对齐做对。真实 BPFO 不会落在 bin 上。帧 B 取 CWRU 驱动端 1730 rpm 的
%  103.56 Hz = 2.21 个 bin，逼近 df = 46.875 Hz 这个硬天花板。
%  已扫过（bearing_frame_b.m）：k=1 对比度 24.18 -> 23.10 dB，扇贝损失只吃 1.08 dB。
%
%  对齐约定：本脚本用 double 算，C 第一次也用 double，容差 1e-6 绝对
%  （不是 1e-9 —— 输入帧是 float，6e-8 的相对误差从源头就带进来了）。
%
%  头文件里宏名/数组名两帧必须不同，否则同一个 .c include 两份就重定义：
%     帧 A:  FRAME_N ... EXP_N ... frame_fault ... exp_xa_re
%     帧 B:  FRAME_B_N ... EXP_B_N ... frame_b_fault ... exp_b_xa_re

clear; clc; close all;

%% ---------------- 共同参数（两帧逐字相同）----------------
fs = 48000;  N = 1024;  df = fs/N;
f_res = 3000;              % 结构共振 Hz
B     = 3200;              % 带通带宽 Hz -> 1400 ~ 4600
beta  = 500;  snr_db = 10;  seed = 1;
K     = 4;                 % 看 1..K 次谐波

% A4.2 导出的完整包络谱 bin 数。包络谱的有用带宽 = 带通带宽/2 = B/2 = 1600 Hz，
% 48 kHz 口径落 bin 34，39.0625 kHz 口径落 bin 42。取 64 两种 fs 都够 ——
% 所以将来 fs 口径从 48k 改成 39.0625k 时，这个数不用回头改。
E_BINS = 64;

% 机器背景（两帧逐字相同）
f_shaft = 25;  shaft_h = [1 2 3 4];  a_shaft = [1.00 0.40 0.20 0.10];
f_line  = [50 100];                  a_line  = [0.60 0.25];

n = (0:N-1).';  t = n/fs;  f = (0:N-1).' * df;
bp_mask = (f >= f_res-B/2) & (f <= f_res+B/2);
win     = 0.5*(1 - cos(2*pi*n/(N-1)));      % Hann（对称），C 那边照这个写

%% ---------------- 两帧的定义 ----------------
% bpfo 是唯一变化的量。其余字段全是"写到磁盘上的名字"，不参与计算。
cases = struct( ...
    'tag',    {'A',                          'B'}, ...
    'bpfo',   {4*df,                         103.56}, ...
    'note',   {'',                           'Frame B: BPFO = 103.56 Hz = 2.21 bins -- non-integer bin, near the resolution limit'}, ...
    'iname',  {'frame_input.h',              'frame_b_input.h'}, ...
    'ename',  {'frame_expect.h',             'frame_b_expect.h'}, ...
    'iguard', {'FRAME_INPUT_H',              'FRAME_B_INPUT_H'}, ...
    'eguard', {'FRAME_EXPECT_H',             'FRAME_B_EXPECT_H'}, ...
    'imac',   {'FRAME_',                     'FRAME_B_'}, ...
    'emac',   {'EXP_',                       'EXP_B_'}, ...
    'iarr',   {'frame_',                     'frame_b_'}, ...
    'earr',   {'exp_',                       'exp_b_'});

fprintf('===== 定稿参数（两帧共同）=====\n');
fprintf('  N = %d   fs = %d   df = %.4f Hz   帧长 %.3f ms\n', N, fs, df, N/fs*1000);
fprintf('  带通 %.0f ~ %.0f Hz  (B = %d Hz, 带内 %d bin)   包络谱上限 %.0f Hz\n', ...
        f_res-B/2, f_res+B/2, B, sum(bp_mask), B/2);
fprintf('  Hann 窗: w[i] = 0.5*(1 - cos(2*pi*i/(N-1)))\n');
fprintf('  beta = %d, snr = %d dB, seed = %d, K = %d\n\n', beta, snr_db, seed, K);

outdir = fullfile(fileparts(mfilename('fullpath')), 'a4_c_data');
if ~exist(outdir, 'dir'), mkdir(outdir); end

%% ---------------- 逐帧生成 ----------------
for ci = 1:numel(cases)
    f_bpfo = cases(ci).bpfo;
    cbin   = f_bpfo / df;
    hw     = max(1, min(2, floor(cbin/2)));     % 峰值搜索半宽

    fprintf('===== 帧 %s =====\n', cases(ci).tag);
    fprintf('  BPFO = %.2f Hz -> bin %.2f   看 k = 1..%d 次谐波, 搜索半宽 ±%d bin\n', ...
            f_bpfo, cbin, K, hw);
    if ~isempty(cases(ci).note)
        fprintf('  %s\n', cases(ci).note);
    end

    % ---- 冲击串（T_imp 的算法必须与改版前逐字一致，否则帧 A 的头文件会变）----
    T_imp = 1/f_bpfo;
    m_max = floor(t(end)/T_imp);
    x_imp = zeros(N,1);
    for m = 0:m_max
        tm = m*T_imp;  idx = t >= tm;  tau = t(idx) - tm;
        x_imp(idx) = x_imp(idx) + exp(-beta*tau).*sin(2*pi*f_res*tau);
    end

    x_bg = zeros(N,1);
    for k = 1:numel(shaft_h), x_bg = x_bg + a_shaft(k)*sin(2*pi*f_shaft*shaft_h(k)*t); end
    for k = 1:numel(f_line),   x_bg = x_bg + a_line(k)*sin(2*pi*f_line(k)*t); end

    p_noise = mean(x_imp.^2) / 10^(snr_db/10);
    rng(seed);                                  % 每轮重置 -> 两帧共用同一次噪声
    noise = sqrt(p_noise) * randn(N,1);

    x_fault = x_bg + x_imp + noise;
    x_heal  = x_bg         + noise;

    fprintf('  一帧内冲击个数 = %d   噪声功率 %.6f（两帧共用同一次实现）\n\n', m_max+1, p_noise);

    % ---- 跑链路 ----
    [xa_f, env_f, eac_f, E_f, feat_f, mw_f] = ...
        pipeline(x_fault, N, bp_mask, win, cbin, hw, K);
    [xa_h, env_h, eac_h, E_h, feat_h, mw_h] = ...
        pipeline(x_heal,  N, bp_mask, win, cbin, hw, K);

    con = zeros(1,K);
    for k = 1:K
        con(k) = 20*log10( feat_f(k) / (feat_h(k) + eps) );
    end

    fprintf('  CP2 故障 env max/mean: %.10f  %.10f\n', max(env_f), mean(env_f));
    fprintf('  CP3 故障 m            : %.12f\n', mw_f);
    fprintf('  CP4 故障 |E| @ bin ');
    fprintf('%d ', floor((1:K)*cbin));  fprintf(': ');
    fprintf('%.8f ', abs(E_f(floor((1:K)*cbin)+1))); fprintf('\n');

    fprintf('\n  ===== CP5 最终判据 =====\n');
    fprintf('       k   频率(Hz)     故障峰      健康峰    对比度(dB)\n');
    for k = 1:K
        fprintf('      %2d  %9.2f  %.8f  %.8f  %9.2f\n', ...
                k, k*f_bpfo, feat_f(k), feat_h(k), con(k));
    end
    fprintf('    最差谐波对比度 = %.2f dB\n\n', min(con));

    % ---- 导出 .h ----
    write_frame_input(fullfile(outdir, cases(ci).iname), ...
                      cases(ci).iguard, cases(ci).imac, cases(ci).iarr, ...
                      cases(ci).note, ...
                      x_fault, x_heal, N, fs, f_bpfo, f_res, B, beta, snr_db, seed);

    write_frame_expect(fullfile(outdir, cases(ci).ename), ...
                       cases(ci).eguard, cases(ci).emac, cases(ci).earr, ...
                       cases(ci).note, ...
                       xa_f, env_f, eac_f, E_f, E_h, mw_f, feat_f, ...
                       env_h, feat_h, con, ...
                       N, cbin, hw, K, f_bpfo, E_BINS);
end

fprintf('===== .h 已写到 =====\n  %s\n', outdir);
for ci = 1:numel(cases)
    fprintf('  帧 %s:  %s  %s\n', cases(ci).tag, cases(ci).iname, cases(ci).ename);
end

%% ================= 局部函数 =================
function [xa, env, eac, E, feat, mw] = pipeline(x, N, bp_mask, win, cbin, hw, K)
    X = fft(x);

    H = zeros(N,1);
    H(1)     = 1;
    H(2:N/2) = 2;
    H(N/2+1) = 1;
    H = H .* bp_mask;

    xa  = ifft(X .* H);
    env = abs(xa);
    mw  = sum(env.*win) / sum(win);
    eac = env - mw;
    E   = fft(eac.*win) / sum(win);

    feat = zeros(1,K);
    for k = 1:K
        c  = k*cbin;
        lo = max(1, floor(c) - hw + 1);
        hi = min(N/2, floor(c) + hw + 1);
        feat(k) = max(abs(E(lo:hi)));
    end
end

function write_frame_input(path, guard, mac, arr, note, ...
                           x_fault, x_heal, N, fs, f_bpfo, f_res, B, beta, snr_db, seed)
    fid = fopen(path, 'w');
    fprintf(fid, '/* A4.1 fixed test frame -- generated by bearing_pipeline_final.m */\n');
    fprintf(fid, '/* DO NOT EDIT BY HAND. Regenerate from the .m script instead. */\n');
    fprintf(fid, '/* All values are float. C should read them as-is, no transformation. */\n');
    if ~isempty(note), fprintf(fid, '/* %s */\n', note); end
    fprintf(fid, '#ifndef %s\n#define %s\n\n', guard, guard);
    fprintf(fid, '#define %sN      %d\n', mac, N);
    fprintf(fid, '#define %sFS     %d\n', mac, fs);
    fprintf(fid, '#define %sBPFO   %.6f\n', mac, f_bpfo);
    fprintf(fid, '#define %sFRES   %.6f\n', mac, f_res);
    fprintf(fid, '#define %sBANDPASS_BW  %d\n', mac, B);
    fprintf(fid, '#define %sBETA   %.6f\n', mac, beta);
    fprintf(fid, '#define %sSNR_DB %.6f\n', mac, snr_db);
    fprintf(fid, '#define %sSEED   %d\n\n', mac, seed);
    fprintf(fid, '/* fault frame: background + impulse train + noise */\n');
    write_f32(fid, [arr 'fault'], x_fault);
    fprintf(fid, '/* healthy frame: identical background and identical noise, no impulses */\n');
    write_f32(fid, [arr 'heal'], x_heal);
    fprintf(fid, '#endif /* %s */\n', guard);
    fclose(fid);
end

function write_frame_expect(path, guard, mac, arr, note, ...
                            xa_f, env_f, eac_f, E_f, E_h, mw_f, feat_f, ...
                            env_h, feat_h, con, N, cbin, hw, K, f_bpfo, e_bins)
    fid = fopen(path, 'w');
    fprintf(fid, '/* A4.1 expected intermediate values -- generated by bearing_pipeline_final.m */\n');
    fprintf(fid, '/* MATLAB computed these in double. C must match to ~1e-9 relative error. */\n');
    fprintf(fid, '/* Non-ASCII comments are avoided on purpose (Vitis re-encodes sources). */\n');
    if ~isempty(note), fprintf(fid, '/* %s */\n', note); end
    fprintf(fid, '#ifndef %s\n#define %s\n\n', guard, guard);
    fprintf(fid, '#define %sN          %d\n', mac, N);
    fprintf(fid, '#define %sCBIN       %.10f\n', mac, cbin);
    fprintf(fid, '#define %sHW         %d\n', mac, hw);
    fprintf(fid, '#define %sK          %d\n', mac, K);
    fprintf(fid, '#define %sBPFO       %.6f\n', mac, f_bpfo);
    fprintf(fid, '#define %sEBINS      %d\n\n', mac, e_bins);

    fprintf(fid, '/* ---- CP1: analytic signal xa[0..7] (complex) ---- */\n');
    write_f64(fid, [arr 'xa_re'], real(xa_f(1:8)));
    write_f64(fid, [arr 'xa_im'], imag(xa_f(1:8)));

    fprintf(fid, '/* ---- CP2: envelope env[0..7] ---- */\n');
    write_f64(fid, [arr 'env_fault'], env_f(1:8));
    write_f64(fid, [arr 'env_heal'],  env_h(1:8));

    fprintf(fid, '/* ---- CP3: weighted mean m  and  eac[0..7] ---- */\n');
    fprintf(fid, 'static const double %smean_w = %.17g;\n', arr, mw_f);
    write_f64(fid, [arr 'eac_fault'], eac_f(1:8));

    % CP4 取 k*BPFO 落到的那个 bin。cbin 是整数时 floor(k*cbin) = k*cbin，
    % 帧 A 由此得到 bin 4/8/12/16，与改版前逐字一致。
    fprintf(fid, '/* ---- CP4: envelope spectrum at k*BPFO, k=1..%d (complex) ---- */\n', K);
    idx = floor((1:K)*cbin) + 1;                 % +1 转 MATLAB 1-based
    write_f64(fid, [arr 'E_re'], real(E_f(idx)));
    write_f64(fid, [arr 'E_im'], imag(E_f(idx)));

    fprintf(fid, '/* ---- CP5: feature peaks, k=1..%d (the actual decision input) ---- */\n', K);
    write_f64(fid, [arr 'feat_fault'], feat_f);
    write_f64(fid, [arr 'feat_heal'],  feat_h);
    write_f64(fid, [arr 'contrast_db'], con);

    % A4.2：整条包络谱的模，bin 0..E_BINS-1（MATLAB 1-based 就是 E(1:E_BINS)）。
    % CP4 只摘了 k*BPFO 落到的 4 个 bin，这里把曲线本身也导出来，C 才能逐项对照。
    % 有用的只是前 ~34/42 个 bin（B/2 = 1600 Hz），取 64 是给两种 fs 都留余量。
    fprintf(fid, '/* ---- A4.2: whole envelope spectrum |E|, bins 0..%d ---- */\n', e_bins-1);
    fprintf(fid, '/* Useful band is B/2 = 1600 Hz -> bin 34 at 48 kHz, bin 42 at 39.0625 kHz. */\n');
    fprintf(fid, '/* %d bins covers both, so this array survives an fs change.                   */\n', e_bins);
    write_f64(fid, [arr 'E_mag_fault'], abs(E_f(1:e_bins)));
    write_f64(fid, [arr 'E_mag_heal'],  abs(E_h(1:e_bins)));

    fprintf(fid, '#endif /* %s */\n', guard);
    fclose(fid);
end

function write_f32(fid, name, v)
    fprintf(fid, 'static const float %s[%d] = {\n', name, numel(v));
    for i = 1:numel(v)
        if mod(i-1, 6) == 0, fprintf(fid, '    '); end
        fprintf(fid, '%.9gf', v(i));
        if i < numel(v), fprintf(fid, ','); end
        if mod(i, 6) == 0 || i == numel(v), fprintf(fid, '\n'); end
    end
    fprintf(fid, '};\n\n');
end

function write_f64(fid, name, v)
    fprintf(fid, 'static const double %s[%d] = {', name, numel(v));
    for i = 1:numel(v)
        fprintf(fid, '%.17g', v(i));
        if i < numel(v), fprintf(fid, ', '); end
    end
    fprintf(fid, '};\n\n');
end
