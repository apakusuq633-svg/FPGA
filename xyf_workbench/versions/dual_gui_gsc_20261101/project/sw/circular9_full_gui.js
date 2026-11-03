'use strict';
// Browser-only display/analysis. No classifier, feature extractor or PL control
// algorithm is replaced by this file. All inputs carry snapshot/track identity.
var latest=null, paused=false, c9busy=false, c9state=null, c9health=null;
var guiDisplayedPlot=null,guiPlotBusy=false,guiSpectrumView=null;
var GUI_SPECTRUM_MAX_HZ=8000;
var guiSequence=0,guiTrack=0,guiSession=null,guiHistory=[],guiEvents=new Map(),guiTrails=new Map();
var guiHealthCursor=0,guiEventCursor=0,guiPreviewToken=0,guiLastCandidate=0,guiLastHealth=0;
const $=id=>document.getElementById(id);
const labels=['未知','正常','故障','干扰','异常（未确认故障）'];
const states=['正常监测','疑似异常','故障/异常报警','恢复观察'];
const reasonNames={ok:'有效',no_model:'尚未配置模型',bad_model:'模型契约不匹配',bad_input:'转速或输入无效',bad_binding:'方向/分离关联条件不足',silent:'低电平',rejected:'模型拒识',unvalidated:'模型未经验证',clipped:'输入削顶',unseen_separation_filter:'分离频带未获模型验证',no_carrier:'共振带能量不足'};
function fixedText(el,value){el.textContent=String(value??'—');}
function text(id,v){if($(id))fixedText($(id),v);}
function line(table,k,v){let row=document.createElement('tr'),key=document.createElement('td'),cell=document.createElement('td');key.textContent=k;cell.title=String(v??'—');if(k==='方向'&&String(v).includes(' / ')){String(v).split(' / ').forEach((a,i)=>{let n=document.createElement('span');n.className='angle-value';n.textContent=(i?' / ':'')+a;cell.appendChild(n);});}else cell.textContent=String(v??'—');row.appendChild(key);row.appendChild(cell);table.appendChild(row);}
function rows(id,data){$(id).textContent='';data.forEach(r=>line($(id),r[0],r[1]));}
function num(x,d=2){return Number.isFinite(x)?x.toFixed(d):'未提供';}
function angle(x){return Number.isFinite(x)?num(x/1000)+'°':'未知';}
function download(name,data,type='application/json'){let u=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);}
async function get(path,binary=false,accepted=false){let controller=new AbortController(),timer=setTimeout(()=>controller.abort(),2500);try{let r=await fetch(path,{cache:'no-store',signal:controller.signal});if(r.status===202&&!accepted)return null;if(!r.ok){let e=Error(path+'：HTTP '+r.status);e.status=r.status;throw e;}return binary?await r.arrayBuffer():await r.json();}finally{clearTimeout(timer);}}
async function control(path){text('action_note','正在提交并读取返回状态…');try{let r=await get(path,false,true),note='设置已受理';
 if(path.startsWith('/api/rpm?')){note='已确认 '+r.rpm+' rpm；等待重新采集完整诊断窗口';renderCandidates(await get('/api/candidates'));}
 else if(path.startsWith('/api/recording/'))note='UDP连续录音已'+(r.udp_enabled?'开启（需PC接收端）':'关闭')+'；候选诊断独立运行';
 else if(path.startsWith('/api/gsc/target?'))note=r.accepted?'固定目标已提交；现在可开启GSC实验':'目标未生效';
 else if(path.startsWith('/api/gsc/'))note='UDP链路：GSC请求'+(r.gsc_requested?'开启':'关闭')+'，自适应'+(r.freeze_updates?'冻结':'允许更新')+'；最近输出'+(r.gsc_reason===0?'GSC处理':r.gsc_reason===9?'旁路：缺少有效配置':'旁路，原因码 '+r.gsc_reason);
 else if(path==='/api/target/fault')note='已请求故障跟踪；等待可信故障方向，不会强制定向';
 else if(path.startsWith('/api/target'))note='定向请求已受理；是否实际执行仍受定位门控约束';
 text('action_note',note);
 }catch(e){text('action_note','设置或状态回读失败：'+String(e));}}
function validFault(c,s){return !!(c.diagnosis&&c.diagnosis.fault_direction_valid&&!c.stale&&c.stable&&c.separation_ready&&s.geometry_confirmed&&s.calibration_version&&s.model_validated&&c.diagnosis.binding.track_id===c.track_id&&c.diagnosis.model_version===s.model_version);}
function plot(id,values,xmax,xlabel,ylabel='相对幅值（峰值=1）',signed=false,emptyMessage='等待有效快照',xmin=0,xvalues=null){
 let c=$(id),responsive=id==='spectrum_plot'||id==='envelope_plot';
 if(responsive){window.c9PlotCache=window.c9PlotCache||{};window.c9PlotCache[id]=[id,values,xmax,xlabel,ylabel,signed,emptyMessage,xmin,xvalues];}
 let box=c.getBoundingClientRect(),cw=responsive&&box.width>0?box.width:c.width,ch=responsive&&box.height>0?box.height:c.height,dpr=responsive?Math.min(devicePixelRatio||1,2):1;
 if(responsive&&box.width>0&&box.height>0){let w=Math.round(cw*dpr),h=Math.round(ch*dpr);if(c.width!==w||c.height!==h){c.width=w;c.height=h;}}
 let g=c.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);
 let L=responsive?Math.max(60,Math.min(72,cw*.05)):62,R=cw-18,T=responsive?34:25,B=ch-(responsive?52:42);g.clearRect(0,0,cw,ch);g.font=(responsive?'16':'13')+'px monospace';g.fillStyle='#a0b3c2';g.fillText(ylabel,L,responsive?22:16);
 if(responsive){window.c9PlotBounds=window.c9PlotBounds||{};window.c9PlotBounds[id]={canvas_css_width:cw,canvas_css_height:ch,plot_css_width:R-L,plot_css_height:B-T,width_fraction:(R-L)/cw,source_points:values?values.length:0,xmin,xmax,backing_width:c.width,backing_height:c.height,dpr};}
 g.strokeStyle='#304352';g.lineWidth=1;
 for(let k=0;k<=4;k++){let y=T+(B-T)*k/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText((signed?1-k/2:1-k/4).toFixed(2),8,y+4);let x=L+(R-L)*k/4;g.beginPath();g.moveTo(x,T);g.lineTo(x,B);g.stroke();let tick=num(xmin+(xmax-xmin)*k/4,xmax<10?2:0);g.fillText(tick,responsive?Math.max(0,Math.min(cw-g.measureText(tick).width,x-g.measureText(tick).width/2)):x-12,B+(responsive?25:19));}
 g.fillText(xlabel,(L+R)/2-g.measureText(xlabel).width/2,ch-(responsive?8:4));
 if(!values||!values.length){g.fillText(emptyMessage,L+20,T+50);return;}
 g.strokeStyle='#52d6c1';g.beginPath();let drawing=false;values.forEach((v,i)=>{let fraction=xvalues?(xvalues[i]-xmin)/(xmax-xmin):i/(values.length-1);if(!Number.isFinite(v)||fraction<0||fraction>1){drawing=false;return;}let x=L+fraction*(R-L),y=signed?(T+B)/2-v*(B-T)/2:B-v*(B-T);if(drawing)g.lineTo(x,y);else g.moveTo(x,y);drawing=true;});g.stroke();
}
function renderStatus(s){latest=s;text('source','9麦同步PDM → PL方向定位 → PS多候选分离与诊断');
 text('state',s.input_error?'采集错误 '+s.input_error:'持续采集中；分类有效性见候选与监测状态');
 rows('runtime',[['旧单路音频块（九麦不使用）',s.received_blocks],['PL丢失采样点',s.pl_dropped],['PS丢失采样点',s.ps_dropped],['CPU1忙',s.computing],['诊断观察窗','1024 ms；更新间隔512 ms'],['采样率','156250 Hz原始 / 39062.5 Hz诊断']]);
 $('mics').textContent='';for(let i=0;i<9;i++)line($('mics'),'CH'+i,s.mic_valid?'RMS '+num((s.mic_rms_ppm||[])[i]/10000,4)+' %FS；峰值 '+num((s.mic_peak_ppm||[])[i]/10000,4)+' %FS；均值 '+num((s.mic_mean_ppm||[])[i]/10000,4)+' %FS；削顶 '+((s.mic_clipped||[])[i]??'未提供'):'等待通道快照');
}
function renderCandidates(s){c9state=s;guiLastCandidate=Date.now();
 const chosen=Number($('candidate_select').value)||guiTrack;
 $('candidate_select').textContent='';$('candidates').textContent='';
 (s.candidates||[]).forEach((c,i)=>{let o=document.createElement('option');o.value=c.track_id;o.textContent='轨迹 '+c.track_id+' / '+angle(c.azimuth_mdeg);$('candidate_select').appendChild(o);
  let d=c.diagnosis||{},p=document.createElement('p');p.className=validFault(c,s)?'alarm':'muted';fixedText(p,'轨迹 '+c.track_id+'：水平角 '+angle(c.azimuth_mdeg)+'，俯仰角 '+angle(c.elevation_mdeg)+'；'+(c.stale?'已过期':c.stable?'稳定':'待稳定')+'；'+(d.label||'unknown')+'；'+(reasonNames[d.reason]||d.reason||'等待诊断'));let b=document.createElement('button');b.textContent='拾取此方向';b.disabled=!!c.stale;b.onclick=()=>control('/api/target?grid='+c.grid);p.appendChild(b);$('candidates').appendChild(p);
 });
 if((s.candidates||[]).length)$('candidate_select').value=(s.candidates.some(c=>c.track_id===chosen)?chosen:s.candidates[0].track_id);
 text('model_note','PS完整联合评分正式版；PL候选仍独立参与；'+(s.fstf_experiment_enabled?'FSTF六类实验已启用（未验证，仅1800rpm）；原判决':'')+'模型版本 '+s.model_version+'；'+(s.model_validated?'已验证':'未验证/未配置，保持未知')+'；'+(s.shaft_confirmed?'已配置转速 '+num(s.shaft_millihz*.06,0)+' rpm':'转速未确认')+'；快照 #'+s.sequence+'，年龄 '+s.result_age_ms+' ms');
 if(!(s.candidates||[]).length)text('candidates','尚无可读取的候选诊断快照；下方实时提议独立更新，不代表已完成诊断。');
 $('live_proposals').textContent='';
 const proposals=s.proposals||[];
 text('proposal_note','已完整显示本次接口返回的 '+proposals.length+' 条提议；后台仍有质量筛选、方向合并及最多3条限制，不是全部原始峰。方向状态约每250ms读取；上方诊断快照另有计算与观察窗延迟。');
 for(let i=0;i<Math.max(3,proposals.length);i++){
 let p=proposals[i],row=document.createElement('div');row.className='proposal-row';
 let vals=p?[p.track_id,angle(p.azimuth_mdeg),angle(p.elevation_mdeg),p.observations,({1:'已观测',2:'历史方向·保持',3:'恢复观察'}[p.track_state]||'未知')]:['—','—','—','—','暂无提议'];
 vals.forEach((v,k)=>{let cell=document.createElement('span');cell.className=k<4?'proposal-value':'proposal-state';cell.textContent=String(v??'—');cell.title=String(v??'—');row.appendChild(cell);});$('live_proposals').appendChild(row);
 }
 const c=(s.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));renderDiagnosis(c,s);
}
function renderDiagnosis(c,s){if(!c){rows('diagnosis',[['状态','等待候选诊断']]);rows('levels',[]);rows('features',[]);if(!guiDisplayedPlot){plot('spectrum_plot',null,8,'频率(kHz)');plot('envelope_plot',null,900,'频率(Hz)');}else text('plot_note','当前无候选；保留历史快照 #'+guiDisplayedPlot.sequence+'，轨迹 '+guiDisplayedPlot.track+'，不是最新结果。');return;}let d=c.diagnosis||{};
 rows('diagnosis',[['轨迹',c.track_id],['方向',angle(c.azimuth_mdeg)+' / '+angle(c.elevation_mdeg)],['类别',c.stale?'过期结果（仅供回看）':({normal:'正常',fault:'故障',interference:'干扰',anomaly:'异常',unknown:'未知'}[d.label]||'未知')],['有效性',reasonNames[d.reason]||d.reason],['模型距离间隔（非概率）',num(d.margin,4)],['故障方向确认',validFault(c,s)?'已确认':'未确认']]);
 const experiment=d.fstf_experimental;
 if(experiment&&experiment.enabled){
  const names={inner:'内圈',outer:'外圈',ball:'滚动体',healthy:'正常',looseness:'松动',combined:'复合'};
  line($('diagnosis'),'FSTF实验细类',experiment.available?(names[experiment.label]||'未知')+'（未验证'+(c.stale?'；历史快照':'')+'）':'等待1800rpm、有效分离及特征');
  if(experiment.available)line($('diagnosis'),'实验模型距离 / 间隔',num(experiment.distance,4)+' / '+num(experiment.margin,3)+'；非概率，不参与报警或故障定向');
 }
 const analyzed=!!(d.extraction&&d.extraction.fft_count===1);
 rows('levels',[['分离音频RMS',analyzed?num(d.rms*100,4)+' %FS':'未计算'],['载频带RMS',analyzed?num(d.extraction.carrier_rms*100,4)+' %FS':'未计算'],['调制RMS',analyzed?num(d.extraction.modulation_rms*100,4)+' %FS':'未计算'],['削顶点数',analyzed?d.clipped_samples:'未统计'],['载频带','2200–4600 Hz（C9F2）']]);
 $('features').textContent='';if(!analyzed||!(d.shaft_hz>=10&&d.shaft_hz<=30))line($('features'),'阶次特征','未计算：缺少有效转速或包络');else (d.features||[]).forEach((v,i)=>line($('features'),'特征 '+(i+1),num(v,5)));

 if(guiSequence!==s.sequence||guiTrack!==c.track_id){guiSequence=s.sequence;guiTrack=c.track_id;text('plot_note',guiDisplayedPlot?'新快照待读取；下图保留历史快照 #'+guiDisplayedPlot.sequence+' / 轨迹 '+guiDisplayedPlot.track+'，不是最新结果。':'新快照已到达，正在等待音频读取；也可点击获取同快照波形。');}
}
var heatmapView={values:null,key:null,at:0,lastSignal:0,lo:0,hi:0,smooth:true,seq:0};
function heatmapDisplay(m,now,smooth){
 if(!m||!Array.isArray(m.scores)||m.scores.length!==1024||m.scores.some(x=>!Number.isFinite(x)))return null;
 let lo=Math.min(...m.scores),hi=Math.max(...m.scores),flat=hi===lo,key=m.sequence+'/'+m.frame;
 let reset=!heatmapView.values||smooth!==heatmapView.smooth||m.sequence<heatmapView.seq||now-heatmapView.at>1500;
 let fresh=reset||key!==heatmapView.key;
 if(fresh){
  if(reset)heatmapView.lastSignal=flat?0:now;
  let dt=reset?0:Math.max(0,now-heatmapView.at),alpha=reset||!smooth?1:1-Math.exp(-dt/250);
  heatmapView.values=reset?m.scores.slice():heatmapView.values.map((v,i)=>v+alpha*(m.scores[i]-v));
  let a=Math.min(...heatmapView.values),b=Math.max(...heatmapView.values),decay=reset||!smooth?1:1-Math.exp(-dt/1200);
  heatmapView.lo=reset?a:Math.min(a,heatmapView.lo+decay*(a-heatmapView.lo));
  heatmapView.hi=reset?b:Math.max(b,heatmapView.hi+decay*(b-heatmapView.hi));
  heatmapView.key=key;heatmapView.at=now;heatmapView.seq=m.sequence;heatmapView.smooth=smooth;
  if(!flat)heatmapView.lastSignal=now;
 }
 return {values:heatmapView.values,lo:heatmapView.lo,hi:heatmapView.hi,flat:flat&&(!smooth||!heatmapView.lastSignal||now-heatmapView.lastSignal>=800),sourceFlat:flat,newFrame:fresh};
}
// Display-only interpolation and sampled Viridis; never fed back to DSP.
var mapColorScale={ready:false,lo:0,hi:1},mapRaster={canvas:null,key:null},guiLastMap=null,guiLastMapAt=0;
const mapViridis=[[68,1,84],[72,36,117],[65,68,135],[53,95,141],[42,120,142],[33,145,140],[34,168,132],[68,191,112],[122,209,81],[189,223,38],[253,231,37]];
function mapColor(t){let x=Math.max(0,Math.min(1,t))*10,i=Math.min(9,Math.floor(x)),f=x-i;return mapViridis[i].map((v,k)=>Math.round(v+(mapViridis[i+1][k]-v)*f));}
const mapColorLut=Array.from({length:256},(_,i)=>mapColor(i/255)),mapNeutral=[20,36,49];
function mapSample(values,x,y){x=Math.max(0,Math.min(31,x));y=Math.max(0,Math.min(31,y));let a=Math.floor(x),b=Math.floor(y),u=x-a,v=y-b,c=Math.min(31,a+1),d=Math.min(31,b+1);return (1-v)*((1-u)*values[b*32+a]+u*values[b*32+c])+v*((1-u)*values[d*32+a]+u*values[d*32+c]);}
function mapRange(m,view,mode){if(mode==='auto')return {lo:view.lo,hi:view.hi};if(!mapColorScale.ready&&!view.sourceFlat){mapColorScale.lo=Math.min(...m.scores);mapColorScale.hi=Math.max(...m.scores);mapColorScale.ready=mapColorScale.hi>mapColorScale.lo;}return mapColorScale;}
function renderMap(m){let smooth=$('map_smooth').checked,view=heatmapDisplay(m,Date.now(),smooth);if(!view){let c=$('direction_map'),g=c.getContext('2d');g.clearRect(0,0,c.width,c.height);g.fillStyle='#a0b3c2';g.fillText('等待完整评分图',54,40);text('map_note','评分图不可用；不显示旧定位标记。');return;}if(m!==guiLastMap){guiLastMap=m;guiLastMapAt=Date.now();}
 let c=$('direction_map'),g=c.getContext('2d'),L=54,T=18,W=320,H=320,range=mapRange(m,view,$('map_scale').value),lo=range.lo,hi=range.hi,n=$('map_interp').checked?256:32;
 let age=m.map_age_us+Math.max(0,Date.now()-guiLastMapAt)*1000,stale=age>m.stale_after_us,key=heatmapView.key+'/'+smooth+'/'+view.flat+'/'+n+'/'+lo+'/'+hi;
 if(!mapRaster.canvas)mapRaster.canvas=document.createElement('canvas');
 if(key!==mapRaster.key){let r=mapRaster.canvas;r.width=r.height=n;let q=r.getContext('2d'),im=q.createImageData(n,n);
  for(let y=0;y<n;y++)for(let x=0;x<n;x++){let v=mapSample(view.values,(x+.5)*32/n-.5,31-((y+.5)*32/n-.5)),rgb=view.flat?mapNeutral:mapColorLut[Math.round(Math.max(0,Math.min(1,hi>lo?(v-lo)/(hi-lo):0))*255)],i=4*(y*n+x);im.data[i]=rgb[0];im.data[i+1]=rgb[1];im.data[i+2]=rgb[2];im.data[i+3]=255;}
  q.putImageData(im,0,0);mapRaster.key=key;}
 g.clearRect(0,0,c.width,c.height);g.imageSmoothingEnabled=true;g.globalAlpha=stale?.45:1;g.drawImage(mapRaster.canvas,L,T,W,H);g.globalAlpha=1;
 g.fillStyle='#a0b3c2';g.font='12px monospace';[-90,-45,0,45,90].forEach(a=>{g.fillText(a+'°',L+(a+90)*W/180-10,T+H+19);g.fillText(a+'°',8,T+(90-a)*H/180+4);});g.fillText('水平角（正前方0°）',L+72,T+H+39);g.fillText('俯仰角',3,12);
 for(let i=0;i<256;i++){g.fillStyle='rgb('+mapColor(i/255).join(',')+')';g.fillRect(L+i*W/256,398,W/256+1,10);}g.fillStyle='#a0b3c2';let scaleReady=$('map_scale').value==='auto'?hi>lo:mapColorScale.ready;g.fillText(scaleReady?'评分（非概率）':'色阶待初始化',L,391);g.fillText(scaleReady?num(lo,0):'—',L,427);g.fillText(scaleReady?num(hi,0):'—',L+W-50,427);
 const xy=(az,el)=>[L+(az+90)*W/180,T+(90-el)*H/180],now=Date.now();
 if(!view.sourceFlat&&!stale){let peak=m.scores.indexOf(Math.max(...m.scores)),x=L+(peak%32+.5)*10,y=T+(31-Math.floor(peak/32)+.5)*10;g.strokeStyle='white';g.lineWidth=2;g.beginPath();g.moveTo(x-6,y);g.lineTo(x+6,y);g.moveTo(x,y-6);g.lineTo(x,y+6);g.stroke();g.lineWidth=1;}
 if(!$('show_proposals').checked)guiTrails.clear();($('show_proposals').checked&&c9state&&c9state.proposals||[]).forEach(p=>{let trail=guiTrails.get(p.track_id)||[];if(!trail.length||trail.at(-1).sequence!==p.observations)trail.push({x:p.azimuth_mdeg/1000,y:p.elevation_mdeg/1000,t:guiLastCandidate,sequence:p.observations});guiTrails.set(p.track_id,trail.slice(-60));
  if(now-guiLastCandidate<1000){let [x,y]=xy(p.azimuth_mdeg/1000,p.elevation_mdeg/1000);g.strokeStyle='#5bd9ff';g.setLineDash(p.track_state===1?[]:[3,3]);g.beginPath();g.arc(x,y,4,0,2*Math.PI);g.stroke();g.setLineDash([]);}});
 guiTrails.forEach((trail,id)=>{trail=trail.filter(p=>now-p.t<=5000);if(!trail.length){guiTrails.delete(id);return;}guiTrails.set(id,trail);g.strokeStyle='#ffffff70';g.beginPath();trail.forEach((p,i)=>{let [x,y]=xy(p.x,p.y);i?g.lineTo(x,y):g.moveTo(x,y);});g.stroke();});
 (c9state&&c9state.candidates||[]).forEach(p=>{if(p.stale||now-guiLastCandidate>=1000)return;let [x,y]=xy(p.azimuth_mdeg/1000,p.elevation_mdeg/1000);g.strokeStyle=validFault(p,c9state)?'#ff6174':'white';g.strokeRect(x-5,y-5,10,10);if(p.track_id===Number($('candidate_select').value)){g.beginPath();g.arc(x,y,9,0,2*Math.PI);g.stroke();}g.fillStyle='white';g.fillText('T'+String(p.track_id).slice(-4),x>L+W-50?x-46:x+7,Math.max(T+12,y-7));});
 let clipped=scaleReady?view.values.filter(v=>v<lo||v>hi).length:0;
 text('map_note',(smooth?'时间平滑250ms；':'无时间平滑；')+(n===256?'256×256显示插值；':'32×32原始格；')+($('map_scale').value==='auto'?'慢速自动色阶':'锁定色阶')+(clipped?'；超出色阶 '+clipped+'/1024格':'')+'；'+(view.sourceFlat?'当前无空间对比；':'')+(stale?'评分已过期，仅供回看':m.accepted?'评分通过定位门控':'候选评分（未确认声源）')+'；帧 '+m.frame+'，年龄 '+num(age/1000)+' ms。白线保留5秒历史；标记与背景独立更新。');
}
function renderHealth(s){c9health=s;if(guiSession!==s.session){guiSession=s.session;guiHistory=[];guiEvents.clear();guiHealthCursor=guiEventCursor=0;guiTrails.clear();}
 text('health_note',(s.enabled?'监测已启用':'监测已关闭')+'；连续'+s.thresholds.join(' / ')+'次：疑似 / 报警 / 恢复；断流或未知结果不会解除报警。');
 $('health_status').textContent='';(s.tracks||[]).forEach(t=>{let r=t.record,p=document.createElement('p');p.className=r.state>=2?'alarm':'';fixedText(p,'轨迹 '+r.track+'：'+states[r.state]+'；'+(t.fresh?'有效诊断':'数据无效/过期，保留报警状态')+'；最近有效时间 '+num(t.last_valid_ms/1000,1)+' s；RMS '+num(r.rms*100,4)+' %FS');$('health_status').appendChild(p);});
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
 let c=$('history_plot'),g=c.getContext('2d'),L=62,R=c.width-16,T=26,B=c.height-38;g.clearRect(0,0,c.width,c.height);g.font='12px monospace';g.fillStyle='#a0b3c2';g.fillText('RMS (%FS)，每条曲线只对应选中轨迹',L,16);let max=Math.max(.01,...r.map(v=>v.rms*100));g.strokeStyle='#304352';for(let i=0;i<=4;i++){let y=T+(B-T)*i/4;g.beginPath();g.moveTo(L,y);g.lineTo(R,y);g.stroke();g.fillText(num(max*(1-i/4),2),4,y+3);g.fillText('-'+num(seconds*(1-i/4),0)+'s',L+i*(R-L)/4-10,B+18);}let previous=null;r.forEach(v=>{let x=L+(1-(now-v.ms)/seconds/1000)*(R-L),y=B-v.rms*100/max*(B-T);if(previous&&v.track===previous.track&&v.ms-previous.ms<3000){g.strokeStyle=v.valid?'#52d6c1':'#738598';g.beginPath();g.moveTo(previous.x,previous.y);g.lineTo(x,y);g.stroke();}g.fillStyle=v.valid?['#52d6c1','#ffd17c','#ff6174','#ffb454'][v.state]:'#738598';g.fillRect(x-2,y-2,4,4);previous={...v,x,y};});text('history_note','当前窗口 '+seconds+' 秒；'+r.length+'条真实诊断记录。灰点表示无效诊断；板内最多保留256条。');
 $('events').textContent='';Array.from(guiEvents.values()).sort((a,b)=>b.id-a.id).forEach(e=>{let r=document.createElement('tr');[e.id,'轨迹 '+e.track,states[e.state],labels[e.label],e.closed?'已关闭':'进行中',num(e.first_ms/1000,1)+' s'].forEach(v=>{let td=document.createElement('td');td.textContent=v;r.appendChild(td);});let td=document.createElement('td'),b=document.createElement('button');b.textContent='详情';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));td.appendChild(b);r.appendChild(td);$('events').appendChild(r);});
}
async function fetchHealth(){let s=await get('/api/health9/status');renderHealth(s);let h=await get('/api/health9/history?after='+guiHealthCursor+'&limit=32');if(h.session!==guiSession)return;guiHistory.push(...h.records);guiHistory=guiHistory.slice(-256);guiHealthCursor=h.next_after;let e=await get('/api/health9/events?after='+guiEventCursor+'&limit=16');if(e.session!==guiSession)return;e.events.forEach(v=>guiEvents.set(v.id,v));if(guiEvents.size>32)guiEvents.delete(guiEvents.keys().next().value);guiEventCursor=e.next_after;renderHistory();}
async function archiveView(){try{let data=await get('/archive/history?seconds='+$('history_range').value);rows('archive_records',(data.records||[]).slice(-64).map(r=>[r.received_utc+' / 会话'+r.archive_session,'轨迹'+r.track+'；'+states[r.state]+'；RMS '+num(r.rms*100,4)+' %FS']));$('archive_events').textContent='';(data.events||[]).forEach(e=>{let p=document.createElement('p');p.textContent=e.received_utc+'；会话'+e.archive_session+'；事件'+e.id+'；轨迹'+e.track+'；'+states[e.state]+'；'+(e.closed?'已恢复关闭':'历史未关闭，不能推断已恢复');let b=document.createElement('button');b.textContent='详情';b.onclick=()=>text('event_detail',JSON.stringify(e,null,2));p.appendChild(b);$('archive_events').appendChild(p);});text('archive_note','SQLite跨重启历史；时间为PC接收UTC，不是声源发生时间。'+(data.archive_error?'归档异常：'+data.archive_error:'最近归档正常。'));}catch(e){text('archive_note','请运行PC归档服务并从 http://127.0.0.1:8769/ 打开完整页面。'+String(e));}}
function selectedPlotCandidate(state){return state&&(state.candidates||[]).find(c=>c.track_id===Number($('candidate_select').value));}
function decodePlotSnapshot(buf,seq,track,index,state){
 if(!buf||buf.byteLength!==8512)throw Error('双谱快照长度错误');
 let v=new DataView(buf),h=Array.from({length:16},(_,i)=>v.getUint32(4*i,true));
 if(h[0]!==0x43394732||h[1]!==1||h[2]!==seq||h[3]!==track||h[4]!==index||!h[5]||!h[6]||h[7]!==4096||h[8]!==128||h[9]>1||h[10]>4||h[15]>1)throw Error('双谱快照身份或格式错误');
 if(state&&((Number.isInteger(state.snapshot_session)&&h[13]!==state.snapshot_session)||(Number.isInteger(state.snapshot_epoch)&&h[12]!==state.snapshot_epoch)||(Number.isInteger(state.snapshot_first_sample)&&h[11]!==state.snapshot_first_sample)))throw Error('双谱采集会话或时间起点不匹配');
 if((h[14]!==0&&(h[14]<10000||h[14]>30000))||(h[15]&&(!h[9]||!h[14]))||(h[9]&&(h[10]===0||h[10]===4)))throw Error('包络/阶次有效性标志不一致');
 let audio=Array.from({length:4096},(_,i)=>v.getInt16(64+2*i,true)),envelope=Array.from({length:128},(_,i)=>v.getUint16(8256+2*i,true));
 if(envelope.some(x=>x>1000))throw Error('包络归一化数据越界');
 return {sequence:h[2],track:h[3],fs:h[5]/h[6],envelope_valid:h[9],envelope_status:h[10],first:h[11],epoch:h[12],session:h[13],shaft_millihz:h[14],features_available:h[15],audio,envelope};
}
async function preview(){
 if(guiPlotBusy)return false;
 let state=c9state,c=selectedPlotCandidate(state);if(!c){text('plot_note','尚无候选快照；不会用方向提议冒充诊断音频。');return false;}
 guiPlotBusy=true;const token=++guiPreviewToken;$('preview').disabled=true;
 try{
  let packet;
  for(let attempt=0;attempt<2;attempt++){
   let seq=state.sequence,index=state.candidates.indexOf(c);
   try{packet=decodePlotSnapshot(await get('/api/gui/snapshot?sequence='+seq+'&index='+index,true),seq,c.track_id,index,state);break;}
   catch(e){
    if(e.status!==409||attempt!==0)throw e;
    let fresh=await get('/api/candidates');if(!fresh||token!==guiPreviewToken)throw Error('选择已改变，取消旧读取');
    let same=(fresh.candidates||[]).find(x=>x.track_id===c.track_id);renderCandidates(fresh);
    if(!same)throw Error('原轨迹已退出，等待新快照重试');state=fresh;c=same;
   }
  }
  if(token!==guiPreviewToken)throw Error('选择已改变，取消旧读取');
  let re=Float64Array.from(packet.audio),im=new Float64Array(4096),mean=re.reduce((a,b)=>a+b,0)/re.length;
  for(let i=0;i<re.length;i++)re[i]=(re[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(re.length-1)));
  gccFft(re,im,false);let count=Math.min(2048,Math.floor(GUI_SPECTRUM_MAX_HZ*4096/packet.fs)),bins=Array.from({length:count},(_,i)=>Math.hypot(re[i+1],im[i+1])),max=Math.max(...bins)||1,xvalues=bins.map((_,i)=>(i+1)*packet.fs/4096000);
  guiSpectrumView={max_hz:GUI_SPECTRUM_MAX_HZ,bins:count,last_hz:count*packet.fs/4096};
  plot('spectrum_plot',bins.map(x=>x/max),8,'频率(kHz)','相对幅值（0–8kHz峰值=1）',false,'等待音频',0,xvalues);
  const envelopeMessage=({0:'本快照未计算包络',4:'输入无效，未生成包络'}[packet.envelope_status]||'本快照未生成包络');
  plot('envelope_plot',packet.envelope_valid?packet.envelope.map(x=>x/1000):null,900,'频率(Hz)','相对幅值（峰值=1）',false,envelopeMessage);
  guiDisplayedPlot={sequence:packet.sequence,track:packet.track,session:packet.session,epoch:packet.epoch,first:packet.first,received:Date.now(),envelope_valid:packet.envelope_valid};
  let historical=!c9state||c9state.sequence!==packet.sequence||!selectedPlotCandidate(c9state)||selectedPlotCandidate(c9state).track_id!==packet.track;
  text('plot_note',(historical?'历史':'已读取')+'快照 #'+packet.sequence+' / 轨迹 '+packet.track+'；采集会话 '+packet.session+'，epoch '+packet.epoch+'；双谱一次性读取，不混帧。');
  text('spectrum_note','快照 #'+packet.sequence+' / 轨迹 '+packet.track+'；仅显示0–8kHz，可见频带峰值归一；同一分离快照前4096点，去均值/Hann窗FFT；'+num(packet.fs,1)+' Hz采样；非DC首频点 '+num(packet.fs/4096,3)+' Hz。');
  let status=packet.envelope_status===2?'载频带能量不足；':packet.envelope_status===3?'未见明显调制；':'';
  text('envelope_note',packet.envelope_valid?'快照 #'+packet.sequence+' / 轨迹 '+packet.track+'；'+status+'同一完整1.024秒C9F2包络，0–900Hz分组最大值，排除DC。'+(packet.features_available?'阶次特征已计算，分类有效性另行判定。':'转速未确认：仅显示Hz包络，阶次特征和分类未执行。'):envelopeMessage+'；不显示其他快照的包络冒充当前结果。');
  return true;
 }catch(e){
  text('plot_note',String(e)+(guiDisplayedPlot?'；保留历史快照 #'+guiDisplayedPlot.sequence+' / 轨迹 '+guiDisplayedPlot.track:'；暂无已读取波形，自动更新将重试'));
  if(!guiDisplayedPlot){plot('spectrum_plot',null,8,'频率(kHz)','相对幅值',false,'音频快照读取未完成');plot('envelope_plot',null,900,'频率(Hz)','相对幅值',false,'包络快照读取未完成');}
  return false;
 }finally{guiPlotBusy=false;$('preview').disabled=false;}
}

async function pair(){ window.guiPair=null;$('pair_capture').disabled=true;try{let a=Number($('pair_a').value),b=Number($('pair_b').value),buf=await get('/api/debug/pair?a='+a+'&b='+b,true),v=new DataView(buf);if(v.getUint32(0,true)!==0x43395031||buf.byteLength!==4128)throw Error('快照格式错误');let fs=v.getUint32(4,true),x=[],y=[];for(let i=0;i<1024;i++){x.push(v.getInt16(32+4*i,true));y.push(v.getInt16(34+4*i,true));}let mx=x.reduce((a,b)=>a+b)/1024,my=y.reduce((a,b)=>a+b)/1024,xx=x.map(a=>a-mx),yy=y.map(a=>a-my),xy=0,sx=0,sy=0;xx.forEach((a,i)=>{xy+=a*yy[i];sx+=a*a;sy+=yy[i]*yy[i];});let positions=c9ChannelPositions,r=gccAnalyze([x,y],fs,[positions[a],positions[b]])[0];let peak=Math.max(...xx.map(Math.abs),...yy.map(Math.abs),1);plot('pair_plot',xx.map(a=>a/peak),1023/fs*1000,'时间(ms)','共享幅值轴（AC PCM）',true);let g=$('pair_plot').getContext('2d'),L=62,R=$('pair_plot').width-18,T=25,B=$('pair_plot').height-42;g.strokeStyle='#ffb454';g.beginPath();yy.forEach((v,i)=>{let px=L+i*(R-L)/1023,py=(T+B)/2-v/peak*(B-T)/2;i?g.lineTo(px,py):g.moveTo(px,py);});g.stroke();rows('pair_result',[['同帧原始PCM','CH'+a+' / CH'+b+'；'+fs+' Hz；起点 '+v.getUint32(20,true)],['AC相关系数',sx&&sy?num(xy/Math.sqrt(sx*sy),6):'无有效能量'],['正峰',gccEstimateText(r.positive)],['负谷',gccEstimateText(r.negative)],['绝对峰',gccEstimateText(r.absolute)]]);text('pair_note','保留原始时间轴，无移位、无极性翻转；GCC仅浏览器调试。声孔半径：左右22mm、上下25.5mm、斜向23mm（暂按45°）；幅相标定及声学准确性仍待验收。');window.guiPair={a,b,fs,first:v.getUint32(20,true),epoch:v.getUint32(24,true),session:v.getUint32(28,true),x,y,gcc:r};}catch(e){text('pair_note',String(e));}finally{$('pair_capture').disabled=false;}}
async function tick(){if(document.hidden||paused||c9busy)return;c9busy=true;try{if(Date.now()-guiLastCandidate>=250){renderStatus(await get('/api/status'));let s=await get('/api/candidates');renderCandidates(s);}renderMap(await get('/api/heatmap'));if(Date.now()-guiLastHealth>1000){if(document.body.dataset.view!=="overview")await fetchHealth();renderPerformance(await get('/api/gsc'));guiLastHealth=Date.now();}text('err','');}catch(e){text('err','通信/数据不可用：'+String(e)+'；保留报警，等待恢复。');}finally{c9busy=false;}}
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
$('map_scale_reset').onclick=()=>{$('map_scale').value='locked';mapColorScale.ready=false;mapRaster.key=null;if(guiLastMap)renderMap(guiLastMap);};
['map_interp','map_scale','map_smooth','show_proposals'].forEach(id=>$(id).onchange=()=>{if(guiLastMap)renderMap(guiLastMap);});
$('direction_map').onclick=function(e){let r=this.getBoundingClientRect(),x=(e.clientX-r.left)*this.width/r.width,y=(e.clientY-r.top)*this.height/r.height;if(x<54||x>=374||y<18||y>=338)return;control('/api/target?grid='+((31-Math.floor((y-18)/10))*32+Math.floor((x-54)/10)));};
document.querySelectorAll('[data-control]').forEach(b=>b.onclick=()=>control(b.dataset.control));
for(let i=0;i<9;i++)['pair_a','pair_b'].forEach(id=>{let o=document.createElement('option');o.value=i;o.textContent='CH'+i;$(id).appendChild(o);});$('pair_b').value=1;
plot('spectrum_plot',null,8,'频率(kHz)');plot('envelope_plot',null,900,'频率(Hz)');plot('pair_plot',null,6.5536,'时间(ms)','AC PCM',true);
setInterval(()=>{if(!paused&&guiLastCandidate&&Date.now()-guiLastCandidate>3000){text('health_note','通信已过期；下方为历史状态，不代表当前正常。');guiTrails.clear();}},500);
setInterval(tick,100);tick();

$("gsc_target_set").onclick=()=>{let a=Number($("gsc_az").value),e=Number($("gsc_el").value);if(!Number.isInteger(a)||!Number.isInteger(e)||Math.abs(a)>85||Math.abs(e)>85){text("action_note","请输入-85到85度整数角度");return;}control("/api/gsc/target?az="+a+"&el="+e);};

const gscBasePerformance=renderPerformance;renderPerformance=function(z){gscBasePerformance(z);text("gsc_live","GSC请求："+z.gsc_requested+"；输出原因："+z.gsc_reason+"；实际处理样本："+z.gsc_active_samples+"；对齐错误："+z.gsc_alignment_errors+"；目标保护："+z.gsc_guard_active+"；固定目标："+z.gsc_target_az_deg+"° / "+z.gsc_target_el_deg+"°");};
