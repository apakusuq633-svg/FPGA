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

#define UI_BODY_MAX   40960   /* 页面与 JSON 的上限；超了报 500，不截断服务 */

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
"<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>&#22768;&#23398;&#30417;&#27979;</title><style>\n"
"*{box-sizing:border-box}body{margin:0;background:#101820;color:#e5edf4;font:14px/1.5 system-ui}main{max-width:1050px;margin:auto;padding:24px}h1{margin:0}h2{font-size:17px}.muted{color:#a0b3c2}.bar,.card{padding:18px;background:#182530;border:1px solid #304352;border-radius:10px}.bar{margin:18px 0}.layout{display:grid;grid-template-columns:1fr 1fr;gap:16px}.wide{grid-column:1/-1}table{width:100%}td{padding:7px;border-bottom:1px solid #304352}td:last-child{text-align:right}.plot{position:relative;aspect-ratio:1;max-width:300px;margin:15px auto;border:1px solid #a0b3c2;background:linear-gradient(0deg,#304352 1px,transparent 1px),linear-gradient(90deg,#304352 1px,transparent 1px)}#dot{display:none;position:absolute;width:12px;height:12px;background:#52d6c1;border-radius:50%;transform:translate(-50%,-50%)}.empty{padding:30px 8px;border:1px dashed #526674;text-align:center;color:#a0b3c2}.warn{color:#ffd17c}button{background:#304352;color:white;border:1px solid #526674;border-radius:5px;padding:8px;cursor:pointer}#err{color:#ffacac;min-height:22px}canvas{width:100%;height:auto;background:#101820;border:1px solid #304352}@media(max-width:650px){.layout{grid-template-columns:1fr}main{padding:12px}}\n"
"</style></head><body><main><h1>&#22768;&#23398;&#25925;&#38556;&#30417;&#27979;</h1><div class=\"muted\">&#22768;&#28304;&#23450;&#20301;&#19982;&#38899;&#39057;&#35786;&#26029;</div>\n"
"<div class=\"bar\"><strong id=\"state\">&#27491;&#22312;&#36830;&#25509;&#8230;</strong><div id=\"source\">&#36755;&#20837;&#26469;&#28304;&#65306;&#31561;&#24453;&#25968;&#25454;</div><div id=\"age\"></div><button id=\"pause\">&#26242;&#20572;&#26174;&#31034;</button> <button id=\"save\">&#20445;&#23384;&#24555;&#29031;</button><div id=\"err\" role=\"status\"></div></div>\n"
"<div class=\"layout\"><section class=\"card\"><h2>&#22768;&#28304;&#23450;&#20301;</h2><div id=\"position\">&#26242;&#26080;&#23450;&#20301;&#32467;&#26524;</div><div class=\"plot\" id=\"scan\"><svg id=\"trail\" viewBox=\"0 0 100 100\" style=\"position:absolute;inset:0;width:100%;height:100%;pointer-events:none\"></svg><span id=\"dot\"></span></div><div class=\"muted\">X&#65306;-200 &#33267; +200 mm&#65288;&#20174;&#24038;&#21040;&#21491;&#65289;<br>Y&#65306;-200 &#33267; +200 mm&#65288;&#20174;&#19979;&#21040;&#19978;&#65289;&#65307;Z = 300 mm</div><p class=\"warn\">&#24403;&#21069;&#20165;&#26174;&#31034;&#23450;&#20301;&#28857;&#65292;&#23436;&#25972; SRP &#28909;&#21147;&#22270;&#23578;&#26410;&#25509;&#20837;&#12290;</p><p class=\"muted\"><span id=\"association\">&#31561;&#24453;&#19982;&#38899;&#39057;&#23545;&#24212;&#30340;&#23450;&#20301;&#25968;&#25454;&#12290;</span></p></section>\n"
"<section class=\"card\"><h2>&#35786;&#26029;&#32467;&#26524;</h2><table id=\"diagnosis\"></table><p class=\"muted\">&#25237;&#31080;&#27604;&#20363;&#34920;&#31034;&#27169;&#22411;&#30340;&#19968;&#33268;&#24615;&#65292;&#24403;&#21069;&#19981;&#20195;&#34920;&#23454;&#38469;&#25925;&#38556;&#20005;&#37325;&#31243;&#24230;&#12290;</p></section>\n"
"<section class=\"card\"><h2>DAS &#22686;&#24378;&#38899;&#39057;&#39057;&#35889;</h2><canvas id=\"spectrum_plot\" width=\"460\" height=\"180\"></canvas><div id=\"spectrum_note\" class=\"muted\"></div><p class=\"muted\">&#32437;&#36724;&#20026;&#30456;&#23545;&#24133;&#20540;&#65292;&#23578;&#26410;&#25509;&#20837;&#21442;&#32771;&#40614;&#20811;&#39118;&#23545;&#29031;&#12290;</p></section>\n"
"<section class=\"card\"><h2>&#21253;&#32476;&#35889;</h2><canvas id=\"envelope_plot\" width=\"460\" height=\"180\"></canvas><div id=\"envelope_note\" class=\"muted\"></div><p class=\"muted\">&#36733;&#39057;&#24102; 1400&#8211;4600 Hz&#65307;&#27599;&#27573; 1.024 &#31186;&#65307;&#36716;&#39057;&#30001;&#20154;&#24037;&#35774;&#32622;&#12290;</p></section>\n"
"<section class=\"card wide\"><h2>&#36816;&#34892;&#29366;&#24577;</h2><table id=\"runtime\"></table><div class=\"muted\">&#20002;&#22833;&#37327;&#20197;&#37319;&#26679;&#28857;&#35745;&#65292;&#35786;&#26029;&#32791;&#26102;&#21253;&#21547;&#39057;&#35889;&#35745;&#31639;&#12290;&#23436;&#25972; SRP &#28909;&#21147;&#22270;&#21450;&#23450;&#20301;&#32791;&#26102;&#23578;&#24453;&#25509;&#20837;&#12290;</div></section></div>\n"
"<section class=\"card\"><h2>&#38899;&#39057;&#30005;&#24179;&#19982;&#30452;&#27969;&#20998;&#37327;</h2><table id=\"levels\"></table><p class=\"muted\">&#30005;&#24179;&#20197;&#28385;&#37327;&#31243;&#30334;&#20998;&#27604;&#34920;&#31034;&#65307;&#21066;&#27874;&#25968;&#32479;&#35745;&#36755;&#20986;&#27573; 40000 &#20010;&#37319;&#26679;&#28857;&#20013;&#36798;&#21040;&#37327;&#31243;&#31471;&#28857;&#30340;&#25968;&#37327;&#12290;</p></section>\n"
"<section class=\"card\"><h2>&#40614;&#20811;&#39118;&#36755;&#20837;</h2><table id=\"mics\"></table><p id=\"mic_note\" class=\"muted\">J3 &#25968;&#25454;&#24341;&#33050;&#65306;CH0=34&#12289;CH1=32&#12289;CH2=33&#12289;CH3=35&#12290;&#30005;&#24179;&#26469;&#33258;&#29420;&#31435;&#30340; 1024 &#28857;&#23450;&#20301;&#24555;&#29031;&#65292;&#20301;&#20110; PL &#21435;&#30452;&#27969;&#20043;&#21518;&#12289;DAS &#20043;&#21069;&#12290;CH0=&#21491;&#19978; / CH1=&#24038;&#19978; / CH2=&#24038;&#19979; / CH3=&#21491;&#19979; (&#29031;&#29255;&#35270;&#35282;)</p></section>\n"
"<section class=\"card\"><h2>原始多通道校准</h2><button id=\"raw_button\" onclick=\"captureRaw()\">下载同步原始快照</button><p id=\"raw_note\" class=\"muted\">每路1024点，约26.2毫秒；用于通道核对和校准，请让声源保持稳定。</p></section>\n"
"<script>\n"
"async function captureRaw(){var b=document.getElementById('raw_button'),note=document.getElementById('raw_note');b.disabled=true;try{note.textContent='正在获取同步原始快照，定位短暂停顿，音频继续输出。';var r=await fetch('/api/raw/start',{cache:'no-store'});if(r.status!==202)throw Error('请求未接受，请确认配套固件且没有其他采集任务');for(var k=0;k<30;k++){await new Promise(function(resolve){setTimeout(resolve,100)});r=await fetch('/api/raw',{cache:'no-store'});if(r.status===200){var blob=await r.blob(),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='microphones_'+Date.now()+'.raw';a.click();setTimeout(function(){URL.revokeObjectURL(url)},1000);note.textContent='同步快照已下载：含采样率、采样起点和各通道 int16 数据。';return}if(r.status!==202)throw Error('快照超时或无效，请重试')}throw Error('等待快照超时')}catch(e){note.textContent=e.message}finally{b.disabled=false}}\n"

"var latest=null,paused=false;function el(id){return document.getElementById(id)}function row(k,v){var tr=document.createElement('tr');[k,v].forEach(function(t){var td=document.createElement('td');td.textContent=t;tr.appendChild(td)});el('diagnosis').appendChild(tr)}\n"
"function renderBase(s){el('diagnosis').textContent='';el('dot').style.display='none';el('position').textContent='\\u6682\\u65e0\\u5b9a\\u4f4d\\u7ed3\\u679c';el('source').textContent=s.have?(s.synthetic?'\\u8f93\\u5165\\uff1a\\u5408\\u6210\\u81ea\\u6d4b\\u97f3\\u9891':'\\u8f93\\u5165\\uff1a\\u5b9e\\u65f6\\u91c7\\u96c6'):'\\u8f93\\u5165\\u6765\\u6e90\\uff1a\\u5c1a\\u65e0\\u7ed3\\u679c';el('age').textContent=s.have?'\\u5e27\\u53f7 #'+s.frame+' | \\u7ed3\\u679c\\u8ddd\\u4eca\\uff1a'+s.age_ms+' ms':'';el('state').textContent=!s.have?'\\u7b49\\u5f85\\u9996\\u4e2a\\u7ed3\\u679c':s.age_ms>3000?'\\u7ed3\\u679c\\u5df2\\u8fc7\\u671f\\uff08\\u663e\\u793a\\u9608\\u503c 3 \\u79d2\\uff09':'\\u7ed3\\u679c\\u5df2\\u66f4\\u65b0';if(!s.have)return;row('\\u6545\\u969c\\u7c7b\\u522b',({'normal':'\\u6b63\\u5e38','outer':'\\u5916\\u5708\\u6545\\u969c','inner':'\\u5185\\u5708\\u6545\\u969c','ball':'\\u6eda\\u52a8\\u4f53\\u6545\\u969c'}[s.cls]||s.cls));row('\\u6a21\\u578b\\u6295\\u7968\\u6bd4\\u4f8b',s.conf+' %');row('\\u6295\\u7968\\uff08\\u6b63\\u5e38 / \\u5916\\u5708 / \\u5185\\u5708 / \\u6eda\\u52a8\\u4f53\\uff09',s.votes.join(' / '));if(s.grid_w>1&&s.grid>=0&&s.grid<s.grid_w*s.grid_w&&s.gx>=0&&s.gx<s.grid_w&&s.gy>=0&&s.gy<s.grid_w){el('scan').style.backgroundSize=(100/(s.grid_w-1))+'% '+(100/(s.grid_w-1))+'%';var x=-200+400*s.gx/(s.grid_w-1),y=-200+400*s.gy/(s.grid_w-1);el('position').textContent='X '+x.toFixed(1)+' mm, Y '+y.toFixed(1)+' mm | '+s.grid_w+' x '+s.grid_w+' \\u7f51\\u683c';el('dot').style.left=(100*s.gx/(s.grid_w-1))+'%';el('dot').style.top=(100-100*s.gy/(s.grid_w-1))+'%';el('dot').style.display='block'}}\n"
"function runtimeRow(k,v){var tr=document.createElement('tr');[k,v].forEach(function(t){var td=document.createElement('td');td.textContent=t;tr.appendChild(td)});el('runtime').appendChild(tr)}\n"
"function plot(id,data){var c=el(id),g=c.getContext('2d');g.clearRect(0,0,c.width,c.height);if(!data||!data.length)return;g.strokeStyle='#52d6c1';g.beginPath();data.forEach(function(v,i){var x=8+i*(c.width-16)/(data.length-1),y=c.height-8-Math.max(0,Math.min(1000,v))*(c.height-16)/1000;if(i)g.lineTo(x,y);else g.moveTo(x,y)});g.stroke()}\n"
"function render(s){renderBase(s);el('runtime').textContent='';\n"
" el('source').textContent='\\u8f93\\u5165\\uff1a'+(s.input_mode==1?'\\u5408\\u6210\\u97f3\\u9891\\u5757\\u56de\\u653e':s.input_mode==2?'PL DAS/FIR FIFO':'\\u672a\\u914d\\u7f6e')+(s.input_channels?' | '+s.input_channels+' \\u8def\\u9ea6\\u514b\\u98ce':'')+(s.have?' | \\u7ed3\\u679c\\uff1a'+(s.synthetic?'\\u5408\\u6210':'\\u5b9e\\u65f6'):'');\n"
" if(s.input_error)el('state').textContent='\\u97f3\\u9891\\u8f93\\u5165\\u9519\\u8bef\\uff1a'+s.input_error;\n"
" [['\\u5df2\\u63a5\\u6536\\u97f3\\u9891\\u5757',s.received_blocks],['PL / \\u6570\\u636e\\u6e90\\u4e22\\u5931\\u91c7\\u6837\\u70b9',s.pl_dropped],['PS \\u4e22\\u5931\\u91c7\\u6837\\u70b9',s.ps_dropped],['\\u97f3\\u9891\\u6bb5\\u91cd\\u7f6e\\u6b21\\u6570',s.discontinuities],['CPU1 \\u6b63\\u5728\\u8ba1\\u7b97',s.computing],['\\u8bca\\u65ad\\u8017\\u65f6\\uff08ms\\uff09',s.diag_ms]].forEach(function(v){runtimeRow(v[0],v[1]===undefined?'\\u672a\\u63d0\\u4f9b':v[1])});\n"
" plot('envelope_plot',s.envelope);plot('spectrum_plot',s.spectrum);\n"
" el('envelope_note').textContent=s.envelope?'0\\u2013605.6 Hz\\uff1b\\u9891\\u7387\\u95f4\\u9694 4.7684 Hz\\uff1b\\u8f6c\\u9891 '+s.shaft_millihz/1000+' Hz\\uff08\\u4eba\\u5de5\\u8bbe\\u7f6e\\uff09':'\\u7b49\\u5f85\\u5305\\u7edc\\u8c31';\n"
" el('spectrum_note').textContent=s.spectrum?'0\\u201319.53 kHz\\uff1b\\u6bcf 32 \\u4e2a\\u9891\\u70b9\\u53d6\\u6700\\u5927\\u503c\\uff1b\\u76f8\\u5bf9\\u5e45\\u503c':'\\u7b49\\u5f85\\u97f3\\u9891\\u9891\\u8c31';\n"
" el('association').textContent=s.first_sample!==undefined?'\\u4f1a\\u8bdd\\u8d77\\u59cb\\u91c7\\u6837\\u70b9 '+s.first_sample+'\\uff1b\\u6bb5\\u957f '+s.sample_count+((s.audio_flags&16)?'\\uff1bPL FIFO \\u5c1a\\u672a\\u63d0\\u4f9b\\u5b9a\\u4f4d\\u4e0e\\u6ce2\\u675f\\u6307\\u5411\\u7684\\u5bf9\\u5e94\\u6570\\u636e':'\\uff1b\\u6ce2\\u675f\\u6307\\u5411\\u5e8f\\u53f7 '+s.steer_seq+(s.synthetic?'\\u3002\\u5b9a\\u4f4d\\u6765\\u81ea\\u5408\\u6210\\u56de\\u653e\\u5143\\u6570\\u636e\\u3002':'\\u3002\\u5b9a\\u4f4d\\u968f\\u97f3\\u9891\\u8bb0\\u5f55\\u3002')):'\\u6682\\u65e0\\u97f3\\u9891\\u4e0e\\u5b9a\\u4f4d\\u5bf9\\u5e94\\u6570\\u636e';\n"
" function cell(id,k,v){var tr=document.createElement('tr');[k,v].forEach(function(t){var td=document.createElement('td');td.textContent=t;tr.appendChild(td)});el(id).appendChild(tr)}function fs(v){return v===undefined?'\\u672a\\u63d0\\u4f9b':(v/10000).toFixed(4)+' %FS'}\n"
" el('levels').textContent='';[['\\u97f3\\u9891\\u6bb5\\u5747\\u503c',s.mean_ppm],['\\u6709\\u6548\\u503c RMS',s.rms_ppm],['\\u5cf0\\u503c',s.peak_ppm],['\\u539f\\u59cb\\u7a97\\u5185\\u76f4\\u6d41\\u5206\\u91cf\\uff080 Hz\\uff09',s.spectrum_dc_ppm]].forEach(function(p){cell('levels',p[0],fs(p[1]))});cell('levels','\\u524a\\u6ce2\\u91c7\\u6837\\u70b9',s.clipped_samples===undefined?'\\u672a\\u63d0\\u4f9b':s.clipped_samples);\n"
"\n"
" if(s.input_channels===12){el('mic_note').textContent=\"12 \\u8def\\uff0c6 \\u6839\\u5171\\u7ebf DATA\\uff0c66 \\u4e2a\\u9ea6\\u5bf9\\uff1b\\u76f8\\u90bb\\u4e09\\u4e2a\\u5782\\u76f4\\u9762\\u5404 4 \\u9ea6\\u3002\\u5c3a\\u5bf8\\u4e0e\\u9ea6\\u4f4d\\u5f85\\u56fe\\u7eb8\\uff0c\\u5f53\\u524d\\u53ea\\u8fd0\\u884c\\u91c7\\u96c6\\u548c\\u7b49\\u6743 DAS\\uff0c\\u4e09\\u7ef4\\u5b9a\\u4f4d\\u5c1a\\u672a\\u542f\\u7528\\u3002\";}\n"
" if(s.input_channels===16){el('mic_note').textContent='16 \\u8def\\uff0c\\u4e24\\u9ea6\\u5171\\u7ebf\\uff1aCH(2k) \\u4e0e CH(2k+1) \\u5171\\u7528 DINk\\uff0c\\u5206\\u522b\\u4e3a L/R=GND \\u4e0e VDD\\u3002'+(s.loc_enabled?'120 \\u5bf9\\u5b9a\\u4f4d\\uff0c32\\xd732 \\u7f51\\u683c\\uff0c\\u81ea\\u52a8\\u8f6c\\u5411 DAS\\uff1b\\u9635\\u5217\\u4f4d\\u7f6e\\u6682\\u6309\\u534a\\u5f84 50 mm \\u5706\\u9635\\uff0c\\u5b9e\\u7269\\u6620\\u5c04\\u5f85\\u786e\\u8ba4\\u3002':'\\u5f53\\u524d\\u4e3a\\u6b63\\u524d\\u65b9\\u56fa\\u5b9a DAS\\uff0c16 \\u8def\\u7b49\\u6743\\u5e73\\u5747\\uff1b\\u5b9a\\u4f4d\\u5c1a\\u672a\\u542f\\u7528\\u3002');}\n"
" el('mics').textContent='';for(var i=0;i<(s.input_channels||4);i++)cell('mics','CH'+i,s.mic_valid?((s.mic_frozen&(1<<i))?'\\u65e0 PDM \\u6d3b\\u52a8':'\\u6709 PDM \\u6d3b\\u52a8')+' | RMS '+fs(s.mic_rms_ppm[i])+' | \\u5cf0\\u503c '+fs(s.mic_peak_ppm[i])+' | \\u5747\\u503c '+fs(s.mic_mean_ppm[i])+' | \\u524a\\u6ce2\\u6570 '+s.mic_clipped[i]:'\\u7b49\\u5f85 PL \\u5feb\\u7167');\n"
" if(s.display_dsp==1){el('envelope_note').textContent='4.7684\\u2013605.6 Hz\\uff1b\\u5df2\\u4fee\\u6b63\\u663e\\u793a\\u5305\\u7edc\\uff1b\\u8f6c\\u9891 '+s.shaft_millihz/1000+' Hz\\uff08\\u4eba\\u5de5\\u8bbe\\u7f6e\\uff09\\u3002\\u5206\\u7c7b\\u5668\\u4fdd\\u6301\\u4e0e\\u8bad\\u7ec3\\u4e00\\u81f4\\u7684\\u5904\\u7406\\u6d41\\u7a0b\\u3002';el('spectrum_note').textContent='0 Hz \\u5206\\u91cf\\u5355\\u72ec\\u5217\\u51fa\\uff1b\\u6bcf\\u7ec4 32 \\u4e2a\\u9891\\u70b9\\uff1b\\u76f8\\u5bf9\\u5e45\\u503c'}\n"
"}\n"
"\n"
"\n"
"var track=[],shown=null,lastLoc=0,lastGood=0,pending=null;\n"
"function renderLocation(s){\n"
" if(s.input_mode===2&&s.input_channels===12&&!s.loc_enabled){el('dot').style.display='none';el('trail').textContent='';el('position').textContent=\"12 \\u9ea6\\u51e0\\u4f55\\u5f85\\u56fe\\u7eb8\\uff0c\\u4e09\\u7ef4\\u5b9a\\u4f4d\\u672a\\u542f\\u7528\";return;}\n"
" if(s.input_mode!==2)return;if(s.input_channels===16&&!s.loc_enabled){el('dot').style.display='none';el('trail').textContent='';el('position').textContent='\\u56fa\\u5b9a\\u6b63\\u524d\\u65b9 DAS\\uff0c\\u5b9a\\u4f4d\\u672a\\u542f\\u7528';el('association').textContent='16 \\u9ea6\\u7b2c\\u4e00\\u9636\\u6bb5\\uff1a\\u91c7\\u96c6\\u4e0e\\u56fa\\u5b9a DAS \\u901a\\u8def\\u9a8c\\u8bc1\\u3002';return;}\n"
" var w=s.loc_grid_w||16,now=Date.now(),good=s.loc_valid&&s.loc_age_ms<=3000&&s.loc_grid>=0&&s.loc_grid<w*w;\n"
" if(now-lastGood>1500){shown=null;pending=null;}\n"
" if(good&&s.loc_seq!==lastLoc){\n"
"  lastLoc=s.loc_seq;\n"
"  var p={x:s.loc_grid%w*100/(w-1),y:100-Math.floor(s.loc_grid/w)*100/(w-1),t:now};\n"
"  if(!s.loc_quality_supported&&shown&&Math.hypot(p.x-shown.x,p.y-shown.y)>30){\n"
"   if(!pending||Math.hypot(p.x-pending.x,p.y-pending.y)>15){pending=p;p=null;}\n"
"  }else pending=null;\n"
"  if(p){pending=null;shown=shown?{x:shown.x*.55+p.x*.45,y:shown.y*.55+p.y*.45}:p;lastGood=now;track.push({x:shown.x,y:shown.y,t:now});}\n"
" }\n"
" track=track.filter(function(p){return now-p.t<5000}).slice(-30);\n"
" var svg=el('trail');svg.textContent='';\n"
" track.forEach(function(p,i){var c=document.createElementNS('http://www.w3.org/2000/svg','circle');c.setAttribute('cx',p.x);c.setAttribute('cy',p.y);c.setAttribute('r',1);c.setAttribute('fill','#52d6c1');c.setAttribute('opacity',.1+.5*(1-(now-p.t)/5000));svg.appendChild(c)});\n"
" var held=shown&&now-lastGood<=1500;\n"
" el('dot').style.display=held?'block':'none';\n"
" if(held){el('dot').style.left=shown.x+'%';el('dot').style.top=shown.y+'%';el('dot').style.opacity=good&&!pending?'1':'.45';}\n"
" el('scan').style.backgroundSize=(100/(w-1))+'% '+(100/(w-1))+'%';\n"
" el('position').textContent=held?'\\u663e\\u793a\\u5b9a\\u4f4d\\uff1aX '+(-200+shown.x*4).toFixed(1)+' mm\\uff0cY '+(200-shown.y*4).toFixed(1)+' mm'+(good&&!pending?'':'\\uff08\\u4fdd\\u7559\\u6700\\u8fd1\\u6709\\u6548\\u4f4d\\u7f6e\\uff09'):'\\u7b49\\u5f85\\u6709\\u6548\\u5b9a\\u4f4d';\n"
" el('association').textContent='\\u9875\\u9762\\u8f6e\\u8be2 10 Hz\\uff1b\\u8f68\\u8ff9\\u4fdd\\u7559 5 \\u79d2\\uff1b\\u4f4d\\u7f6e\\u7ecf\\u8fc7\\u663e\\u793a\\u5e73\\u6ed1\\u3002\\u72ec\\u7acb\\u5b9a\\u4f4d\\u4e0e\\u97f3\\u9891\\u6bb5\\u5c1a\\u672a\\u540c\\u6b65\\u3002\\u5e8f\\u53f7 '+(s.loc_frame||0)+'\\uff1b\\u66f4\\u65b0\\u8ddd\\u4eca '+(s.loc_age_ms||0)+' ms\\u3002';\n"
" if(s.input_channels===16){el('association').textContent+=' \\u5b9a\\u4f4d\\u8ba1\\u7b97 '+((s.loc_compute_cycles||0)/40000).toFixed(1)+' ms\\uff1bDAS '+(s.loc_error?'\\u5b9a\\u4f4d\\u5f02\\u5e38 '+s.loc_error:(s.loc_steer_status&16)?'\\u5df2\\u9501\\u5b9a':'\\u7b49\\u5f85\\u65b9\\u5411\\u786e\\u8ba4')+'\\u3002';}\n"
" if(s.loc_quality_supported){var why=(s.loc_reason&1)?'\\u67d0\\u8def\\u4f4e\\u7535\\u5e73':(s.loc_reason&2)?'\\u8f93\\u5165\\u524a\\u6ce2':(s.loc_reason&4)?'\\u76f8\\u5173\\u5cf0\\u504f\\u5f31':(s.loc_reason&8)?'\\u7a7a\\u95f4\\u5cf0\\u4e0d\\u660e\\u786e':(s.loc_reason&32)?'校准快照暂停':(s.loc_reason&16)?'\\u7b49\\u5f85\\u8fde\\u7eed\\u786e\\u8ba4':'\\u5df2\\u786e\\u8ba4';el('association').textContent+=' \\u5b9a\\u4f4d\\u72b6\\u6001\\uff1a'+why+'\\uff1b\\u5cf0\\u503c\\u5206\\u79bb '+((s.loc_quality_permille||0)/10).toFixed(1)+'%\\uff08\\u975e\\u6b63\\u786e\\u7387\\uff09\\uff1b\\u901a\\u8fc7/\\u62d2\\u7edd '+(s.loc_accepted||0)+'/'+(s.loc_rejected||0);if(s.loc_raw_grid>=0&&s.loc_raw_grid<w*w)el('association').textContent+='\\uff1b\\u5019\\u9009\\u683c '+s.loc_raw_grid+' / \\u786e\\u8ba4\\u683c '+s.loc_grid;}\n"
"}\n"
"var fetching=false;async function poll(){if(paused||fetching)return;fetching=true;try{var r=await fetch('/api/status',{cache:'no-store'});if(!r.ok)throw Error('HTTP '+r.status);var s=await r.json();latest=s;if(!paused){render(s);renderLocation(s);}el('err').textContent=''}catch(e){el('state').textContent='\\u8fde\\u63a5\\u5f02\\u5e38\\uff0c\\u4fdd\\u7559\\u4e0a\\u6b21\\u7ed3\\u679c';el('err').textContent=String(e)}finally{fetching=false}}\n"
"el('pause').onclick=function(){paused=!paused;this.textContent=paused?'\\u7ee7\\u7eed\\u663e\\u793a':'\\u6682\\u505c\\u663e\\u793a';if(paused)el('state').textContent='\\u663e\\u793a\\u5df2\\u6682\\u505c\\uff08\\u91c7\\u96c6\\u7ee7\\u7eed\\uff09';else poll()};el('save').onclick=function(){if(!latest){el('err').textContent='\\u6682\\u65e0\\u53ef\\u4fdd\\u5b58\\u7684\\u5feb\\u7167';return}var blob=new Blob([JSON.stringify({saved_at:new Date().toISOString(),status:latest},null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='acoustic-snapshot.json';a.click();setTimeout(function(){URL.revokeObjectURL(url)},1000)};poll();setInterval(poll,100);\n"
"var c9busy = false, c9candidateAt = 0, c9lastCandidatesOk = 0, c9candidates = null;\n"
"var c9hiddenSections = [], c9changedText = [];\n"
"function c9live(s) { return !!(s && s.input_channels === 9 && s.input_mode === 2); }\n"
"function c9text(node, text) {\n"
"  if (!node) return;\n"
"  if (!c9changedText.some(function(p) {return p.node === node;})) c9changedText.push({node:node,text:node.textContent});\n"
"  node.textContent = text;\n"
"}\n"
"function c9legacyPanels(hide) {\n"
"  if (!hide) {\n"
"    c9hiddenSections.forEach(function(p) {p.node.hidden = p.hidden;});c9hiddenSections = [];\n"
"    c9changedText.forEach(function(p) {p.node.textContent = p.text;});c9changedText = [];\n"
"    if (el('c9section')) el('c9section').hidden = true;\n"
"    return;\n"
"  }\n"
"  ['position','diagnosis','spectrum_plot','envelope_plot','raw_button'].forEach(function(id) {\n"
"    var node = el(id), section = node && node.closest('section');\n"
"    if (section && !c9hiddenSections.some(function(p) {return p.node === section;})) {\n"
"      c9hiddenSections.push({node:section,hidden:section.hidden});section.hidden = true;\n"
"    }\n"
"  });\n"
"  if (el('c9section')) el('c9section').hidden = false;\n"
"  var levelSection = el('levels') && el('levels').closest('section');\n"
"  c9text(levelSection && levelSection.querySelector('h2'), '\\u5404\\u65b9\\u5411\\u5206\\u79bb\\u97f3\\u9891\\u7535\\u5e73');\n"
"  c9text(levelSection && levelSection.querySelector('.muted'), 'RMS \\u6765\\u81ea\\u5bf9\\u5e94\\u8f68\\u8ff9\\u7684 1.024 \\u79d2\\u5206\\u79bb\\u97f3\\u9891\\uff1b\\u4ee5\\u6ee1\\u91cf\\u7a0b\\u767e\\u5206\\u6bd4\\u8868\\u793a\\u3002\\u8fc7\\u671f\\u7ed3\\u679c\\u4ec5\\u4f9b\\u56de\\u770b\\uff0c\\u4e0d\\u80fd\\u4f5c\\u4e3a\\u5f53\\u524d\\u6545\\u969c\\u65b9\\u5411\\u3002');\n"
"  var runtimeSection = el('runtime') && el('runtime').closest('section');\n"
"  c9text(runtimeSection && runtimeSection.querySelector('.muted'), 'CPU0 \\u6301\\u7eed\\u91c7\\u96c6\\u5e76\\u8bfb\\u53d6 FPGA \\u5b9a\\u4f4d\\uff1bCPU1 \\u5728\\u540c\\u4e00\\u539f\\u59cb\\u5feb\\u7167\\u4e0a\\u5206\\u79bb\\u5019\\u9009\\u65b9\\u5411\\uff0c\\u518d\\u6267\\u884c\\u8bca\\u65ad\\u3002\\u5b9a\\u4f4d\\u5ef6\\u8fdf\\u548c\\u8bca\\u65ad\\u89c2\\u5bdf\\u65f6\\u95f4\\u5206\\u522b\\u7edf\\u8ba1\\u3002');\n"
"  c9text(el('mic_note'), '9 \\u8def\\u540c\\u6b65\\u8f93\\u5165\\uff0c5 \\u6839\\u5171\\u4eab DATA\\uff1b\\u5916\\u5708 8 \\u9ea6\\u52a0\\u4e2d\\u5fc3 1 \\u9ea6\\u3002\\u4ee5\\u4e0b\\u4e3a\\u5404\\u901a\\u9053\\u7684 PDM \\u6d3b\\u52a8\\u53ca\\u8f93\\u5165\\u5feb\\u7167\\u7535\\u5e73\\uff0c\\u901a\\u9053\\u987a\\u5e8f\\u3001\\u51e0\\u4f55\\u548c\\u6807\\u5b9a\\u987b\\u6309\\u5b9e\\u7269\\u9a8c\\u6536\\u3002');\n"
"}\n"
"function c9status(s) {\n"
"  if (!c9live(s)) return;\n"
"  var state = c9candidates;\n"
"  el('source').textContent = '\\u8f93\\u5165\\uff1a9 \\u9ea6\\u540c\\u6b65 PDM\\uff1bFPGA \\u65b9\\u5411\\u5b9a\\u4f4d \\u2192 PS \\u5019\\u9009\\u5206\\u79bb\\u4e0e\\u8bca\\u65ad';\n"
"  el('state').textContent = s.input_error ? '\\u97f3\\u9891\\u8f93\\u5165\\u9519\\u8bef\\uff1a' + s.input_error :\n"
"    !state ? '\\u91c7\\u96c6\\u4e2d\\uff0c\\u7b49\\u5f85\\u65b9\\u5411\\u4e0e\\u8bca\\u65ad\\u63a5\\u53e3' : (state.candidates || []).length ? '\\u65b9\\u5411\\u5019\\u9009\\u4e0e\\u8bca\\u65ad\\u5df2\\u66f4\\u65b0' : '\\u91c7\\u96c6\\u4e2d\\uff0c\\u7b49\\u5f85\\u7a33\\u5b9a\\u5019\\u9009\\u65b9\\u5411';\n"
"  el('age').textContent = state ? '\\u8bca\\u65ad\\u5feb\\u7167 #' + state.sequence + ' | \\u6536\\u5230\\u8ddd\\u4eca\\uff1a' + state.result_age_ms + ' ms' : '';\n"
"  el('runtime').textContent = '';\n"
"  [['\\u5df2\\u63a5\\u6536\\u97f3\\u9891\\u5757',s.received_blocks],['PL / \\u6570\\u636e\\u6e90\\u4e22\\u5931\\u91c7\\u6837\\u70b9',s.pl_dropped],['PS \\u4e22\\u5931\\u91c7\\u6837\\u70b9',s.ps_dropped],\n"
"    ['\\u97f3\\u9891\\u6bb5\\u91cd\\u7f6e\\u6b21\\u6570',s.discontinuities],['CPU1 \\u6b63\\u5728\\u5206\\u79bb / \\u8bca\\u65ad',s.computing],\n"
"    ['\\u6700\\u8fd1\\u5019\\u9009\\u5206\\u79bb\\u4e0e\\u8bca\\u65ad\\u5904\\u7406\\u8017\\u65f6\\uff08ms\\uff09',state ? state.processing_ms : '\\u7b49\\u5f85\\u9996\\u4e2a\\u5019\\u9009\\u5feb\\u7167'],\n"
"    ['\\u8bca\\u65ad\\u89c2\\u5bdf\\u7a97\\uff08ms\\uff09',1024]].forEach(function(v) {runtimeRow(v[0],v[1] === undefined ? '\\u672a\\u63d0\\u4f9b' : v[1]);});\n"
"  var table = el('levels');table.textContent = '';\n"
"  (state && state.candidates || []).forEach(function(c) {\n"
"    var d = c.diagnosis || {}, tr = document.createElement('tr');\n"
"    ['\\u8f68\\u8ff9 ' + c.track_id + (c.stale ? '\\uff08\\u8fc7\\u671f\\uff09' : ''),\n"
"      Number.isFinite(d.rms) ? (d.rms * 100).toFixed(4) + ' %FS RMS' : '\\u7b49\\u5f85\\u5206\\u79bb\\u97f3\\u9891'].forEach(function(v) {\n"
"      var td = document.createElement('td');td.textContent = v;tr.appendChild(td);\n"
"    });table.appendChild(tr);\n"
"  });\n"
"  if (!table.childNodes.length) {\n"
"    var tr = document.createElement('tr'), td = document.createElement('td');td.textContent = '\\u7b49\\u5f85\\u5019\\u9009\\u65b9\\u5411\\u7684\\u5206\\u79bb\\u97f3\\u9891';tr.appendChild(td);table.appendChild(tr);\n"
"  }\n"
"}\n"
"/* Keep legacy DOM nodes for the shared renderer; only the live nine-mic path\n"
" * substitutes the newer direction/candidate panels and data source. */\n"
"var c9legacyRender = render, c9legacyRenderLocation = renderLocation;\n"
"render = function(s) {\n"
"  if (!c9live(s) && c9hiddenSections.length) c9legacyPanels(false);\n"
"  c9legacyRender(s);\n"
"  if (c9live(s)) {c9legacyPanels(true);c9status(s);}\n"
"};\n"
"renderLocation = function(s) {if (!c9live(s)) c9legacyRenderLocation(s);};\n"
"function c9angle(mdeg) { return Number.isFinite(mdeg) ? (mdeg / 1000).toFixed(2) + '\\u00b0' : '\\u672a\\u77e5'; }\n"
"function c9fault(c, state) {\n"
"  return !!(c.diagnosis && c.diagnosis.fault_direction_valid && c.diagnosis.binding &&\n"
"    c.diagnosis.binding.track_id === c.track_id && c.diagnosis.binding.grid === c.grid &&\n"
"    c.diagnosis.model_version === state.model_version && c.stable && c.separation_ready && !c.stale &&\n"
"    state.geometry_confirmed && state.calibration_version && state.model_validated);\n"
"}\n"
"function c9candidateView(state) {\n"
"  var proposals = el('c9proposals');proposals.textContent = '';\n"
"  var stages = {1:'\\u5df2\\u8fde\\u7eed\\u89c2\\u6d4b',2:'\\u77ed\\u6682\\u7f3a\\u6d4b\\uff0c\\u4fdd\\u7559\\u8eab\\u4efd\\u5e76\\u6682\\u505c\\u6545\\u969c\\u5b9a\\u5411',3:'\\u6b63\\u5728\\u6062\\u590d\\u786e\\u8ba4'};\n"
"  (state.proposals || []).forEach(function(p) {\n"
"    var line = document.createElement('p');\n"
"    line.textContent = '\\u5019\\u9009\\u8f68\\u8ff9 ' + p.track_id + '\\uff1a\\u6c34\\u5e73\\u89d2 ' + c9angle(p.azimuth_mdeg) +\n"
"      '\\uff0c\\u4fef\\u4ef0\\u89d2 ' + c9angle(p.elevation_mdeg) + '\\uff1b' + (stages[p.track_state] || '\\u65b9\\u5411\\u5f85\\u786e\\u8ba4') +\n"
"      (p.angle_refined ? '\\uff1b\\u5df2\\u5c40\\u90e8\\u62df\\u5408\\uff0c\\u5b9e\\u9645\\u7cbe\\u5ea6\\u5f85\\u5b9e\\u6d4b' : '');\n"
"    proposals.appendChild(line);\n"
"  });\n"
"  var list = el('c9candidates');list.textContent = '';\n"
"  (state.candidates || []).forEach(function(c) {\n"
"    var d = c.diagnosis || {}, item = document.createElement('p');\n"
"    var names = {normal:'\\u6b63\\u5e38',fault:'\\u6545\\u969c',interference:'\\u5e72\\u6270',anomaly:'\\u5f02\\u5e38\\uff08\\u672a\\u786e\\u8ba4\\u6545\\u969c\\uff09',unknown:'\\u672a\\u77e5'};\n"
"    var fault = c9fault(c, state), label = fault ? '\\u6545\\u969c\\u65b9\\u5411\\u5df2\\u786e\\u8ba4' :\n"
"      d.label === 'fault' ? '\\u65b9\\u5411\\u8bca\\u65ad\\u5f85\\u91cd\\u65b0\\u786e\\u8ba4' : names[d.label] || '\\u672a\\u77e5';\n"
"    item.style.color = fault ? '#dc2626' : d.label === 'normal' ? '#15803d' : 'inherit';\n"
"    item.textContent = '\\u8f68\\u8ff9 ' + c.track_id + '\\uff1a\\u65b9\\u4f4d\\u89d2 ' + c9angle(c.azimuth_mdeg) +\n"
"      '\\uff0c\\u4fef\\u4ef0\\u89d2 ' + c9angle(c.elevation_mdeg) + '\\uff1b' + label +\n"
"      '\\uff1b' + (c.stale ? '\\u8f68\\u8ff9\\u5df2\\u8fc7\\u671f' : c.stable ? '\\u8f68\\u8ff9\\u7a33\\u5b9a' : '\\u65b9\\u5411\\u5f85\\u7a33\\u5b9a') +\n"
"      '\\uff1b' + (c.separation_ready ? '\\u5df2\\u6709\\u5b9a\\u5411\\u5206\\u79bb\\u97f3\\u9891' : '\\u5206\\u79bb\\u6761\\u4ef6\\u5f85\\u6ee1\\u8db3') +\n"
"      (d.reason && d.reason !== 'ok' ? '\\uff1b\\u8bca\\u65ad\\u72b6\\u6001 ' + d.reason : '');\n"
"    var button = document.createElement('button');button.textContent = '\\u62fe\\u53d6\\u6b64\\u65b9\\u5411';\n"
"    button.disabled = !!c.stale;\n"
"    button.onclick = function() {\n"
"      fetch('/api/target?grid=' + c.grid, {cache:'no-store'})\n"
"        .then(function(r) { if (!r.ok) throw Error('\\u76ee\\u6807\\u9009\\u62e9\\u5931\\u8d25'); })\n"
"        .catch(function(e) { el('c9gsc').textContent = String(e); });\n"
"    };\n"
"    item.appendChild(document.createTextNode(' '));item.appendChild(button);list.appendChild(item);\n"
"  });\n"
"  if (!(state.candidates || []).length) list.textContent = '\\u7b49\\u5f85\\u6ee1\\u8db3\\u65b9\\u5411\\u4e0e\\u8f93\\u5165\\u8d28\\u91cf\\u6761\\u4ef6\\u7684\\u5019\\u9009\\u58f0\\u6e90\\u3002';\n"
"  el('c9model').textContent = 'PS \\u8bca\\u65ad\\u6a21\\u578b\\uff1a' + (!state.model_version ? '\\u672a\\u914d\\u7f6e\\uff0c\\u7ed3\\u679c\\u4fdd\\u6301\\u672a\\u77e5' :\n"
"    '\\u7248\\u672c ' + state.model_version + (state.model_validated ? '\\uff0c\\u5df2\\u901a\\u8fc7\\u6307\\u5b9a\\u6d4b\\u8bd5\\u57df\\u9a8c\\u6536' : '\\uff0c\\u5c1a\\u672a\\u9a8c\\u6536\\uff0c\\u4ec5\\u4f9b\\u8bd5\\u9a8c')) +\n"
"    '\\u3002\\u8f6c\\u901f\\uff1a' + (state.shaft_confirmed ? ((state.shaft_millihz || 0) * 0.06).toFixed(0) + ' rpm\\uff08\\u4eba\\u5de5\\u8bbe\\u7f6e\\u6216\\u8f6c\\u901f\\u8f93\\u5165\\uff09' : '\\u672a\\u786e\\u8ba4') +\n"
"    '\\u3002\\u8bca\\u65ad\\u5feb\\u7167 ' + state.sequence + '\\uff1b\\u5904\\u7406 ' + state.processing_ms + ' ms\\uff1b\\u7ed3\\u679c\\u5e74\\u9f84 ' + state.result_age_ms + ' ms\\u3002';\n"
"  c9status(latest);\n"
"}\n"
"async function c9view() {\n"
"  if (paused || c9busy || !c9live(latest)) return;\n"
"  c9busy = true;\n"
"  try {\n"
"    if (!el('c9map')) {\n"
"      var box = document.createElement('section');\n"
"      box.id = 'c9section';box.className = 'card';\n"
"      box.innerHTML = '<h3>9 \\u9ea6\\u65b9\\u5411\\u70ed\\u529b\\u56fe\\u4e0e\\u58f0\\u6e90\\u8bca\\u65ad</h3><p>\\u6a2a\\u8f74\\uff1a\\u65b9\\u4f4d\\u89d2 \\u221290\\u00b0 \\u2192 +90\\u00b0\\uff1b\\u7eb5\\u8f74\\uff1a\\u4fef\\u4ef0\\u89d2 \\u221290\\u00b0 \\u2192 +90\\u00b0\\u30020\\u00b0 \\u6307\\u5411\\u9635\\u5217\\u6b63\\u524d\\u65b9\\uff1b\\u672c\\u56fe\\u4e0d\\u626b\\u63cf\\u8ddd\\u79bb\\u3002</p>' +\n"
"        '<canvas id=\"c9map\" width=\"320\" height=\"320\"></canvas><p>\\u84dd\\u81f3\\u9ec4\\u8868\\u793a\\u5b9a\\u4f4d\\u8bc4\\u5206\\uff1b\\u7ea2\\u6846\\u4ec5\\u8868\\u793a\\u5df2\\u786e\\u8ba4\\u7684\\u6545\\u969c\\u65b9\\u5411\\u3002\\u70b9\\u51fb\\u7f51\\u683c\\u53ef\\u624b\\u52a8\\u5b9a\\u5411\\u62fe\\u97f3\\u3002</p>' +\n"
"        '<p id=\"c9note\"></p><div id=\"c9proposals\"></div><p id=\"c9model\"></p><div id=\"c9candidates\"></div><p id=\"c9gsc\"></p>' +\n"
"        '<button id=\"c9on\">\\u542f\\u7528\\u81ea\\u9002\\u5e94\\u62fe\\u97f3</button> <button id=\"c9off\">\\u539f\\u59cb\\u5b9a\\u5411\\u62fe\\u97f3</button> ' +\n"
"        '<button id=\"c9freeze\">\\u51bb\\u7ed3\\u66f4\\u65b0</button> <button id=\"c9adapt\">\\u7ee7\\u7eed\\u66f4\\u65b0</button> ' +\n"
"        '<button id=\"c9auto\">\\u8ddf\\u8e2a\\u6700\\u5f3a\\u5b9a\\u4f4d\\u5cf0</button> <button id=\"c9faultauto\">\\u8ddf\\u8e2a\\u5df2\\u8bca\\u65ad\\u6545\\u969c\\u65b9\\u5411</button>' +\n"
"        '<p><label>\\u5b9e\\u9645\\u8f6c\\u901f rpm <input id=\"c9rpm\" type=\"number\" min=\"600\" max=\"1800\" value=\"1500\" step=\"1\"></label> <button id=\"c9rpmset\">\\u786e\\u8ba4\\u5b9e\\u9645\\u8f6c\\u901f</button></p>';\n"
"      var main = document.querySelector('main');main.insertBefore(box, main.querySelector('.layout'));\n"
"      var timing = document.createElement('p');timing.id = 'c9latency';box.appendChild(timing);\n"
"      ['auto','faultauto'].forEach(function(k) {\n"
"        el('c9' + k).onclick = function() {\n"
"          fetch('/api/target/' + (k === 'auto' ? 'auto' : 'fault'), {cache:'no-store'})\n"
"            .then(function(r) {if (!r.ok) throw Error('\\u76ee\\u6807\\u6a21\\u5f0f\\u8bbe\\u7f6e\\u5931\\u8d25');})\n"
"            .catch(function(e) {el('c9gsc').textContent = String(e);});\n"
"        };\n"
"      });\n"
"      el('c9rpmset').onclick = function() {\n"
"        var rpm = Number(el('c9rpm').value);\n"
"        if (!Number.isInteger(rpm) || rpm < 600 || rpm > 1800) {el('c9model').textContent = '\\u8bf7\\u8f93\\u5165\\u5b9e\\u9645\\u8f6c\\u901f\\uff0c\\u8303\\u56f4 600\\u20131800 rpm\\u3002';return;}\n"
"        fetch('/api/rpm?value=' + rpm, {cache:'no-store'})\n"
"          .then(function(r) {if (!r.ok) throw Error('\\u8f6c\\u901f\\u8bbe\\u7f6e\\u5931\\u8d25');c9candidateAt = 0;})\n"
"          .catch(function(e) {el('c9model').textContent = String(e);});\n"
"      };\n"
"      el('c9map').onclick = async function(e) {\n"
"        var r = this.getBoundingClientRect(), x = Math.floor((e.clientX - r.left) * 32 / r.width), y = 31 - Math.floor((e.clientY - r.top) * 32 / r.height);\n"
"        if (x < 0 || x > 31 || y < 0 || y > 31) return;\n"
"        try {\n"
"          var q = await fetch('/api/target?grid=' + (y * 32 + x), {cache:'no-store'});\n"
"          if (!q.ok) throw Error('\\u76ee\\u6807\\u9009\\u62e9\\u5931\\u8d25');\n"
"          el('c9gsc').textContent = '\\u5df2\\u7533\\u8bf7\\u624b\\u52a8\\u5b9a\\u5411\\u62fe\\u97f3\\uff0c\\u4ecd\\u9700\\u901a\\u8fc7\\u51e0\\u4f55\\u548c\\u8f93\\u5165\\u8d28\\u91cf\\u68c0\\u67e5\\u3002';\n"
"        } catch (err) {el('c9gsc').textContent = String(err);}\n"
"      };\n"
"      ['on','off','freeze','adapt'].forEach(function(k) {\n"
"        el('c9' + k).onclick = function() {\n"
"          fetch('/api/gsc/' + k, {cache:'no-store'}).catch(function(e) {el('c9gsc').textContent = String(e);});\n"
"        };\n"
"      });\n"
"    }\n"
"    if (Date.now() - c9candidateAt >= 500) {\n"
"      var cr = await fetch('/api/candidates', {cache:'no-store'});\n"
"      if (cr.ok) {c9candidates = await cr.json();c9lastCandidatesOk = Date.now();c9candidateView(c9candidates);}\n"
"      c9candidateAt = Date.now();\n"
"    }\n"
"    var r = await fetch('/api/heatmap', {cache:'no-store'});\n"
"    if (r.status === 200) {\n"
"      var m = await r.json(), v = m.scores;\n"
"      if (v && v.length === 1024) {\n"
"        var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), g = el('c9map').getContext('2d');\n"
"        for (var i = 0; i < 1024; i++) {\n"
"          var t = hi > lo ? (v[i] - lo) / (hi - lo) : 0;\n"
"          g.fillStyle = 'hsl(' + (240 - 180 * t) + ',85%,45%)';\n"
"          g.fillRect(i % 32 * 10, (31 - Math.floor(i / 32)) * 10, 10, 10);\n"
"        }\n"
"        if (c9candidates) (c9candidates.candidates || []).forEach(function(c) {\n"
"          if (c.stale || c.grid < 0 || c.grid >= 1024) return;\n"
"          var px = Number.isFinite(c.azimuth_mdeg) ? (c.azimuth_mdeg / 1000 + 90) * 320 / 180 : c.grid % 32 * 10 + 5;\n"
"          var py = Number.isFinite(c.elevation_mdeg) ? (90 - c.elevation_mdeg / 1000) * 320 / 180 : (31 - Math.floor(c.grid / 32)) * 10 + 5;\n"
"          g.strokeStyle = c9fault(c, c9candidates) ? '#ff0000' : '#ffffff';g.lineWidth = 2;\n"
"          g.strokeRect(px - 4, py - 4, 8, 8);\n"
"          g.fillStyle = '#ffffff';g.font = '12px sans-serif';\n"
"          g.fillText(String(c.track_id), px + 5, py + 4);\n"
"        });\n"
"        el('c9note').textContent = (m.accepted ? '\\u5df2\\u901a\\u8fc7\\u5b9a\\u4f4d\\u5224\\u5b9a' : '\\u5019\\u9009\\u65b9\\u5411\\u56fe\\uff0c\\u5c1a\\u672a\\u901a\\u8fc7\\u5b9a\\u4f4d\\u5224\\u5b9a') +\n"
"          '\\uff1b\\u524d\\u534a\\u7a7a\\u95f4\\u89d2\\u5ea6\\u626b\\u63cf\\uff1b\\u5e27 ' + m.frame + '\\u3002\\u5b9a\\u4f4d\\u5cf0\\u8868\\u793a\\u58f0\\u97f3\\u65b9\\u5411\\uff0c\\u4e0d\\u76f4\\u63a5\\u8868\\u793a\\u6545\\u969c\\u3002';\n"
"      }\n"
"    }\n"
"    var q = await fetch('/api/gsc', {cache:'no-store'});\n"
"    if (q.ok) {\n"
"      var z = await q.json();\n"
"      el('c9latency').textContent = '\\u9996\\u4e2a PCM \\u2192 PS \\u9996\\u6b21\\u6536\\u5230\\u5b9a\\u4f4d\\u7ed3\\u679c\\uff1a\\u76ee\\u6807 ' +\n"
"        (z.single_window_deadline_us / 1000).toFixed(2) + ' ms\\uff1b' +\n"
"        (z.latency_samples ? '\\u672c\\u6b21 ' + (z.pcm_to_ps_us / 1000).toFixed(3) +\n"
"          ' ms\\uff0c\\u6700\\u5927 ' + (z.pcm_to_ps_max_us / 1000).toFixed(3) +\n"
"          ' ms\\uff0cP95/P99 \\u4e0a\\u754c ' + (z.pcm_to_ps_p95_upper_us / 1000).toFixed(3) +\n"
"          '/' + (z.pcm_to_ps_p99_upper_us / 1000).toFixed(3) +\n"
"          ' ms\\uff1b\\u8d85\\u65f6 ' + z.deadline_misses + '/' + z.latency_samples +\n"
"          ' \\u5e27\\uff1b\\u672a\\u8bfb\\u5230\\u7684\\u53d1\\u5e03 ' + z.skipped_publications : '\\u7b49\\u5f85\\u9996\\u6b21\\u7ed3\\u679c') +\n"
"        '\\u3002' + (z.location_stale ? '\\u5f53\\u524d\\u7ed3\\u679c\\u5df2\\u8fc7\\u671f\\u3002' : '') +\n"
"        ' \\u8bca\\u65ad\\u91c7\\u7528\\u72ec\\u7acb\\u7684 1.024 \\u79d2\\u89c2\\u5bdf\\u7a97\\u3002\\u6574\\u94fe\\u8def\\u5b9e\\u7269\\u9a8c\\u6536\\uff1a' + (z.board_validated ? '\\u5df2\\u5b8c\\u6210' : '\\u672a\\u5b8c\\u6210');\n"
"      el('c9gsc').textContent = (!z.geometry_confirmed || !z.calibration_version ?\n"
"        '\\u9635\\u5217\\u51e0\\u4f55\\u6216\\u6807\\u5b9a\\u5f85\\u9a8c\\u6536\\uff0c\\u81ea\\u9002\\u5e94\\u8f93\\u51fa\\u65c1\\u8def\\u3002' : '\\u81ea\\u9002\\u5e94\\u62fe\\u97f3\\u72b6\\u6001 ' + z.gsc_reason + '\\u3002') +\n"
"        ' \\u8fde\\u7eed\\u5f55\\u97f3\\uff1aUDP 1234\\uff1b\\u5df2\\u53d1\\u9001 ' + z.udp_sent + ' \\u5305\\uff1b\\u91c7\\u96c6\\u4e22\\u6837 ' + z.dma_drops;\n"
"    }\n"
"  } catch (e) {\n"
"    if (el('c9note')) el('c9note').textContent = '\\u65b9\\u5411\\u6216\\u8bca\\u65ad\\u8bfb\\u53d6\\u5931\\u8d25\\uff1a' + String(e);\n"
"  } finally {c9busy = false;}\n"
"}\n"
"setInterval(c9view, 100);\n"
"setInterval(function() {\n"
"  if (c9candidates && Date.now() - c9lastCandidatesOk > 2000) {\n"
"    c9candidates = null;\n"
"    if (el('c9candidates')) el('c9candidates').textContent = '\\u5019\\u9009\\u8bca\\u65ad\\u8fde\\u63a5\\u5df2\\u8fc7\\u671f\\uff0c\\u7b49\\u5f85\\u5237\\u65b0\\u3002';\n"
"    c9status(latest);\n"
"  }\n"
"}, 500);\n"
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
    if(!s->audio.valid)return off;
    off=ui_append(dst,cap,off,",\"display_dsp\":1,\"mean_ppm\":%d,\"rms_ppm\":%u,\"peak_ppm\":%u,\"clipped_samples\":%u,\"spectrum_dc_ppm\":%u",
        s->audio.mean_ppm,s->audio.rms_ppm,s->audio.peak_ppm,s->audio.clipped_samples,s->audio.spectrum_dc_ppm);
    if(off<0)return -1;
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
