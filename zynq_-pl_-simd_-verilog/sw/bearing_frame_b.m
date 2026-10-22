%% bearing_frame_b.m
%  A4.1-4b  帧 B：BPFO 逼近分辨率下限时，链路还立不立得住
%  2026-09-19
%
%  背景：定稿帧 A 的 BPFO 故意取 4*df = 187.5 Hz（正好落在 bin 中心），那是为了把扇贝损失
%  这个混淆因素排除掉、先把对齐做对。真实 BPFO 不会落在 bin 上 —— CWRU 驱动端 1730 rpm
%  时是 103.56 Hz，只有 103.56/46.875 = 2.21 个 bin。
%
%  本脚本要回答的唯一问题：当 BPFO 逼近 df = 46.875 Hz 这个硬天花板时，
%  包络谱法给出的对比度还剩多少？还够不够当判据？
%
%  与 bearing_bpfo_sweep.m 的区别（不要混用两者的数）：
%    - 这个用定稿参数 B = 3200（带通 1400~4600），扫描脚本用的是旧的 B = 2400
%    - 这个往低端细扫（bin 2.0 ~ 4.0），扫描脚本覆盖的是 103 ~ 450 Hz 全段
%    - 这个多报一列"窗内峰值落在第几个 bin"，用来看窗口有没有偏
%
%  下限的来历：k=1 的搜索中心是 floor(cbin)。cbin < 1 时 floor = 0，
%  窗口会掉到直流上 —— 所以 BPFO 至少要 2 个 bin，即 93.75 Hz。

clear; clc; close all;

%% ---------------- 定稿参数（与 bearing_pipeline_final.m 逐字一致）----------------
fs = 48000; N = 1024; df = fs/N;
f_res = 3000;              % 结构共振 Hz
B     = 3200;              % 带通带宽 Hz -> 1400 ~ 4600
beta  = 500;  snr_db = 10;  seed = 1;
K     = 4;

% 机器背景（与定稿一致）
f_shaft = 25;  shaft_h = [1 2 3 4];  a_shaft = [1.00 0.40 0.20 0.10];
f_line  = [50 100];                  a_line  = [0.60 0.25];

% 参考案例：噪声功率由它定，全部案例共用同一次噪声实现
f_bpfo_ref = 4*df;                          % 187.5 Hz，就是帧 A

% 扫描点，按 bin 数排（Hz 标注的是它的物理含义）
bpfo_list = df * [2.00 2.21 2.50 3.00 3.50 4.00];
bpfo_note = {'2.00 bin', '2.21 bin = CWRU 1730rpm', '2.50 bin', ...
             '3.00 bin', '3.50 bin', '4.00 bin = frame A'};

n = (0:N-1).';  t = n/fs;  f = (0:N-1).' * df;
bp_mask = (f >= f_res-B/2) & (f <= f_res+B/2);
win     = 0.5*(1 - cos(2*pi*n/(N-1)));       % Hann（对称），C 那边照这个写

fprintf('===== 定稿参数 =====\n');
fprintf('  N = %d   df = %.4f Hz   B = %d Hz -> 带通 %.0f ~ %.0f Hz\n', ...
        N, df, B, f_res-B/2, f_res+B/2);
fprintf('  包络谱上限 = B/2 = %.0f Hz\n', B/2);
fprintf('  k=4 时需要 B >= 2*4*BPFO = %.0f Hz  ->  BPFO <= %.1f Hz\n\n', ...
        8*max(bpfo_list), B/8);

%% ---------------- 噪声：由参考案例定，全部案例共用 ----------------
x_ref   = make_impulses(t, f_bpfo_ref, beta, f_res);
p_noise = mean(x_ref.^2) / 10^(snr_db/10);
rng(seed);
noise = sqrt(p_noise) * randn(N,1);

x_bg = zeros(N,1);
for k = 1:numel(shaft_h), x_bg = x_bg + a_shaft(k)*sin(2*pi*f_shaft*shaft_h(k)*t); end
for k = 1:numel(f_line),   x_bg = x_bg + a_line(k)*sin(2*pi*f_line(k)*t); end

fprintf('  噪声功率 %.6f（按 BPFO = %.2f Hz 参考案例定，全部案例共用同一次实现）\n\n', ...
        p_noise, f_bpfo_ref);

%% ---------------- 扫描 ----------------
fprintf('===== 对比度 vs BPFO =====\n');
fprintf('  BPFO      bin    hw |     k=1      k=2      k=3      k=4 |   最差   真峰bin\n');
fprintf('  %s\n', repmat('-', 1, 78));

rows = zeros(numel(bpfo_list), 10);   % f_bpfo,cbin,hw,con(1..4),min,peakbin
for ii = 1:numel(bpfo_list)
    f_bpfo = bpfo_list(ii);

    x_fault = x_bg + make_impulses(t, f_bpfo, beta, f_res) + noise;
    x_heal  = x_bg                                        + noise;

    [Ef, ~]  = env_spec(x_fault, N, bp_mask, win);
    [Eh, ~]  = env_spec(x_heal,  N, bp_mask, win);

    cbin = f_bpfo / df;
    hw   = max(1, min(2, floor(cbin/2)));

    con = zeros(1,K);  winpeak = zeros(1,K);
    for k = 1:K
        c  = k*cbin;
        lo = max(1, floor(c) - hw + 1);         % MATLAB 1-based
        hi = min(N/2, floor(c) + hw + 1);
        seg = abs(Ef(lo:hi));
        con(k)     = 20*log10( max(seg) / (max(abs(Eh(lo:hi))) + eps) );
        [~, ip]    = max(seg);
        winpeak(k) = (lo + ip - 2) / k;         % -1 转 0-based，再折算回 BPFO 的 bin 数
    end

    fprintf('  %7.2f  %5.2f  %4d |', f_bpfo, cbin, hw);
    for k = 1:K, fprintf(' %8.2f', con(k)); end
    fprintf(' | %7.2f  %7.2f\n', min(con), winpeak(1));

    rows(ii,:) = [f_bpfo, cbin, hw, con, min(con), winpeak(1), 0];
end

fprintf('\n  真峰bin = k=1 窗口内 |E| 最大处折算出的 BPFO bin 数\n');
fprintf('  窗口中心 = floor(cbin)。两者差得越多，说明 Hann 主瓣把峰推离了窗口中心。\n');
fprintf('  Hann 主瓣宽 4 个 bin，所以 cbin < 4 时峰必然被抹开。\n');

%% ---------------- k=1 附近的 |E| 形状（最诊断性的一张表）----------------
fprintf('\n===== k=1 附近 |E| 的形状（看峰宽和位置）=====\n');
fprintf('   bin :');
for b = 1:8, fprintf('%9d', b); end
fprintf('\n');
for ii = [1 2 6]
    f_bpfo  = bpfo_list(ii);
    x_fault = x_bg + make_impulses(t, f_bpfo, beta, f_res) + noise;
    [Ef, ~] = env_spec(x_fault, N, bp_mask, win);
    v = abs(Ef(2:9));                 % 0-based bin 1..8
    fprintf('  %5.2f:', f_bpfo/df);
    for b = 1:8, fprintf('%9.5f', v(b)); end
    fprintf('   <- %s\n', bpfo_note{ii});
end

%% ---------------- 汇总 ----------------
fprintf('\n===== 汇总 =====\n');
allmin = min(rows(:,4:7), [], 'all');
fprintf('  全部案例、全部 k 的最差对比度 = %.2f dB   (出现在 BPFO = %.2f Hz)\n', ...
        allmin, rows(find(min(rows(:,4:7),[],2) == allmin, 1), 1));
fprintf('  k=1 对比度: %.2f (%.2f bin)  ..  %.2f (%.2f bin)\n', ...
        rows(1,4), rows(1,2), rows(end,4), rows(end,2));
fprintf('  帧 A (4.00 bin) k=1 = %.2f dB 是上界；扇贝损失把它压到 %.2f dB 在 2.21 bin 处\n', ...
        rows(end,4), rows(2,4));

%% ---------------- 画图 ----------------
figure('Name','帧 B: BPFO 逼近分辨率下限','Position',[80 50 1000 620]);

subplot(2,1,1); hold on; grid on;
cols = lines(K);
for k = 1:K
    plot(rows(:,2), rows(:,3+k), 'o-', 'Color', cols(k,:), ...
         'DisplayName', sprintf('k = %d', k));
end
xline(2.21, 'k--', 'DisplayName', 'CWRU 1730 rpm (2.21 bin)');
xticks(rows(:,2));
xticklabels({bpfo_note{:}}); xtickangle(20);
xlabel('BPFO (bin)'); ylabel('对比度 (dB)');
title(sprintf('对比度随 BPFO 逼近分辨率下限的变化（B = %d Hz, df = %.2f Hz）', B, df));
legend('Location','southwest');

subplot(2,1,2); hold on; grid on;
bar(rows(:,2), rows(:,9));                  % 真峰bin
plot(rows(:,2), rows(:,2), 'k--', 'DisplayName','理想：峰就在 cbin');
plot(rows(:,2), floor(rows(:,2)), 'r:', 'DisplayName','搜索窗中心 floor(cbin)');
xticks(rows(:,2));
xticklabels({bpfo_note{:}}); xtickangle(20);
xlabel('BPFO (bin)'); ylabel('bin');
title('k=1 真峰位置 vs 窗口中心（偏差 = 扇贝损失 + 搜索窗偏移）');
legend('Location','northwest');

out_png = fullfile(fileparts(mfilename('fullpath')), 'bearing_frame_b_result.png');
saveas(gcf, out_png);
fprintf('\n图已存：%s\n', out_png);

%% ================= 局部函数 =================
function x = make_impulses(t, f_bpfo, beta, f_res)
% 冲击串：每 1/f_bpfo 秒一发指数衰减正弦
    T     = 1/f_bpfo;
    m_max = floor(t(end)/T);
    x     = zeros(size(t));
    for m = 0:m_max
        tm  = m*T;
        idx = t >= tm;
        tau = t(idx) - tm;
        x(idx) = x(idx) + exp(-beta*tau) .* sin(2*pi*f_res*tau);
    end
end

function [E, H] = env_spec(x, N, bp_mask, win)
% 包络谱（定稿链路），顺便把 H 也吐出来便于查
    H = zeros(N,1);
    H(1)     = 1;                 % 直流
    H(2:N/2) = 2;                 % 正频率 x2
    H(N/2+1) = 1;                 % Nyquist
    H = H .* bp_mask;             % 共振带带通

    env = abs(ifft(fft(x) .* H));
    env = env - sum(env.*win)/sum(win);
    E   = fft(env.*win) / sum(win);
end
