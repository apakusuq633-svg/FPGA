/* ps_ui_page.h —— 站 15：把一次诊断结果变成浏览器能看的一页（PS 侧，纯字符串）
 *
 * -- 为什么单独一个头 ---------------------------------------------------------------------
 *
 * 这一层是整条链上唯一"有人看"的地方，也是最容易在板上悄悄坏掉的地方：页面返回 200 但字段
 * 错位、JSON 少个逗号、路由把 /favicon.ico 当成 /api/status —— 这些都不会让板子报错，
 * 只会让人读到一个错的诊断。所以它被写成**不碰 lwip、不碰寄存器**的纯函数：
 *   - 在宿主机上按 -Wall -Wextra -Werror -Wformat=2 编得过（scripts/check_ps_apps.py）
 *   - 能被 sw/ps_ui_test.c 单独喂进几个快照，把字符串逐字查一遍
 * 网络那一层在 sw/ps_ui.c，它只负责把这里的字节搬进 TCP，不含任何判断。
 *
 * -- 字段 ---------------------------------------------------------------------------------
 *
 * 结构体**复用 ps_output.h 的 struct diag_result**，不另立一份。字段的定义只留一处，
 * 页面和串口看到的就是同一组数（本仓库的老毛病就是同一件事存两份，迟早漂）。
 *
 * 全部整数，理由与 ps_output.h 头注同一条：板上的 printf 没有 %f。所以这里没有 double，
 * 也没有 width 修饰符 —— 只保证"整数打出来是对的"，浮点显示留给浏览器。
 *
 * 运行时字符串**全 ASCII**（页面、JSON、理由短语）：串口按 cp936 解码，且 Vitis 导入会把
 * UTF-8 当 GBK 再写回去。中文只出现在注释里。
 *
 * -- 诚实条款 -----------------------------------------------------------------------------
 *
 * 页面上有 synthetic 这个字段，且**必须显示**。PS 侧现在还没有把真 PDM 波形喂进站 11 的
 * 代码（见 ps_diag.h），第一版喂进去的是程序自己造的合成帧。字段值是真的、来源是假的，
 * 页面不说清楚就等于拿自检冒充诊断。
 */
#ifndef PS_UI_PAGE_H
#define PS_UI_PAGE_H

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "ps_das_report.h"
#include "ps_mic_levels.h"
#include "ps_output.h"     /* struct diag_result、CLF_N_CLASS、clf_class_names */

/* 一次"最新结果"快照。除了 diag_result 本身，就是它有多旧、第几帧、从哪来。 */
struct ui_status {
    struct diag_result r;
    das_audio_report audio;
    mic_levels mics;
    unsigned diag_ms,input_mode,input_channels,received_blocks,pl_dropped,ps_dropped,discontinuities,computing;
    int input_error;
    int      have_result;    /* 0 = 还没跑过一帧，页面显示 waiting */
    int      synthetic;      /* 1 = 这一帧是程序自造的，不是真 PDM 波形 */
    unsigned frame;          /* 第几帧（自检从 1 开始） */
    unsigned age_ms;         /* 结果距现在多少毫秒 */
};

#define UI_BODY_MAX   61440   /* 页面与 JSON 的上限；超了报 500，不截断服务 */

/* HTTP 应答的三个组成部分。body 已经写进调用方的缓冲区，这里只报状态与长度。 */
struct ui_reply {
    int         code;
    const char *reason;
    const char *ctype;
    int         len;
};

/* 页面。字符串常量，没有文件系统 —— 板上改了要重新编，但也不会有"盘上那份和固件里那份不一样"。
 * 只画结论，不画热力图与频谱（这是本次范围）。 */
static const char UI_PAGE_HTML[] =
"<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\344\271\235\351\272\246\345\243\260\345\255\246\346\225\205\351\232\234\347\233\221\346\265\213</title><style>\n"
"*{box-sizing:border-box}body{margin:0;background:#101820;color:#e5edf4;font:14px/1.5 system-ui}main{max-width:1050px;margin:auto;padding:24px}h1{margin:0}h2{font-size:17px}.muted{color:#a0b3c2}.bar,.card{padding:18px;background:#182530;border:1px solid #304352;border-radius:10px}.bar{margin:18px 0}.layout{display:grid;grid-template-columns:1fr 1fr;gap:16px}.wide{grid-column:1/-1}table{width:100%}td{padding:7px;border-bottom:1px solid #304352}td:last-child{text-align:right}.plot{position:relative;aspect-ratio:1;max-width:300px;margin:15px auto;border:1px solid #a0b3c2;background:linear-gradient(0deg,#304352 1px,transparent 1px),linear-gradient(90deg,#304352 1px,transparent 1px)}#dot{display:none;position:absolute;width:12px;height:12px;background:#52d6c1;border-radius:50%;transform:translate(-50%,-50%)}.empty{padding:30px 8px;border:1px dashed #526674;text-align:center;color:#a0b3c2}.warn{color:#ffd17c}button{background:#304352;color:white;border:1px solid #526674;border-radius:5px;padding:8px;cursor:pointer}#err{color:#ffacac;min-height:22px}canvas{width:100%;height:auto;background:#101820;border:1px solid #304352}@media(max-width:650px){.layout{grid-template-columns:1fr}main{padding:12px}}\n"
"\n"
"/* Fixed numeric slots keep changing digit counts from shifting adjacent text. */\n"
".layout{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}.card{min-width:0;margin-bottom:16px}\n"
"table{table-layout:fixed;border-collapse:collapse;font-variant-numeric:tabular-nums}td{overflow-wrap:anywhere}td:first-child{width:48%}td:last-child{font-variant-numeric:tabular-nums}\n"
".number{display:inline-block;width:11ch;text-align:right;white-space:nowrap;font-family:Consolas,monospace;font-variant-numeric:tabular-nums}\n"
"#age,#connection{min-height:1.8em}#err{min-height:1.5em}#position{min-height:3em}#association{min-height:16em}#heatmap_note{min-height:5em}#gsc_state{min-height:6em}\n"
".table-scroll{overflow-x:auto}.data-table{min-width:720px}.data-table td,.data-table th{width:auto;text-align:right;padding:8px;white-space:nowrap;border-bottom:1px solid #304352;font-family:Consolas,monospace;font-variant-numeric:tabular-nums}\n"
".data-table th{font-family:system-ui}.data-table th:first-child,.data-table td:first-child{text-align:left;width:15%}.data-table td:last-child{white-space:normal;text-align:left;font-family:system-ui}.mic-table td:last-child{text-align:right;font-family:Consolas,monospace}\n"
".phase-controls{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.phase-controls select{padding:8px;color:#e5edf4;background:#101820;border:1px solid #304352}#phase_meta,#phase_note,#phase_legend{min-height:3em}\n"
"@media(max-width:650px){.layout{grid-template-columns:minmax(0,1fr)}}\n"
".gcc-table{min-width:1250px}.gcc-table td{white-space:pre-line!important;text-align:right!important;font-family:Consolas,monospace!important}.gcc-table td:first-child{text-align:left!important}.gcc-table td:last-child{width:12%}#gcc_panel input{width:8ch}#gcc_note,#gcc_selected{min-height:3em}\n"
"table{table-layout:fixed;border-collapse:collapse}td{overflow-wrap:anywhere;font-variant-numeric:tabular-nums}td:first-child{width:46%}\n"
"select,input{background:#101820;color:#e5edf4;padding:7px;border:1px solid #526674;max-width:100%}\n"
".alarm{color:#ff6174}.actions{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.card{margin-bottom:16px;min-width:0}\n"
"#direction_map{max-width:420px;display:block;margin:auto}pre{white-space:pre-wrap;max-height:300px;overflow:auto}\n"
"#candidates p,#health_status p{min-height:42px}canvas{max-width:100%}details{margin:12px 0}\n"
"</style></head><body><main>\n"
"<h1>\345\243\260\345\255\246\346\225\205\351\232\234\345\256\232\344\275\215\344\270\216\350\256\276\345\244\207\345\201\245\345\272\267\347\233\221\346\265\213</h1><p class=\"muted\">\344\271\235\351\272\246\346\226\271\345\220\221\345\256\232\344\275\215 \302\267 \345\244\232\345\200\231\351\200\211\345\210\206\347\246\273 \302\267 \350\257\212\346\226\255\344\270\216\344\272\213\344\273\266\347\256\241\347\220\206</p>\n"
"<div class=\"bar\"><strong id=\"state\">\350\277\236\346\216\245\344\270\255</strong><p id=\"source\"></p><p id=\"connection\">\347\255\211\345\276\205\351\246\226\346\254\241\345\223\215\345\272\224</p><button id=\"pause\">\346\232\202\345\201\234\346\230\276\347\244\272</button> <button id=\"save\">\344\277\235\345\255\230\347\263\273\347\273\237\345\277\253\347\205\247</button><p id=\"err\" role=\"status\"></p></div>\n"
"<div class=\"layout\"><section class=\"card\"><h2>\345\243\260\346\272\220\346\226\271\345\220\221\344\270\216\347\203\255\345\212\233\345\233\276</h2><label><input type=\"checkbox\" id=\"map_smooth\" checked>\347\203\255\345\233\276\346\230\276\347\244\272\345\271\263\346\273\221\357\274\210250ms\357\274\211</label> <label><input type=\"checkbox\" id=\"show_proposals\" checked>\346\230\276\347\244\272\346\234\252\347\241\256\350\256\244\345\200\231\351\200\211\344\270\216\347\225\231\347\227\225</label><p id=\"location_detail\" class=\"muted\"></p><canvas id=\"direction_map\" width=\"410\" height=\"390\"></canvas><p id=\"map_note\" class=\"muted\"></p><p class=\"muted\">\346\260\264\345\271\263\350\247\222/\344\277\257\344\273\260\350\247\222\357\274\214\346\227\240\350\267\235\347\246\273\346\211\253\346\217\217\343\200\202\347\231\275\350\211\262\344\270\272\345\200\231\351\200\211\357\274\214\347\272\242\350\211\262\344\273\205\347\224\250\344\272\216\345\267\262\351\252\214\350\257\201\346\225\205\351\232\234\346\226\271\345\220\221\343\200\202\347\202\271\345\207\273\347\275\221\346\240\274\345\217\257\347\224\263\350\257\267\345\256\232\345\220\221\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\350\257\212\346\226\255\347\273\223\346\236\234</h2><label>\346\237\245\347\234\213\350\275\250\350\277\271 <select id=\"candidate_select\"></select></label><table id=\"diagnosis\"></table><p id=\"model_note\" class=\"muted\"></p><h3>\345\267\262\345\256\214\346\210\220\350\257\212\346\226\255\347\232\204\350\275\250\350\277\271\357\274\210\345\277\253\347\205\247\346\226\271\345\220\221\357\274\211</h3><div id=\"candidates\"></div><h3>\345\256\236\346\227\266\346\226\271\345\220\221\346\217\220\350\256\256\357\274\210\345\260\232\351\235\236\346\225\205\351\232\234\347\273\223\350\256\272\357\274\211</h3><p id=\"proposal_note\" class=\"muted\"></p><div id=\"live_proposals\"></div></section>\n"
"<section class=\"card\"><h2>\351\200\211\344\270\255\350\275\250\350\277\271\347\232\204\345\210\206\347\246\273\351\237\263\351\242\221\351\242\221\350\260\261</h2><canvas id=\"spectrum_plot\" width=\"560\" height=\"250\"></canvas><p id=\"spectrum_note\" class=\"muted\">\347\255\211\345\276\205\345\200\231\351\200\211\351\237\263\351\242\221\357\274\233\344\270\215\350\246\201\346\261\202\346\250\241\345\236\213\345\267\262\351\252\214\350\257\201\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\345\220\214\345\277\253\347\205\247\345\214\205\347\273\234\350\260\261</h2><canvas id=\"envelope_plot\" width=\"560\" height=\"250\"></canvas><p id=\"envelope_note\" class=\"muted\">Hz\345\214\205\347\273\234\344\270\215\344\276\235\350\265\226\350\275\254\351\200\237\357\274\233\351\230\266\346\254\241\344\270\216\345\210\206\347\261\273\344\273\215\351\234\200\346\234\211\346\225\210\350\275\254\351\200\237\343\200\202</p><p class=\"muted\">C9F2\350\275\275\351\242\2212200\342\200\2234600Hz\357\274\233\345\214\205\347\273\234\346\250\252\350\275\264\344\270\272\350\260\203\345\210\266\351\242\221\347\216\207\343\200\2021.024\347\247\222\350\247\202\345\257\237\357\274\214\350\241\245\351\233\266\344\270\215\346\217\220\351\253\230\347\234\237\345\256\236\345\210\206\350\276\250\347\216\207\343\200\202</p></section></div>\n"
"<section class=\"card\"><button id=\"preview\">\350\216\267\345\217\226\345\220\214\345\277\253\347\205\247\346\263\242\345\275\242</button> <label><input id=\"auto_preview\" type=\"checkbox\" checked>\350\207\252\345\212\250\346\233\264\346\226\260\350\257\212\346\226\255\345\217\214\350\260\261\357\274\210\346\226\260\345\277\253\347\205\247\346\234\200\345\277\253\346\257\2171\347\247\222\357\274\211</label><p id=\"plot_note\" class=\"muted\">\346\234\211\346\226\260\345\277\253\347\205\247\346\227\266\346\234\200\345\277\253\346\257\2171\347\247\222\350\257\273\345\217\226\344\270\200\346\254\241\345\220\214\345\277\253\347\205\247\351\237\263\351\242\221\357\274\233\346\227\240\346\226\260\347\273\223\346\236\234\344\270\215\351\207\215\345\244\215\350\257\273\345\217\226\357\274\214\345\217\257\345\205\263\351\227\255\350\207\252\345\212\250\346\233\264\346\226\260\343\200\202\345\216\206\345\217\262\346\233\262\347\272\277\346\230\216\347\241\256\346\240\207\350\256\260\345\277\253\347\205\247\345\217\267\357\274\233\346\234\252\350\256\241\347\256\227\347\232\204\345\214\205\347\273\234\350\257\264\346\230\216\345\216\237\345\233\240\343\200\202</p><details><summary>18\347\273\264\350\257\212\346\226\255\347\211\271\345\276\201</summary><table id=\"features\"></table></details></section>\n"
"<div class=\"layout\"><section class=\"card\"><h2>\351\237\263\351\242\221\347\224\265\345\271\263\344\270\216\350\275\275\351\242\221\346\214\207\346\240\207</h2><table id=\"levels\"></table></section><section class=\"card\"><h2>\347\263\273\347\273\237\350\277\220\350\241\214\347\212\266\346\200\201</h2><table id=\"runtime\"></table></section></div>\n"
"<section class=\"card\"><h2>\344\271\235\350\267\257\351\272\246\345\205\213\351\243\216\350\276\223\345\205\245</h2><div class=\"table-scroll\"><table class=\"data-table mic-table\"><thead><tr><th>\351\200\232\351\201\223 / DIN</th><th>RMS (%FS)</th><th>\345\263\260\345\200\274 (%FS)</th><th>\345\235\207\345\200\274 (%FS)</th><th>\345\211\212\351\241\266</th></tr></thead><tbody id=\"mics\"></tbody></table></div><p class=\"muted\">\347\213\254\347\253\213\345\256\232\344\275\215\345\277\253\347\205\247\347\224\265\345\271\263\357\274\233\351\200\232\351\201\223\346\230\240\345\260\204\343\200\201\345\271\205\347\233\270\345\217\212\345\256\236\347\211\251\345\207\240\344\275\225\344\273\215\351\241\273\351\252\214\346\224\266\357\274\214\344\270\215\345\260\206PDM\346\264\273\345\212\250\345\275\223\344\275\234\347\213\254\347\253\213\351\272\246\345\205\213\351\243\216\351\252\214\350\257\201\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\345\217\214\351\272\246\345\220\214\345\270\247PCM\344\270\216GCC\350\260\203\350\257\225</h2><select id=\"pair_a\"></select> / <select id=\"pair_b\"></select> <button id=\"pair_capture\">\346\212\223\345\217\226\344\270\200\345\270\247</button> <button id=\"pair_save\">\345\257\274\345\207\272PCM\344\270\216GCC</button><button id=\"pair_run\">&#36830;&#32493;&#37319;&#38598;10&#24103;</button> <button id=\"raw_download\">&#19979;&#36733;&#20061;&#36335;&#21516;&#27493;&#24555;&#29031;</button><canvas id=\"pair_plot\" width=\"1000\" height=\"300\"></canvas><table id=\"pair_result\"></table><p id=\"pair_note\" class=\"muted\">\350\257\273\350\277\236\347\273\255\345\216\237\345\247\213\345\216\206\345\217\262\357\274\214\344\270\215\346\232\202\345\201\234PL\357\274\233\345\216\237\345\247\213PCM\346\227\266\351\227\264\350\275\264\344\277\235\347\225\231\346\227\266\345\273\266\343\200\202\346\255\243\345\263\260\343\200\201\350\264\237\350\260\267\343\200\201\347\273\235\345\257\271\345\263\260\345\217\252\347\224\250\344\272\216\350\260\203\350\257\225\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\345\216\237\345\247\213\350\276\223\345\205\245\350\247\202\345\257\237 \302\267 \344\270\215\344\276\235\350\265\226\350\257\212\346\226\255\345\277\253\347\205\247</h2><div class=\"actions\"><label>\350\276\223\345\205\245\351\200\232\351\201\223 <select id=\"raw_channel\"></select></label><button id=\"raw_capture\">\350\257\273\345\217\226\344\271\235\350\267\257\345\220\214\346\255\245PCM</button><button id=\"raw_save\">\345\257\274\345\207\272\345\216\237\345\247\213PCM\344\270\216\345\205\250\351\203\250GCC</button></div><p id=\"raw_meta\" class=\"muted\">\346\211\213\345\212\250\350\257\273\345\217\226\347\216\260\346\234\211\345\216\206\345\217\262\357\274\214\344\270\215\346\232\202\345\201\234PL\357\274\233\350\277\231\351\207\214\344\270\215\346\230\257DAS\343\200\201GSC\346\210\226\346\225\205\351\232\234\350\257\212\346\226\255\350\276\223\345\207\272\343\200\202</p><canvas id=\"raw_spectrum\" width=\"1000\" height=\"260\"></canvas><p id=\"raw_spectrum_note\" class=\"muted\"></p><h3>\345\220\214DIN\345\233\233\347\273\204\347\233\270\344\275\215\345\257\271\347\205\247</h3><div class=\"table-scroll\"><table class=\"data-table\"><thead><tr><th>\351\200\232\351\201\223\345\257\271</th><th>AC\347\233\270\345\205\263\347\263\273\346\225\260</th><th>A AC RMS (LSB)</th><th>B AC RMS (LSB)</th><th>\350\257\264\346\230\216</th></tr></thead><tbody id=\"phase_groups\"></tbody></table></div><h3>\345\205\250\351\203\25036\345\257\271GCC \302\267 \346\255\243\345\263\260 / \350\264\237\350\260\267 / \347\273\235\345\257\271\345\263\260</h3><p>\346\255\243\346\227\266\345\273\266\350\241\250\347\244\272B\346\231\232\344\272\216A\343\200\202\347\211\251\347\220\206\344\270\212\351\231\220\346\214\211\344\270\211\347\273\264\345\235\220\346\240\207\350\267\235\347\246\273\345\217\212343m/s\350\256\241\347\256\227\357\274\233\346\236\201\345\200\274\344\270\215\350\207\252\345\212\250\347\255\211\344\272\216\346\234\211\346\225\210\345\243\260\345\255\246\346\227\266\345\273\266\343\200\202</p><div class=\"table-scroll\"><table class=\"data-table gcc-table\"><thead><tr><th>A / B</th><th>\350\267\235\347\246\273/\346\234\200\345\244\247\346\227\266\345\273\266</th><th>\346\255\243\345\263\260</th><th>\350\264\237\350\260\267</th><th>\347\273\235\345\257\271\345\263\260</th></tr></thead><tbody id=\"all_gcc\"></tbody></table></div><details><summary>\345\267\262\347\237\245\345\243\260\346\272\220\345\235\220\346\240\207\347\232\204\344\270\211\347\273\264\347\220\206\350\256\272\346\227\266\345\273\266\345\257\271\347\205\247\357\274\210\345\217\257\351\200\211\357\274\211</summary><label>X(mm) <input id=\"source_x\" type=\"number\"></label><label>Y(mm) <input id=\"source_y\" type=\"number\"></label><label>Z(mm) <input id=\"source_z\" type=\"number\"></label><button id=\"expected_delay\">\350\256\241\347\256\227\347\220\206\350\256\272\346\227\266\345\273\266</button><pre id=\"expected_result\"></pre><p>\345\235\220\346\240\207\347\263\273\344\270\216\345\275\223\345\211\215\345\234\206\347\216\257\345\207\240\344\275\225\344\270\200\350\207\264\357\274\214\346\234\252\345\241\253\345\206\231\344\270\215\345\201\207\345\256\232\345\243\260\346\272\220\344\275\215\347\275\256\357\274\233\344\273\205\344\276\233\350\260\203\350\257\225\357\274\214\344\270\215\346\216\247\345\210\266\345\256\232\344\275\215\343\200\202</p></details><label>\346\237\245\347\234\213GCC\346\233\262\347\272\277 <select id=\"gcc_select\"></select></label><canvas id=\"gcc_curve\" width=\"1000\" height=\"260\"></canvas></section>\n"
"<section class=\"card\"><h2>\350\256\276\345\244\207\345\201\245\345\272\267\347\233\221\346\265\213</h2><button id=\"health_toggle\">\345\220\257\347\224\250/\345\205\263\351\227\255\347\233\221\346\265\213</button><p id=\"health_note\"></p><p id=\"storage_note\" class=\"muted\"></p><details><summary>\351\242\204\350\255\246\345\217\202\346\225\260\357\274\210\346\234\211\346\225\210\350\257\212\346\226\255\346\254\241\346\225\260\357\274\211</summary><label>\347\226\221\344\274\274 <input id=\"threshold_suspect\" type=\"number\" min=\"1\" max=\"10000\" value=\"3\"></label> <label>\346\212\245\350\255\246 <input id=\"threshold_alarm\" type=\"number\" min=\"1\" max=\"10000\" value=\"5\"></label> <label>\346\201\242\345\244\215 <input id=\"threshold_recover\" type=\"number\" min=\"1\" max=\"10000\" value=\"10\"></label> <button id=\"threshold_apply\">\345\272\224\347\224\250\345\217\202\346\225\260</button><p>\346\234\252\347\237\245\343\200\201\346\227\240\346\225\210\345\217\212\346\226\255\346\265\201\344\270\215\344\274\232\344\275\234\344\270\272\346\201\242\345\244\215\357\274\233\344\277\256\346\224\271\345\217\202\346\225\260\344\274\232\346\270\205\347\251\272\350\277\236\347\273\255\350\256\241\346\225\260\357\274\214\344\277\235\347\225\231\344\272\213\344\273\266\344\270\216\346\212\245\350\255\246\343\200\202</p></details><div id=\"health_status\"></div><label>\345\216\206\345\217\262\350\214\203\345\233\264 <select id=\"history_range\"><option value=\"60\">\346\234\200\350\277\2211\345\210\206\351\222\237</option><option value=\"300\" selected>\346\234\200\350\277\2215\345\210\206\351\222\237</option><option value=\"900\">\346\234\200\350\277\22115\345\210\206\351\222\237</option><option value=\"1800\">\346\234\200\350\277\22130\345\210\206\351\222\237</option><option value=\"3600\">\346\234\200\350\277\2211\345\260\217\346\227\266</option></select></label><canvas id=\"history_plot\" width=\"1000\" height=\"240\"></canvas><p id=\"history_note\" class=\"muted\"></p><p class=\"muted\">RMS\344\270\272\347\234\237\345\256\236\345\210\206\347\246\273\351\237\263\351\242\221\345\200\274\357\274\214\344\270\215\346\230\257\345\201\245\345\272\267\345\272\246\343\200\202\346\235\277\345\206\205\346\227\245\345\277\227\345\256\271\351\207\217\345\233\272\345\256\232\357\274\233\350\267\250\351\207\215\345\220\257\345\216\206\345\217\262\351\234\200\350\277\220\350\241\214PC\345\275\222\346\241\243\346\234\215\345\212\241\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\346\225\205\351\232\234\344\270\216\345\274\202\345\270\270\344\272\213\344\273\266</h2><button id=\"export\">\345\257\274\345\207\272\345\275\223\345\211\215\345\216\206\345\217\262\344\270\216\344\272\213\344\273\266</button><table><thead><tr><th>ID</th><th>\350\275\250\350\277\271</th><th>\347\212\266\346\200\201</th><th>\347\261\273\345\210\253</th><th>\347\224\237\345\221\275\345\221\250\346\234\237</th><th>\351\246\226\346\254\241\346\227\266\351\227\264</th><th>\350\257\246\346\203\205</th></tr></thead><tbody id=\"events\"></tbody></table><pre id=\"event_detail\"></pre><p class=\"muted\">\350\275\250\350\277\271ID\345\217\252\350\241\250\347\244\272\345\243\260\345\255\246\346\226\271\345\220\221\350\267\237\350\270\252\357\274\214\344\270\215\346\230\257\346\234\272\345\231\250\350\272\253\344\273\275\343\200\202\345\274\202\345\270\270\347\261\273\345\210\253\344\270\215\350\207\252\345\212\250\347\255\211\345\220\214\346\234\272\346\242\260\346\225\205\351\232\234\357\274\233\346\234\252\347\237\245\346\210\226\346\226\255\346\265\201\344\270\215\344\274\232\350\247\243\351\231\244\346\212\245\350\255\246\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\346\213\276\351\237\263\344\270\216\345\256\236\351\231\205\350\275\254\351\200\237</h2><div class=\"actions\"><button data-control=\"/api/recording/on\">\345\274\200\345\220\257UDP\350\277\236\347\273\255\345\275\225\351\237\263</button><button data-control=\"/api/recording/off\">\345\205\263\351\227\255UDP\350\277\236\347\273\255\345\275\225\351\237\263</button></div><p class=\"muted\">\351\273\230\350\256\244\345\217\252\345\201\232\345\256\236\346\227\266\347\233\221\346\265\213\357\274\214\351\201\277\345\205\215\346\227\240\344\272\272\346\216\245\346\224\266\347\232\204\350\277\236\347\273\255\345\275\225\351\237\263\345\215\240\347\224\250\351\207\207\351\233\206\351\242\204\347\256\227\343\200\202\344\271\235\350\267\257\345\277\253\347\205\247\344\270\213\350\275\275\344\273\215\345\217\257\344\275\277\347\224\250\357\274\233\350\277\236\347\273\255\345\275\225\351\237\263\345\274\200\345\220\257\345\220\216\347\232\204\345\256\236\346\227\266\350\264\237\350\275\275\351\234\200\345\215\225\347\213\254\351\252\214\346\224\266\343\200\202</p><div class=\"actions\"><button data-control=\"/api/gsc/on\">\345\220\257\347\224\250GSC</button><button data-control=\"/api/gsc/off\">DAS\346\227\201\350\267\257</button><button data-control=\"/api/gsc/freeze\">\345\206\273\347\273\223\350\207\252\351\200\202\345\272\224</button><button data-control=\"/api/gsc/adapt\">\347\273\247\347\273\255\350\207\252\351\200\202\345\272\224</button><button data-control=\"/api/target/auto\">\350\267\237\350\270\252\346\234\200\345\274\272\345\263\260</button><button data-control=\"/api/target/fault\">\350\267\237\350\270\252\345\267\262\350\257\212\346\226\255\346\225\205\351\232\234</button></div><label>\345\267\262\347\237\245\345\256\236\351\231\205\350\275\254\351\200\237rpm <input id=\"rpm\" type=\"number\" min=\"600\" max=\"1800\" value=\"1500\"></label> <button id=\"rpm_set\">\347\241\256\350\256\244\345\256\236\351\231\205\350\275\254\351\200\237</button><p id=\"action_note\"></p><p class=\"muted\">\351\273\230\350\256\244\345\200\274\346\234\252\350\242\253\345\275\223\344\275\234\345\256\236\346\265\213\350\275\254\351\200\237\357\274\214\351\234\200\344\272\272\345\267\245\347\241\256\350\256\244\343\200\202\345\207\240\344\275\225/\346\240\207\345\256\232/\346\250\241\345\236\213\351\227\250\346\216\247\344\277\235\346\214\201\345\216\237\346\234\211\350\247\204\345\210\231\343\200\202</p></section>\n"
"<section class=\"card\"><h2>\350\267\250\351\207\215\345\220\257\345\216\206\345\217\262\345\275\222\346\241\243</h2><button id=\"archive_load\">\346\237\245\347\234\213PC\345\275\222\346\241\243</button><p id=\"archive_note\" class=\"muted\">\345\217\257\351\200\211SQLite\346\234\215\345\212\241\357\274\232127.0.0.1:8769\357\274\233\344\270\215\345\220\257\347\224\250\346\227\266\344\273\215\346\234\211\346\235\277\345\206\205\347\233\221\346\265\213\343\200\202</p><table id=\"archive_records\"></table><div id=\"archive_events\"></div></section>\n"
"<section class=\"card\"><h2>\345\256\232\344\275\215\345\273\266\350\277\237\344\270\216GSC\350\277\220\350\241\214\346\214\207\346\240\207</h2><table id=\"performance\"></table></section>\n"
"<script>\n"
"function gccFft(re,im,inverse){\n"
" var n=re.length;for(var i=1,j=0;i<n;i++){var bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){var t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}\n"
" for(var len=2;len<=n;len*=2){var angle=(inverse?2:-2)*Math.PI/len,wr=Math.cos(angle),wi=Math.sin(angle);\n"
"  for(var start=0;start<n;start+=len){var ur=1,ui=0;for(j=0;j<len/2;j++){var a=start+j,b=a+len/2,vr=re[b]*ur-im[b]*ui,vi=re[b]*ui+im[b]*ur;re[b]=re[a]-vr;im[b]=im[a]-vi;re[a]+=vr;im[a]+=vi;var next=ur*wr-ui*wi;ui=ur*wi+ui*wr;ur=next;}}}\n"
" if(inverse)for(i=0;i<n;i++){re[i]/=n;im[i]/=n;}\n"
"}\n"
"function gccPeak(curve,limit,mode,fs){\n"
" var lag=0,best=-Infinity;for(var k=-limit;k<=limit;k++){var v=curve[k+64],score=mode==='negative'?-v:mode==='absolute'?Math.abs(v):v;if(score>best){best=score;lag=k;}}\n"
" var center=curve[lag+64];if((mode==='positive'&&center<=0)||(mode==='negative'&&center>=0)||Math.abs(center)<1e-12)return null;\n"
" var polarity=mode==='negative'?-1:mode==='absolute'?(center<0?-1:1):1;\n"
" var local=polarity*center>=polarity*curve[lag+63]&&polarity*center>=polarity*curve[lag+65]&&\n"
"  (polarity*center>polarity*curve[lag+63]||polarity*center>polarity*curve[lag+65]);\n"
" var delta=0,edge=Math.abs(lag)===limit,refined=false;\n"
" if(!edge){var sign=mode==='negative'?-1:mode==='absolute'?(center<0?-1:1):1,l=sign*curve[lag+63],m=sign*center,r=sign*curve[lag+65],den=l-2*m+r;\n"
"  if(den<-1e-15){delta=Math.max(-.5,Math.min(.5,.5*(l-r)/den));refined=true;}}\n"
" return {integer_samples:lag,samples:lag+delta,microseconds:(lag+delta)*1e6/fs,value:center,sign:center<0?-1:1,boundary:edge,interpolated:refined,local_extremum:local};\n"
"}\n"
"function gccAnalyze(samples,fs,positions){\n"
" var n=2048,frames=samples[0].length,cache=[],records=[];\n"
" samples.forEach(function(x){var re=new Float64Array(n),im=new Float64Array(n),mean=0;for(var i=0;i<frames;i++)mean+=x[i]/frames;\n"
"  for(i=0;i<frames;i++)re[i]=(x[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(frames-1)));gccFft(re,im,false);cache.push({re:re,im:im});});\n"
" for(var a=0;a<samples.length;a++)for(var b=a+1;b<samples.length;b++){\n"
"  var re=new Float64Array(n),im=new Float64Array(n),mag=new Float64Array(n),max=0;\n"
"  // B*conj(A): positive lag means B arrives later than A.\n"
"  for(var k=0;k<n;k++){var f=Math.min(k,n-k)*fs/n;if(f<200||f>8000)continue;\n"
"   re[k]=cache[b].re[k]*cache[a].re[k]+cache[b].im[k]*cache[a].im[k];im[k]=cache[b].im[k]*cache[a].re[k]-cache[b].re[k]*cache[a].im[k];mag[k]=Math.hypot(re[k],im[k]);max=Math.max(max,mag[k]);}\n"
"  var bins=0;for(k=0;k<n;k++){if(mag[k]>Math.max(max*1e-9,1e-12)){re[k]/=mag[k];im[k]/=mag[k];bins++;}else{re[k]=0;im[k]=0;}}\n"
"  gccFft(re,im,true);var curve=[];for(k=-64;k<=64;k++)curve.push(re[(k+n)%n]);\n"
"  var distance=Math.hypot(positions[b][0]-positions[a][0],positions[b][1]-positions[a][1],positions[b][2]-positions[a][2]);\n"
"  var physical=distance*fs/343,limit=Math.min(63,Math.ceil(physical)),valid=bins>0;\n"
"  var r={a:a,b:b,same_din:Math.floor(a/2)===Math.floor(b/2),distance_mm:distance*1000,max_physical_samples:physical,limit:limit,bins:bins,curve:curve,\n"
"   positive:valid?gccPeak(curve,limit,'positive',fs):null,negative:valid?gccPeak(curve,limit,'negative',fs):null,absolute:valid?gccPeak(curve,limit,'absolute',fs):null};\n"
"  ['positive','negative','absolute'].forEach(function(name){var p=r[name];if(p){p.outside_physical=Math.abs(p.samples)>physical+1e-9;p.rejection_reasons=[];if(p.boundary)p.rejection_reasons.push('\346\220\234\347\264\242\350\276\271\347\225\214');if(p.outside_physical)p.rejection_reasons.push('\350\266\205\345\207\240\344\275\225\347\225\214\351\231\220');if(!p.local_extremum)p.rejection_reasons.push('\351\235\236\345\261\200\351\203\250\346\236\201\345\200\274');p.candidate_usable=p.rejection_reasons.length===0;}});records.push(r);\n"
" }return records;\n"
"}\n"
"function gccEstimateText(p){if(!p)return '\346\227\240\346\234\211\346\225\210\345\263\260';return (p.candidate_usable?'\345\200\231\351\200\211 '+p.samples.toFixed(3)+' \347\202\271 / '+p.microseconds.toFixed(2)+' us':'\346\227\240\346\234\211\346\225\210\346\227\266\345\273\266\345\200\231\351\200\211\\n\350\257\212\346\226\255\346\236\201\345\200\274 '+p.samples.toFixed(3)+' \347\202\271')+'\\n\345\200\274 '+p.value.toFixed(5)+(p.rejection_reasons.length?' ['+p.rejection_reasons.join(' / ')+']':'\\n\345\260\232\346\234\252\351\252\214\350\257\201\344\270\272\345\243\260\345\255\246\346\227\266\345\273\266');}\n"
"\n"
"var c9ChannelPositions=[[0,-0.0255,0],[-0.01626345596729059,-0.01626345596729059,0],[-0.022,0,0],[-0.01626345596729059,0.01626345596729059,0],[0.01626345596729059,-0.01626345596729059,0],[0.022,0,0],[0.01626345596729059,0.01626345596729059,0],[0,0.0255,0],[0,0,0]];\n"
"'use strict';\n"
"// Browser-only display/analysis. No classifier, feature extractor or PL control\n"
"// algorithm is replaced by this file. All inputs carry snapshot/track identity.\n"
"var latest=null, paused=false, c9busy=false, c9state=null, c9health=null;\n"
"var guiDisplayedPlot=null,guiPlotBusy=false,guiSpectrumView=null;\n"
"var GUI_SPECTRUM_MAX_HZ=8000;\n"
"var guiSequence=0,guiTrack=0,guiSession=null,guiHistory=[],guiEvents=new Map(),guiTrails=new Map();\n"
"var guiHealthCursor=0,guiEventCursor=0,guiPreviewToken=0,guiLastCandidate=0,guiLastHealth=0;\n"
"const $=id=>document.getElementById(id);\n"
"const labels=['\346\234\252\347\237\245','\346\255\243\345\270\270','\346\225\205\351\232\234','\345\271\262\346\211\260','\345\274\202\345\270\270\357\274\210\346\234\252\347\241\256\350\256\244\346\225\205\351\232\234\357\274\211'];\n"
"const states=['\346\255\243\345\270\270\347\233\221\346\265\213','\347\226\221\344\274\274\345\274\202\345\270\270','\346\225\205\351\232\234/\345\274\202\345\270\270\346\212\245\350\255\246','\346\201\242\345\244\215\350\247\202\345\257\237'];\n"
"const reasonNames={ok:'\346\234\211\346\225\210',no_model:'\345\260\232\346\234\252\351\205\215\347\275\256\346\250\241\345\236\213',bad_model:'\346\250\241\345\236\213\345\245\221\347\272\246\344\270\215\345\214\271\351\205\215',bad_input:'\350\275\254\351\200\237\346\210\226\350\276\223\345\205\245\346\227\240\346\225\210',bad_binding:'\346\226\271\345\220\221/\345\210\206\347\246\273\345\205\263\350\201\224\346\235\241\344\273\266\344\270\215\350\266\263',silent:'\344\275\216\347\224\265\345\271\263',rejected:'\346\250\241\345\236\213\346\213\222\350\257\206',unvalidated:'\346\250\241\345\236\213\346\234\252\347\273\217\351\252\214\350\257\201',clipped:'\350\276\223\345\205\245\345\211\212\351\241\266',unseen_separation_filter:'\345\210\206\347\246\273\351\242\221\345\270\246\346\234\252\350\216\267\346\250\241\345\236\213\351\252\214\350\257\201',no_carrier:'\345\205\261\346\214\257\345\270\246\350\203\275\351\207\217\344\270\215\350\266\263'};\n"
"function text(id,v){if($(id))$(id).textContent=v;}\n"
"function line(table,k,v){let r=document.createElement('tr');[k,v].forEach(s=>{let c=document.createElement('td');c.textContent=s;r.appendChild(c);});table.appendChild(r);}\n"
"function rows(id,data){$(id).textContent='';data.forEach(r=>line($(id),r[0],r[1]));}\n"
"function num(x,d=2){return Number.isFinite(x)?x.toFixed(d):'\346\234\252\346\217\220\344\276\233';}\n"
"function angle(x){return Number.isFinite(x)?num(x/1000)+'\302\260':'\346\234\252\347\237\245';}\n"
"function download(name,data,type='application/json'){let u=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);}\n"
"async function get(path,binary=false){let controller=new AbortController(),timer=setTimeout(()=>controller.abort(),2500);try{let r=await fetch(path,{cache:'no-store',signal:controller.signal});if(r.status===202)return null;if(!r.ok){let e=Error(path+'\357\274\232HTTP '+r.status);e.status=r.status;throw e;}return binary?await r.arrayBuffer():await r.json();}finally{clearTimeout(timer);}}\n"
"async function control(path){try{await get(path);text('action_note','\350\256\276\347\275\256\345\267\262\346\217\220\344\272\244\357\274\214\346\230\257\345\220\246\347\224\237\346\225\210\344\273\245\345\220\216\345\217\260\347\212\266\346\200\201\344\270\272\345\207\206\343\200\202');}catch(e){text('action_note',String(e));}}\n"
"function validFault(c,s){return !!(c.diagnosis&&c.diagnosis.fault_direction_valid&&!c.stale&&c.stable&&c.separation_ready&&s.geometry_confirmed&&s.calibration_version&&s.model_validated&&c.diagnosis.binding.track_id===c.track_id&&c.diagnosis.model_version===s.model_version);}\n"
"function plot(id,values,xmax,xlabel,ylabel='\347\233\270\345\257\271\345\271\205\345\200\274\357\274\210\345\263\260\345\200\274=1\357\274\211',signed=false,emptyMessage='\347\255\211\345\276\205\346\234\211\346\225\210\345\277\253\347\205\247',xmin=0,xvalues=null){\n"
" let c=$(id),g=c.getContext('2d'),L=62,R=c.width-18,T=25,B=c.height-42;g.clearRect(0,0,c.width,c.height);g.font='13px system-ui';g.fillStyle='#a0b3c2';g.fillText(ylabel,L,16);\n"
" g.strokeStyle='#304352';g.lineWidth=1;\n"
" for(let k=0;k<=4;k++){let y=T+(B-T)*k/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText((signed?1-k/2:1-k/4).toFixed(2),8,y+4);let x=L+(R-L)*k/4;g.beginPath();g.moveTo(x,T);g.lineTo(x,B);g.stroke();g.fillText(num(xmin+(xmax-xmin)*k/4,xmax<10?2:0),x-12,B+19);}\n"
" g.fillText(xlabel,(L+R)/2-35,c.height-4);\n"
" if(!values||!values.length){g.fillText(emptyMessage,L+20,T+50);return;}\n"
" g.strokeStyle='#52d6c1';g.beginPath();let drawing=false;values.forEach((v,i)=>{let fraction=xvalues?(xvalues[i]-xmin)/(xmax-xmin):i/(values.length-1);if(!Number.isFinite(v)||fraction<0||fraction>1){drawing=false;return;}let x=L+fraction*(R-L),y=signed?(T+B)/2-v*(B-T)/2:B-v*(B-T);if(drawing)g.lineTo(x,y);else g.moveTo(x,y);drawing=true;});g.stroke();\n"
"}\n"
"function renderStatus(s){latest=s;text('source','9\351\272\246\345\220\214\346\255\245PDM \342\206\222 PL\346\226\271\345\220\221\345\256\232\344\275\215 \342\206\222 PS\345\244\232\345\200\231\351\200\211\345\210\206\347\246\273\344\270\216\350\257\212\346\226\255');\n"
" text('state',s.input_error?'\351\207\207\351\233\206\351\224\231\350\257\257 '+s.input_error:'\346\214\201\347\273\255\351\207\207\351\233\206\344\270\255\357\274\233\345\210\206\347\261\273\346\234\211\346\225\210\346\200\247\350\247\201\345\200\231\351\200\211\344\270\216\347\233\221\346\265\213\347\212\266\346\200\201');\n"
" rows('runtime',[['\346\227\247\345\215\225\350\267\257\351\237\263\351\242\221\345\235\227\357\274\210\344\271\235\351\272\246\344\270\215\344\275\277\347\224\250\357\274\211',s.received_blocks],['PL\344\270\242\345\244\261\351\207\207\346\240\267\347\202\271',s.pl_dropped],['PS\344\270\242\345\244\261\351\207\207\346\240\267\347\202\271',s.ps_dropped],['CPU1\345\277\231',s.computing],['\350\257\212\346\226\255\350\247\202\345\257\237\347\252\227','1024 ms\357\274\233\346\233\264\346\226\260\351\227\264\351\232\224512 ms'],['\351\207\207\346\240\267\347\216\207','156250 Hz\345\216\237\345\247\213 / 39062.5 Hz\350\257\212\346\226\255']]);\n"
" $('mics').textContent='';for(let i=0;i<9;i++)line($('mics'),'CH'+i,s.mic_valid?'RMS '+num((s.mic_rms_ppm||[])[i]/10000,4)+' %FS\357\274\233\345\263\260\345\200\274 '+num((s.mic_peak_ppm||[])[i]/10000,4)+' %FS\357\274\233\345\235\207\345\200\274 '+num((s.mic_mean_ppm||[])[i]/10000,4)+' %FS\357\274\233\345\211\212\351\241\266 '+((s.mic_clipped||[])[i]?\?'\346\234\252\346\217\220\344\276\233'):'\347\255\211\345\276\205\351\200\232\351\201\223\345\277\253\347\205\247');\n"
"}\n"
"function renderCandidates(s){c9state=s;guiLastCandidate=Date.now();\n"
" const chosen=Number($('candidate_select').value)||guiTrack;\n"
" $('candidate_select').textContent='';$('candidates').textContent='';\n"
" (s.candidates||[]).forEach((c,i)=>{let o=document.createElement('option');o.value=c.track_id;o.textContent='\350\275\250\350\277\271 '+c.track_id+' / '+angle(c.azimuth_mdeg);$('candidate_select').appendChild(o);\n"
"  let d=c.diagnosis||{},p=document.createElement('p');p.className=validFault(c,s)?'alarm':'muted';p.textContent='\350\275\250\350\277\271 '+c.track_id+'\357\274\232\346\260\264\345\271\263\350\247\222 '+angle(c.azimuth_mdeg)+'\357\274\214\344\277\257\344\273\260\350\247\222 '+angle(c.elevation_mdeg)+'\357\274\233'+(c.stale?'\345\267\262\350\277\207\346\234\237':c.stable?'\347\250\263\345\256\232':'\345\276\205\347\250\263\345\256\232')+'\357\274\233'+(d.label||'unknown')+'\357\274\233'+(reasonNames[d.reason]||d.reason||'\347\255\211\345\276\205\350\257\212\346\226\255');let b=document.createElement('button');b.textContent='\346\213\276\345\217\226\346\255\244\346\226\271\345\220\221';b.disabled=!!c.stale;b.onclick=()=>control('/api/target?grid='+c.grid);p.appendChild(b);$('candidates').appendChild(p);\n"
" });\n"
" if((s.candidates||[]).length)$('candidate_select').value=(s.candidates.some(c=>c.track_id===chosen)?chosen:s.candidates[0].track_id);\n"
" text('model_note',(s.fstf_experiment_enabled?'FSTF\345\205\255\347\261\273\345\256\236\351\252\214\345\267\262\345\220\257\347\224\250\357\274\210\346\234\252\351\252\214\350\257\201\357\274\214\344\273\2051800rpm\357\274\211\357\274\233\345\216\237\345\210\244\345\206\263':'')+'\346\250\241\345\236\213\347\211\210\346\234\254 '+s.model_version+'\357\274\233'+(s.model_validated?'\345\267\262\351\252\214\350\257\201':'\346\234\252\351\252\214\350\257\201/\346\234\252\351\205\215\347\275\256\357\274\214\344\277\235\346\214\201\346\234\252\347\237\245')+'\357\274\233'+(s.shaft_confirmed?'\345\267\262\347\241\256\350\256\244\350\275\254\351\200\237 '+num(s.shaft_millihz*.06,0)+' rpm':'\350\275\254\351\200\237\346\234\252\347\241\256\350\256\244')+'\357\274\233\345\277\253\347\205\247 #'+s.sequence+'\357\274\214\345\271\264\351\276\204 '+s.result_age_ms+' ms');\n"
" if(!(s.candidates||[]).length)text('candidates','\345\260\232\346\227\240\345\217\257\350\257\273\345\217\226\347\232\204\345\200\231\351\200\211\350\257\212\346\226\255\345\277\253\347\205\247\357\274\233\344\270\213\346\226\271\345\256\236\346\227\266\346\217\220\350\256\256\347\213\254\347\253\213\346\233\264\346\226\260\357\274\214\344\270\215\344\273\243\350\241\250\345\267\262\345\256\214\346\210\220\350\257\212\346\226\255\343\200\202');\n"
" $('live_proposals').textContent='';\n"
" const proposals=s.proposals||[];\n"
" text('proposal_note','\345\267\262\345\256\214\346\225\264\346\230\276\347\244\272\346\234\254\346\254\241\346\216\245\345\217\243\350\277\224\345\233\236\347\232\204 '+proposals.length+' \346\235\241\346\217\220\350\256\256\357\274\233\345\220\216\345\217\260\344\273\215\346\234\211\350\264\250\351\207\217\347\255\233\351\200\211\343\200\201\346\226\271\345\220\221\345\220\210\345\271\266\345\217\212\346\234\200\345\244\2323\346\235\241\351\231\220\345\210\266\357\274\214\344\270\215\346\230\257\345\205\250\351\203\250\345\216\237\345\247\213\345\263\260\343\200\202\346\226\271\345\220\221\347\212\266\346\200\201\347\272\246\346\257\217250ms\350\257\273\345\217\226\357\274\233\344\270\212\346\226\271\350\257\212\346\226\255\345\277\253\347\205\247\345\217\246\346\234\211\350\256\241\347\256\227\344\270\216\350\247\202\345\257\237\347\252\227\345\273\266\350\277\237\343\200\202');\n"
" proposals.forEach(p=>{let el=document.createElement('p');el.className='muted';el.textContent='\345\256\236\346\227\266\346\217\220\350\256\256\350\275\250\350\277\271 '+p.track_id+'\357\274\232\346\260\264\345\271\263\350\247\222 '+angle(p.azimuth_mdeg)+'\357\274\214\344\277\257\344\273\260\350\247\222 '+angle(p.elevation_mdeg)+'\357\274\233\350\247\202\345\257\237\346\254\241\346\225\260 '+p.observations+'\357\274\233'+({1:'\345\267\262\350\247\202\346\265\213',2:'\347\237\255\346\227\266\344\277\235\346\214\201\357\274\210\345\216\206\345\217\262\346\226\271\345\220\221\357\274\211',3:'\346\201\242\345\244\215\350\247\202\345\257\237'}[p.track_state]||'\347\212\266\346\200\201\346\234\252\347\237\245');$('live_proposals').appendChild(el);});\n"
" if(!proposals.length)text('live_proposals','\345\275\223\345\211\215\346\262\241\346\234\211\346\273\241\350\266\263\345\220\216\345\217\260\346\235\241\344\273\266\347\232\204\345\256\236\346\227\266\346\226\271\345\220\221\346\217\220\350\256\256\357\274\233\344\270\215\350\241\250\347\244\272\346\262\241\346\234\211\345\243\260\346\272\220\343\200\202');\n"
" const c=(s.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));renderDiagnosis(c,s);\n"
"}\n"
"function renderDiagnosis(c,s){if(!c){rows('diagnosis',[['\347\212\266\346\200\201','\347\255\211\345\276\205\345\200\231\351\200\211\350\257\212\346\226\255']]);rows('levels',[]);rows('features',[]);if(!guiDisplayedPlot){plot('spectrum_plot',null,8,'\351\242\221\347\216\207(kHz)');plot('envelope_plot',null,900,'\351\242\221\347\216\207(Hz)');}else text('plot_note','\345\275\223\345\211\215\346\227\240\345\200\231\351\200\211\357\274\233\344\277\235\347\225\231\345\216\206\345\217\262\345\277\253\347\205\247 #'+guiDisplayedPlot.sequence+'\357\274\214\350\275\250\350\277\271 '+guiDisplayedPlot.track+'\357\274\214\344\270\215\346\230\257\346\234\200\346\226\260\347\273\223\346\236\234\343\200\202');return;}let d=c.diagnosis||{};\n"
" rows('diagnosis',[['\350\275\250\350\277\271',c.track_id],['\346\226\271\345\220\221',angle(c.azimuth_mdeg)+' / '+angle(c.elevation_mdeg)],['\347\261\273\345\210\253',c.stale?'\350\277\207\346\234\237\347\273\223\346\236\234\357\274\210\344\273\205\344\276\233\345\233\236\347\234\213\357\274\211':({normal:'\346\255\243\345\270\270',fault:'\346\225\205\351\232\234',interference:'\345\271\262\346\211\260',anomaly:'\345\274\202\345\270\270',unknown:'\346\234\252\347\237\245'}[d.label]||'\346\234\252\347\237\245')],['\346\234\211\346\225\210\346\200\247',reasonNames[d.reason]||d.reason],['\346\250\241\345\236\213\350\267\235\347\246\273\351\227\264\351\232\224\357\274\210\351\235\236\346\246\202\347\216\207\357\274\211',num(d.margin,4)],['\346\225\205\351\232\234\346\226\271\345\220\221\347\241\256\350\256\244',validFault(c,s)?'\345\267\262\347\241\256\350\256\244':'\346\234\252\347\241\256\350\256\244']]);\n"
" const experiment=d.fstf_experimental;\n"
" if(experiment&&experiment.enabled){\n"
"  const names={inner:'\345\206\205\345\234\210',outer:'\345\244\226\345\234\210',ball:'\346\273\232\345\212\250\344\275\223',healthy:'\346\255\243\345\270\270',looseness:'\346\235\276\345\212\250',combined:'\345\244\215\345\220\210'};\n"
"  line($('diagnosis'),'FSTF\345\256\236\351\252\214\347\273\206\347\261\273',experiment.available?(names[experiment.label]||'\346\234\252\347\237\245')+'\357\274\210\346\234\252\351\252\214\350\257\201'+(c.stale?'\357\274\233\345\216\206\345\217\262\345\277\253\347\205\247':'')+'\357\274\211':'\347\255\211\345\276\2051800rpm\343\200\201\346\234\211\346\225\210\345\210\206\347\246\273\345\217\212\347\211\271\345\276\201');\n"
"  if(experiment.available)line($('diagnosis'),'\345\256\236\351\252\214\346\250\241\345\236\213\350\267\235\347\246\273 / \351\227\264\351\232\224',num(experiment.distance,4)+' / '+num(experiment.margin,3)+'\357\274\233\351\235\236\346\246\202\347\216\207\357\274\214\344\270\215\345\217\202\344\270\216\346\212\245\350\255\246\346\210\226\346\225\205\351\232\234\345\256\232\345\220\221');\n"
" }\n"
" const analyzed=!!(d.extraction&&d.extraction.fft_count===1);\n"
" rows('levels',[['\345\210\206\347\246\273\351\237\263\351\242\221RMS',analyzed?num(d.rms*100,4)+' %FS':'\346\234\252\350\256\241\347\256\227'],['\350\275\275\351\242\221\345\270\246RMS',analyzed?num(d.extraction.carrier_rms*100,4)+' %FS':'\346\234\252\350\256\241\347\256\227'],['\350\260\203\345\210\266RMS',analyzed?num(d.extraction.modulation_rms*100,4)+' %FS':'\346\234\252\350\256\241\347\256\227'],['\345\211\212\351\241\266\347\202\271\346\225\260',analyzed?d.clipped_samples:'\346\234\252\347\273\237\350\256\241'],['\350\275\275\351\242\221\345\270\246','2200\342\200\2234600 Hz\357\274\210C9F2\357\274\211']]);\n"
" $('features').textContent='';if(!analyzed||!(d.shaft_hz>=10&&d.shaft_hz<=30))line($('features'),'\351\230\266\346\254\241\347\211\271\345\276\201','\346\234\252\350\256\241\347\256\227\357\274\232\347\274\272\345\260\221\346\234\211\346\225\210\350\275\254\351\200\237\346\210\226\345\214\205\347\273\234');else (d.features||[]).forEach((v,i)=>line($('features'),'\347\211\271\345\276\201 '+(i+1),num(v,5)));\n"
"\n"
" if(guiSequence!==s.sequence||guiTrack!==c.track_id){guiSequence=s.sequence;guiTrack=c.track_id;text('plot_note',guiDisplayedPlot?'\346\226\260\345\277\253\347\205\247\345\276\205\350\257\273\345\217\226\357\274\233\344\270\213\345\233\276\344\277\235\347\225\231\345\216\206\345\217\262\345\277\253\347\205\247 #'+guiDisplayedPlot.sequence+' / \350\275\250\350\277\271 '+guiDisplayedPlot.track+'\357\274\214\344\270\215\346\230\257\346\234\200\346\226\260\347\273\223\346\236\234\343\200\202':'\346\226\260\345\277\253\347\205\247\345\267\262\345\210\260\350\276\276\357\274\214\346\255\243\345\234\250\347\255\211\345\276\205\351\237\263\351\242\221\350\257\273\345\217\226\357\274\233\344\271\237\345\217\257\347\202\271\345\207\273\350\216\267\345\217\226\345\220\214\345\277\253\347\205\247\346\263\242\345\275\242\343\200\202');}\n"
"}\n"
"var heatmapView={values:null,key:null,at:0,lastSignal:0,lo:0,hi:0,smooth:true,seq:0};\n"
"function heatmapDisplay(m,now,smooth){\n"
" if(!m||!Array.isArray(m.scores)||m.scores.length!==1024||m.scores.some(x=>!Number.isFinite(x)))return null;\n"
" let lo=Math.min(...m.scores),hi=Math.max(...m.scores),flat=hi===lo,key=m.sequence+'/'+m.frame;\n"
" let reset=!heatmapView.values||smooth!==heatmapView.smooth||m.sequence<heatmapView.seq||now-heatmapView.at>1500;\n"
" let fresh=reset||key!==heatmapView.key;\n"
" if(fresh){\n"
"  if(reset)heatmapView.lastSignal=flat?0:now;\n"
"  let dt=reset?0:Math.max(0,now-heatmapView.at),alpha=reset||!smooth?1:1-Math.exp(-dt/250);\n"
"  heatmapView.values=reset?m.scores.slice():heatmapView.values.map((v,i)=>v+alpha*(m.scores[i]-v));\n"
"  let a=Math.min(...heatmapView.values),b=Math.max(...heatmapView.values),decay=reset||!smooth?1:1-Math.exp(-dt/1200);\n"
"  heatmapView.lo=reset?a:Math.min(a,heatmapView.lo+decay*(a-heatmapView.lo));\n"
"  heatmapView.hi=reset?b:Math.max(b,heatmapView.hi+decay*(b-heatmapView.hi));\n"
"  heatmapView.key=key;heatmapView.at=now;heatmapView.seq=m.sequence;heatmapView.smooth=smooth;\n"
"  if(!flat)heatmapView.lastSignal=now;\n"
" }\n"
" return {values:heatmapView.values,lo:heatmapView.lo,hi:heatmapView.hi,flat:flat&&(!smooth||!heatmapView.lastSignal||now-heatmapView.lastSignal>=800),sourceFlat:flat,newFrame:fresh};\n"
"}\n"
"function renderMap(m){let smooth=$('map_smooth').checked,view=heatmapDisplay(m,Date.now(),smooth);if(!view){text('map_note','\347\255\211\345\276\205\345\256\214\346\225\264\350\257\204\345\210\206\345\233\276\357\274\233\346\255\244\345\211\215\345\233\276\345\203\217\344\273\205\344\276\233\345\233\236\347\234\213\357\274\214\344\270\215\344\273\243\350\241\250\345\275\223\345\211\215\345\256\232\344\275\215\343\200\202');return;}let c=$('direction_map'),g=c.getContext('2d'),L=54,T=18,W=320,H=320;g.clearRect(0,0,c.width,c.height);let lo=view.lo,hi=view.hi;\n"
" view.values.forEach((v,i)=>{let t=hi>lo?Math.max(0,Math.min(1,(v-lo)/(hi-lo))):0;g.fillStyle=view.flat?'#142431':'hsl('+(240-180*t)+',85%,45%)';g.fillRect(L+i%32*10,T+(31-Math.floor(i/32))*10,10,10);});\n"
" g.fillStyle='#a0b3c2';g.font='12px system-ui';[-90,-45,0,45,90].forEach(a=>{g.fillText(a+'\302\260',L+(a+90)*W/180-10,T+H+19);g.fillText(a+'\302\260',8,T+(90-a)*H/180+4);});g.fillText('\346\260\264\345\271\263\350\247\222\357\274\210\346\255\243\345\211\215\346\226\2710\302\260\357\274\211',L+72,T+H+39);g.fillText('\344\277\257\344\273\260\350\247\222',3,12);\n"
" const now=Date.now();if(!$('show_proposals').checked)guiTrails.clear();($('show_proposals').checked&&c9state&&c9state.proposals||[]).forEach(p=>{let trail=guiTrails.get(p.track_id)||[];if(trail.length===0||trail.at(-1).sequence!==p.observations)trail.push({x:p.azimuth_mdeg/1000,y:p.elevation_mdeg/1000,t:guiLastCandidate,sequence:p.observations});guiTrails.set(p.track_id,trail.slice(-60));});\n"
" guiTrails.forEach((trail,id)=>{trail=trail.filter(p=>now-p.t<=5000);if(!trail.length){guiTrails.delete(id);return;}guiTrails.set(id,trail);g.strokeStyle='#ffffff70';g.beginPath();trail.forEach((p,i)=>{let x=L+(p.x+90)*W/180,y=T+(90-p.y)*H/180;i?g.lineTo(x,y):g.moveTo(x,y);});g.stroke();});\n"
" (c9state&&c9state.candidates||[]).forEach(p=>{if(p.stale)return;let x=L+(p.azimuth_mdeg/1000+90)*W/180,y=T+(90-p.elevation_mdeg/1000)*H/180;g.strokeStyle=validFault(p,c9state)?'#ff6174':'white';g.strokeRect(x-5,y-5,10,10);g.fillStyle='white';g.fillText('\350\275\250\350\277\271 '+p.track_id,x+6,y);});\n"
" text('map_note',(smooth?'\346\230\276\347\244\272\345\271\263\346\273\221250ms\357\274\210\344\270\215\345\217\202\344\270\216\345\256\232\344\275\215\357\274\211\357\274\233':'\345\216\237\345\247\213\346\230\276\347\244\272\357\274\210\346\227\240\345\271\263\346\273\221\357\274\211\357\274\233')+(view.sourceFlat?'\345\275\223\345\211\215\350\257\204\345\210\206\346\227\240\347\251\272\351\227\264\345\257\271\346\257\224\357\274\233':'')+(m.map_age_us>m.stale_after_us?'\350\257\204\345\210\206\345\233\276\345\267\262\350\277\207\346\234\237\357\274\214\344\273\205\344\276\233\345\233\236\347\234\213':m.accepted?'\351\200\232\350\277\207\345\256\232\344\275\215\351\227\250\346\216\247':'\345\200\231\351\200\211\350\257\204\345\210\206\345\233\276\357\274\210\346\234\252\347\241\256\350\256\244\345\256\232\344\275\215\357\274\211')+'\357\274\233\345\270\247 '+m.frame+'\357\274\233\346\225\260\346\215\256\345\271\264\351\276\204 '+num(m.map_age_us/1000)+' ms\357\274\233\347\231\275\347\272\277\344\270\272\346\234\200\350\277\2215\347\247\222\345\200\231\351\200\211\346\226\271\345\220\221\347\225\231\347\227\225\343\200\202\350\257\204\345\210\206\344\270\215\344\273\243\350\241\250\346\225\205\351\232\234\346\246\202\347\216\207\343\200\202');\n"
"}\n"
"function renderHealth(s){c9health=s;if(guiSession!==s.session){guiSession=s.session;guiHistory=[];guiEvents.clear();guiHealthCursor=guiEventCursor=0;guiTrails.clear();}\n"
" text('health_note',(s.enabled?'\347\233\221\346\265\213\345\267\262\345\220\257\347\224\250':'\347\233\221\346\265\213\345\267\262\345\205\263\351\227\255')+'\357\274\233\350\277\236\347\273\255'+s.thresholds.join(' / ')+'\346\254\241\357\274\232\347\226\221\344\274\274 / \346\212\245\350\255\246 / \346\201\242\345\244\215\357\274\233\346\226\255\346\265\201\346\210\226\346\234\252\347\237\245\347\273\223\346\236\234\344\270\215\344\274\232\350\247\243\351\231\244\346\212\245\350\255\246\343\200\202');\n"
" $('health_status').textContent='';(s.tracks||[]).forEach(t=>{let r=t.record,p=document.createElement('p');p.className=r.state>=2?'alarm':'';p.textContent='\350\275\250\350\277\271 '+r.track+'\357\274\232'+states[r.state]+'\357\274\233'+(t.fresh?'\346\234\211\346\225\210\350\257\212\346\226\255':'\346\225\260\346\215\256\346\227\240\346\225\210/\350\277\207\346\234\237\357\274\214\344\277\235\347\225\231\346\212\245\350\255\246\347\212\266\346\200\201')+'\357\274\233\346\234\200\350\277\221\346\234\211\346\225\210\346\227\266\351\227\264 '+num(t.last_valid_ms/1000,1)+' s\357\274\233RMS '+num(r.rms*100,4)+' %FS';$('health_status').appendChild(p);});\n"
" if(!(s.tracks||[]).length)text('health_status','\347\255\211\345\276\205\347\234\237\345\256\236\345\200\231\351\200\211\350\257\212\346\226\255\357\274\233\345\275\223\345\211\215\346\262\241\346\234\211\346\234\211\346\225\210\350\257\212\346\226\255\357\274\214\344\270\215\350\241\250\347\244\272\350\256\276\345\244\207\346\255\243\345\270\270\343\200\202');\n"
"}\n"
"function renderPerformance(z){let aux=c9state&&c9state.auxiliary_search||{},d=c9state&&c9state.diagnostic_scheduler||{};\n"
" rows('performance',[\n"
" ['\345\216\237\345\247\213PCM\345\267\262\346\216\245\346\224\266 / \345\216\206\345\217\262\344\277\235\347\225\231',z.dma_frame_ok+' / '+z.history_frames+' \351\207\207\346\240\267\345\270\247'],\n"
" ['\351\207\207\351\233\206\350\277\236\347\273\255\344\274\232\350\257\235 / DMA\351\224\231\350\257\257',z.history_session+' / '+z.dma_corrupt],\n"
" ['DMA\344\270\242\346\240\267 / UDP\344\270\242\346\240\267',z.dma_drops+' / '+z.udp_frames_dropped],\n"
" ['UDP\350\277\236\347\273\255\345\275\225\351\237\263',z.udp_enabled?'\345\267\262\345\220\257\347\224\250\357\274\210\345\214\205\345\220\253\350\277\236\347\273\255\350\276\223\345\207\272\345\244\204\347\220\206\357\274\211':'\345\267\262\345\205\263\351\227\255\357\274\233\347\213\254\347\253\213\345\200\231\351\200\211\345\210\206\347\246\273/\350\257\212\346\226\255\347\273\247\347\273\255\350\277\220\350\241\214'],\n"
" ['GSC\350\257\267\346\261\202 / \346\227\201\350\267\257\345\216\237\345\233\240',z.gsc_requested+' / '+z.gsc_reason],\n"
" ['\345\256\214\346\225\264\350\257\204\345\210\206\345\233\276 / \351\207\215\350\257\225',c9state?c9state.map_copies+' / '+c9state.map_retries:'\347\255\211\345\276\205'],\n"
" ['\350\276\205\345\212\251\346\220\234\347\264\242\345\256\214\346\210\220 / \346\216\245\345\217\227 / \350\266\205\346\227\266',aux.cpu1_completed+' / '+aux.accepted+' / '+aux.cpu1_late],\n"
" ['\350\276\205\345\212\251\346\220\234\347\264\242\346\234\200\345\244\247\350\200\227\346\227\266',num(aux.cpu1_processing_us_max/1000,3)+' ms / 200 ms\346\234\237\351\231\220'],\n"
" ['\346\220\234\347\264\242\345\210\206\346\256\265\357\274\232\350\257\273\345\217\226/\351\231\215\351\207\207\346\240\267/\347\273\237\350\256\241/\346\220\234\347\264\242',[aux.copy_us,aux.prepare_us,aux.observations_us,aux.search_us].map(x=>num(x/1000,2)).join(' / ')+' ms'],\n"
" ['\350\257\212\346\226\255\344\273\273\345\212\241 / \345\256\214\346\210\220 / \347\252\227\345\217\243\346\234\252\347\250\263\345\256\232',d.cpu1_started+' / '+d.cpu1_completed+' / '+d.coverage_rejected],\n"
" ['\345\256\232\344\275\215\351\246\226PCM\345\210\260PS\357\274\210\345\275\223\345\211\215/\346\234\200\345\244\247\357\274\211',z.latency_samples?num(z.pcm_to_ps_us/1000,3)+' / '+num(z.pcm_to_ps_max_us/1000,3)+' ms':'\347\255\211\345\276\205\347\234\237\345\256\236\346\265\213\351\207\217'],\n"
" ['\351\237\263\351\242\221\346\234\215\345\212\241\346\234\200\345\244\247\351\227\264\351\232\224 / \350\200\227\346\227\266',z.max_ps_poll_gap_us+' / '+z.max_ps_service_us+' us'],\n"
" ['\345\256\232\344\275\215\344\270\216\346\225\205\351\232\234\345\207\206\347\241\256\346\200\247\351\252\214\346\224\266',z.board_validated?'\345\267\262\345\256\214\346\210\220':'\345\260\232\346\234\252\345\256\214\346\210\220\357\274\214\351\207\207\351\233\206\350\277\236\351\200\232\344\270\215\344\273\243\350\241\250\345\207\206\347\241\256\346\200\247\351\200\232\350\277\207']]);}\n"
"\n"
"function renderHistory(){let seconds=Number($('history_range').value),now=c9health?c9health.uptime_ms:0,track=Number($('candidate_select').value),r=guiHistory.filter(v=>now-v.ms<=seconds*1000&&(!track||v.track===track));\n"
" let c=$('history_plot'),g=c.getContext('2d'),L=62,R=c.width-16,T=26,B=c.height-38;g.clearRect(0,0,c.width,c.height);g.font='12px system-ui';g.fillStyle='#a0b3c2';g.fillText('RMS (%FS)\357\274\214\346\257\217\346\235\241\346\233\262\347\272\277\345\217\252\345\257\271\345\272\224\351\200\211\344\270\255\350\275\250\350\277\271',L,16);let max=Math.max(.01,...r.map(v=>v.rms*100));g.strokeStyle='#304352';for(let i=0;i<=4;i++){let y=T+(B-T)*i/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText(num(max*(1-i/4),2),4,y+3);g.fillText('-'+num(seconds*(1-i/4),0)+'s',L+i*(R-L)/4-10,B+18);}let previous=null;r.forEach(v=>{let x=L+(1-(now-v.ms)/seconds/1000)*(R-L),y=B-v.rms*100/max*(B-T);if(previous&&v.track===previous.track&&v.ms-previous.ms<3000){g.strokeStyle=v.valid?'#52d6c1':'#738598';g.beginPath();g.moveTo(previous.x,previous.y);g.lineTo(x,y);g.stroke();}g.fillStyle=v.valid?['#52d6c1','#ffd17c','#ff6174','#ffb454'][v.state]:'#738598';g.fillRect(x-2,y-2,4,4);previous={...v,x,y};});text('history_note','\345\275\223\345\211\215\347\252\227\345\217\243 '+seconds+' \347\247\222\357\274\233'+r.length+'\346\235\241\347\234\237\345\256\236\350\257\212\346\226\255\350\256\260\345\275\225\343\200\202\347\201\260\347\202\271\350\241\250\347\244\272\346\227\240\346\225\210\350\257\212\346\226\255\357\274\233\346\235\277\345\206\205\346\234\200\345\244\232\344\277\235\347\225\231256\346\235\241\343\200\202');\n"
" $('events').textContent='';Array.from(guiEvents.values()).sort((a,b)=>b.id-a.id).forEach(e=>{let r=document.createElement('tr');[e.id,'\350\275\250\350\277\271 '+e.track,states[e.state],labels[e.label],e.closed?'\345\267\262\345\205\263\351\227\255':'\350\277\233\350\241\214\344\270\255',num(e.first_ms/1000,1)+' s'].forEach(v=>{let td=document.createElement('td');td.textContent=v;r.appendChild(td);});let td=document.createElement('td'),b=document.createElement('button');b.textContent='\350\257\246\346\203\205';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));td.appendChild(b);r.appendChild(td);$('events').appendChild(r);});\n"
"}\n"
"async function fetchHealth(){let s=await get('/api/health9/status');renderHealth(s);let h=await get('/api/health9/history?after='+guiHealthCursor+'&limit=32');if(h.session!==guiSession)return;guiHistory.push(...h.records);guiHistory=guiHistory.slice(-256);guiHealthCursor=h.next_after;let e=await get('/api/health9/events?after='+guiEventCursor+'&limit=16');if(e.session!==guiSession)return;e.events.forEach(v=>guiEvents.set(v.id,v));if(guiEvents.size>32)guiEvents.delete(guiEvents.keys().next().value);guiEventCursor=e.next_after;renderHistory();}\n"
"async function archiveView(){try{let data=await get('/archive/history?seconds='+$('history_range').value);rows('archive_records',(data.records||[]).slice(-64).map(r=>[r.received_utc+' / \344\274\232\350\257\235'+r.archive_session,'\350\275\250\350\277\271'+r.track+'\357\274\233'+states[r.state]+'\357\274\233RMS '+num(r.rms*100,4)+' %FS']));$('archive_events').textContent='';(data.events||[]).forEach(e=>{let p=document.createElement('p');p.textContent=e.received_utc+'\357\274\233\344\274\232\350\257\235'+e.archive_session+'\357\274\233\344\272\213\344\273\266'+e.id+'\357\274\233\350\275\250\350\277\271'+e.track+'\357\274\233'+states[e.state]+'\357\274\233'+(e.closed?'\345\267\262\346\201\242\345\244\215\345\205\263\351\227\255':'\345\216\206\345\217\262\346\234\252\345\205\263\351\227\255\357\274\214\344\270\215\350\203\275\346\216\250\346\226\255\345\267\262\346\201\242\345\244\215');let b=document.createElement('button');b.textContent='\350\257\246\346\203\205';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));p.appendChild(b);$('archive_events').appendChild(p);});text('archive_note','SQLite\350\267\250\351\207\215\345\220\257\345\216\206\345\217\262\357\274\233\346\227\266\351\227\264\344\270\272PC\346\216\245\346\224\266UTC\357\274\214\344\270\215\346\230\257\345\243\260\346\272\220\345\217\221\347\224\237\346\227\266\351\227\264\343\200\202'+(data.archive_error?'\345\275\222\346\241\243\345\274\202\345\270\270\357\274\232'+data.archive_error:'\346\234\200\350\277\221\345\275\222\346\241\243\346\255\243\345\270\270\343\200\202'));}catch(e){text('archive_note','\350\257\267\350\277\220\350\241\214PC\345\275\222\346\241\243\346\234\215\345\212\241\345\271\266\344\273\216 http://127.0.0.1:8769/ \346\211\223\345\274\200\345\256\214\346\225\264\351\241\265\351\235\242\343\200\202'+String(e));}}\n"
"function selectedPlotCandidate(state){return state&&(state.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));}\n"
"function decodePlotSnapshot(buf,seq,track,index,state){\n"
" if(!buf||buf.byteLength!==8512)throw Error('\345\217\214\350\260\261\345\277\253\347\205\247\351\225\277\345\272\246\351\224\231\350\257\257');\n"
" let v=new DataView(buf),h=Array.from({length:16},(_,i)=>v.getUint32(4*i,true));\n"
" if(h[0]!==0x43394732||h[1]!==1||h[2]!==seq||h[3]!==track||h[4]!==index||!h[5]||!h[6]||h[7]!==4096||h[8]!==128||h[9]>1||h[10]>4||h[15]>1)throw Error('\345\217\214\350\260\261\345\277\253\347\205\247\350\272\253\344\273\275\346\210\226\346\240\274\345\274\217\351\224\231\350\257\257');\n"
" if(state&&((Number.isInteger(state.snapshot_session)&&h[13]!==state.snapshot_session)||(Number.isInteger(state.snapshot_epoch)&&h[12]!==state.snapshot_epoch)||(Number.isInteger(state.snapshot_first_sample)&&h[11]!==state.snapshot_first_sample)))throw Error('\345\217\214\350\260\261\351\207\207\351\233\206\344\274\232\350\257\235\346\210\226\346\227\266\351\227\264\350\265\267\347\202\271\344\270\215\345\214\271\351\205\215');\n"
" if((h[14]!==0&&(h[14]<10000||h[14]>30000))||(h[15]&&(!h[9]||!h[14]))||(h[9]&&(h[10]===0||h[10]===4)))throw Error('\345\214\205\347\273\234/\351\230\266\346\254\241\346\234\211\346\225\210\346\200\247\346\240\207\345\277\227\344\270\215\344\270\200\350\207\264');\n"
" let audio=Array.from({length:4096},(_,i)=>v.getInt16(64+2*i,true)),envelope=Array.from({length:128},(_,i)=>v.getUint16(8256+2*i,true));\n"
" if(envelope.some(x=>x>1000))throw Error('\345\214\205\347\273\234\345\275\222\344\270\200\345\214\226\346\225\260\346\215\256\350\266\212\347\225\214');\n"
" return {sequence:h[2],track:h[3],fs:h[5]/h[6],envelope_valid:h[9],envelope_status:h[10],first:h[11],epoch:h[12],session:h[13],shaft_millihz:h[14],features_available:h[15],audio,envelope};\n"
"}\n"
"async function preview(){\n"
" if(guiPlotBusy)return false;\n"
" let state=c9state,c=selectedPlotCandidate(state);if(!c){text('plot_note','\345\260\232\346\227\240\345\200\231\351\200\211\345\277\253\347\205\247\357\274\233\344\270\215\344\274\232\347\224\250\346\226\271\345\220\221\346\217\220\350\256\256\345\206\222\345\205\205\350\257\212\346\226\255\351\237\263\351\242\221\343\200\202');return false;}\n"
" guiPlotBusy=true;const token=++guiPreviewToken;$('preview').disabled=true;\n"
" try{\n"
"  let packet;\n"
"  for(let attempt=0;attempt<2;attempt++){\n"
"   let seq=state.sequence,index=state.candidates.indexOf(c);\n"
"   try{packet=decodePlotSnapshot(await get('/api/gui/snapshot?sequence='+seq+'&index='+index,true),seq,c.track_id,index,state);break;}\n"
"   catch(e){\n"
"    if(e.status!==409||attempt!==0)throw e;\n"
"    let fresh=await get('/api/candidates');if(!fresh||token!==guiPreviewToken)throw Error('\351\200\211\346\213\251\345\267\262\346\224\271\345\217\230\357\274\214\345\217\226\346\266\210\346\227\247\350\257\273\345\217\226');\n"
"    let same=(fresh.candidates||[]).find(x=>x.track_id===c.track_id);renderCandidates(fresh);\n"
"    if(!same)throw Error('\345\216\237\350\275\250\350\277\271\345\267\262\351\200\200\345\207\272\357\274\214\347\255\211\345\276\205\346\226\260\345\277\253\347\205\247\351\207\215\350\257\225');state=fresh;c=same;\n"
"   }\n"
"  }\n"
"  if(token!==guiPreviewToken)throw Error('\351\200\211\346\213\251\345\267\262\346\224\271\345\217\230\357\274\214\345\217\226\346\266\210\346\227\247\350\257\273\345\217\226');\n"
"  let re=Float64Array.from(packet.audio),im=new Float64Array(4096),mean=re.reduce((a,b)=>a+b,0)/re.length;\n"
"  for(let i=0;i<re.length;i++)re[i]=(re[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(re.length-1)));\n"
"  gccFft(re,im,false);let count=Math.min(2048,Math.floor(GUI_SPECTRUM_MAX_HZ*4096/packet.fs)),bins=Array.from({length:count},(_,i)=>Math.hypot(re[i+1],im[i+1])),max=Math.max(...bins)||1,xvalues=bins.map((_,i)=>(i+1)*packet.fs/4096000);\n"
"  guiSpectrumView={max_hz:GUI_SPECTRUM_MAX_HZ,bins:count,last_hz:count*packet.fs/4096};\n"
"  plot('spectrum_plot',bins.map(x=>x/max),8,'\351\242\221\347\216\207(kHz)','\347\233\270\345\257\271\345\271\205\345\200\274\357\274\2100\342\200\2238kHz\345\263\260\345\200\274=1\357\274\211',false,'\347\255\211\345\276\205\351\237\263\351\242\221',0,xvalues);\n"
"  const envelopeMessage=({0:'\346\234\254\345\277\253\347\205\247\346\234\252\350\256\241\347\256\227\345\214\205\347\273\234',4:'\350\276\223\345\205\245\346\227\240\346\225\210\357\274\214\346\234\252\347\224\237\346\210\220\345\214\205\347\273\234'}[packet.envelope_status]||'\346\234\254\345\277\253\347\205\247\346\234\252\347\224\237\346\210\220\345\214\205\347\273\234');\n"
"  plot('envelope_plot',packet.envelope_valid?packet.envelope.map(x=>x/1000):null,900,'\351\242\221\347\216\207(Hz)','\347\233\270\345\257\271\345\271\205\345\200\274\357\274\210\345\263\260\345\200\274=1\357\274\211',false,envelopeMessage);\n"
"  guiDisplayedPlot={sequence:packet.sequence,track:packet.track,session:packet.session,epoch:packet.epoch,first:packet.first,received:Date.now(),envelope_valid:packet.envelope_valid};\n"
"  let historical=!c9state||c9state.sequence!==packet.sequence||!selectedPlotCandidate(c9state)||selectedPlotCandidate(c9state).track_id!==packet.track;\n"
"  text('plot_note',(historical?'\345\216\206\345\217\262':'\345\267\262\350\257\273\345\217\226')+'\345\277\253\347\205\247 #'+packet.sequence+' / \350\275\250\350\277\271 '+packet.track+'\357\274\233\351\207\207\351\233\206\344\274\232\350\257\235 '+packet.session+'\357\274\214epoch '+packet.epoch+'\357\274\233\345\217\214\350\260\261\344\270\200\346\254\241\346\200\247\350\257\273\345\217\226\357\274\214\344\270\215\346\267\267\345\270\247\343\200\202');\n"
"  text('spectrum_note','\345\277\253\347\205\247 #'+packet.sequence+' / \350\275\250\350\277\271 '+packet.track+'\357\274\233\344\273\205\346\230\276\347\244\2720\342\200\2238kHz\357\274\214\345\217\257\350\247\201\351\242\221\345\270\246\345\263\260\345\200\274\345\275\222\344\270\200\357\274\233\345\220\214\344\270\200\345\210\206\347\246\273\345\277\253\347\205\247\345\211\2154096\347\202\271\357\274\214\345\216\273\345\235\207\345\200\274/Hann\347\252\227FFT\357\274\233'+num(packet.fs,1)+' Hz\351\207\207\346\240\267\357\274\233\351\235\236DC\351\246\226\351\242\221\347\202\271 '+num(packet.fs/4096,3)+' Hz\343\200\202');\n"
"  let status=packet.envelope_status===2?'\350\275\275\351\242\221\345\270\246\350\203\275\351\207\217\344\270\215\350\266\263\357\274\233':packet.envelope_status===3?'\346\234\252\350\247\201\346\230\216\346\230\276\350\260\203\345\210\266\357\274\233':'';\n"
"  text('envelope_note',packet.envelope_valid?'\345\277\253\347\205\247 #'+packet.sequence+' / \350\275\250\350\277\271 '+packet.track+'\357\274\233'+status+'\345\220\214\344\270\200\345\256\214\346\225\2641.024\347\247\222C9F2\345\214\205\347\273\234\357\274\2140\342\200\223900Hz\345\210\206\347\273\204\346\234\200\345\244\247\345\200\274\357\274\214\346\216\222\351\231\244DC\343\200\202'+(packet.features_available?'\351\230\266\346\254\241\347\211\271\345\276\201\345\267\262\350\256\241\347\256\227\357\274\214\345\210\206\347\261\273\346\234\211\346\225\210\346\200\247\345\217\246\350\241\214\345\210\244\345\256\232\343\200\202':'\350\275\254\351\200\237\346\234\252\347\241\256\350\256\244\357\274\232\344\273\205\346\230\276\347\244\272Hz\345\214\205\347\273\234\357\274\214\351\230\266\346\254\241\347\211\271\345\276\201\345\222\214\345\210\206\347\261\273\346\234\252\346\211\247\350\241\214\343\200\202'):envelopeMessage+'\357\274\233\344\270\215\346\230\276\347\244\272\345\205\266\344\273\226\345\277\253\347\205\247\347\232\204\345\214\205\347\273\234\345\206\222\345\205\205\345\275\223\345\211\215\347\273\223\346\236\234\343\200\202');\n"
"  return true;\n"
" }catch(e){\n"
"  text('plot_note',String(e)+(guiDisplayedPlot?'\357\274\233\344\277\235\347\225\231\345\216\206\345\217\262\345\277\253\347\205\247 #'+guiDisplayedPlot.sequence+' / \350\275\250\350\277\271 '+guiDisplayedPlot.track:'\357\274\233\346\232\202\346\227\240\345\267\262\350\257\273\345\217\226\346\263\242\345\275\242\357\274\214\350\207\252\345\212\250\346\233\264\346\226\260\345\260\206\351\207\215\350\257\225'));\n"
"  if(!guiDisplayedPlot){plot('spectrum_plot',null,8,'\351\242\221\347\216\207(kHz)','\347\233\270\345\257\271\345\271\205\345\200\274',false,'\351\237\263\351\242\221\345\277\253\347\205\247\350\257\273\345\217\226\346\234\252\345\256\214\346\210\220');plot('envelope_plot',null,900,'\351\242\221\347\216\207(Hz)','\347\233\270\345\257\271\345\271\205\345\200\274',false,'\345\214\205\347\273\234\345\277\253\347\205\247\350\257\273\345\217\226\346\234\252\345\256\214\346\210\220');}\n"
"  return false;\n"
" }finally{guiPlotBusy=false;$('preview').disabled=false;}\n"
"}\n"
"\n"
"async function pair(){ window.guiPair=null;$('pair_capture').disabled=true;try{let a=Number($('pair_a').value),b=Number($('pair_b').value),buf=await get('/api/debug/pair?a='+a+'&b='+b,true),v=new DataView(buf);if(v.getUint32(0,true)!==0x43395031||buf.byteLength!==4128)throw Error('\345\277\253\347\205\247\346\240\274\345\274\217\351\224\231\350\257\257');let fs=v.getUint32(4,true),x=[],y=[];for(let i=0;i<1024;i++){x.push(v.getInt16(32+4*i,true));y.push(v.getInt16(34+4*i,true));}let mx=x.reduce((a,b)=>a+b)/1024,my=y.reduce((a,b)=>a+b)/1024,xx=x.map(a=>a-mx),yy=y.map(a=>a-my),xy=0,sx=0,sy=0;xx.forEach((a,i)=>{xy+=a*yy[i];sx+=a*a;sy+=yy[i]*yy[i];});let positions=c9ChannelPositions,r=gccAnalyze([x,y],fs,[positions[a],positions[b]])[0];let peak=Math.max(...xx.map(Math.abs),...yy.map(Math.abs),1);plot('pair_plot',xx.map(a=>a/peak),1023/fs*1000,'\346\227\266\351\227\264(ms)','\345\205\261\344\272\253\345\271\205\345\200\274\350\275\264\357\274\210AC PCM\357\274\211',true);let g=$('pair_plot').getContext('2d'),L=62,R=$('pair_plot').width-18,T=25,B=$('pair_plot').height-42;g.strokeStyle='#ffb454';g.beginPath();yy.forEach((v,i)=>{let px=L+i*(R-L)/1023,py=(T+B)/2-v/peak*(B-T)/2;i?g.lineTo(px,py):g.moveTo(px,py);});g.stroke();rows('pair_result',[['\345\220\214\345\270\247\345\216\237\345\247\213PCM','CH'+a+' / CH'+b+'\357\274\233'+fs+' Hz\357\274\233\350\265\267\347\202\271 '+v.getUint32(20,true)],['AC\347\233\270\345\205\263\347\263\273\346\225\260',sx&&sy?num(xy/Math.sqrt(sx*sy),6):'\346\227\240\346\234\211\346\225\210\350\203\275\351\207\217'],['\346\255\243\345\263\260',gccEstimateText(r.positive)],['\350\264\237\350\260\267',gccEstimateText(r.negative)],['\347\273\235\345\257\271\345\263\260',gccEstimateText(r.absolute)]]);text('pair_note','\344\277\235\347\225\231\345\216\237\345\247\213\346\227\266\351\227\264\350\275\264\357\274\214\346\227\240\347\247\273\344\275\215\343\200\201\346\227\240\346\236\201\346\200\247\347\277\273\350\275\254\357\274\233GCC\344\273\205\346\265\217\350\247\210\345\231\250\350\260\203\350\257\225\343\200\202\345\243\260\345\255\224\345\215\212\345\276\204\357\274\232\345\267\246\345\217\26322mm\343\200\201\344\270\212\344\270\21325.5mm\343\200\201\346\226\234\345\220\22123mm\357\274\210\346\232\202\346\214\21145\302\260\357\274\211\357\274\233\345\271\205\347\233\270\346\240\207\345\256\232\345\217\212\345\243\260\345\255\246\345\207\206\347\241\256\346\200\247\344\273\215\345\276\205\351\252\214\346\224\266\343\200\202');window.guiPair={a,b,fs,first:v.getUint32(20,true),epoch:v.getUint32(24,true),session:v.getUint32(28,true),x,y,gcc:r};}catch(e){text('pair_note',String(e));}finally{$('pair_capture').disabled=false;}}\n"
"async function tick(){if(paused||c9busy)return;c9busy=true;try{if(Date.now()-guiLastCandidate>=250){renderStatus(await get('/api/status'));let s=await get('/api/candidates');renderCandidates(s);}renderMap(await get('/api/heatmap'));if(Date.now()-guiLastHealth>1000){await fetchHealth();renderPerformance(await get('/api/gsc'));guiLastHealth=Date.now();}text('err','');}catch(e){text('err','\351\200\232\344\277\241/\346\225\260\346\215\256\344\270\215\345\217\257\347\224\250\357\274\232'+String(e)+'\357\274\233\344\277\235\347\225\231\346\212\245\350\255\246\357\274\214\347\255\211\345\276\205\346\201\242\345\244\215\343\200\202');}finally{c9busy=false;}}\n"
"$('pause').onclick=()=>{paused=!paused;text('pause',paused?'\347\273\247\347\273\255\346\230\276\347\244\272':'\346\232\202\345\201\234\346\230\276\347\244\272');};\n"
"$('save').onclick=()=>download('acoustic_snapshot.json',JSON.stringify({captured_utc:new Date().toISOString(),status:latest,candidates:c9state,health:c9health},null,2));\n"
"$('preview').onclick=preview;$('pair_capture').onclick=pair;$('pair_save').onclick=()=>window.guiPair&&download('pair_pcm_gcc.json',JSON.stringify(window.guiPair));\n"
"let pairRunning=false,pairFrames=[];$('pair_run').onclick=async()=>{if(pairRunning){pairRunning=false;return;}pairRunning=true;pairFrames=[];text('pair_run','\345\201\234\346\255\242\350\277\236\347\273\255\351\207\207\351\233\206');try{for(let i=0;i<10&&pairRunning;i++){await pair();if(window.guiPair)pairFrames.push(window.guiPair);if(i<9)await new Promise(resolve=>setTimeout(resolve,1000));}if(pairFrames.length)download('pair_10frames.json',JSON.stringify({source:'hardware_pcm',frames:pairFrames}));}finally{pairRunning=false;text('pair_run','\350\277\236\347\273\255\351\207\207\351\233\20610\345\270\247');}};\n"
"$('raw_download').onclick=async()=>{try{let buf=await get('/api/debug/raw',true);download('nine_microphones.raw',buf,'application/octet-stream');text('pair_note','\344\271\235\350\267\257\345\220\214\346\255\245\345\277\253\347\205\247\345\267\262\344\270\213\350\275\275\357\274\232C9R1\345\244\264\343\200\201\351\207\207\346\240\267\347\216\207\343\200\201\350\265\267\347\202\271\343\200\201epoch/session\345\217\212\344\272\244\351\224\231int16 PCM\343\200\202');}catch(e){text('pair_note',String(e));}};\n"
"$('history_range').onchange=renderHistory;$('candidate_select').onchange=()=>{guiPreviewToken++;renderDiagnosis((c9state.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value)),c9state);renderHistory();};\n"
"$('export').onclick=()=>download('health_events.json',JSON.stringify({session:guiSession,records:guiHistory,events:Array.from(guiEvents.values())},null,2));\n"
"$('archive_load').onclick=archiveView;\n"
"$('health_toggle').onclick=()=>control('/api/health9/enabled?value='+(c9health&&c9health.enabled?0:1));\n"
"$('rpm_set').onclick=()=>{let rpm=Number($('rpm').value);if(!Number.isInteger(rpm)||rpm<600||rpm>1800){text('action_note','\350\257\267\350\276\223\345\205\245\345\267\262\347\237\245\345\256\236\351\231\205\350\275\254\351\200\237600\342\200\2231800rpm');return;}control('/api/rpm?value='+rpm);};\n"
"$('direction_map').onclick=function(e){let r=this.getBoundingClientRect(),x=(e.clientX-r.left)*this.width/r.width,y=(e.clientY-r.top)*this.height/r.height;if(x<54||x>=374||y<18||y>=338)return;control('/api/target?grid='+((31-Math.floor((y-18)/10))*32+Math.floor((x-54)/10)));};\n"
"document.querySelectorAll('[data-control]').forEach(b=>b.onclick=()=>control(b.dataset.control));\n"
"for(let i=0;i<9;i++)['pair_a','pair_b'].forEach(id=>{let o=document.createElement('option');o.value=i;o.textContent='CH'+i;$(id).appendChild(o);});$('pair_b').value=1;\n"
"plot('spectrum_plot',null,8,'\351\242\221\347\216\207(kHz)');plot('envelope_plot',null,900,'\351\242\221\347\216\207(Hz)');plot('pair_plot',null,6.5536,'\346\227\266\351\227\264(ms)','AC PCM',true);\n"
"setInterval(()=>{if(!paused&&guiLastCandidate&&Date.now()-guiLastCandidate>3000){text('health_note','\351\200\232\344\277\241\345\267\262\350\277\207\346\234\237\357\274\233\344\270\213\346\226\271\344\270\272\345\216\206\345\217\262\347\212\266\346\200\201\357\274\214\344\270\215\344\273\243\350\241\250\345\275\223\345\211\215\346\255\243\345\270\270\343\200\202');guiTrails.clear();}},500);\n"
"setInterval(tick,100);tick();\n"
"\n"
"/* Eight-mic UI capabilities adapted to nine-mic data contracts. Display only. */\n"
"var rawSnapshot=null,rawBusy=false,lastStatusReceipt=0;\n"
"const baseRenderStatus=renderStatus;\n"
"renderStatus=function(s){baseRenderStatus(s);lastStatusReceipt=Date.now();\n"
" $('mics').textContent='';for(let i=0;i<9;i++){let tr=document.createElement('tr');['CH'+i+' / DIN'+Math.floor(i/2),...['mic_rms_ppm','mic_peak_ppm','mic_mean_ppm'].map(k=>s.mic_valid?num((s[k]||[])[i]/10000,4):'\346\234\252\346\217\220\344\276\233'),s.mic_valid?(s.mic_clipped||[])[i]:'\346\234\252\346\217\220\344\276\233'].forEach(v=>{let td=document.createElement('td');td.textContent=v;tr.appendChild(td);});$('mics').appendChild(tr);}\n"
" let reasons=[];[[1,'\344\275\216\347\224\265\345\271\263'],[2,'\350\276\223\345\205\245\345\274\202\345\270\270'],[4,'SRP\345\276\227\345\210\206\344\270\215\350\266\263'],[8,'\345\263\260\345\200\274\345\214\272\345\210\206\344\270\215\350\266\263'],[16,'\344\275\215\347\275\256\347\241\256\350\256\244\344\270\255'],[32,'\345\207\240\344\275\225\346\234\252\347\241\256\350\256\244'],[64,'\347\273\223\346\236\234\350\277\207\346\234\237']].forEach(([bit,name])=>{if(s.loc_reason&bit)reasons.push(name);});\n"
" text('location_detail','\345\256\232\344\275\215 '+(s.loc_valid?'\346\234\211\346\225\210':'\346\234\252\351\200\232\350\277\207')+'\357\274\233\345\216\237\345\247\213\345\200\231\351\200\211\346\240\274 '+s.loc_raw_grid+'\357\274\233\345\270\247 '+s.loc_frame+'\357\274\233\345\216\237\345\233\240 '+(reasons.join(' / ')||'\346\227\240\346\213\222\347\273\235\346\240\207\345\277\227')+'\357\274\233\351\200\232\350\277\207/\346\213\222\347\273\235 '+s.loc_accepted+' / '+s.loc_rejected+'\357\274\233\345\263\260\345\200\274 '+s.loc_best+'\357\274\214\351\235\236\345\261\200\351\203\250\345\263\260 '+s.loc_nonlocal+'\357\274\233\345\257\271\346\257\224\345\272\246 '+s.loc_quality_permille+'\342\200\260\357\274\210\351\235\236\346\246\202\347\216\207\357\274\211');\n"
"};\n"
"const baseHealth=renderHealth;\n"
"renderHealth=function(s){baseHealth(s);text('storage_note','\346\235\277\345\206\205\345\216\206\345\217\262 '+s.cursor+' \346\235\241\347\264\257\350\256\241\357\274\233\345\216\206\345\217\262\350\246\206\347\233\226 '+s.history_overwritten+'\357\274\233\344\272\213\344\273\266\346\272\242\345\207\272 '+s.event_overflow+'\357\274\233\350\275\250\350\277\271\346\272\242\345\207\272 '+s.track_overflow+'\357\274\233\345\275\222\346\241\243\344\274\232\350\257\235 '+s.session+'\343\200\202\346\235\277\344\270\212\351\207\215\345\220\257\346\270\205RAM\357\274\214\350\267\250\351\207\215\345\220\257\344\275\277\347\224\250PC\345\275\222\346\241\243\343\200\202');};\n"
"const basePerformance=renderPerformance;\n"
"renderPerformance=function(z){basePerformance(z);[['PDM\346\212\275\345\217\226 / \345\256\232\344\275\215\347\252\227 / hop',z.pdm_decimation+' / '+z.window_samples+' / '+z.hop_samples],['\345\216\237\345\247\213PCM\351\207\207\346\240\267\347\216\207',z.sample_rate_num+' / '+z.sample_rate_den+' Hz'],['\345\207\240\344\275\225 / \346\240\207\345\256\232\347\211\210\346\234\254 / \347\212\266\346\200\201',z.geometry_confirmed+' / '+z.calibration_version+' / '+z.calibration_status],['\350\207\252\351\200\202\345\272\224\345\206\273\347\273\223',z.freeze_updates?'\345\267\262\345\206\273\347\273\223':'\346\234\252\345\206\273\347\273\223'],['\345\256\232\344\275\215\346\234\211\346\225\210\345\273\266\350\277\237\346\240\267\346\234\254 / \345\205\250\351\203\250\346\240\267\346\234\254',z.valid_latency_samples+' / '+z.latency_samples],['\345\256\232\344\275\21510ms\346\234\237\351\231\220\350\277\235\347\272\246',z.deadline_misses],['\346\234\211\346\225\210\345\256\232\344\275\215\346\234\237\351\231\220\350\277\235\347\272\246',z.valid_deadline_misses]].forEach(r=>line($('performance'),...r));let d=c9state&&c9state.diagnostic_scheduler||{};Object.keys(d).forEach(k=>line($('performance'),'\350\257\212\346\226\255\350\260\203\345\272\246 / '+k,d[k]));};\n"
"function waveformStats(x,y){let n=x.length,m=x.reduce((a,b)=>a+b,0)/n,q=y.reduce((a,b)=>a+b,0)/n,xx=0,yy=0,xy=0;for(let i=0;i<n;i++){let a=x[i]-m,b=y[i]-q;xx+=a*a;yy+=b*b;xy+=a*b;}return {a:Math.sqrt(xx/n),b:Math.sqrt(yy/n),r:xx&&yy?xy/Math.sqrt(xx*yy):null};}\n"
"function rawSpectrum(){if(!rawSnapshot)return;let x=rawSnapshot.channels[Number($('raw_channel').value)],n=x.length,mean=x.reduce((a,b)=>a+b,0)/n,re=new Float64Array(n),im=new Float64Array(n);for(let i=0;i<n;i++)re[i]=(x[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(n-1)));gccFft(re,im,false);let a=Array.from({length:n/2},(_,i)=>Math.hypot(re[i+1],im[i+1])),max=Math.max(...a)||1;plot('raw_spectrum',a.map(v=>v/max),rawSnapshot.fs/2000,'\351\242\221\347\216\207(kHz)');text('raw_spectrum_note','\345\216\237\345\247\213CH'+$('raw_channel').value+'\357\274\2141024\347\202\271\345\216\273\345\235\207\345\200\274/Hann\347\252\227\357\274\233\351\242\221\347\216\207\351\227\264\351\232\224 '+num(rawSnapshot.fs/n,3)+' Hz\343\200\202\351\246\226\351\242\221\347\202\271 '+num(rawSnapshot.fs/n,3)+' Hz\357\274\214\351\235\236DC\357\274\233\347\233\270\345\257\271\345\271\205\345\200\274\357\274\214\344\270\215\346\230\257\345\243\260\345\216\213\343\200\201\345\242\236\345\274\272\350\276\223\345\207\272\346\210\226\350\257\212\346\226\255\345\214\205\347\273\234\350\260\261\343\200\202');}\n"
"function drawGcc(){if(!rawSnapshot)return;let r=rawSnapshot.gcc[Number($('gcc_select').value)];if(!r)return;let c=$('gcc_curve'),g=c.getContext('2d'),L=62,R=c.width-20,T=30,B=c.height-42,max=Math.max(...r.curve.map(Math.abs),1e-12);g.clearRect(0,0,c.width,c.height);g.font='12px system-ui';g.fillStyle='#a0b3c2';g.fillText('CH'+r.a+' / CH'+r.b+' GCC-PHAT\357\274\214200\342\200\2238000Hz\357\274\233\347\233\270\345\257\271\345\271\205\345\200\274',L,16);g.strokeStyle='#304352';for(let k=0;k<=4;k++){let x=L+(R-L)*k/4,y=T+(B-T)*k/4;g.beginPath();g.moveTo(x,T);g.lineTo(x,B);g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText(String(-64+k*32),x-10,B+18);g.fillText(num(max*(1-k/2),3),3,y+4);}g.fillText('B\347\233\270\345\257\271A\346\227\266\345\273\266\357\274\210\351\207\207\346\240\267\347\202\271\357\274\211',L+(R-L)/2-70,c.height-4);g.strokeStyle='#52d6c1';g.beginPath();r.curve.forEach((v,i)=>{let x=L+i/128*(R-L),y=(T+B)/2-v/max*(B-T)/2;i?g.lineTo(x,y):g.moveTo(x,y);});g.stroke();[['positive','#52d6c1'],['negative','#ffb454'],['absolute','#ff6174']].forEach(([name,color])=>{let p=r[name];if(!p)return;let x=L+(p.samples+64)/128*(R-L);g.strokeStyle=color;g.beginPath();g.moveTo(x,T);g.lineTo(x,B);g.stroke();});}\n"
"async function captureAll(){if(rawBusy)return;rawBusy=true;$('raw_capture').disabled=true;try{let buf=await get('/api/debug/raw',true),v=new DataView(buf);if(buf.byteLength!==18464||v.getUint32(0,true)!==0x43395231||v.getUint32(8,true)!==1024||v.getUint32(12,true)!==9)throw Error('\344\271\235\350\267\257\345\277\253\347\205\247\346\240\274\345\274\217\351\224\231\350\257\257');let fs=v.getUint32(4,true);if(!fs)throw Error('\351\207\207\346\240\267\347\216\207\346\227\240\346\225\210');let channels=Array.from({length:9},()=>[]);for(let i=0;i<1024;i++)for(let ch=0;ch<9;ch++)channels[ch].push(v.getInt16(32+18*i+2*ch,true));let gcc=gccAnalyze(channels,fs,c9ChannelPositions);rawSnapshot={source:'hardware_raw_pcm',received_utc:new Date().toISOString(),fs,first:v.getUint32(20,true),epoch:v.getUint32(24,true),session:v.getUint32(28,true),channels,gcc};\n"
" text('raw_meta','\344\271\235\350\267\257\345\220\214\345\270\247\345\216\237\345\247\213PCM\357\274\233Fs '+fs+' Hz\357\274\233\350\265\267\347\202\271 '+rawSnapshot.first+'\357\274\233epoch/session '+rawSnapshot.epoch+'/'+rawSnapshot.session+'\357\274\233\346\227\266\351\225\277 '+num(1024/fs*1000,4)+' ms\357\274\233\346\234\252\347\247\273\344\275\215\343\200\201\346\234\252\345\217\215\347\233\270\343\200\202\346\211\213\345\212\250\345\277\253\347\205\247\344\270\215\344\274\232\350\207\252\345\212\250\346\233\264\346\226\260\343\200\202');$('phase_groups').textContent='';for(let a=0;a<8;a+=2){let z=waveformStats(channels[a],channels[a+1]),tr=document.createElement('tr');['CH'+a+' / CH'+(a+1),z.r===null?'\346\227\240\350\203\275\351\207\217':num(z.r,6),num(z.a,3),num(z.b,3),'\347\233\270\345\205\263\346\200\247\344\270\215\345\215\225\347\213\254\350\257\201\346\230\216\344\270\244\351\272\246\347\213\254\347\253\213\346\210\226\346\225\205\351\232\234'].forEach(t=>{let td=document.createElement('td');td.textContent=t;tr.appendChild(td);});$('phase_groups').appendChild(tr);}\n"
" $('all_gcc').textContent='';$('gcc_select').textContent='';gcc.forEach((r,i)=>{let tr=document.createElement('tr');['CH'+r.a+' / CH'+r.b,num(r.distance_mm)+' mm / '+num(r.max_physical_samples,3)+' \347\202\271',gccEstimateText(r.positive),gccEstimateText(r.negative),gccEstimateText(r.absolute)].forEach(t=>{let td=document.createElement('td');td.textContent=t;tr.appendChild(td);});$('all_gcc').appendChild(tr);let o=document.createElement('option');o.value=i;o.textContent='CH'+r.a+' / CH'+r.b;$('gcc_select').appendChild(o);});$('gcc_select').value=0;rawSpectrum();drawGcc();\n"
" }catch(e){text('raw_meta','\350\257\273\345\217\226\345\244\261\350\264\245\357\274\214\344\277\235\347\225\231\344\270\212\346\254\241\345\277\253\347\205\247\344\276\233\345\233\236\347\234\213\357\274\232'+String(e));}finally{rawBusy=false;$('raw_capture').disabled=false;}}\n"
"$('raw_capture').onclick=captureAll;$('raw_save').onclick=()=>rawSnapshot&&download('nine_raw_pcm_gcc.json',JSON.stringify(rawSnapshot));$('raw_channel').onchange=rawSpectrum;$('gcc_select').onchange=drawGcc;\n"
"for(let i=0;i<9;i++){let o=document.createElement('option');o.value=i;o.textContent='CH'+i;$('raw_channel').appendChild(o);}\n"
"$('threshold_apply').onclick=()=>{let a=Number($('threshold_suspect').value),b=Number($('threshold_alarm').value),c=Number($('threshold_recover').value);if(![a,b,c].every(x=>Number.isInteger(x)&&x>=1&&x<=10000)||b<a){text('action_note','\346\254\241\346\225\260\351\241\273\344\270\2721\342\200\22310000\346\225\264\346\225\260\357\274\214\346\212\245\350\255\246\346\254\241\346\225\260\344\270\215\350\203\275\345\260\217\344\272\216\347\226\221\344\274\274\346\254\241\346\225\260');return;}control('/api/health9/config?suspect='+a+'&alarm='+b+'&recover='+c);};\n"
"plot('raw_spectrum',null,78.125,'\351\242\221\347\216\207(kHz)');plot('gcc_curve',null,64,'\346\227\266\345\273\266(\351\207\207\346\240\267\347\202\271)','\347\255\211\345\276\205\345\216\237\345\247\213PCM',true);\n"
"setInterval(()=>{let age=lastStatusReceipt?Date.now()-lastStatusReceipt:null;text('connection',paused?'\346\230\276\347\244\272\345\267\262\346\232\202\345\201\234\357\274\233\346\235\277\347\253\257\345\244\204\347\220\206\347\273\247\347\273\255':age===null?'\347\255\211\345\276\205\351\246\226\346\254\241\347\212\266\346\200\201\345\223\215\345\272\224':age>3000?'\350\277\236\346\216\245\350\277\207\346\234\237\357\274\214\346\230\276\347\244\272\345\216\206\345\217\262\346\225\260\346\215\256\357\274\233\350\267\235\346\234\200\350\277\221\345\223\215\345\272\224 '+num(age/1000,1)+' s':'\345\267\262\350\277\236\346\216\245\357\274\233\350\267\235\346\234\200\350\277\221\347\212\266\346\200\201\345\223\215\345\272\224 '+num(age/1000,1)+' s');},500);\n"
"\n"
"$('expected_delay').onclick=()=>{let v=['source_x','source_y','source_z'].map(id=>$(id).value.trim()===''?NaN:Number($(id).value)/1000);if(!rawSnapshot||!v.every(Number.isFinite)){text('expected_result','\350\257\267\345\205\210\350\257\273\345\217\226\345\220\214\346\255\245PCM\357\274\214\345\271\266\345\241\253\345\206\231\345\205\250\351\203\250XYZ\345\235\220\346\240\207');return;}text('expected_result',rawSnapshot.gcc.map(r=>{let distance=ch=>Math.hypot(...c9ChannelPositions[ch].map((q,k)=>q-v[k])),samples=(distance(r.b)-distance(r.a))*rawSnapshot.fs/343;return 'CH'+r.a+'/CH'+r.b+'\357\274\232\347\220\206\350\256\272 '+num(samples,3)+'\347\202\271 / '+num(samples*1e6/rawSnapshot.fs,2)+'us\357\274\233\347\273\235\345\257\271\345\263\260 '+(r.absolute?num(r.absolute.samples,3)+'\347\202\271':'\346\227\240');}).join('\\n'));};\n"
"var automaticPlotBusy=false,automaticPlotKey='',automaticPlotAt=0;\n"
"function plotRequestKey(){let c=selectedPlotCandidate(c9state);return c?[c9state.snapshot_session||0,c9state.snapshot_epoch||0,c9state.snapshot_first_sample||0,c9state.sequence,c.track_id].join('/'):'';}\n"
"async function automaticPreview(){\n"
" if(paused||automaticPlotBusy||guiPlotBusy||!$('auto_preview').checked||!c9state||!(c9state.candidates||[]).length||Date.now()-guiLastCandidate>3000)return;\n"
" let key=plotRequestKey();if(!key||key===automaticPlotKey||Date.now()-automaticPlotAt<1000)return;\n"
" automaticPlotBusy=true;automaticPlotAt=Date.now();try{if(await preview())automaticPlotKey=key;}finally{automaticPlotBusy=false;}\n"
"}\n"
"setInterval(automaticPreview,250);\n"
"\n"
"</script></main></body></html>\n";

/* 追加式格式化：放不下就返回 -1（而不是截断后照样发出去）。 */
static inline int ui_append(char *dst, int cap, int off, const char *fmt, ...)
{
    va_list ap;
    int n;
    int room = cap - off;

    if (room <= 1 || off < 0) {
        return -1;
    }
    va_start(ap, fmt);
    n = vsnprintf(dst + off, (size_t)room, fmt, ap);
    va_end(ap);
    if (n < 0 || n >= room) {     /* 截断了：整条作废，不留半句 JSON */
        return -1;
    }
    return off + n;
}

static inline void ui_status_clear(struct ui_status *s)
{
    memset(s, 0, sizeof *s);
}

/* 收下一帧结果。**先写结构体再给 have_result=1 的可见性**不是这里管的事：
 * 入参 s 是调用方自己的结构体 —— 站 15 的 CPU0 把 ipc_consume() 拷出来的**本地副本**
 * 交给这里，不是共享页指针，所以不存在并发读。
 * （原注写的是"单核裸机上……同一个 main 循环"，站 15 落地后已经是两个核，理由换成
 *  "私有副本"才仍然成立；结论没变。） */
static inline void ui_status_put(struct ui_status *s, const struct diag_result *r,
                                 unsigned frame, unsigned age_ms, int synthetic)
{
    s->r         = *r;
    s->frame     = frame;
    s->age_ms    = age_ms;
    s->synthetic = synthetic ? 1 : 0;
    s->have_result = 1;
}

/* ------------------------------------------------------------------------------------------
 * /api/status 的 JSON。字段名短，因为这个字符串每秒都要过一遍 TCP。
 *
 * 没有把串口那行 FDIAG 原样塞进来：那行的格式串只应该有一处（ps_output.h），
 * 在这里再写一遍就是第二处，改了那边不会报错、只会两边不一致。
 * ------------------------------------------------------------------------------------------ */
static inline int ui_audio_fields(char *dst,int cap,int off,const struct ui_status *s)
{
    unsigned i;
    if(s->input_mode) {
        off=ui_append(dst,cap,off,",\"input_mode\":%u,\"input_channels\":%u,\"input_error\":%d,\"received_blocks\":%u,\"pl_dropped\":%u,\"ps_dropped\":%u,\"discontinuities\":%u,\"computing\":%u",
            s->input_mode,s->input_channels,s->input_error,s->received_blocks,s->pl_dropped,s->ps_dropped,s->discontinuities,s->computing);
        if(off<0)return -1;
    }
    if(s->input_mode==2) {
        off=ui_append(dst,cap,off,",\"loc_enabled\":%u,\"loc_grid_w\":%u",s->mics.loc_enabled,s->mics.loc_grid_w);
        off=ui_append(dst,cap,off,",\"loc_compute_cycles\":%u,\"loc_total_cycles\":%u,\"loc_first_sample\":%u,\"loc_steer_status\":%u,\"loc_error\":%u",
            s->mics.loc_compute_cycles,s->mics.loc_total_cycles,s->mics.loc_first_sample,s->mics.loc_steer_status,s->mics.loc_error);
        off=ui_append(dst,cap,off,",\"loc_seq\":%u,\"loc_valid\":%u,\"loc_grid\":%u,\"loc_frame\":%u,\"loc_age_ms\":%u,\"loc_best\":%d,\"loc_second\":%d",
            s->mics.loc_seq,s->mics.loc_valid,s->mics.loc_grid,s->mics.loc_frame,s->mics.loc_age_ms,s->mics.loc_best,s->mics.loc_second);
        off=ui_append(dst,cap,off,",\"loc_quality_supported\":%u,\"loc_reason\":%u,\"loc_quality_permille\":%u,\"loc_raw_grid\":%u,\"loc_nonlocal\":%d,\"loc_accepted\":%u,\"loc_rejected\":%u,\"loc_score_per_pair\":%u",
            s->mics.loc_quality_supported,s->mics.loc_reason,s->mics.loc_quality_permille,s->mics.loc_raw_grid,
            s->mics.loc_nonlocal,s->mics.loc_accepted,s->mics.loc_rejected,s->mics.loc_score_per_pair);
        if(off<0)return -1;
    }
    off=ui_append(dst,cap,off,",\"mic_valid\":%u,\"mic_seq\":%u,\"mic_frozen\":%u",s->mics.valid,s->mics.seq,s->mics.frozen);
    if(off<0)return -1;
    for(i=0;i<4;i++) {
        const char *name=i==0?"mic_mean_ppm":i==1?"mic_rms_ppm":i==2?"mic_peak_ppm":"mic_clipped";
        unsigned j;off=ui_append(dst,cap,off,",\"%s\":[",name);if(off<0)return -1;
        for(j=0;j<(s->mics.channels?s->mics.channels:4);j++) {
            if(i==0)off=ui_append(dst,cap,off,"%s%d",j?",":"",s->mics.mean_ppm[j]);
            else off=ui_append(dst,cap,off,"%s%u",j?",":"",i==1?s->mics.rms_ppm[j]:i==2?s->mics.peak_ppm[j]:s->mics.clipped[j]);
            if(off<0)return -1;
        }
        off=ui_append(dst,cap,off,"]");if(off<0)return -1;
    }
    if(!s->audio.valid)return off;
    off=ui_append(dst,cap,off,",\"display_dsp\":1,\"mean_ppm\":%d,\"rms_ppm\":%u,\"peak_ppm\":%u,\"clipped_samples\":%u,\"spectrum_dc_ppm\":%u",
        s->audio.mean_ppm,s->audio.rms_ppm,s->audio.peak_ppm,s->audio.clipped_samples,s->audio.spectrum_dc_ppm);
    if(off<0)return -1;
    off=ui_append(dst,cap,off,",\"diag_ms\":%u,\"first_sample\":\"%llu\",\"sample_count\":%u,\"steer_seq\":%u,\"audio_flags\":%u,\"shaft_millihz\":%u,\"envelope\":[",
        s->diag_ms,(unsigned long long)s->audio.desc.first_sample,s->audio.desc.sample_count,
        s->audio.desc.steer_seq,s->audio.desc.flags,s->audio.shaft_millihz);
    if(off<0)return -1;
    for(i=0;i<DAS_PLOT_N;i++) {off=ui_append(dst,cap,off,"%s%u",i?",":"",s->audio.envelope[i]);if(off<0)return -1;}
    off=ui_append(dst,cap,off,"],\"spectrum\":[");if(off<0)return -1;
    for(i=0;i<DAS_PLOT_N;i++) {off=ui_append(dst,cap,off,"%s%u",i?",":"",s->audio.spectrum[i]);if(off<0)return -1;}
    return ui_append(dst,cap,off,"]");
}

static inline int ui_json(char *dst, int cap, const struct ui_status *s)
{
    int off = 0;
    int i;

    if (cap < 2) {
        return -1;
    }
    if (!s->have_result) {
        off = ui_append(dst, cap, 0, "{\"have\":0");
        if(off<0)return -1;
        off=ui_audio_fields(dst,cap,off,s);
        return off<0?-1:ui_append(dst,cap,off,"}\n");
    }

    off = ui_append(dst, cap, off,
                    "{\"have\":1,\"synthetic\":%d,\"frame\":%u,\"age_ms\":%u,"
                    "\"cls\":\"%s\",\"conf\":%d,\"votes\":[",
                    s->synthetic ? 1 : 0, s->frame, s->age_ms,
                    (s->r.cls >= 1 && s->r.cls <= CLF_N_CLASS) ? clf_class_names[s->r.cls - 1] : "unverified_model",
                    s->r.conf_pct);
    if (off < 0) {
        return -1;
    }
    for (i = 0; i < CLF_N_CLASS; i++) {
        off = ui_append(dst, cap, off, "%s%d", i ? "," : "", s->r.votes[i]);
        if (off < 0) {
            return -1;
        }
    }
    off = ui_append(dst, cap, off, "],\"grid_w\":%d", s->r.grid_w);
    if (off < 0) {
        return -1;
    }
    if (s->r.grid_w > 0) {
        off = ui_append(dst, cap, off, ",\"grid\":%d,\"gx\":%d,\"gy\":%d,\"azim\":%d",
                        s->r.grid, s->r.gx, s->r.gy, s->r.azim_pct);
    } else {
        off = ui_append(dst, cap, off, ",\"grid\":-1,\"gx\":-1,\"gy\":-1,\"azim\":0");
    }
    if (off < 0) {
        return -1;
    }
    off = ui_append(dst, cap, off, ",\"sev\":%d,\"med\":%d", s->r.sev_pct, s->r.med_milli);
    if(off<0)return -1;
    off=ui_audio_fields(dst,cap,off,s);
    return off<0?-1:ui_append(dst,cap,off,"}\n");
}

/* ------------------------------------------------------------------------------------------
 * 路由。请求**整行**（"GET /api/status?x=1 HTTP/1.1"）进来，body 写进调用方的缓冲区。
 *
 * 只认三个路径，其余一律 404 —— /favicon.ico 走这里，浏览器不会因为拿到 404 就不显示页面。
 * 与 ps_net.c 的 path_is 同一条规则：精确匹配，或后面跟 '?' / ' '，所以
 * "/api/statusx" 不会被当成 "/api/status"。
 * ------------------------------------------------------------------------------------------ */
static inline int ui_path_is(const char *req_line, const char *want)
{
    const char *p = strchr(req_line, ' ');
    size_t n;

    if (p == NULL) {
        return 0;
    }
    p++;
    n = strlen(want);
    if (strncmp(p, want, n) != 0) {
        return 0;
    }
    return (p[n] == '\0' || p[n] == '?' || p[n] == ' ');
}

static inline struct ui_reply ui_route(const char *req_line, const struct ui_status *s,
                                       char *body, int cap)
{
    struct ui_reply rep;
    int len;

    if (ui_path_is(req_line, "/")) {
        len = (int)strlen(UI_PAGE_HTML);
        if (len >= cap) {
            rep.code = 500; rep.reason = "Internal Server Error";
            rep.ctype = "text/plain"; rep.len = 0;
            return rep;
        }
        memcpy(body, UI_PAGE_HTML, (size_t)len);
        rep.code = 200; rep.reason = "OK";
        rep.ctype = "text/html; charset=utf-8"; rep.len = len;
        return rep;
    }

    if (ui_path_is(req_line, "/api/status")) {
        len = ui_json(body, cap, s);
        if (len < 0) {
            rep.code = 500; rep.reason = "Internal Server Error";
            rep.ctype = "text/plain"; rep.len = 0;
            return rep;
        }
        rep.code = 200; rep.reason = "OK";
        rep.ctype = "application/json"; rep.len = len;
        return rep;
    }

    rep.code = 404; rep.reason = "Not Found";
    rep.ctype = "text/plain"; rep.len = 0;
    return rep;
}

#endif /* PS_UI_PAGE_H */
