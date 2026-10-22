%% clf_train_export_demo.m —— 站 12：合成数据 → 训练随机森林 → 导出 C 头文件
%
% 三件事，第 3 件是最容易被漏掉的那件：
%   1. 造带标签的合成轴承数据（4 类：正常 / 外圈 / 内圈 / 滚珠）
%   2. 用**按录制分组**的切分训练随机森林，打印混淆矩阵
%   3. **把森林导出成 C 头文件** —— 这是"能答辩"和"能实现"的分界线
%
% ⚠⚠ **这个脚本有两份，用途不同，别拿混。** 训练部分两边一致（rng 钉死），分叉只在
%    "导出成 C 头"那一步，两份各自服务一条消费链：
%      - 本份  sw/clf_train_export_demo.m（在仓库里）
%          产出 sw/clf_model.h —— **板载版**：ASCII 类名 normal/outer/inner/ball、
%          保护宏 CLF_MODEL_H。给 sw/ps_classifier.h、sw/ps_clf_test.c 用。
%      - 另一份  算法学习笔记\matlab\clf_train_export_demo.m
%          产出 站12_分类器代码\clf_model_demo.h —— **Host 演示版**：中文类名、
%          保护宏 CLF_MODEL_DEMO_H。给 站12_分类器代码\clf_infer_demo.c 用。
%    改了训练逻辑（数据合成、特征、阶次、归一化）**两份都要改**，否则两条链会静默发散。
%
% ⚠ 与既有脚本的关系：
%   - 思路沿用 sw/bearing_synth_frame.m（合成冲击串）和 sw/bearing_pipeline_final.m（6 步链）
%   - **但 fs 用 39062.5，不是那两个脚本里的 48000** —— 板子上跑的是 39062.5，
%     训练要用推理时同样的采样率，否则训练/推理分布不一致。
%
% ⚠ 两个必须写在最前面的诚实说明（详见文件末尾「设计说明」）：
%   ① 现有 pipeline_run() 的 feat[4] 是"在**给定一个** BPFO 的 k 次谐波上的能量"——
%      那是**检测器**特征（"有没有"），不是**判别器**特征（"是哪一种"）。
%      要分类，必须**同时探测多个候选阶次**，让分类器去比"哪个阶次突出"。
%   ② **准确率这个数，在合成数据上没有说服力** —— 见「设计说明」第 3 条。
%
% 运行：matlab -batch "set(0,'DefaultFigureVisible','off'); clf_train_export_demo"
%   （脚本放在 sw/ 下跑，产出就是 sw/clf_model.h。rng 已钉死，重跑逐位可复现。）

clear; clc; close all;

%% ===== 0. 全局参数 =====
fs     = 39062.5;             % 板子上的实际采样率（FCLK/1024），**不是 48000**
N_fft  = 8192;                % 特征提取用的窗长
df     = fs / N_fft;          % 频率分辨率
T_seg  = 1.024;               % 每段"录制"的时长 s
N_seg  = round(T_seg * fs);   % 每段录制的样点数
f_res  = 3000;                % 结构共振 Hz
B_lo   = 1400;  B_hi = 4600;  % 共振带
K      = 4;                   % 每个候选阶次看 1..K 次谐波
HW     = 2;                   % 取峰时左右各留几个 bin

JITTER = 0.03;                % ⚠ 轴承**几何未知**，标称阶次和真实阶次有 ±3% 出入
                              %   这一项直接影响准确率，也是"轴承型号没定"的量化体现

OUT_H  = fullfile(fileparts(mfilename('fullpath')), 'clf_model.h');

% ── 候选阶次（6205 标称几何）────────────────────────────────────────────
% 分类的关键：**逐个探测**，让分类器比"哪个阶次突出"。
ORDERS      = [0.398  2.357  3.572  5.428];   % FTF / BSF / BPFO / BPFI
ORDER_NAMES = {'FTF','BSF','BPFO','BPFI'};

% ── 类别 ──────────────────────────────────────────────────────────────
% 1 = 正常（不按任何阶次发冲击）
% 2 = 外圈：按 BPFO 发冲击，**无调制**
% 3 = 内圈：按 BPFI 发冲击，**被转频 f_r 调制**   ← 内外圈的关键物理差别
% 4 = 滚珠：按 BSF  发冲击，**被保持架频率 FTF 调制**
CLASS_NAMES = {'正常','外圈','内圈','滚珠'};
% 写进 C 头用的 ASCII 类名，顺序与 CLASS_NAMES 一一对应。
% 板子串口按 cp936 解码、xil_printf 打中文必乱码，所以导出那一步换 ASCII。
CLASS_NAMES_C = {'normal', 'outer', 'inner', 'ball'};
N_CLASS     = numel(CLASS_NAMES);

R_PER_CLASS = 30;             % 每类几段录制（1 段录制 = 1 个样本，见下）
% 特征数：4 个候选阶次 × K 次谐波 + 1X + 2X 转频线
N_FEAT = numel(ORDERS) * K + 2;

fprintf('===== 参数 =====\n');
fprintf('  fs = %.1f Hz   N_fft = %d   df = %.4f Hz\n', fs, N_fft, df);
fprintf('  每段录制 %.3f s = %d 样点\n', T_seg, N_seg);
fprintf('  特征 %d 维 = %d 个候选阶次 × %d 次谐波 + 1X + 2X\n', ...
        N_FEAT, numel(ORDERS), K);
fprintf('  阶次抖动 ±%.0f%%（轴承几何未知）\n\n', JITTER*100);

%% ===== 1. 造数据 =====
% ⚠ 一段录制 = 一个样本。
%   （早先的写法是把整段算出的特征复制 8 份当 8 个样本 —— 那是假样本量，
%     会让交叉验证看起来很稳，实际等效样本数没变。这里改掉。）
X = zeros(R_PER_CLASS * N_CLASS, N_FEAT);
Y = zeros(R_PER_CLASS * N_CLASS, 1);
G = zeros(R_PER_CLASS * N_CLASS, 1);
run_id = 0;

for c = 1:N_CLASS
    for r = 1:R_PER_CLASS
        run_id = run_id + 1;
        rng(1000 * c + r);

        f_r    = 25 + 10 * rand();            % 转频 25~35 Hz（1500~2100 rpm）
        snr_db = -8 + 16 * rand();            % -8~8 dB（含很难的低信噪比）
        sev    = 0.3 + 0.7 * rand();          % 冲击强度
        jit    = 1 + JITTER * (2*rand() - 1); % 真实阶次 ≠ 标称阶次

        x = synth_segment(N_seg, fs, c, f_r, f_res, sev, snr_db, ORDERS, jit);

        % ── 6 步链：多窗平均的包络谱 ──
        [P, ~] = avg_envelope_spectrum(x, N_fft, fs, B_lo, B_hi);

        % ── 取特征：按**标称**阶次取峰（信号是按 jit 后的真实阶次发的）──
        v = zeros(1, N_FEAT);
        for o = 1:numel(ORDERS)
            for k = 1:K
                v((o-1)*K + k) = peak_near(P, k * ORDERS(o) * f_r, df, HW);
            end
        end
        for k = 1:2
            v(numel(ORDERS)*K + k) = peak_near(P, k * f_r, df, HW);
        end

        % ── 归一化：转成"相对本帧中位数"的 dB ──
        % 让特征与增益、机器个体无关，剩下的信息才是"哪个阶次相对突出"。
        % 不做这一步，分类器很可能学到的是"这是哪台机器 / 这一帧多响"。
        X(run_id, :) = 20 * log10((v + eps) / (median(v) + eps));
        Y(run_id)    = c;
        G(run_id)    = run_id;
    end
end

fprintf('===== 数据 =====\n');
fprintf('  录制段数 = %d，样本数 = %d（1 段 = 1 样本）\n', run_id, size(X,1));
for c = 1:N_CLASS
    fprintf('    %s: %d 段\n', CLASS_NAMES{c}, sum(Y==c));
end

%% ===== 2. 训练 + 按录制留一交叉验证 =====
% ⚠ 切分按**录制** G，不是按帧随机切 —— 这是站 12 最大的坑（数据泄漏）。
%   这里"一段录制一个样本"，按帧随机切就没意义了；一旦以后改成一段录制出多个样本，
%   这一行就是唯一挡住泄漏的东西。
% ⚠ 固定全局种子。数据生成已经按录制各自 rng 了，但 fitcensemble 的
%   **袋装抽样**用的是全局流。不在这里钉住，同样的数据训两次会得到两片不同的森林，
%   "板上与 MATLAB 逐帧一致"这句就没法复现。
rng(0);

tpl = templateTree('MinLeafSize', 5);   % MinLeaf 默认 1，小样本上会记住单帧

cvp = cvpartition(G, 'LeaveOut');
Ypred_all = zeros(size(Y));
for i = 1:cvp.NumTestSets
    tr = training(cvp, i);  te = test(cvp, i);
    mi = fitcensemble(X(tr,:), Y(tr), 'Method', 'Bag', 'Learners', tpl);
    Ypred_all(te) = predict(mi, X(te,:));
end

fprintf('\n===== 按录制留一的交叉验证（%d 折）=====\n', cvp.NumTestSets);
fprintf('  准确率 = %.4f\n', mean(Ypred_all == Y));
fprintf('  ⚠ 这个数**只在合成数据上成立**，不能当性能指标用 —— 见「设计说明」第 3 条。\n');

Cm = confusionmat(Y, Ypred_all);
fprintf('\n  混淆矩阵（行=真实，列=预测）\n');
fprintf('  %8s', '');  fprintf('%8s', CLASS_NAMES{:});  fprintf('\n');
for c = 1:N_CLASS
    fprintf('  %8s', CLASS_NAMES{c});
    fprintf('%8d', Cm(c,:));
    fprintf('    召回率 %.3f\n', Cm(c,c) / max(1, sum(Cm(c,:))));
end

%% ===== 3. 用全量数据训练最终模型，并导出成 C =====
m = fitcensemble(X, Y, 'Method', 'Bag', 'Learners', tpl);

% ---- 3.1 自检：把 C 里要跑的推理循环，在 MATLAB 里原样实现一遍 ----
% 这是"验收 = 板上输出与 MATLAB 推理逐帧一致"的前半段 ——
% 现在还验不了 C（本机没有 gcc），但可以验**导出的那几张数组**能不能复现 predict()。
[pred_ref, NP] = clf_export_predict(m, X, N_CLASS);
n_diff = sum(pred_ref ~= predict(m, X));
fprintf('\n===== 导出自检（纯 MATLAB 复刻 C 的推理循环）=====\n');
fprintf('  总节点数 = %d，与 predict() 不一致的样本 = %d / %d\n', NP, n_diff, size(X,1));
if n_diff == 0
    fprintf('  ✅ 导出的数组能逐样本复现 predict() —— C 照这个循环写就对。\n');
else
    fprintf('  ❌ 不一致，导出逻辑有问题，先别写 C。\n');
end

% ---- 3.2 挑测试向量（每类 2 个，供板上编译后自检）----
% ⚠ 这些是**训练集里**的样本，只验"移植有没有搬错"，不构成泛化性能声明。
ti = [];
for c = 1:N_CLASS
    idx = find(Y == c);
    ti = [ti; idx(1:min(2, numel(idx)))]; %#ok<AGROW>
end
ti = ti(1:8);

% ---- 3.3 写头文件 ----
clf_write_header(m, OUT_H, N_FEAT, N_CLASS, CLASS_NAMES_C, ORDER_NAMES, X, Y, ti);
fprintf('\n头文件已写：%s\n', OUT_H);

% ---- 3.4 存模型，供画图脚本复用（避免重训）----
OUT_MAT = fullfile(fileparts(mfilename('fullpath')), 'clf_work.mat');
save(OUT_MAT, 'm', 'X', 'Y', 'G', 'ti', 'N_FEAT', 'N_CLASS', ...
     'CLASS_NAMES', 'ORDERS', 'ORDER_NAMES', 'K', 'fs', 'df', 'N_fft');
fprintf('模型已存：%s\n', OUT_MAT);

%% ===== 4. 特征重要性（看一眼特征提得对不对）=====
lbl = clf_feature_labels(ORDERS, ORDER_NAMES, K);
fprintf('\n===== 特征重要性（前 8）=====\n');
try
    imp = predictorImportance(m);
    [sv, si] = sort(imp, 'descend');
    for i = 1:min(8, numel(si))
        fprintf('  %-14s %.4f\n', lbl{si(i)}, sv(i));
    end
catch ME
    fprintf('  取不到（%s）—— 换 ''''NumVariablesToSample'''',''''all'''' 再试\n', ME.identifier);
end

fprintf('\n完成。\n');


%% ===================== 局部函数 =====================
% ⚠ MATLAB 要求脚本里的局部函数放在**文件末尾**。

%% peak_near —— 在 f0 附近 ±HW 个 bin 里取最大值
function p = peak_near(P, f0, df, HW)
b = round(f0 / df) + 1;
a = max(1, b - HW);  z = min(numel(P), b + HW);
p = max(P(a:z));
end

%% synth_segment —— 合成一段轴承信号
function x = synth_segment(N, fs, cls, f_r, f_res, sev, snr_db, ORDERS, jit)
% cls: 1 正常 / 2 外圈 / 3 内圈 / 4 滚珠
% ⚠ 三类故障不只是"频率不同"，**调制方式也不同** —— 这是它们能被分开的物理依据：
%     外圈：故障点固定在承载区，冲击幅度**恒定**
%     内圈：故障点随轴转、进出承载区 ⇒ 幅度被**转频 f_r** 调制
%     滚珠：故障点随保持架转         ⇒ 幅度被**保持架频率 FTF** 调制
% jit: 真实阶次 / 标称阶次，模拟"轴承型号没定"
t = (0:N-1).' / fs;

% 转频线（1X + 2X）—— 正常状态也有，是"背景"
x = 0.05 * sin(2*pi*f_r*t) + 0.02 * sin(2*pi*2*f_r*t);

if cls > 1
    if cls == 2
        fi = ORDERS(3) * jit * f_r;  mod_f = 0;              md = 0;    % 外圈，无调制
    elseif cls == 3
        fi = ORDERS(4) * jit * f_r;  mod_f = f_r;            md = 0.8;  % 内圈，转频调制
    else
        fi = ORDERS(2) * jit * f_r;  mod_f = ORDERS(1) * f_r; md = 0.8; % 滚珠，保持架调制
    end

    T_imp = 1 / fi;
    for mm = 0:floor(t(end) / T_imp)
        tm  = mm * T_imp;
        idx = t >= tm;
        tau = t(idx) - tm;
        a   = sev;
        if md > 0
            a = a * (1 + md * cos(2*pi*mod_f*tm));   % 按调制频率改这一发的幅度
        end
        x(idx) = x(idx) + a * exp(-500*tau) .* sin(2*pi*f_res*tau);
    end
end

% ⚠ 再加一点**非轴承冲击**背景（磕碰、电磁干扰）——
%   没有这一项，森林只要看见"某个阶次有峰"就能答对，任务太干净。
n_ran = poissrnd(2);
for i = 1:n_ran
    t0 = rand() * t(end);
    tau = t - t0;  tau(tau < 0) = 0;
    x = x + 0.4 * sev * exp(-800*tau) .* sin(2*pi*(2*f_res)*tau);
end

% 加噪声（按实际信号功率定）
p_noise = mean(x.^2) / 10^(snr_db/10);
x = x + sqrt(p_noise) * randn(N, 1);
end

%% avg_envelope_spectrum —— 6 步链的"多窗平均"版本
function [P, f_ax] = avg_envelope_spectrum(x, N_fft, fs, B_lo, B_hi)
% 和 ps_env_pipeline.h 的 6 步同构，只是把单帧换成**多窗平均**：
%   单帧 1024 点时 df = 38 Hz，BPFO 只有 2~3 个 bin，**根本分辨不出谐波**；
%   所以特征提取必须用长窗 + 平均。见「设计说明」第 2 条。
w = 0.5 - 0.5*cos(2*pi*(0:N_fft-1)'/(N_fft-1));    % Hann
H = zeros(N_fft, 1);                                % 解析信号掩码（单边 + 带通）
b1 = max(1, round(B_lo/(fs/N_fft)) + 1);
b2 = min(N_fft/2, round(B_hi/(fs/N_fft)) + 1);
H(b1:b2) = 2;

acc = zeros(N_fft, 1);  nw = 0;
for s = 1:(N_fft/2):(numel(x) - N_fft + 1)          % 50% 重叠
    xa  = ifft(fft(x(s:s+N_fft-1) .* w) .* H);      % 带通解析信号
    env = abs(xa);
    acc = acc + abs(fft((env - mean(env)) .* w));
    nw  = nw + 1;
end
P = acc / max(1, nw);
P = P(1:N_fft/2);
f_ax = (0:N_fft/2-1)' * (fs/N_fft);
end

%% clf_export_predict —— 纯 MATLAB 复刻"C 里要跑的推理循环"
% ⚠ 这个函数**故意写得和 C 一样笨**（逐样本、逐树、while 往下走）。
%   它要证明的不是"MATLAB 能算对"，而是"**导出的那几张数组**能算对"。
%
% ⚠⚠ fitcensemble 会把**矩阵**输入偷偷转成 table，于是：
%     T.CutPredictor 是 cellstr，分支节点是 'x3' 这种，叶子是 ''
%     T.NodeClass    是 cellstr，是类名 '2' 这种
%   按"数值数组"写会直接报错（'cell 类型的操作数不支持 ~='）。
%   下面的 clf_cut_feat / clf_node_class 两个助手把两种形态都吃下来。
function [y, n_nodes] = clf_export_predict(m, X, N_CLASS)
n_tree  = numel(m.Trained);
n_samp  = size(X,1);
votes   = zeros(n_samp, N_CLASS);
n_nodes = 0;

for t = 1:n_tree
    T = m.Trained{t};
    n_nodes = n_nodes + T.NumNodes;
    for i = 1:n_samp
        n = 1;                                   % 根节点（MATLAB 下标从 1 起）
        while true
            f = clf_cut_feat(T, n);
            if f == 0, break; end                % 0 = 叶子
            if X(i, f) <= T.CutPoint(n)
                n = T.Children(n, 1);
            else
                n = T.Children(n, 2);
            end
        end
        c = clf_node_class(T, n);
        if c < 1 || c > N_CLASS       % 宁可炸掉，也不要静默全答一类
            error('节点 %d 的类别号取到 %g，不在 1..%d', n, c, N_CLASS);
        end
        votes(i, c) = votes(i, c) + 1;
    end
end
[~, y] = max(votes, [], 2);
end

%% clf_cut_feat —— 取第 n 个节点的分支特征号；0 表示叶子
function f = clf_cut_feat(T, n)
v = T.CutPredictor;
if iscell(v)
    s = v{n};
    if isempty(s), f = 0; else, f = sscanf(s, 'x%d'); end
else
    f = v(n);                                    % 数值形态（如 TreeBagger）
end
end

%% clf_node_class —— 取第 n 个节点的类别号（1..N_CLASS）
% ⚠⚠ 实测（2026-10-04，见 probe_tree.m）：
%     T.ClassNames 是**数值** [1;2;3;4]（class=double）
%     T.NodeClass  是 **char cell**，元素是 '2' 这种（class=cell → char）
%   两边形态**不一致**，所以 strcmp(ClassNames, NodeClass{n}) 恒为空 ——
%   而空值不会报错，只会让投票循环变成空操作，最后所有样本都答"类 1"。
%   这个坑的可怕之处就在这：不报错，只是安静地全错。
function c = clf_node_class(T, n)
v = T.NodeClass;
if ~iscell(v)
    c = v(n);                                    % 数值形态（如 TreeBagger）
    return;
end
s = v{n};
if isempty(s), c = 0; return; end
cn = T.ClassNames;
if isnumeric(cn)
    i = find(cn == str2double(s), 1);            % 数值 ClassNames → 比数值
else
    i = find(strcmp(cn, s), 1);                  % cellstr ClassNames → 比字符串
end
if isempty(i)
    i = str2double(s);                           % 兜底：类名就是类别号
end
c = i;
end

%% clf_feature_labels —— 给特征取名字，便于看重要性
function lbl = clf_feature_labels(ORDERS, ORDER_NAMES, K)
lbl = {};
for o = 1:numel(ORDERS)
    for k = 1:K
        lbl{end+1} = sprintf('%s-%dX', ORDER_NAMES{o}, k); %#ok<AGROW>
    end
end
lbl{end+1} = '1X';  lbl{end+1} = '2X';
end

%% clf_write_header —— 把森林写成一个自包含的 C 头文件
function clf_write_header(m, path, N_FEAT, N_CLASS, CLASS_NAMES, ORDER_NAMES, X, Y, ti)
n_tree = numel(m.Trained);
tot = 0;
for t = 1:n_tree, tot = tot + m.Trained{t}.NumNodes; end

off    = zeros(1, n_tree + 1);
cutf   = zeros(1, tot, 'int32');
cutp   = zeros(1, tot, 'single');
left   = zeros(1, tot, 'int32');
right  = zeros(1, tot, 'int32');
nodecl = zeros(1, tot, 'int32');

p = 0;
for t = 1:n_tree
    T = m.Trained{t};
    off(t) = p;
    for n = 1:T.NumNodes
        p = p + 1;
        f = clf_cut_feat(T, n);
        cutf(p)   = f;
        cc        = clf_node_class(T, n);
        if cc < 1 || cc > N_CLASS
            error('节点 %d 的类别号取到 %g，不在 1..%d', n, cc, N_CLASS);
        end
        nodecl(p) = cc;
        if f == 0
            cutp(p)  = 0;      % 叶子：MATLAB 这里是 NaN，换成 0
            left(p)  = 0;      % 叶子：Children 是 [0 0]，直接减 1 会变负数，钳到 0
            right(p) = 0;
        else
            cutp(p)  = single(T.CutPoint(n));
            left(p)  = T.Children(n, 1) - 1 + off(t);   % 转全局下标、0 起
            right(p) = T.Children(n, 2) - 1 + off(t);
        end
    end
end
off(n_tree + 1) = p;

n_leaf = sum(cutf == 0);        % 叶子数：cut_feat == 0
n_nz   = sum(nodecl > 0);       % node_class 非零的节点数（分支节点上也有值）

fid = fopen(path, 'w');
if fid < 0, error('打不开 %s', path); end

fprintf(fid, '/* clf_model.h —— 站 12 分类器的训练产物：随机森林（MATLAB fitcensemble, Method=''Bag''）\n');
fprintf(fid, ' * 导出成 6 张数组。**这个文件是生成的，别手改** —— 改了下次导出就盖掉。\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * 生成脚本就在本仓库：sw/clf_train_export_demo.m（rng 钉死，重跑逐位可复现）\n');
fprintf(fid, ' *     cd sw && matlab -batch "set(0,''DefaultFigureVisible'',''off''); clf_train_export_demo"\n');
fprintf(fid, ' * 产出就是本文件；同目录的 clf_work.mat 是中间产物，已进 .gitignore。\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * 数组布局（推理在 ps_classifier.h 里，本文件只有数据）：\n');
fprintf(fid, ' *   clf_tree_off[t]     第 t 棵树的根在本文件里的**全局**下标；末尾多一个 = 节点总数\n');
fprintf(fid, ' *   clf_cut_feat[n]     **0 = 叶子**；非 0 = 该节点的分裂特征号（**1 起**，MATLAB 习惯）\n');
fprintf(fid, ' *   clf_cut_point[n]    分裂阈值：x[特征] <= 它 走左，否则走右\n');
fprintf(fid, ' *   clf_left[n]         左孩子的全局下标\n');
fprintf(fid, ' *   clf_right[n]        右孩子的全局下标（叶子这两个都是 0，不会被读到）\n');
fprintf(fid, ' *   clf_node_class[n]   该节点占多数的类（**1 起**）\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * ⚠⚠ **clf_node_class 在分支节点上也有值** —— 导出格式给每个节点都写了它占多数的类。\n');
fprintf(fid, ' *    所以**不能拿"node_class 非零"当叶子判据**，叶子只看 `clf_cut_feat[n] == 0`。\n');
fprintf(fid, ' *    （实测本模型：%d 个节点 = %d 个叶子 + %d 个分支；%d 个节点 node_class 非零。）\n', tot, n_leaf, tot - n_leaf, n_nz);
fprintf(fid, ' *\n');
fprintf(fid, ' * 特征顺序（18 维）：FTF 的 1..4X、BSF 的 1..4X、BPFO 的 1..4X、BPFI 的 1..4X、1X、2X。\n');
fprintf(fid, ' * ⚠ 特征必须**先归一化**：v_db = 20*log10(v / median(v))。喂原始幅度不报错，只是一直答错。\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * ⚠ 两处与本仓库口径的差异，都是**故意的**，改的时候别改回去：\n');
fprintf(fid, ' *   1. 类名改成了 ASCII "normal/outer/inner/ball"（对应 MATLAB 里的 正常/外圈/内圈/滚珠）。\n');
fprintf(fid, ' *      板子串口按 cp936 解码，xil_printf 打中文必乱码 —— 见 ps_main.c 头注。\n');
fprintf(fid, ' *   2. 没有拆成"模型 + 测试向量"两个文件，保持与导出脚本一字对应。\n');
fprintf(fid, ' *\n');
fprintf(fid, ' * ⚠ clf_test_x / clf_test_y 是自检用的（训练集样本，只验搬运没搬错），目前只有\n');
fprintf(fid, ' *   ps_clf_test.c 在用。**把它们引到一个不调用 clf_predict 的 TU 里会触发\n');
fprintf(fid, ' *   -Wunused-const-variable**（本仓库闸门开了 -Werror）。真遇到就拆文件。\n');
fprintf(fid, ' */\n');
fprintf(fid, '\n');
fprintf(fid, '#ifndef CLF_MODEL_H\n#define CLF_MODEL_H\n\n');
fprintf(fid, '#define CLF_N_TREE   %d\n', n_tree);
fprintf(fid, '#define CLF_N_FEAT   %d\n', N_FEAT);
fprintf(fid, '#define CLF_N_CLASS  %d\n', N_CLASS);
fprintf(fid, '#define CLF_N_NODE   %d\n', tot);
fprintf(fid, '#define CLF_N_TEST   %d\n\n', numel(ti));
fprintf(fid, '/* ASCII，原因见文件头。顺序 = 类别号 1..4。 */\n');
fprintf(fid, 'static const char *clf_class_names[CLF_N_CLASS] = {');
for c = 1:N_CLASS
    if c > 1, fprintf(fid, ', '); end
    fprintf(fid, '"%s"', CLASS_NAMES{c});
end
fprintf(fid, '};\n\n');

clf_emit_arr(fid, 'clf_tree_off',   off,    '%d');
clf_emit_arr(fid, 'clf_cut_feat',   cutf,   '%d');     % 1..N_FEAT，0 = 叶子
clf_emit_arr(fid, 'clf_cut_point',  cutp,   '%.9g');
clf_emit_arr(fid, 'clf_left',       left,   '%d');
clf_emit_arr(fid, 'clf_right',      right,  '%d');
clf_emit_arr(fid, 'clf_node_class', nodecl, '%d');

% 测试向量：按行展开
fprintf(fid, '/* 移植自检用（训练集样本，只验搬运没搬错）：每 %d 个数一帧 */\n', N_FEAT);
fprintf(fid, 'static const float clf_test_x[CLF_N_TEST * CLF_N_FEAT] = {\n');
for i = 1:numel(ti)
    for k = 1:N_FEAT
        if mod(k-1, 8) == 0, fprintf(fid, '    '); end
        fprintf(fid, '%.9gf, ', X(ti(i), k));
        if mod(k, 8) == 0 || k == N_FEAT, fprintf(fid, '\n'); end
    end
end
fprintf(fid, '};\n\n');
fprintf(fid, 'static const int clf_test_y[CLF_N_TEST] = {');
for i = 1:numel(ti)
    if i > 1, fprintf(fid, ', '); end
    fprintf(fid, '%d', Y(ti(i)));
end
fprintf(fid, '};\n\n');

fprintf(fid, '#endif /* CLF_MODEL_H */\n');
fclose(fid);
end

function clf_emit_arr(fid, name, vec, fmt)
n = numel(vec);
if strcmp(fmt, '%.9g')
    ctype = 'float';
else
    ctype = 'int';
end
fprintf(fid, 'static const %s %s[%d] = {\n', ctype, name, n);
for i = 1:n
    if mod(i-1, 12) == 0, fprintf(fid, '    '); end
    fprintf(fid, [fmt ', '], vec(i));
    if mod(i, 12) == 0 || i == n, fprintf(fid, '\n'); end
end
fprintf(fid, '};\n\n');
end
