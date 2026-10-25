'use strict';
// Browser-only display/analysis. No classifier, feature extractor or PL control
// algorithm is replaced by this file. All inputs carry snapshot/track identity.
var latest=null, paused=false, c9busy=false, c9state=null, c9health=null;
var guiSequence=0,guiTrack=0,guiSession=null,guiHistory=[],guiEvents=new Map(),guiTrails=new Map();
var guiHealthCursor=0,guiEventCursor=0,guiPreviewToken=0,guiLastCandidate=0,guiLastHealth=0;
const $=id=>document.getElementById(id);
const labels=['未知','正常','故障','干扰','异常（未确认故障）'];
const states=['正常监测','疑似异常','故障/异常报警','恢复观察'];
const reasonNames={ok:'有效',no_model:'尚未配置模型',bad_model:'模型契约不匹配',bad_input:'转速或输入无效',bad_binding:'方向/分离关联条件不足',silent:'低电平',rejected:'模型拒识',unvalidated:'模型未经验证',clipped:'输入削顶',unseen_separation_filter:'分离频带未获模型验证',no_carrier:'共振带能量不足'};
function text(id,v){if($(id))$(id).textContent=v;}
function line(table,k,v){let r=document.createElement('tr');[k,v].forEach(s=>{let c=document.createElement('td');c.textContent=s;r.appendChild(c);});table.appendChild(r);}
function rows(id,data){$(id).textContent='';data.forEach(r=>line($(id),r[0],r[1]));}
function num(x,d=2){return Number.isFinite(x)?x.toFixed(d):'未提供';}
function angle(x){return Number.isFinite(x)?num(x/1000)+'°':'未知';}
function download(name,data,type='application/json'){let u=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);}
async function get(path,binary=false){let controller=new AbortController(),timer=setTimeout(()=>controller.abort(),2500);try{let r=await fetch(path,{cache:'no-store',signal:controller.signal});if(r.status===202)return null;if(!r.ok)throw Error(path+'：HTTP '+r.status);return binary?await r.arrayBuffer():await r.json();}finally{clearTimeout(timer);}}
async function control(path){try{await get(path);text('action_note','设置已提交，是否生效以后台状态为准。');}catch(e){text('action_note',String(e));}}
function validFault(c,s){return !!(c.diagnosis&&c.diagnosis.fault_direction_valid&&!c.stale&&c.stable&&c.separation_ready&&s.geometry_confirmed&&s.calibration_version&&s.model_validated&&c.diagnosis.binding.track_id===c.track_id&&c.diagnosis.model_version===s.model_version);}
function plot(id,values,xmax,xlabel,ylabel='相对幅值（峰值=1）',signed=false){
 let c=$(id),g=c.getContext('2d'),L=62,R=c.width-18,T=25,B=c.height-42;g.clearRect(0,0,c.width,c.height);g.font='13px system-ui';g.fillStyle='#a0b3c2';g.fillText(ylabel,L,16);
 g.strokeStyle='#304352';g.lineWidth=1;
 for(let k=0;k<=4;k++){let y=T+(B-T)*k/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText((signed?1-k/2:1-k/4).toFixed(2),8,y+4);let x=L+(R-L)*k/4;g.beginPath();g.moveTo(x,T);g.lineTo(x,B);g.stroke();g.fillText(num(xmax*k/4,xmax<10?2:0),x-12,B+19);}
 g.fillText(xlabel,(L+R)/2-35,c.height-4);
 if(!values||!values.length){g.fillText('等待有效快照',L+40,T+50);return;}
 g.strokeStyle='#52d6c1';g.beginPath();values.forEach((v,i)=>{let x=L+i*(R-L)/(values.length-1),y=signed?(T+B)/2-v*(B-T)/2:B-v*(B-T);if(i)g.lineTo(x,y);else g.moveTo(x,y);});g.stroke();
}
function renderStatus(s){latest=s;text('source','9麦同步PDM → PL方向定位 → PS多候选分离与诊断');
 text('state',s.input_error?'采集错误 '+s.input_error:'持续采集中；分类有效性见候选与监测状态');
 rows('runtime',[['旧单路音频块（九麦不使用）',s.received_blocks],['PL丢失采样点',s.pl_dropped],['PS丢失采样点',s.ps_dropped],['CPU1忙',s.computing],['诊断观察窗','1024 ms；更新间隔512 ms'],['采样率','156250 Hz原始 / 39062.5 Hz诊断']]);
 $('mics').textContent='';for(let i=0;i<9;i++)line($('mics'),'CH'+i,s.mic_valid?'AC RMS '+num((s.mic_rms_ppm||[])[i]/10000,4)+' %FS；峰值 '+num((s.mic_peak_ppm||[])[i]/10000,4)+' %FS；均值 '+num((s.mic_mean_ppm||[])[i]/10000,4)+' %FS；削顶 '+((s.mic_clipped||[])[i]??'未提供'):'等待通道快照');
}
function renderCandidates(s){c9state=s;guiLastCandidate=Date.now();
 const chosen=Number($('candidate_select').value)||guiTrack;
 $('candidate_select').textContent='';$('candidates').textContent='';
 (s.candidates||[]).forEach((c,i)=>{let o=document.createElement('option');o.value=c.track_id;o.textContent='轨迹 '+c.track_id+' / '+angle(c.azimuth_mdeg);$('candidate_select').appendChild(o);
  let d=c.diagnosis||{},p=document.createElement('p');p.className=validFault(c,s)?'alarm':'muted';p.textContent='轨迹 '+c.track_id+'：水平角 '+angle(c.azimuth_mdeg)+'，俯仰角 '+angle(c.elevation_mdeg)+'；'+(c.stale?'已过期':c.stable?'稳定':'待稳定')+'；'+(d.label||'unknown')+'；'+(reasonNames[d.reason]||d.reason||'等待诊断');let b=document.createElement('button');b.textContent='拾取此方向';b.disabled=!!c.stale;b.onclick=()=>control('/api/target?grid='+c.grid);p.appendChild(b);$('candidates').appendChild(p);
 });
 if((s.candidates||[]).some(c=>c.track_id===chosen))$('candidate_select').value=chosen;
 text('model_note','模型版本 '+s.model_version+'；'+(s.model_validated?'已验证':'未验证/未配置，保持未知')+'；'+(s.shaft_confirmed?'已确认转速 '+num(s.shaft_millihz*.06,0)+' rpm':'转速未确认')+'；快照 #'+s.sequence+'，年龄 '+s.result_age_ms+' ms');
 if(!(s.candidates||[]).length){text('candidates','尚无覆盖完整1.024秒的稳定诊断方向；下列仅为定位提议，不是故障结果。');(s.proposals||[]).forEach(p=>{let el=document.createElement('p');el.className='muted';el.textContent='提议轨迹 '+p.track_id+'：水平角 '+angle(p.azimuth_mdeg)+'，俯仰角 '+angle(p.elevation_mdeg)+'；观察次数 '+p.observations;$('candidates').appendChild(el);});}
 const c=(s.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));renderDiagnosis(c,s);
}
function renderDiagnosis(c,s){if(!c){rows('diagnosis',[['状态','等待候选诊断']]);return;}let d=c.diagnosis||{};
 rows('diagnosis',[['轨迹',c.track_id],['方向',angle(c.azimuth_mdeg)+' / '+angle(c.elevation_mdeg)],['类别',c.stale?'过期结果（仅供回看）':({normal:'正常',fault:'故障',interference:'干扰',anomaly:'异常',unknown:'未知'}[d.label]||'未知')],['有效性',reasonNames[d.reason]||d.reason],['模型距离间隔（非概率）',num(d.margin,4)],['故障方向确认',validFault(c,s)?'已确认':'未确认']]);
 rows('levels',[['分离音频RMS',num(d.rms*100,4)+' %FS'],['载频带RMS',num((d.extraction||{}).carrier_rms*100,4)+' %FS'],['调制RMS',num((d.extraction||{}).modulation_rms*100,4)+' %FS'],['削顶点数',d.clipped_samples],['载频带','2200–4600 Hz（C9F2）']]);
 $('features').textContent='';(d.features||[]).forEach((v,i)=>line($('features'),'特征 '+(i+1),num(v,5)));
 if(guiSequence!==s.sequence||guiTrack!==c.track_id){guiSequence=s.sequence;guiTrack=c.track_id;text('plot_note','选中轨迹发生变化；点击“获取同快照波形”更新，旧波形已清除。');plot('spectrum_plot',null,19.53125,'频率(kHz)');plot('envelope_plot',null,900,'频率(Hz)');}
}
function renderMap(m){if(!m||!m.scores||m.scores.length!==1024){text('map_note','等待完整评分图；此前图像仅供回看，不代表当前定位。');return;}let c=$('direction_map'),g=c.getContext('2d'),L=54,T=18,W=320,H=320;g.clearRect(0,0,c.width,c.height);let lo=Math.min(...m.scores),hi=Math.max(...m.scores);
 m.scores.forEach((v,i)=>{let t=hi>lo?(v-lo)/(hi-lo):0;g.fillStyle='hsl('+(240-180*t)+',85%,45%)';g.fillRect(L+i%32*10,T+(31-Math.floor(i/32))*10,10,10);});
 g.fillStyle='#a0b3c2';g.font='12px system-ui';[-90,-45,0,45,90].forEach(a=>{g.fillText(a+'°',L+(a+90)*W/180-10,T+H+19);g.fillText(a+'°',8,T+(90-a)*H/180+4);});g.fillText('水平角（正前方0°）',L+72,T+H+39);g.fillText('俯仰角',3,12);
 const now=Date.now();(c9state&&c9state.proposals||[]).forEach(p=>{let trail=guiTrails.get(p.track_id)||[];if(trail.length===0||trail.at(-1).sequence!==p.observations)trail.push({x:p.azimuth_mdeg/1000,y:p.elevation_mdeg/1000,t:guiLastCandidate,sequence:p.observations});guiTrails.set(p.track_id,trail.slice(-60));});
 guiTrails.forEach((trail,id)=>{trail=trail.filter(p=>now-p.t<=5000);if(!trail.length){guiTrails.delete(id);return;}guiTrails.set(id,trail);g.strokeStyle='#ffffff70';g.beginPath();trail.forEach((p,i)=>{let x=L+(p.x+90)*W/180,y=T+(90-p.y)*H/180;i?g.lineTo(x,y):g.moveTo(x,y);});g.stroke();});
 (c9state&&c9state.candidates||[]).forEach(p=>{if(p.stale)return;let x=L+(p.azimuth_mdeg/1000+90)*W/180,y=T+(90-p.elevation_mdeg/1000)*H/180;g.strokeStyle=validFault(p,c9state)?'#ff6174':'white';g.strokeRect(x-5,y-5,10,10);g.fillStyle='white';g.fillText('轨迹 '+p.track_id,x+6,y);});
 text('map_note',(m.map_age_us>m.stale_after_us?'评分图已过期，仅供回看':m.accepted?'通过定位门控':'候选评分图（未确认定位）')+'；帧 '+m.frame+'；数据年龄 '+num(m.map_age_us/1000)+' ms；白线为最近5秒候选方向留痕。评分不代表故障概率。');
}
function renderHealth(s){c9health=s;if(guiSession!==s.session){guiSession=s.session;guiHistory=[];guiEvents.clear();guiHealthCursor=guiEventCursor=0;guiTrails.clear();}
 text('health_note',(s.enabled?'监测已启用':'监测已关闭')+'；连续'+s.thresholds.join(' / ')+'次：疑似 / 报警 / 恢复；断流或未知结果不会解除报警。');
 $('health_status').textContent='';(s.tracks||[]).forEach(t=>{let r=t.record,p=document.createElement('p');p.className=r.state>=2?'alarm':'';p.textContent='轨迹 '+r.track+'：'+states[r.state]+'；'+(t.fresh?'有效诊断':'数据无效/过期，保留报警状态')+'；最近有效时间 '+num(t.last_valid_ms/1000,1)+' s；RMS '+num(r.rms*100,4)+' %FS';$('health_status').appendChild(p);});
 if(!(s.tracks||[]).length)text('health_status','等待真实候选诊断；当前没有有效诊断，不表示设备正常。');
}
function renderPerformance(z){let aux=c9state&&c9state.auxiliary_search||{},d=c9state&&c9state.diagnostic_scheduler||{};
 rows('performance',[
 ['原始PCM已接收 / 历史保留',z.dma_frame_ok+' / '+z.history_frames+' 采样帧'],
 ['采集连续会话 / DMA错误',z.history_session+' / '+z.dma_corrupt],
 ['DMA丢样 / UDP丢样',z.dma_drops+' / '+z.udp_frames_dropped],
 ['UDP连续录音',z.udp_enabled?'已启用（包含连续输出处理）':'已关闭；独立候选分离/诊断继续运行'],
 ['GSC请求 / 旁路原因',z.gsc_requested+' / '+z.gsc_reason],
 ['完整评分图 / 重试',c9state?c9state.map_copies+' / '+c9state.map_retries:'等待'],
 ['辅助搜索完成 / 接受 / 超时',aux.cpu1_completed+' / '+aux.accepted+' / '+aux.cpu1_late],
 ['辅助搜索最大耗时',num(aux.cpu1_processing_us_max/1000,3)+' ms / 200 ms期限'],
 ['搜索分段：读取/降采样/统计/搜索',[aux.copy_us,aux.prepare_us,aux.observations_us,aux.search_us].map(x=>num(x/1000,2)).join(' / ')+' ms'],
 ['诊断任务 / 完成 / 窗口未稳定',d.cpu1_started+' / '+d.cpu1_completed+' / '+d.coverage_rejected],
 ['定位首PCM到PS（当前/最大）',z.latency_samples?num(z.pcm_to_ps_us/1000,3)+' / '+num(z.pcm_to_ps_max_us/1000,3)+' ms':'等待真实测量'],
 ['音频服务最大间隔 / 耗时',z.max_ps_poll_gap_us+' / '+z.max_ps_service_us+' us'],
 ['定位与故障准确性验收',z.board_validated?'已完成':'尚未完成，采集连通不代表准确性通过']]);}

function renderHistory(){let seconds=Number($('history_range').value),now=c9health?c9health.uptime_ms:0,track=Number($('candidate_select').value),r=guiHistory.filter(v=>now-v.ms<=seconds*1000&&(!track||v.track===track));
 let c=$('history_plot'),g=c.getContext('2d'),L=62,R=c.width-16,T=26,B=c.height-38;g.clearRect(0,0,c.width,c.height);g.font='12px system-ui';g.fillStyle='#a0b3c2';g.fillText('RMS (%FS)，每条曲线只对应选中轨迹',L,16);let max=Math.max(.01,...r.map(v=>v.rms*100));g.strokeStyle='#304352';for(let i=0;i<=4;i++){let y=T+(B-T)*i/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText(num(max*(1-i/4),2),4,y+3);g.fillText('-'+num(seconds*(1-i/4),0)+'s',L+i*(R-L)/4-10,B+18);}let previous=null;r.forEach(v=>{let x=L+(1-(now-v.ms)/seconds/1000)*(R-L),y=B-v.rms*100/max*(B-T);if(previous&&v.track===previous.track&&v.ms-previous.ms<3000){g.strokeStyle=v.valid?'#52d6c1':'#738598';g.beginPath();g.moveTo(previous.x,previous.y);g.lineTo(x,y);g.stroke();}g.fillStyle=v.valid?['#52d6c1','#ffd17c','#ff6174','#ffb454'][v.state]:'#738598';g.fillRect(x-2,y-2,4,4);previous={...v,x,y};});text('history_note','当前窗口 '+seconds+' 秒；'+r.length+'条真实诊断记录。灰点表示无效诊断；板内最多保留256条。');
 $('events').textContent='';Array.from(guiEvents.values()).sort((a,b)=>b.id-a.id).forEach(e=>{let r=document.createElement('tr');[e.id,'轨迹 '+e.track,states[e.state],labels[e.label],e.closed?'已关闭':'进行中',num(e.first_ms/1000,1)+' s'].forEach(v=>{let td=document.createElement('td');td.textContent=v;r.appendChild(td);});let td=document.createElement('td'),b=document.createElement('button');b.textContent='详情';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));td.appendChild(b);r.appendChild(td);$('events').appendChild(r);});
}
async function fetchHealth(){let s=await get('/api/health9/status');renderHealth(s);let h=await get('/api/health9/history?after='+guiHealthCursor+'&limit=32');if(h.session!==guiSession)return;guiHistory.push(...h.records);guiHistory=guiHistory.slice(-256);guiHealthCursor=h.next_after;let e=await get('/api/health9/events?after='+guiEventCursor+'&limit=16');if(e.session!==guiSession)return;e.events.forEach(v=>guiEvents.set(v.id,v));if(guiEvents.size>32)guiEvents.delete(guiEvents.keys().next().value);guiEventCursor=e.next_after;renderHistory();}
async function archiveView(){try{let data=await get('/archive/history?seconds='+$('history_range').value);rows('archive_records',(data.records||[]).slice(-64).map(r=>[r.received_utc+' / 会话'+r.archive_session,'轨迹'+r.track+'；'+states[r.state]+'；RMS '+num(r.rms*100,4)+' %FS']));$('archive_events').textContent='';(data.events||[]).forEach(e=>{let p=document.createElement('p');p.textContent=e.received_utc+'；会话'+e.archive_session+'；事件'+e.id+'；轨迹'+e.track+'；'+states[e.state]+'；'+(e.closed?'已恢复关闭':'历史未关闭，不能推断已恢复');let b=document.createElement('button');b.textContent='详情';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));p.appendChild(b);$('archive_events').appendChild(p);});text('archive_note','SQLite跨重启历史；时间为PC接收UTC，不是声源发生时间。'+(data.archive_error?'归档异常：'+data.archive_error:'最近归档正常。'));}catch(e){text('archive_note','请运行PC归档服务并从 http://127.0.0.1:8769/ 打开完整页面。'+String(e));}}
async function preview(){const token=++guiPreviewToken,state=c9state,c=(state&&state.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));if(!c)return;
 $('preview').disabled=true;try{let index=state.candidates.indexOf(c),seq=state.sequence,p=await get('/api/gui/plots?sequence='+seq+'&index='+index),re=new Float64Array(4096),im=new Float64Array(4096);for(let offset=0;offset<4096;offset+=512){let data=await get('/api/candidate/audio?sequence='+seq+'&index='+index+'&offset='+offset+'&count=512',true),v=new DataView(data);for(let i=0;i<512;i++)re[offset+i]=v.getInt16(i*2,true);}
 if(token!==guiPreviewToken||!c9state||c9state.sequence!==seq||Number($('candidate_select').value)!==c.track_id)throw Error('候选快照已更新，丢弃波形并重试');let mean=re.reduce((a,b)=>a+b,0)/re.length;for(let i=0;i<re.length;i++)re[i]=(re[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(re.length-1)));gccFft(re,im,false);let bins=[];for(let i=1;i<=2048;i++)bins.push(Math.hypot(re[i],im[i]));let max=Math.max(...bins)||1;plot('spectrum_plot',bins.map(x=>x/max),19.53125,'频率(kHz)');plot('envelope_plot',p.envelope_valid?p.envelope.map(x=>x/1000):null,900,'频率(Hz)');text('plot_note','轨迹 '+c.track_id+'，快照 #'+seq+'；音频谱为前4096点、去均值Hann窗FFT；包络谱来自同一1.024秒C9F2诊断计算，0–900Hz，分组最大值；各自峰值归一。');
 }catch(e){text('plot_note',String(e));}finally{$('preview').disabled=false;}}
async function pair(){ window.guiPair=null;$('pair_capture').disabled=true;try{let a=Number($('pair_a').value),b=Number($('pair_b').value),buf=await get('/api/debug/pair?a='+a+'&b='+b,true),v=new DataView(buf);if(v.getUint32(0,true)!==0x43395031||buf.byteLength!==4128)throw Error('快照格式错误');let fs=v.getUint32(4,true),x=[],y=[];for(let i=0;i<1024;i++){x.push(v.getInt16(32+4*i,true));y.push(v.getInt16(34+4*i,true));}let mx=x.reduce((a,b)=>a+b)/1024,my=y.reduce((a,b)=>a+b)/1024,xx=x.map(a=>a-mx),yy=y.map(a=>a-my),xy=0,sx=0,sy=0;xx.forEach((a,i)=>{xy+=a*yy[i];sx+=a*a;sy+=yy[i]*yy[i];});let positions=Array.from({length:9},(_,i)=>i===8?[0,0,0]:[.03*Math.cos(i*Math.PI/4),.03*Math.sin(i*Math.PI/4),0]),r=gccAnalyze([x,y],fs,[positions[a],positions[b]])[0];let peak=Math.max(...xx.map(Math.abs),...yy.map(Math.abs),1);plot('pair_plot',xx.map(a=>a/peak),1023/fs*1000,'时间(ms)','共享幅值轴（AC PCM）',true);let g=$('pair_plot').getContext('2d'),L=62,R=$('pair_plot').width-18,T=25,B=$('pair_plot').height-42;g.strokeStyle='#ffb454';g.beginPath();yy.forEach((v,i)=>{let px=L+i*(R-L)/1023,py=(T+B)/2-v/peak*(B-T)/2;i?g.lineTo(px,py):g.moveTo(px,py);});g.stroke();rows('pair_result',[['同帧原始PCM','CH'+a+' / CH'+b+'；'+fs+' Hz；起点 '+v.getUint32(20,true)],['AC相关系数',sx&&sy?num(xy/Math.sqrt(sx*sy),6):'无有效能量'],['正峰',gccEstimateText(r.positive)],['负谷',gccEstimateText(r.negative)],['绝对峰',gccEstimateText(r.absolute)]]);text('pair_note','保留原始时间轴，无移位、无极性翻转；GCC仅浏览器调试。几何按名义30mm圆环，实际映射/标定仍待验收。');window.guiPair={a,b,fs,first:v.getUint32(20,true),epoch:v.getUint32(24,true),session:v.getUint32(28,true),x,y,gcc:r};}catch(e){text('pair_note',String(e));}finally{$('pair_capture').disabled=false;}}
async function tick(){if(paused||c9busy)return;c9busy=true;try{if(Date.now()-guiLastCandidate>=500){renderStatus(await get('/api/status'));let s=await get('/api/candidates');renderCandidates(s);}renderMap(await get('/api/heatmap'));if(Date.now()-guiLastHealth>1000){await fetchHealth();renderPerformance(await get('/api/gsc'));guiLastHealth=Date.now();}text('err','');}catch(e){text('err','通信/数据不可用：'+String(e)+'；保留报警，等待恢复。');}finally{c9busy=false;}}
$('pause').onclick=()=>{paused=!paused;text('pause',paused?'继续显示':'暂停显示');};
$('save').onclick=()=>download('acoustic_snapshot.json',JSON.stringify({captured_utc:new Date().toISOString(),status:latest,candidates:c9state,health:c9health},null,2));
$('preview').onclick=preview;$('pair_capture').onclick=pair;$('pair_save').onclick=()=>window.guiPair&&download('pair_pcm_gcc.json',JSON.stringify(window.guiPair));
let pairRunning=false,pairFrames=[];$('pair_run').onclick=async()=>{if(pairRunning){pairRunning=false;return;}pairRunning=true;pairFrames=[];text('pair_run','停止连续采集');try{for(let i=0;i<10&&pairRunning;i++){await pair();if(window.guiPair)pairFrames.push(window.guiPair);if(i<9)await new Promise(resolve=>setTimeout(resolve,1000));}if(pairFrames.length)download('pair_10frames.json',JSON.stringify({source:'hardware_pcm',frames:pairFrames}));}finally{pairRunning=false;text('pair_run','连续采集10帧');}};
$('raw_download').onclick=async()=>{try{let buf=await get('/api/debug/raw',true);download('nine_microphones.raw',buf,'application/octet-stream');text('pair_note','九路同步快照已下载：C9R1头、采样率、起点、epoch/session及交错int16 PCM。');}catch(e){text('pair_note',String(e));}};
$('history_range').onchange=renderHistory;$('candidate_select').onchange=()=>{guiPreviewToken++;renderDiagnosis((c9state.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value)),c9state);renderHistory();};
$('export').onclick=()=>download('health_events.json',JSON.stringify({session:guiSession,records:guiHistory,events:Array.from(guiEvents.values())},null,2));
$('archive_load').onclick=archiveView;
$('health_toggle').onclick=()=>control('/api/health9/enabled?value='+(c9health&&c9health.enabled?0:1));
$('rpm_set').onclick=()=>{let rpm=Number($('rpm').value);if(!Number.isInteger(rpm)||rpm<600||rpm>1800){text('action_note','请输入已知实际转速600–1800rpm');return;}control('/api/rpm?value='+rpm);};
$('direction_map').onclick=function(e){let r=this.getBoundingClientRect(),x=(e.clientX-r.left)*this.width/r.width,y=(e.clientY-r.top)*this.height/r.height;if(x<54||x>=374||y<18||y>=338)return;control('/api/target?grid='+((31-Math.floor((y-18)/10))*32+Math.floor((x-54)/10)));};
document.querySelectorAll('[data-control]').forEach(b=>b.onclick=()=>control(b.dataset.control));
for(let i=0;i<9;i++)['pair_a','pair_b'].forEach(id=>{let o=document.createElement('option');o.value=i;o.textContent='CH'+i;$(id).appendChild(o);});$('pair_b').value=1;
plot('spectrum_plot',null,19.53125,'频率(kHz)');plot('envelope_plot',null,900,'频率(Hz)');plot('pair_plot',null,6.5536,'时间(ms)','AC PCM',true);
setInterval(()=>{if(!paused&&guiLastCandidate&&Date.now()-guiLastCandidate>3000){text('health_note','通信已过期；下方为历史状态，不代表当前正常。');guiTrails.clear();}},500);
setInterval(tick,100);tick();
