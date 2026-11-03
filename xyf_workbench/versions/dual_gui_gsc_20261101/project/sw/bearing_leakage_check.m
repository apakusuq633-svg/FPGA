%% bearing_leakage_check.m
%  A4.1-3  诊断：v2 的特征峰为什么塌了
%  2026-09-19
%
%  两个怀疑的效应，分开测：
%    效应 A 帧边缘泄漏  -> 用 Hann 窗治
%    效应 B 背景当载波把特征峰劈开 -> 用共振带带通治
%
%  4 种组合，在同一对信号（故障/健康）上跑，看哪个把对比度买回来。

clear; clc; close all;

%% ---------------- 信号（与 bearing_synth_compare.m 完全相同）----------------
fs      = 48000;
N       = 1024;
df      = fs / N;

f_bpfo  = 4  * df;           % 187.5 Hz
f_res   = 64 * df;           % 3000  Hz
beta    = 500;
snr_db  = 10;
seed    = 1;

f_shaft = 25;
shaft_h = [1 2 3 4];
a_shaft = [1.00 0.40 0.20 0.10];
f_line  = [50 100];
a_line  = [0.60 0.25];

bp_lo   = 2500;              % 共振带下界 Hz
bp_hi   = 3500;              % 共振带上界 Hz

n = (0:N-1).';
t = n / fs;

T_imp = 1 / f_bpfo;
m_max = floor(t(end) / T_imp);
x_imp = zeros(N,1);
for m = 0:m_max
    tm  = m * T_imp;
    idx = t >= tm;
    tau = t(idx) - tm;
    x_imp(idx) = x_imp(idx) + exp(-beta*tau) .* sin(2*pi*f_res*tau);
end

x_bg = zeros(N,1);
for k = 1:numel(shaft_h)
    x_bg = x_bg + a_shaft(k) * sin(2*pi*f_shaft*shaft_h(k)*t);
end
for k = 1:numel(f_line)
    x_bg = x_bg + a_line(k) * sin(2*pi*f_line(k)*t);
end

p_sig   = mean(x_imp.^2);
p_noise = p_sig / 10^(snr_db/10);
rng(seed);
noise = sqrt(p_noise) * randn(N,1);

x_fault = x_bg + x_imp + noise;
x_heal  = x_bg         + noise;

fprintf('===== 设置 =====\n');
fprintf('  df = %.4f Hz   共振带 %d~%d Hz (bin %d~%d)\n', ...
        df, bp_lo, bp_hi, round(bp_lo/df), round(bp_hi/df));
fprintf('  背景总功率 %.4f   冲击串功率 %.4f   噪声功率 %.4f\n', ...
        mean(x_bg.^2), mean(x_imp.^2), mean(noise.^2));

%% ---------------- 4 种组合 ----------------
cases = {
    '1  rect  不带通', false, false;
    '2  hann  不带通', true,  false;
    '3  rect  带通  ', false, true;
    '4  hann  带通  ', true,  true;
};

step = round(f_bpfo/df);
ncase = size(cases,1);
feat_f = zeros(ncase,1);
feat_h = zeros(ncase,1);
Eall_f = zeros(N/2, ncase);
Eall_h = zeros(N/2, ncase);

for c = 1:ncase
    Ef = env_spec(x_fault, N, fs, cases{c,2}, cases{c,3}, bp_lo, bp_hi);
    Eh = env_spec(x_heal,  N, fs, cases{c,2}, cases{c,3}, bp_lo, bp_hi);
    Eall_f(:,c) = abs(Ef(1:N/2)) / N;
    Eall_h(:,c) = abs(Eh(1:N/2)) / N;
    feat_f(c) = sum(abs(Ef(step*(1:4)+1))) / N;
    feat_h(c) = sum(abs(Eh(step*(1:4)+1))) / N;
end

%% ---------------- 判据表 ----------------
fprintf('\n===== 特征指标 = sum(|E| @ k*BPFO, k=1..4) =====\n');
fprintf('  情况              故障        健康       比值     比值(dB)\n');
for c = 1:ncase
    r = feat_f(c) / (feat_h(c) + eps);
    fprintf('  %s  %.6f  %.6f  %8.3f  %8.2f\n', ...
            cases{c,1}, feat_f(c), feat_h(c), r, 20*log10(r));
end

fprintf('\n===== 逐 k 明细（k=1..4 的 |E|/N）=====\n');
for c = 1:ncase
    fprintf('\n  --- %s ---\n', cases{c,1});
    fprintf('     k   频率(Hz)     故障        健康       比值(dB)\n');
    for k = 1:4
        idx = k*step + 1;             % Eall_* 的第 idx 行 = FFT 的 bin k*step
        rf = Eall_f(idx, c);
        rh = Eall_h(idx, c);
        fprintf('    %3d  %9.2f  %.6f  %.6f  %8.2f\n', ...
                k, k*f_bpfo, rf, rh, 20*log10(rf/(rh+eps)));
    end
end

%% ---------------- 画图：健康信号的包络谱（看底噪）----------------
f   = (0:N/2-1).' * df;

figure('Name','A4.1-3 诊断：哪种组合把对比度买回来','Position',[80 40 1100 700]);

subplot(2,1,1);
hold on; grid on;
cols = lines(ncase);
for c = 1:ncase
    plot(f, Eall_h(:,c), 'Color', cols(c,:), 'DisplayName', cases{c,1});
end
for k = 1:4, xline(k*f_bpfo, 'k:'); end
xlim([0 1000]); xlabel('频率 (Hz)'); ylabel('|E|/N');
title('健康信号的包络谱 —— 底噪越低越好（虚线 = k\cdotBPFO，这里应该什么都没有）');
legend('Location','northeast');

subplot(2,1,2);
hold on; grid on;
for c = 1:ncase
    plot(f, Eall_f(:,c), 'Color', cols(c,:), 'DisplayName', cases{c,1});
end
for k = 1:4, xline(k*f_bpfo, 'k:'); end
xlim([0 1000]); xlabel('频率 (Hz)'); ylabel('|E|/N');
title('故障信号的包络谱 —— 峰要立起来');
legend('Location','northeast');

out_png = fullfile(fileparts(mfilename('fullpath')), ...
                   'bearing_leakage_check_result.png');
saveas(gcf, out_png);
fprintf('\n图已存：%s\n', out_png);

%% ================= 局部函数 =================
function E = env_spec(x, N, fs, use_hann, use_bp, bp_lo, bp_hi)
% 包络谱，带两个开关：
%   use_hann : 是否加 Hann 窗（治帧边缘泄漏）
%   use_bp   : 是否先带通到共振带（治背景当载波）
    f = (0:N-1).' * (fs/N);
    X = fft(x);

    % --- 解析信号（单边带）：正频率 x2，负频率清零 ---
    H = zeros(N,1);
    H(1)     = 1;
    H(2:N/2) = 2;
    H(N/2+1) = 1;

    % --- 共振带带通（只作用于正频率侧）---
    if use_bp
        H = H .* (f >= bp_lo & f <= bp_hi);
    end

    env = abs(ifft(X .* H));

    % --- 加窗 ---
    if use_hann
        w = hann(N);
    else
        w = ones(N,1);
    end

    env = env - sum(env .* w) / sum(w);   % 按窗加权去均值
    E   = fft(env .* w) / sum(w);         % 归一化，线幅度与窗无关
end
