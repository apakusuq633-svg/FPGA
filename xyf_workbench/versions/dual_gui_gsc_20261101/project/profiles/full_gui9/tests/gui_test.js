const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(__dirname+'/full_gui.html','utf8');
const canvasOperations=[];
class Node{constructor(tag){this.tag=tag;this.children=[];this.style={};this.value='';this.text='';this.width=560;this.height=250;this.disabled=false;}set textContent(x){this.text=String(x);this.children=[];}get textContent(){return this.text+this.children.map(c=>c.textContent).join('');}appendChild(n){this.children.push(n);if(this.tag==='select'&&!this.value)this.value=n.value;return n;}getContext(){if(!this.ctx){let node=this;this.ctx=new Proxy({createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData:im=>{node.image=im;canvasOperations.push({op:'image',node});}},{get:(o,key)=>key in o?o[key]:(...args)=>canvasOperations.push({op:key,node,style:o.strokeStyle,fill:o.fillStyle,width:o.lineWidth||1,alpha:o.globalAlpha,args})});}return this.ctx;}getBoundingClientRect(){return {left:0,top:0,width:this.width,height:this.height};}click(){}}
let nodes=new Map();for(const m of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)){assert(!nodes.has(m[2]),'duplicate '+m[2]);let n=new Node(m[1]);nodes.set(m[2],n);}
nodes.get('history_range').value='300';nodes.get('map_scale').value='locked';
const document={getElementById:id=>nodes.get(id)||null,createElement:t=>new Node(t),querySelectorAll:()=>[]};
const response={input_channels:9,input_mode:2,received_blocks:10,pl_dropped:0,ps_dropped:0,computing:0};
const candidate={sequence:1,result_age_ms:20,geometry_confirmed:0,calibration_version:0,model_version:0,model_validated:0,shaft_confirmed:0,candidates:[],proposals:[]};
let paths=[];
const context={console,document,Date,Math,Number,JSON,Map,Array,Float64Array,DataView,Blob,URL,AbortController,Error,Infinity,setInterval:()=>0,setTimeout:()=>0,clearTimeout:()=>{},window:{},fetch:async path=>{paths.push(path);let data=path==='/api/status'?response:path==='/api/candidates'?candidate:path==='/api/heatmap'?{sequence:1,frame:1,map_age_us:10,scores:Array(1024).fill(0)}:path==='/api/health9/status'?{session:'1',uptime_ms:2000,enabled:1,thresholds:[3,5,10],tracks:[]}:path.includes('/history?')?{session:'1',records:[],next_after:0}:path.includes('/events?')?{session:'1',events:[],next_after:0}:{};return {ok:true,status:200,json:async()=>data};}};
vm.createContext(context);const js=html.match(/<script>([\s\S]*)<\/script>/)[1];vm.runInContext(js,context);
async function run(){await new Promise(resolve=>setImmediate(resolve));assert(paths.includes('/api/candidates'));assert(nodes.get('model_note').textContent.includes('未验证'));assert(nodes.get('health_status').textContent.includes('没有有效诊断'));
 let x=Array.from({length:1024},(_,i)=>Math.sin(i*.7)+Math.cos(i*.123)),y=x.map((_,i)=>i>=2?x[i-2]:0),r=context.gccAnalyze([x,y],48000,[[0,0,0],[.03,0,0]])[0];assert(r.positive&&Math.abs(r.positive.samples-2)<.6);
 let seeded=12345;const random=()=>{seeded=(Math.imul(seeded,1664525)+1013904223)|0;return seeded/2147483648;};let raw=Array.from({length:1024},random),delayed=raw.map((_,i)=>i>=20?raw[i-20]:0);r=context.gccAnalyze([raw,delayed],156250,[[0,0,0],[.06,0,0]])[0];assert(r.curve.length===129&&r.limit>=28&&r.positive.samples>19,'nine-mic lag range');
 assert(!context.validFault({diagnosis:{fault_direction_valid:1,binding:{track_id:1},model_version:0},track_id:1,stable:1,separation_ready:1},candidate));
 context.renderHealth({session:'1',uptime_ms:2000,enabled:1,thresholds:[3,5,10],tracks:[{fresh:0,last_valid_ms:1000,record:{track:1,state:2,rms:.1}}]});assert(nodes.get('health_status').children[0].textContent.includes('保留报警'));

 assert(nodes.has('raw_spectrum')&&nodes.has('gcc_curve')&&nodes.has('phase_groups'));
 context.renderStatus({...response,mic_valid:1,mic_rms_ppm:Array(9).fill(1000),mic_peak_ppm:Array(9).fill(2000),mic_mean_ppm:Array(9).fill(0),mic_clipped:Array(9).fill(0),loc_reason:36});
 assert(nodes.get('mics').children.length===9);
 assert(nodes.get('location_detail').textContent.includes('几何未确认'));
 let binary=new ArrayBuffer(18464),bv=new DataView(binary);[0x43395231,156250,1024,9,0,10000,3,4].forEach((v,i)=>bv.setUint32(i*4,v,true));
 for(let i=0;i<1024;i++)for(let ch=0;ch<9;ch++)bv.setInt16(32+18*i+2*ch,Math.round(1000*Math.sin(i*.7-ch*.2)),true);
 nodes.get('raw_channel').value='0';context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>binary});
 await context.captureAll();assert(context.rawSnapshot&&context.rawSnapshot.gcc.length===36);
 assert(nodes.get('phase_groups').children.length===4&&nodes.get('all_gcc').children.length===36);
 assert(nodes.get('raw_meta').textContent.includes('未移位'));
 assert(nodes.get('raw_spectrum_note').textContent.includes('不是声压'));
 context.fetch=async()=>({ok:false,status:409});await context.captureAll();assert(nodes.get('raw_meta').textContent.includes('上次快照'));

 if(process.env.C9_LIVE_PAYLOAD){
  let capture=JSON.parse(fs.readFileSync(process.env.C9_LIVE_PAYLOAD,'utf8'));
  let live=capture.rounds.map(x=>x.candidates).find(x=>x.sequence>0&&x.candidates.length);
  assert(live,'live result required');context.renderCandidates(live);
  assert(nodes.get('model_note').textContent.includes('快照 #'+live.sequence));
  assert(nodes.get('diagnosis').children.length>1,'actual result rendered into diagnosis table');
  assert(nodes.get('candidate_select').children.length===live.candidates.length);
  console.log('C9_LIVE_PAYLOAD_DOM_PASS sequence='+live.sequence+' hardware_payload=1 browser_DOM=mocked');
 }


 const plotCandidate={track_id:7,grid:528,azimuth_mdeg:0,elevation_mdeg:0,stable:1,stale:1,separation_ready:1,diagnosis:{shaft_hz:0,label:'unknown',reason:'bad_input',binding:{track_id:7},features:[]}};
 const experimentalCandidate={...plotCandidate,diagnosis:{...plotCandidate.diagnosis,fstf_experimental:{enabled:1,available:1,label:'inner',version:1,validated:0,distance:1,margin:2}}};
 context.renderCandidates({...candidate,candidates:[experimentalCandidate]});
 assert(nodes.get('diagnosis').children.some(row=>row.children.some(cell=>cell.textContent.includes('未验证'))),'experimental subtype clearly unvalidated');
 assert(!context.validFault(experimentalCandidate,candidate),'experimental subtype never becomes trusted fault');
 if(process.env.C9_FSTF_API_JSON){
  const actual=JSON.parse(fs.readFileSync(process.env.C9_FSTF_API_JSON,'utf8'));
  assert(actual._evidence_source==='HOST_FSTF_PLANE_WAVE_SIMULATION');context.renderCandidates(actual);
  assert(nodes.get('model_note').textContent.includes('六类实验已启用'));
  assert(nodes.get('diagnosis').children.some(row=>row.children.some(cell=>cell.textContent.includes('内圈'))),'actual C serialized experiment reaches GUI');
  assert(actual.candidates.every(c=>!context.validFault(c,actual)),'no experimental record authorizes fault routing');
 }
 const plotState={...candidate,sequence:77,candidates:[plotCandidate],snapshot_session:4,snapshot_epoch:3,snapshot_first_sample:123456};
 const liveProposals=[{track_id:99,azimuth_mdeg:87188,elevation_mdeg:0,observations:8,track_state:1},{track_id:100,azimuth_mdeg:65000,elevation_mdeg:0,observations:4,track_state:3},{track_id:101,azimuth_mdeg:0,elevation_mdeg:3000,observations:3,track_state:2}];
 context.renderCandidates({...plotState,proposals:liveProposals});
 assert(nodes.get('candidate_select').children.length===1);
 assert(nodes.get('live_proposals').children.length===3,'all returned proposals visible alongside diagnosis');
 assert(nodes.get('live_proposals').children[0].textContent.includes('99'));
 assert(nodes.get('live_proposals').children[2].textContent.includes('历史方向'));
 context.renderCandidates({...plotState,candidates:[],proposals:liveProposals});
 assert(nodes.get('live_proposals').children.length===3,'proposals remain visible without snapshot');
 context.renderCandidates({...plotState,proposals:[]});assert(nodes.get('live_proposals').textContent.includes('暂无提议'));
 function packet(seq,track=7,env=1,status=1){let b=new ArrayBuffer(8512),v=new DataView(b);[0x43394732,1,seq,track,0,78125,2,4096,128,env,status,123456,3,4,0,0].forEach((x,i)=>v.setUint32(i*4,x,true));for(let i=0;i<4096;i++)v.setInt16(64+i*2,Math.round(1000*Math.sin(i*.2)),true);for(let i=0;i<128;i++)v.setUint16(8256+i*2,i*7,true);return b;}
 function show(seq){context.renderCandidates({...plotState,sequence:seq});nodes.get('candidate_select').value='7';}
 let plotRequests=[];context.fetch=async path=>{plotRequests.push(path);return {ok:true,status:200,arrayBuffer:async()=>packet(77)};};show(77);
 assert(await context.preview());assert(context.guiDisplayedPlot.sequence===77);
 assert(plotRequests.length===1&&plotRequests[0].includes('/api/gui/snapshot?'));
 assert(nodes.get('envelope_note').textContent.includes('仅显示Hz包络'));
 assert(nodes.get('spectrum_note').textContent.includes('快照 #77'));
 show(78);assert(context.guiDisplayedPlot.sequence===77);assert(nodes.get('plot_note').textContent.includes('历史快照 #77'));
 context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>packet(78,99)});
 assert(!await context.preview());assert(context.guiDisplayedPlot.sequence===77,'wrong track cannot replace a valid display');
 context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>new ArrayBuffer(128)});
 assert(!await context.preview());assert(context.guiDisplayedPlot.sequence===77,'short packet cannot replace display');
 let tries=0;plotRequests=[];
 context.fetch=async path=>{plotRequests.push(path);if(path==='/api/candidates')return {ok:true,status:200,json:async()=>({...plotState,sequence:79})};if(tries++===0)return {ok:false,status:409};return {ok:true,status:200,arrayBuffer:async()=>packet(79)};};
 assert(await context.preview());assert(context.guiDisplayedPlot.sequence===79);assert(plotRequests.length===3,'one409 -> refresh metadata -> one retry');
 show(80);context.fetch=async()=>{show(81);return {ok:true,status:200,arrayBuffer:async()=>packet(80)};};
 assert(await context.preview());assert(context.guiDisplayedPlot.sequence===80,'complete older snapshot is retained when polling advances');assert(nodes.get('plot_note').textContent.includes('历史快照 #80'));
 show(82);context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>packet(82,7,0,4)});
 assert(await context.preview());assert(nodes.get('envelope_note').textContent.includes('输入无效'));
 show(83);let release;plotRequests=[];context.fetch=async path=>{plotRequests.push(path);return {ok:true,status:200,arrayBuffer:()=>new Promise(resolve=>{release=resolve;})};};
 let pending=context.preview();await new Promise(resolve=>setImmediate(resolve));assert(!await context.preview(),'only one plot read may be active');release(packet(83));assert(await pending);assert(plotRequests.length===1);

 show(84);let releaseCancelled;context.fetch=async()=>({ok:true,status:200,arrayBuffer:()=>new Promise(resolve=>{releaseCancelled=resolve;})});
 let cancelled=context.preview();await new Promise(resolve=>setImmediate(resolve));context.guiPreviewToken++;releaseCancelled(packet(84));assert(!await cancelled);assert(context.guiDisplayedPlot.sequence===83,'user selection cancels pending response');
 show(84);context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>{let b=packet(84);new DataView(b).setUint32(13*4,9,true);return b;}});
 assert(!await context.preview());assert(context.guiDisplayedPlot.sequence===83,'wrong acquisition session rejected');
 let retries=0;context.fetch=async path=>{retries++;return path==='/api/candidates'?{ok:true,status:200,json:async()=>({...plotState,sequence:84})}:{ok:false,status:409};};
 assert(!await context.preview());assert(retries===3,'repeated409 remains bounded');
 context.renderCandidates({...plotState,sequence:84,candidates:[]});assert(context.guiDisplayedPlot.sequence===83);
 nodes.get('auto_preview').checked=true;context.c9state={...plotState,sequence:85};nodes.get('candidate_select').value='7';context.guiLastCandidate=Date.now();context.automaticPlotAt=0;
 context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>packet(85)});await context.automaticPreview();assert(context.guiDisplayedPlot.sequence===85);
 let duplicateReads=0;context.fetch=async()=>{duplicateReads++;return {ok:true,status:200,arrayBuffer:async()=>packet(85)};};
 context.automaticPlotAt=Date.now()-1500;await context.automaticPreview();assert(duplicateReads===0,'same successful snapshot is not downloaded again');
 context.c9state={...plotState,sequence:86};context.automaticPlotAt=Date.now()-500;await context.automaticPreview();assert(duplicateReads===0,'one-second request rate bound');
 context.automaticPlotAt=Date.now()-1500;context.fetch=async()=>{duplicateReads++;return {ok:true,status:200,arrayBuffer:async()=>packet(86)};};await context.automaticPreview();assert(duplicateReads===1&&context.guiDisplayedPlot.sequence===86,'new snapshot can refresh before old five-second limit');
 context.c9state={...plotState,sequence:85,snapshot_session:5};assert(context.plotRequestKey().startsWith('5/'),'auto refresh identity includes capture session');

 if(process.env.C9_GUI_BINARY_PACKET){
  let bytes=fs.readFileSync(process.env.C9_GUI_BINARY_PACKET),binaryPacket=bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);
  show(1);context.fetch=async()=>({ok:true,status:200,arrayBuffer:async()=>binaryPacket});
  assert(await context.preview());assert(context.guiDisplayedPlot.sequence===1&&context.guiDisplayedPlot.session===4);
  assert(context.guiDisplayedPlot.envelope_valid===1);assert(nodes.get('envelope_note').textContent.includes('仅显示Hz包络'));
  console.log('C9_C_TO_JS_SNAPSHOT_PASS source=synthetic_native_C_packet');
 }

 assert(context.guiSpectrumView.max_hz===8000&&context.guiSpectrumView.bins===838&&context.guiSpectrumView.last_hz<=8000,'audio spectrum ends at8kHz at actual FFT bin positions');
 function map(seq,frame,peak,value=100){let scores=Array(1024).fill(0);if(peak!==null)scores[peak]=value;return {sequence:seq,frame,scores,accepted:0,reason:36};}
 context.heatmapView={values:null,key:null,at:0,lastSignal:0,lo:0,hi:0,smooth:true,seq:0};
 let flatMap=map(2,1,null),display=context.heatmapDisplay(flatMap,1000,true);assert(display.flat&&display.values.every(x=>x===0),'allzero cannot invent hotspot');
 let a=map(4,2,100);display=context.heatmapDisplay(a,1100,true);let prior=display.values.slice();
 let duplicate=context.heatmapDisplay(a,1150,true);assert(!duplicate.newFrame&&duplicate.values.every((x,i)=>x===prior[i]),'polling one map twice does not accumulate evidence');
 let b=map(6,3,200);display=context.heatmapDisplay(b,1200,true);assert(display.values[100]>0&&display.values[200]<100,'display smoothing damps peak jumps');assert(b.accepted===0&&b.reason===36,'display never promotes rejected localization');
 let rawMapView=context.heatmapDisplay(b,1250,false);assert(rawMapView.values[100]===0&&rawMapView.values[200]===100,'raw mode is unmodified score map');
 context.heatmapDisplay(map(8,4,200),1300,true);let fading=context.heatmapDisplay(map(10,5,null),1400,true);assert(fading.sourceFlat&&!fading.flat,'last image fades explicitly');
 assert(context.heatmapDisplay(map(12,6,null),2200,true).flat,'flat input loses historical hotspot after800ms');
 let reset=context.heatmapDisplay(map(2,1,300),2300,true);assert(reset.values[300]===100&&reset.values[200]===0,'reset sequence starts new display history');
 assert(context.heatmapDisplay({sequence:4,frame:2,scores:[NaN]},2400,true)===null,'malformed map rejected');

 // Display interpolation never becomes an algorithm input or a new peak detector.
 const mapRequestCount=paths.length;
 const field=Array.from({length:1024},(_,i)=>i%32+10*Math.floor(i/32)),saved=field.slice();
 assert(context.mapSample(field,4.5,8.5)===89.5);assert(context.mapSample(field,-5,-5)===0);assert(context.mapSample(field,40,40)===341);
 for(let y=0;y<256;y+=3)for(let x=0;x<256;x+=3){let v=context.mapSample(field,(x+.5)/8-.5,31-((y+.5)/8-.5));assert(v>=0&&v<=341);}
 assert(field.every((v,i)=>v===saved[i]),'interpolation cannot mutate raw scores');
 assert(JSON.stringify(context.mapColor(0))==='[68,1,84]'&&JSON.stringify(context.mapColor(1))==='[253,231,37]','Viridis endpoints');
 context.mapColorScale={ready:false,lo:0,hi:1};context.heatmapView={values:null,key:null,at:0,lastSignal:0,lo:0,hi:0,smooth:false,seq:0};
 nodes.get('map_smooth').checked=false;nodes.get('map_interp').checked=true;nodes.get('map_scale').value='locked';
 context.c9state={...candidate,candidates:[],proposals:[]};context.renderMap(map(100,50,null));assert(!context.mapColorScale.ready&&context.mapRaster.canvas.width===256,'flat input stays neutral without initializing arbitrary scale');assert(context.mapRaster.canvas.image.data[0]===20&&context.mapRaster.canvas.image.data[1]===36,'flat image has no colored hotspot');
 context.renderMap(map(102,51,100));assert(context.mapColorScale.ready&&context.mapColorScale.hi===100);
 let imageCount=canvasOperations.filter(x=>x.op==='image').length;context.renderMap(map(102,51,100));assert(canvasOperations.filter(x=>x.op==='image').length===imageCount,'same frame uses cached raster');
 context.renderMap(map(104,52,100,1000));assert(context.mapColorScale.hi===100&&nodes.get('map_note').textContent.includes('超出色阶'),'a new maximum cannot silently renormalize locked scale');
 nodes.get('map_scale').value='auto';nodes.get('map_scale_reset').onclick();assert(nodes.get('map_scale').value==='locked'&&context.mapColorScale.hi===1000,'reset explicitly locks current range');
 nodes.get('map_interp').checked=false;context.mapColorScale={ready:false,lo:0,hi:1};let rows=Array.from({length:1024},(_,i)=>Math.floor(i/32));context.renderMap({...map(106,53,null),scores:rows});
 let pixels=context.mapRaster.canvas.image.data;assert(context.mapRaster.canvas.width===32);assert(pixels[0]===253&&pixels[1]===231&&pixels[31*32*4]===68,'top is positive elevation; row0 remains at bottom');
 const oldControl=context.control;let clicked=[];context.control=p=>clicked.push(p);let canvas=nodes.get('direction_map');canvas.width=410;canvas.height=450;
 canvas.onclick.call(canvas,{clientX:54,clientY:18});canvas.onclick.call(canvas,{clientX:373.9,clientY:337.9});canvas.onclick.call(canvas,{clientX:374,clientY:100});assert(clicked.length===2&&clicked[0].endsWith('grid=992')&&clicked[1].endsWith('grid=31'),'interpolation preserves original32x32 click grid');context.control=oldControl;
 canvasOperations.length=0;context.guiLastCandidate=Date.now();context.c9state={...candidate,candidates:[{track_id:7,azimuth_mdeg:0,elevation_mdeg:0,stable:1,separation_ready:1,diagnosis:{fault_direction_valid:1,binding:{track_id:7},model_version:0}}],proposals:[]};context.renderMap(map(108,54,100));assert(!canvasOperations.some(x=>x.style==='#ff6174'),'unvalidated result never draws confirmed-fault red');
 canvasOperations.length=0;context.guiTrails.clear();context.c9state={...candidate,candidates:[{track_id:7,stale:1}],proposals:[]};context.renderMap({...map(110,55,100),map_age_us:10000,stale_after_us:5000});assert(nodes.get('map_note').textContent.includes('已过期')&&!canvasOperations.some(x=>x.op==='strokeRect')&&canvasOperations.some(x=>x.op==='drawImage'&&x.alpha===.45),'stale background dims and stale diagnostic marker is hidden');assert(paths.length===mapRequestCount,'display controls add no HTTP requests');let aged={...map(112,56,100),map_age_us:100,stale_after_us:5000};context.renderMap(aged);context.guiLastMapAt=Date.now()-1000;context.renderMap(aged);assert(nodes.get('map_note').textContent.includes('已过期'),'changing display controls cannot revive an old cached map');canvasOperations.length=0;context.renderMap(null);assert(nodes.get('map_note').textContent.includes('不可用')&&canvasOperations.some(x=>x.op==='clearRect')&&!canvasOperations.some(x=>x.op==='strokeRect'),'missing map clears old confirmation markers');
 console.log('C9_HEATMAP_P0_PASS interpolation_bounds=1 centers_and_orientation=1 scale_lock=1 flat_neutral=1 cache=1 original_click_grid=1 invalid_never_confirmed=1');

 const savedFetch=context.fetch;let acceptedBodies=0;
 context.fetch=async path=>({ok:true,status:path==='/api/target/fault'||path==='/api/heatmap'?202:200,json:async()=>{if(path==='/api/target/fault')acceptedBodies++;return path==='/api/candidates'?{...candidate,shaft_confirmed:1,shaft_millihz:30000}:path.startsWith('/api/rpm?')?{rpm:1800,shaft_millihz:30000}:path.startsWith('/api/recording/')?{udp_enabled:path.endsWith('/on')?1:0}:path.startsWith('/api/gsc/')?{gsc_requested:1,freeze_updates:1,gsc_reason:9}:{mode:'fault',state:'waiting_for_validated_fault_direction'};}});
 await context.control('/api/rpm?value=1800');assert(nodes.get('action_note').textContent.includes('已确认 1800')&&nodes.get('model_note').textContent.includes('已确认转速 1800'),'RPM confirmation reads back visible state');
 await context.control('/api/recording/on');assert(nodes.get('action_note').textContent.includes('已开启')&&nodes.get('action_note').textContent.includes('PC接收端'));
 await context.control('/api/recording/off');assert(nodes.get('action_note').textContent.includes('已关闭'));
 await context.control('/api/gsc/freeze');assert(nodes.get('action_note').textContent.includes('冻结')&&nodes.get('action_note').textContent.includes('旁路：缺少有效配置'),'requested GSC is not mislabeled active');
 await context.control('/api/target/fault');assert(acceptedBodies===1&&nodes.get('action_note').textContent.includes('等待可信故障方向'),'202 control response is parsed and waiting is explicit');
 assert(await context.get('/api/heatmap')===null,'202 heatmap updating contract unchanged');
 context.fetch=async()=>({ok:false,status:409});await context.control('/api/rpm?value=1800');assert(nodes.get('action_note').textContent.includes('失败')&&nodes.get('action_note').textContent.includes('409'),'errors never report success');context.fetch=savedFetch;
 console.log('C9_CONTROL_FEEDBACK_PASS rpm_readback=1 udp=1 GSC_request_vs_bypass=1 accepted202=1 error=1');
 context.text('model_note','快照 #4294967295，年龄 999999 ms');assert(nodes.get('model_note').textContent==='快照 #4294967295，年龄 999999 ms'&&nodes.get('model_note').children.length===0,'contiguous prose');
 context.renderCandidates({...candidate,proposals:[{track_id:4294967295,azimuth_mdeg:-87123,elevation_mdeg:1234,observations:999999,track_state:1}]});
 assert(nodes.get('live_proposals').children.length===3&&nodes.get('live_proposals').children[0].children.length===5,'fixed proposal columns');assert(nodes.get('live_proposals').children[0].children[0].textContent==='4294967295','full ID');assert(html.includes('max-width:none')&&html.includes('overflow:visible')&&!html.includes('.numeric-slot')&&!html.includes('.value-slot'),'no scrolling numeric boxes');console.log('C9_WIDE_LAYOUT_PASS');
 console.log('C9_GUI_DOM_PASS ids='+nodes.size+' source=mocked_offline_only');}
run().then(()=>{if(process.env.C9_HEATMAP_RECORD){
 const dir=process.env.C9_HEATMAP_RECORD;nodes.get('direction_map').width=410;nodes.get('direction_map').height=450;nodes.get('map_interp').checked=true;nodes.get('map_smooth').checked=true;nodes.get('show_proposals').checked=true;nodes.get('candidate_select').value='7';
 context.mapColorScale={ready:false,lo:0,hi:1};context.heatmapView={values:null,key:null,at:0,lastSignal:0,lo:0,hi:0,smooth:true,seq:0};context.guiTrails.clear();context.guiLastCandidate=Date.now();
 context.c9state={...candidate,candidates:[{track_id:7,azimuth_mdeg:-25000,elevation_mdeg:20000,stable:1,separation_ready:1,diagnosis:{fault_direction_valid:0}}],proposals:[{track_id:7,azimuth_mdeg:-25000,elevation_mdeg:20000,observations:4,track_state:1},{track_id:8,azimuth_mdeg:40000,elevation_mdeg:-15000,observations:3,track_state:1}]};
 const scores=Array.from({length:1024},(_,i)=>{let x=-90+(i%32+.5)*180/32,y=-90+(Math.floor(i/32)+.5)*180/32;return Math.round(900*Math.exp(-((x+25)**2+(y-20)**2)/450)+550*Math.exp(-((x-40)**2+(y+15)**2)/288)-80);});
 canvasOperations.length=0;context.renderMap({sequence:200,frame:200,accepted:0,reason:36,map_age_us:5000,stale_after_us:20000,scores});
 fs.writeFileSync(dir+'/canvas.rgba',Buffer.from(context.mapRaster.canvas.image.data));fs.writeFileSync(dir+'/canvas_ops.json',JSON.stringify({source:'OFFLINE_SYNTHETIC_CANVAS_RECORDING_NOT_BROWSER_SCREENSHOT',size:context.mapRaster.canvas.width,operations:canvasOperations.filter(x=>x.node===nodes.get('direction_map')).map(x=>({op:x.op,style:x.style,fill:x.fill,width:x.width,args:x.op==='drawImage'?[]:x.args}))}));
}}).catch(e=>{console.error(e);process.exitCode=1;});
