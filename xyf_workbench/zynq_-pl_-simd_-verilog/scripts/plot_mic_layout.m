%% plot_mic_layout.m —— 8/16 麦圆阵载板排布图（docs/mic_array_layout.md 的配图）
%
% 数据源：scripts/golden/mic_geometry.py 的 uca_positions()
%   x_k = R*cos(2*pi*k/N),  y_k = R*sin(2*pi*k/N)   —— 从 +x 起逆时针
%   R = 50 mm（R-02 锁定，不要改；改半径要重跑全部实测）
%
% 输出：docs/mic_array_layout_8ch.png / docs/mic_array_layout_16ch.png
% 本脚本只画几何。公差、电气、连接器要求见 docs/mic_array_layout.md。
%
% ⚠ 图上的编号是**槽位号**（物理位置），不是通道号。
%    8 麦阶段 槽位 0,2,4,...,14 → DIN0..7 → 通道 0..7
%    16 麦阶段 槽位 k → DINk → 通道 k
%    两种配置的 DIN→槽位映射不同，接线前先看文档里那两张表。

set(0, 'DefaultFigureVisible', 'off');   % 后台跑，别弹窗挡住编辑器

R  = 50;                                  % mm，圆阵半径（到声孔中心）
FN = 'Microsoft YaHei';

C_BG   = [1 1 1];
C_RING = [0.80 0.80 0.78];
C_AXIS = [0.72 0.72 0.70];
C_TXT  = [0.043 0.043 0.043];             % #0b0b0b
C_SEC  = [0.322 0.318 0.306];             % #52514e
C_MUT  = [0.537 0.533 0.506];             % #898781
C1     = [0.165 0.471 0.839];             % #2a78d6  series-1
C2     = [0.922 0.408 0.204];             % #eb6834  series-2

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir), thisDir = pwd; end
outDir  = fullfile(thisDir, '..', 'docs');

for N = [8 16]
    a  = 2*pi*(0:N-1)/N;
    px = R*cos(a);   py = R*sin(a);
    d  = 2*R*sin(pi/N);                   % 相邻声孔圆心距

    fh = figure('Color', C_BG, 'Position', [80 80 840 840]);
    ax = axes('Parent', fh, 'Position', [0.05 0.05 0.90 0.86]);
    hold(ax, 'on');

    % ── 圆（半径 50 的声孔落点圆）────────────────────────────────
    th = linspace(0, 2*pi, 400);
    plot(ax, R*cos(th), R*sin(th), '-', 'Color', C_RING, 'LineWidth', 1.2);

    % ── 阵列中心 ─────────────────────────────────────────────────
    plot(ax, [-2.5 2.5], [0 0], '-', 'Color', C_MUT, 'LineWidth', 1);
    plot(ax, [0 0], [-2.5 2.5], '-', 'Color', C_MUT, 'LineWidth', 1);

    % ── 半径尺寸线（竖直向上，避开 x 轴的孔径线）─────────────────
    plot(ax, [0 0], [0 R], '-', 'Color', C_AXIS, 'LineWidth', 0.9);
    text(ax, -3.5, R/2, sprintf('R = %.2f mm', R), 'FontName', FN, ...
         'FontSize', 11, 'Color', C_SEC, 'HorizontalAlignment', 'center', ...
         'Rotation', 90, 'BackgroundColor', C_BG, 'Margin', 1);

    % ── 孔径尺寸线 ───────────────────────────────────────────────
    yD = -R - 15;
    plot(ax, [-R R], [yD yD], '-', 'Color', C_AXIS, 'LineWidth', 0.9);
    plot(ax, [-R -R], [yD-3.5 yD+3.5], '-', 'Color', C_AXIS, 'LineWidth', 0.9);
    plot(ax, [ R  R], [yD-3.5 yD+3.5], '-', 'Color', C_AXIS, 'LineWidth', 0.9);
    plot(ax, [-R -R], [-R*0.25 yD], ':', 'Color', C_AXIS, 'LineWidth', 0.7);
    plot(ax, [ R  R], [-R*0.25 yD], ':', 'Color', C_AXIS, 'LineWidth', 0.7);
    text(ax, 0, yD-4.5, sprintf('孔径 %.1f mm', 2*R), 'FontName', FN, ...
         'FontSize', 11, 'Color', C_SEC, 'HorizontalAlignment', 'center', ...
         'VerticalAlignment', 'top');

    % ── 相邻圆心距：弦 0–1（虚线，压在两点之间）──────────────────
    plot(ax, [px(1) px(2)], [py(1) py(2)], '-', 'Color', C_AXIS, 'LineWidth', 1.4);
    mx = (px(1)+px(2))/2 * 0.70;          % 往圆内推，避开点标签
    my = (py(1)+py(2))/2 * 0.70;
    text(ax, mx, my, sprintf('相邻圆心距\n%.2f mm', d), 'FontName', FN, ...
         'FontSize', 10.5, 'Color', C_SEC, 'HorizontalAlignment', 'center', ...
         'VerticalAlignment', 'middle', 'BackgroundColor', C_BG, 'Margin', 1);

    % ── 麦位置 ───────────────────────────────────────────────────
    if N == 8
        plot(ax, px, py, 'o', 'MarkerSize', 13, 'MarkerFaceColor', C1, ...
             'MarkerEdgeColor', C_BG, 'LineWidth', 2);
        t1 = '8 麦排布 —— UCA，R = 50 mm，每 45° 一个';
        t2 = '声孔中心落在圆上；0 号在 +x 轴，逆时针编号';
    else
        is8 = mod(0:N-1, 2) == 0;
        plot(ax, px(is8),  py(is8),  'o', 'MarkerSize', 12, ...
             'MarkerFaceColor', C1, 'MarkerEdgeColor', C_BG, 'LineWidth', 2);
        plot(ax, px(~is8), py(~is8), 'o', 'MarkerSize', 12, ...
             'MarkerFaceColor', C2, 'MarkerEdgeColor', C_BG, 'LineWidth', 2);
        t1 = '16 麦排布 —— UCA，R = 50 mm，每 22.5° 一个';
        t2 = '蓝点 = 8 麦阶段就装的那 8 个（槽位 0,2,…,14）';
    end

    % ── 槽位号 ───────────────────────────────────────────────────
    for k = 1:N
        text(ax, (R+11)*cos(a(k)), (R+11)*sin(a(k)), num2str(k-1), ...
             'FontName', FN, 'FontSize', 11, 'Color', C_TXT, ...
             'FontWeight', 'bold', 'HorizontalAlignment', 'center', ...
             'VerticalAlignment', 'middle');
    end

    % ── 图例（16 麦才需要：≥2 类）────────────────────────────────
    if N == 16
        h1 = plot(ax, nan, nan, 'o', 'MarkerSize', 11, ...
                  'MarkerFaceColor', C1, 'MarkerEdgeColor', C_BG, 'LineWidth', 2);
        h2 = plot(ax, nan, nan, 'o', 'MarkerSize', 11, ...
                  'MarkerFaceColor', C2, 'MarkerEdgeColor', C_BG, 'LineWidth', 2);
        lg = legend(ax, [h1 h2], ...
                    {'8 麦阶段装这 8 个（DIN0–7）', '16 麦阶段补装（DIN8–15）'}, ...
                    'FontName', FN, 'FontSize', 10.5, 'Box', 'off', ...
                    'Location', 'southoutside', 'Orientation', 'horizontal');
        lg.TextColor = C_SEC;
    end

    % ── 标题与轴 ─────────────────────────────────────────────────
    title(ax, {t1; t2}, 'FontName', FN, 'FontSize', 12.5, 'Color', C_TXT);
    daspect(ax, [1 1 1]);
    xlim(ax, [-R-28, R+28]);
    ylim(ax, [yD-16, R+16]);
    axis(ax, 'off');

    % ── 导出 ─────────────────────────────────────────────────────
    if N == 8
        fname = 'mic_array_layout_8ch.png';
    else
        fname = 'mic_array_layout_16ch.png';
    end
    full = fullfile(outDir, fname);
    exportgraphics(fh, full, 'Resolution', 180);
    fprintf('已导出 %s\n', full);
    close(fh);
end
