%% bearing_synth_frame.m
%  A4.1-1  合成一帧轴承外圈故障信号，看频谱与包络谱
%  2026-09-19
%
%  目的：造一个"答案已知"的信号，作为 CPU1 上 C 实现的金标准。
%  本脚本刻意不用 hilbert()/pwelch() 之类的黑盒，每一步都手写展开，
%  因为 C 那边要照抄同一套运算，用黑盒就对不上。

clear; clc; close all;

%% ---------------- 参数 ----------------
fs      = 48000;             % 采样率 Hz        （方案定死）
N       = 1024;              % 帧长             （方案定死）
df      = fs / N;            % 频率分辨率 Hz
T_frame = N / fs;            % 一帧时长 s

f_bpfo  = 4  * df;           % 外圈故障特征频率 Hz（故意落在 bin 中心）
f_res   = 64 * df;           % 系统共振频率 Hz
beta    = 500;               % 冲击衰减系数 1/s
snr_db  = 10;                % 信噪比 dB
seed    = 1;                 % 随机种子，固定 => 可复现

fprintf('===== 参数 =====\n');
fprintf('  fs = %d Hz, N = %d  ->  df = %.4f Hz,  一帧 %.3f ms\n', ...
        fs, N, df, T_frame*1000);

n = (0:N-1).';               % 样点序号
t = n / fs;                  % 时间轴 s

%% ---------------- 1. 冲击序列 ----------------
% 单个冲击 = 指数衰减的正弦（结构共振被激起后的自由响应）
%     h(tau) = exp(-beta*tau) .* sin(2*pi*f_res*tau),   tau >= 0
% 冲击序列 = 每 1/f_bpfo 秒来一发
T_imp = 1 / f_bpfo;
m_max = floor(t(end) / T_imp);

x_clean = zeros(N,1);
for m = 0:m_max
    tm  = m * T_imp;
    idx = t >= tm;
    tau = t(idx) - tm;
    x_clean(idx) = x_clean(idx) + exp(-beta*tau) .* sin(2*pi*f_res*tau);
end
fprintf('  一帧内冲击个数 = %d （BPFO = %.2f Hz, 冲击周期 %.3f ms）\n', ...
        m_max+1, f_bpfo, T_imp*1000);

%% ---------------- 2. 加噪声 ----------------
p_sig   = mean(x_clean.^2);
p_noise = p_sig / 10^(snr_db/10);
rng(seed);
x = x_clean + sqrt(p_noise) * randn(N,1);

%% ---------------- 3. 原始信号频谱 ----------------
X   = fft(x);
f   = (0:N-1).' * df;
pos = 1:N/2;                 % 只取 0 ~ fs/2

%% ---------------- 4. 包络（手写解析信号）----------------
% 解析信号 xa = x + j*Hilbert(x)，在频域构造：
%   H[0]          = 1    （直流不动）
%   H[1 .. N/2-1] = 2    （正频率乘 2）
%   H[N/2]        = 1    （Nyquist 不动）
%   H[N/2+1..N-1] = 0    （负频率砍掉）
% 然后 xa = ifft(fft(x) .* H)，包络 = |xa|
H         = zeros(N,1);
H(1)      = 1;
H(2:N/2)  = 2;
H(N/2+1)  = 1;

xa     = ifft(fft(x) .* H);
env    = abs(xa);            % 包络
env_ac = env - mean(env);    % 去直流，只看起伏

%% ---------------- 5. 包络谱 ----------------
E = fft(env_ac);             % 频率轴与原始谱相同（同一 fs、同一 N）

%% ---------------- 6. 画图 ----------------
figure('Name','A4.1-1 轴承外圈故障合成信号','Position',[100 40 900 820]);

subplot(4,1,1);
plot(t*1000, x, 'b'); grid on;
xlabel('时间 (ms)'); ylabel('幅值');
title(sprintf('时域波形    fs=%d Hz  N=%d  BPFO=%.2f Hz  SNR=%d dB', ...
              fs, N, f_bpfo, snr_db));

subplot(4,1,2);
plot(f(pos), 20*log10(abs(X(pos))/N + eps), 'b'); grid on; hold on;
xline(f_res, 'r--', sprintf('f_{res}=%.0f Hz', f_res));
xlabel('频率 (Hz)'); ylabel('|X| (dB)');
title('原始信号频谱  —— 峰在共振频率上，不在 BPFO 上');

subplot(4,1,3);
plot(t*1000, env, 'r'); grid on; hold on;
yline(mean(env), 'k--');
xlabel('时间 (ms)'); ylabel('幅值');
title('包络  —— 一串衰减鼓包，鼓包间隔 = 1/BPFO');

subplot(4,1,4);
plot(f(pos), abs(E(pos))/N, 'r'); grid on; hold on;
hold on;
for k = 1:5
    xline(k*f_bpfo, 'k:');
end
xlim([0 10*f_bpfo]);
xlabel('频率 (Hz)'); ylabel('|E|');
title('包络谱  —— 峰在 k\cdotBPFO 上（虚线 = k\cdotBPFO）');

%% ---------------- 7. 打印关键量 ----------------
fprintf('\n===== 关键 bin =====\n');
fprintf('  BPFO  = %8.4f Hz  ->  bin %d\n', f_bpfo, round(f_bpfo/df));
fprintf('  f_res = %8.4f Hz  ->  bin %d\n', f_res,  round(f_res/df));

fprintf('\n===== 原始频谱在 f_res 附近 =====\n');
kb = round(f_res/df);
for k = kb-2:kb+2
    fprintf('  bin %4d  %8.2f Hz  %.6f\n', k, k*df, abs(X(k+1))/N);
end

fprintf('\n===== 包络谱前 12 个 bin =====\n');
step = round(f_bpfo/df);
for k = 0:11
    mark = '';
    if k > 0 && mod(k, step) == 0
        mark = '   <== k*BPFO';
    end
    fprintf('  bin %2d  %8.2f Hz  %.6f%s\n', k, k*df, abs(E(k+1))/N, mark);
end

fprintf('\n===== 包络谱在 k*BPFO 上的幅值 =====\n');
for k = 1:8
    idx = k*step + 1;
    if idx <= N/2
        fprintf('  k=%d  %8.2f Hz  %.6f\n', k, k*f_bpfo, abs(E(idx))/N);
    end
end

%% ---------------- 8. 存图 ----------------
out_png = fullfile(fileparts(mfilename('fullpath')), ...
                   'bearing_synth_frame_result.png');
saveas(gcf, out_png);
fprintf('\n图已存：%s\n', out_png);
fprintf('\n完成。请把上面这些数字贴回来。\n');
