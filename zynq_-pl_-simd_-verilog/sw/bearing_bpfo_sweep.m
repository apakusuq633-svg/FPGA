%% bearing_bpfo_sweep.m
%  A4.1-4  扫 BPFO：链路在非整数 bin 上还立得住吗
%  2026-09-19
%
%  之前所有结论都建立在 BPFO = 4*df（正好落在 bin 中心）上，那是我故意挑的。
%  真实 BPFO 不会落在 bin 上（CWRU 驱动端 1730 rpm 时是 103.56 Hz -> bin 2.21）。
%  本脚本扫一遍，看对比度退化多少 —— 这决定链路能不能定稿。
%
%  链路（定稿候选，C 要照抄这套）：
%     X  = fft(x)
%     H  = 单边带(正频率x2, 负频率清零) ∩ 共振带[fc-B/2, fc+B/2]
%     xa = ifft(X .* H)          <- 一次乘同时完成解析信号 + 带通
%     env= |xa|
%     env= env - sum(env.*w)/sum(w)
%     E  = fft(env .* w) / sum(w)         w = Hann
%     峰 = max|E| 在 k*BPFO 附近 ±hw bin 内

clear; clc; close all;

%% ---------------- 固定参数 ----------------
fs = 48000; N = 1024; df = fs/N;
f_res = 3000;              % 结构共振 Hz
B     = 2400;              % 带通带宽 Hz -> 1800 ~ 4200
beta  = 500;               % 冲击衰减系数 1/s
snr_db = 10;  seed = 1;
K     = 4;                 % 看 1..K 次谐波

% 机器背景（固定不变）
f_shaft = 25;  shaft_h = [1 2 3 4];  a_shaft = [1.00 0.40 0.20 0.10];
f_line  = [50 100];                  a_line  = [0.60 0.25];

f_bpfo_ref = 4*df;         % 参考案例，用来定噪声功率
bpfo_list  = [103.56 130 150 187.5 200 225 250 300 350 400 450];

n = (0:N-1).';  t = n/fs;
f = (0:N-1).' * df;

bp_mask = (f >= f_res-B/2) & (f <= f_res+B/2);
win     = 0.5*(1 - cos(2*pi*n/(N-1)));      % Hann（对称），C 那边照这个写

fprintf('===== 设置 =====\n');
fprintf('  N = %d   df = %.4f Hz   帧长 %.3f ms\n', N, df, N/fs*1000);
fprintf('  带通 %.0f ~ %.0f Hz  (B = %d Hz, 带内 %d bin)\n', ...
        f_res-B/2, f_res+B/2, B, sum(bp_mask));
fprintf('  => 包络谱上限 = B/2 = %.1f Hz\n', B/2);
need = 2*K*max(bpfo_list);
if need <= B
    verdict = '够';
else
    verdict = '不够';
end
fprintf('  看 1..%d 次谐波、BPFO 最大 %.0f Hz => 需要 B >= %d Hz，本设置 %s\n\n', ...
        K, max(bpfo_list), need, verdict);

%% ---------------- 机器背景（固定）----------------
x_bg = zeros(N,1);
for k = 1:numel(shaft_h), x_bg = x_bg + a_shaft(k)*sin(2*pi*f_shaft*shaft_h(k)*t); end
for k = 1:numel(f_line),   x_bg = x_bg + a_line(k)*sin(2*pi*f_line(k)*t); end

%% ---------------- 噪声：按参考案例定，所有案例共用同一次实现 ----------------
x_ref   = make_impulses(t, f_bpfo_ref, beta, f_res);
p_noise = mean(x_ref.^2) / 10^(snr_db/10);
rng(seed);
noise = sqrt(p_noise) * randn(N,1);
fprintf('  噪声功率 %.6f  (按 BPFO = %.2f Hz 参考案例定，全部案例共用)\n\n', ...
        p_noise, f_bpfo_ref);

%% ---------------- 扫描 ----------------
fprintf('  BPFO     bin    周期数 |    k=1     k=2     k=3     k=4 |  最差   k=1峰   健康底\n');
fprintf('  %s\n', repmat('-', 1, 88));

rows = zeros(numel(bpfo_list), 9);
for ii = 1:numel(bpfo_list)
    f_bpfo = bpfo_list(ii);

    x_imp   = make_impulses(t, f_bpfo, beta, f_res);
    x_fault = x_bg + x_imp + noise;
    x_heal  = x_bg         + noise;

    Ef = env_spec(x_fault, N, bp_mask, win);
    Eh = env_spec(x_heal,  N, bp_mask, win);

    cbin = f_bpfo / df;                     % 相邻谐波间隔（bin）
    hw   = max(1, min(2, floor(cbin/2)));   % 峰值搜索半宽，防止相邻谐波窗口重叠

    con = zeros(1,K);  pk1 = 0;  hb1 = 0;
    for k = 1:K
        c  = k * cbin;
        lo = max(1, floor(c) - hw + 1);
        hi = min(N/2, floor(c) + hw + 1);
        pf = max(abs(Ef(lo:hi)));
        ph = max(abs(Eh(lo:hi)));
        con(k) = 20*log10( pf / (ph + eps) );
        if k == 1, pk1 = pf;  hb1 = ph;  end
    end

    fprintf('  %6.2f  %7.2f  %6.2f |', f_bpfo, cbin, f_bpfo*N/fs);
    for k = 1:K, fprintf(' %7.2f', con(k)); end
    fprintf(' | %7.2f  %.5f  %.5f\n', min(con), pk1, hb1);

    rows(ii,:) = [f_bpfo, cbin, f_bpfo*N/fs, con, pk1, hb1];
end

%% ---------------- 汇总 ----------------
fprintf('\n===== 汇总 =====\n');
fprintf('  全部案例、全部谐波的最差值 = %.2f dB\n', min(rows(:,4:7), [], 'all'));
fprintf('  k=1 对比度范围             = %.2f ~ %.2f dB\n', ...
        min(rows(:,4)), max(rows(:,4)));
fprintf('  k=1 对比度 >= 25 dB 的案例 = %d / %d\n', ...
        sum(rows(:,4) >= 25), size(rows,1));

%% ---------------- 画图 ----------------
figure('Name','A4.1-4 BPFO 扫描','Position',[80 50 1000 640]);

subplot(2,1,1); hold on; grid on;
cols = lines(K);
for k = 1:K
    plot(rows(:,1), rows(:,3+k), 'o-', 'Color', cols(k,:), ...
         'DisplayName', sprintf('k = %d', k));
end
yline(25, 'k--', 'DisplayName', '判据 25 dB');
xlabel('BPFO (Hz)'); ylabel('对比度 (dB)');
title(sprintf('各次谐波对比度   （带通 %d~%d Hz, B = %d Hz）', ...
              f_res-B/2, f_res+B/2, B));
legend('Location','southwest');

subplot(2,1,2); hold on; grid on;
plot(rows(:,1), rows(:,2), 'ks-', 'DisplayName','BPFO 落在第几个 bin');
yline(1,'k:'); yline(2,'k:'); yline(4,'k:');
xlabel('BPFO (Hz)'); ylabel('bin');
title('BPFO 与 bin 网格的对齐情况（整数 bin = 无扇贝损失）');

out_png = fullfile(fileparts(mfilename('fullpath')), ...
                   'bearing_bpfo_sweep_result.png');
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

function E = env_spec(x, N, bp_mask, win)
% 包络谱（定稿链路）
    H = zeros(N,1);
    H(1)     = 1;                 % 直流
    H(2:N/2) = 2;                 % 正频率 x2
    H(N/2+1) = 1;                 % Nyquist
    H = H .* bp_mask;             % 共振带带通

    env = abs(ifft(fft(x) .* H));
    env = env - sum(env.*win)/sum(win);
    E   = fft(env.*win) / sum(win);
end
