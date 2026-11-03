%% bearing_synth_compare.m
%  A4.1-2  故障 vs 健康 对照
%  2026-09-19
%
%  目的：v1 只证明了算法链路没写错（信号是自己按 BPFO 造的，峰当然在 BPFO）。
%  本脚本加一个"没有故障"的对照信号，让"峰在 k*BPFO 上"变成有判据的结论。
%
%  设计要点：两个信号的差别**只有**冲击串。转频/工频/噪声完全一样，
%  连噪声实现都共用同一次 randn。这样测出来的差就是冲击串本身的贡献。

clear; clc; close all;

%% ---------------- 参数（与 bearing_synth_frame.m 一致）----------------
fs      = 48000;             % 采样率 Hz
N       = 1024;              % 帧长
df      = fs / N;            % 频率分辨率 46.875 Hz
T_frame = N / fs;

f_bpfo  = 4  * df;           % 187.5 Hz  故障特征频率（落在 bin 4）
f_res   = 64 * df;           % 3000  Hz  结构共振（落在 bin 64）
beta    = 500;               % 冲击衰减系数 1/s
snr_db  = 10;                % 信噪比 dB
seed    = 1;                 % 随机种子

% --- 机器背景：两个信号都有 ---
f_shaft = 25;                % 转频 Hz（1500 rpm），落在 bin 0.53
shaft_h = [1 2 3 4];         % 转频的 1..4 次谐波
a_shaft = [1.00 0.40 0.20 0.10];
f_line  = [50 100];          % 工频及二次，落在 bin 1.07 / 2.13
a_line  = [0.60 0.25];

fprintf('===== 参数 =====\n');
fprintf('  fs = %d Hz, N = %d  ->  df = %.4f Hz,  一帧 %.3f ms\n', ...
        fs, N, df, T_frame*1000);
fprintf('  故障特征 BPFO = %.2f Hz  ->  bin %d\n', f_bpfo, round(f_bpfo/df));
fprintf('  结构共振 f_res = %.2f Hz  ->  bin %d\n', f_res, round(f_res/df));

n = (0:N-1).';
t = n / fs;

%% ---------------- 1. 冲击串（只有故障信号有）----------------
T_imp = 1 / f_bpfo;
m_max = floor(t(end) / T_imp);
x_imp = zeros(N,1);
for m = 0:m_max
    tm  = m * T_imp;
    idx = t >= tm;
    tau = t(idx) - tm;
    x_imp(idx) = x_imp(idx) + exp(-beta*tau) .* sin(2*pi*f_res*tau);
end
fprintf('  一帧内冲击个数 = %d\n', m_max+1);

%% ---------------- 2. 机器背景（两个信号都有）----------------
x_bg = zeros(N,1);
for k = 1:numel(shaft_h)
    x_bg = x_bg + a_shaft(k) * sin(2*pi*f_shaft*shaft_h(k)*t);
end
for k = 1:numel(f_line)
    x_bg = x_bg + a_line(k) * sin(2*pi*f_line(k)*t);
end

%% ---------------- 3. 噪声（同功率、同种子 => 两个信号共用同一次实现）----
p_sig   = mean(x_imp.^2);
p_noise = p_sig / 10^(snr_db/10);
rng(seed);
noise = sqrt(p_noise) * randn(N,1);

%% ---------------- 4. 两个信号 ----------------
x_fault = x_bg + x_imp + noise;    % 有故障
x_heal  = x_bg         + noise;    % 无故障

fprintf('\n===== 信号功率 =====\n');
fprintf('  冲击串  %.6f\n', mean(x_imp.^2));
fprintf('  机器背景 %.6f\n', mean(x_bg.^2));
fprintf('  噪声    %.6f\n', mean(noise.^2));
fprintf('  故障信号总功率 %.6f\n', mean(x_fault.^2));
fprintf('  健康信号总功率 %.6f\n', mean(x_heal.^2));

%% ---------------- 5. 处理链（与 v1 完全相同）----------------
E_fault = env_spec(x_fault, N);
E_heal  = env_spec(x_heal,  N);
X_fault = fft(x_fault);
X_heal  = fft(x_heal);

f   = (0:N-1).' * df;
pos = 1:N/2;
kmax_plot = 1000;            % 画图只画到 1000 Hz

%% ---------------- 6. 画图：4 行 x 2 列并排对照 ----------------
figure('Name','A4.1-2 故障 vs 健康','Position',[80 30 1100 860]);

% --- row 1: 时域 ---
subplot(4,2,1);
plot(t*1000, x_fault, 'b'); grid on;
xlabel('时间 (ms)'); ylabel('幅值'); title('故障：时域');

subplot(4,2,2);
plot(t*1000, x_heal, 'Color',[0 0.5 0]); grid on;
xlabel('时间 (ms)'); ylabel('幅值'); title('健康：时域');

% --- row 2: 原始频谱（0~1000 Hz）---
subplot(4,2,3);
plot(f(pos), abs(X_fault(pos))/N, 'b'); grid on; hold on;
xlim([0 kmax_plot]); ylim([0 0.15]);
xlabel('频率 (Hz)'); ylabel('|X|'); title('故障：原始频谱（0~1000 Hz）');

subplot(4,2,4);
plot(f(pos), abs(X_heal(pos))/N, 'Color',[0 0.5 0]); grid on; hold on;
xlim([0 kmax_plot]); ylim([0 0.15]);
xlabel('频率 (Hz)'); ylabel('|X|'); title('健康：原始频谱（0~1000 Hz）');

% --- row 3: 包络 ---
subplot(4,2,5);
plot(t*1000, abs(analytic(x_fault, N)), 'b'); grid on;
xlabel('时间 (ms)'); ylabel('幅值'); title('故障：包络');

subplot(4,2,6);
plot(t*1000, abs(analytic(x_heal, N)), 'Color',[0 0.5 0]); grid on;
xlabel('时间 (ms)'); ylabel('幅值'); title('健康：包络');

% --- row 4: 包络谱（0~1000 Hz）---
step = round(f_bpfo/df);

subplot(4,2,7);
plot(f(pos), abs(E_fault(pos))/N, 'b'); grid on; hold on;
for k = 1:4, xline(k*f_bpfo, 'k:'); end
xlim([0 kmax_plot]);
xlabel('频率 (Hz)'); ylabel('|E|'); title('故障：包络谱（虚线 = k\cdotBPFO）');

subplot(4,2,8);
plot(f(pos), abs(E_heal(pos))/N, 'Color',[0 0.5 0]); grid on; hold on;
for k = 1:4, xline(k*f_bpfo, 'k:'); end
xlim([0 kmax_plot]);
xlabel('频率 (Hz)'); ylabel('|E|'); title('健康：包络谱（虚线 = k\cdotBPFO）');

%% ---------------- 7. 判据表 ----------------
fprintf('\n===== k*BPFO 处的包络谱幅值（判据）=====\n');
fprintf('    k    频率(Hz)      故障        健康       比值      比值(dB)\n');
ratios = zeros(8,1);
for k = 1:8
    idx = k*step + 1;
    if idx > N/2, break; end
    vf = abs(E_fault(idx))/N;
    vh = abs(E_heal(idx))/N;
    r  = vf / (vh + eps);
    ratios(k) = r;
    fprintf('  %3d  %9.2f  %.6f  %.6f  %9.3f  %8.2f\n', ...
            k, k*f_bpfo, vf, vh, r, 20*log10(r));
end

% 噪底参考：k*BPFO 两侧各 2 个 bin 的中位数
fprintf('\n===== 噪底参考（k*BPFO 两侧邻 bin）=====\n');
for k = 1:4
    idx = k*step + 1;
    if idx+2 > N/2, break; end
    nb_f = median(abs(E_fault(idx-2:idx+2))/N);
    nb_h = median(abs(E_heal (idx-2:idx+2))/N);
    fprintf('  k=%d 附近:  故障 %.6f   健康 %.6f\n', k, nb_f, nb_h);
end

% 特征指标：前 4 个谐波的峰高之和
feat_f = sum(abs(E_fault(step*(1:4)+1)))/N;
feat_h = sum(abs(E_heal (step*(1:4)+1)))/N;
fprintf('\n===== 特征指标 = sum(|E| @ k*BPFO, k=1..4) =====\n');
fprintf('  故障 = %.6f\n', feat_f);
fprintf('  健康 = %.6f\n', feat_h);
fprintf('  比值 = %.3f  (%.2f dB)\n', feat_f/feat_h, 20*log10(feat_f/feat_h));

%% ---------------- 8. 存图 ----------------
out_png = fullfile(fileparts(mfilename('fullpath')), ...
                   'bearing_synth_compare_result.png');
saveas(gcf, out_png);
fprintf('\n图已存：%s\n', out_png);

%% ================= 局部函数 =================
function xa = analytic(x, N)
% 解析信号 xa = x + j*Hilbert(x)，频域构造单边带滤波器
    H = zeros(N,1);
    H(1)     = 1;          % 直流不动
    H(2:N/2) = 2;          % 正频率乘 2
    H(N/2+1) = 1;          % Nyquist 不动
    % H(N/2+2:end) 保持 0  —— 负频率砍掉
    xa = ifft(fft(x) .* H);
end

function E = env_spec(x, N)
% 包络谱 = |解析信号| 去均值后做 FFT
    env = abs(analytic(x, N));
    env = env - mean(env);
    E   = fft(env);
end
