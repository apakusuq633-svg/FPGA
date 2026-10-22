// Check the embedded page without a browser or PL connection.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const root = path.resolve(__dirname, '..');
const header = fs.readFileSync(path.join(root, 'sw/ps_ui_page.h'), 'utf8');
const section = header.split('static const char UI_PAGE_HTML[] =')[1].split('\n\n')[0];
const html = [...section.matchAll(/^"(?:[^"\\]|\\.)*"/gm)].map(m => JSON.parse(m[0])).join('');
assert(Buffer.byteLength(html) < Number(header.match(/#define UI_BODY_MAX\s+(\d+)/)[1]));
assert(html.includes('lang="zh-CN"'));
assert(html.includes('&#22768;'));
const script = html.split('<script>')[1].split('</script>')[0];
const elements = new Map(); let strokes = 0;
function element(id) {
  if (!elements.has(id)) elements.set(id, {textContent:'', style:{}, width:640, height:180,
    appendChild(){this.rowCount=(this.rowCount||0)+1;}, getContext(){return {clearRect(){}, beginPath(){}, moveTo(){}, lineTo(){}, stroke(){strokes++;}}}});
  return elements.get(id);
}
const context = {document:{getElementById:element,createElement(){return {textContent:'',appendChild(){}}},createElementNS(){return {setAttribute(){}}}},
  fetch:()=>new Promise(()=>{}), setInterval(){}, setTimeout(){}, console};
vm.createContext(context); vm.runInContext(script, context);
context.render({have:0,input_mode:2,input_error:-1});
assert(element('state').textContent.includes('音频输入错误'));
const status = JSON.parse(fs.readFileSync(path.join(root,'build/gui_status.json'),'utf8'));
context.render(status);
assert(element('association').textContent.includes(String(status.first_sample)));
assert(element('source').textContent.includes('合成'));
assert(strokes === 2);
assert(element('dot').style.display === 'block');
context.render({...status,input_mode:2,synthetic:0,grid_w:0,grid:-1,gx:-1,gy:-1,audio_flags:16});
assert(element('association').textContent.includes('尚未提供'));
assert(element('dot').style.display === 'none');
assert(element('source').textContent.includes('FIFO'));
context.render({...status,display_dsp:1,mic_valid:1,mic_frozen:240,mic_rms_ppm:[1,2,3,4],mic_mean_ppm:[0,0,0,0],mic_peak_ppm:[2,3,4,5],mic_clipped:[0,0,0,0]});
assert(element('envelope_note').textContent.includes('分类器保持'));
assert(element('spectrum_note').textContent.includes('0 Hz 分量单独列出'));
console.log('UI_PAGE_PASS: waiting/error, metadata association, source and both plots');

let now=1000;context.Date={now:()=>now};
context.renderLocation({input_mode:2,loc_seq:2,loc_valid:1,loc_grid:255,loc_frame:1,loc_age_ms:10});
assert(element('dot').style.display==='block');
assert(element('dot').style.left==='100%');
assert(element('dot').style.top==='0%');
assert(element('association').textContent.includes('尚未同步'));
now+=200;
context.renderLocation({input_mode:2,loc_seq:4,loc_valid:0,loc_grid:0,loc_age_ms:0});
assert(element('dot').style.display==='block');
assert(element('dot').style.opacity==='.45');
context.renderLocation({input_mode:2,loc_seq:6,loc_valid:1,loc_grid:0,loc_age_ms:0});
assert(element('dot').style.left==='100%');
now+=200;
context.renderLocation({input_mode:2,loc_seq:8,loc_valid:1,loc_grid:0,loc_age_ms:0});
assert(parseFloat(element('dot').style.left)<100);
assert(context.track.length===2);
context.renderLocation({input_mode:2,loc_seq:8,loc_valid:1,loc_grid:0,loc_age_ms:0});
assert(context.track.length===2);
now+=1600;
context.renderLocation({input_mode:2,loc_seq:10,loc_valid:0,loc_grid:0,loc_age_ms:0});
assert(element('dot').style.display==='none');
now+=5000;
context.renderLocation({input_mode:2,loc_seq:12,loc_valid:0,loc_grid:0,loc_age_ms:0});
assert(context.track.length===0);
console.log('LOCATION_UI_PASS: hold, expiry, outlier confirmation, smoothing, dedup and trail expiry');
element('mics').rowCount=0;
const sixteen={...status,input_mode:2,input_channels:16,mic_valid:1,mic_frozen:0,
 mic_rms_ppm:Array(16).fill(10),mic_mean_ppm:Array(16).fill(0),
 mic_peak_ppm:Array(16).fill(20),mic_clipped:Array(16).fill(0)};
context.render(sixteen);context.renderLocation(sixteen);
assert(element('mics').rowCount===16);
assert(element('dot').style.display==='none');
assert(element('position').textContent.includes('固定正前方'));
assert(element('mic_note').textContent.includes('L/R=GND'));
console.log('LIVE16_UI_PASS: sixteen input levels and fixed DAS mode');
element('mics').rowCount=0;
const twelve={...sixteen,input_channels:12,loc_enabled:0,loc_grid_w:32,
 mic_rms_ppm:Array(12).fill(10),mic_mean_ppm:Array(12).fill(0),
 mic_peak_ppm:Array(12).fill(20),mic_clipped:Array(12).fill(0)};
context.render(twelve);context.renderLocation(twelve);
assert(element('mics').rowCount===12);
assert(element('mic_note').textContent.includes('66'));
assert(element('position').textContent.includes('图纸'));
assert(element('dot').style.display==='none');
console.log('LIVE12_UI_PASS: twelve inputs, six DATA lines, geometry-pending indication');
context.track=[];context.shown=null;context.lastLoc=0;context.lastGood=0;context.pending=null;
const located={...sixteen,loc_enabled:1,loc_grid_w:32,loc_valid:1,loc_grid:773,loc_seq:2,loc_frame:1,loc_age_ms:10,
 loc_compute_cycles:9968351,loc_steer_status:0,loc_error:0};
context.render(located);context.renderLocation(located);
assert(element('dot').style.display==='block');
assert(Math.abs(parseFloat(element('dot').style.left)-500/31)<1e-8);
assert(Math.abs(parseFloat(element('dot').style.top)-(100-2400/31))<1e-8);
assert(element('mic_note').textContent.includes('120 对定位'));
assert(element('association').textContent.includes('尚未同步'));
assert(element('association').textContent.includes('页面轮询 10 Hz'));
assert(element('association').textContent.includes('249.2 ms'));
assert(element('association').textContent.includes('等待方向确认'));
context.renderLocation({...located,loc_steer_status:16});
assert(element('association').textContent.includes('已锁定'));
context.renderLocation({...located,loc_error:4});
assert(element('association').textContent.includes('定位异常 4'));
context.renderLocation({...located,loc_seq:4,loc_grid:1024});
assert(element('dot').style.opacity==='.45');
console.log('LIVE16_LOCATION_UI_PASS: 32x32 coordinates, high grid index and invalid point hold');
now+=200;
context.renderLocation({...located,loc_quality_supported:1,loc_quality_permille:120,loc_raw_grid:778,
 loc_reason:4,loc_valid:0,loc_accepted:10,loc_rejected:3,loc_seq:6});
assert(element('association').textContent.includes('相关峰偏弱'));
assert(element('association').textContent.includes('12.0%（非正确率）'));
assert(element('association').textContent.includes('10/3'));
assert(element('dot').style.opacity==='.45');
now+=1600;
context.renderLocation({...located,loc_quality_supported:1,loc_reason:16,loc_valid:0,loc_seq:8});
assert(element('dot').style.display==='none');
assert(element('association').textContent.includes('等待连续确认'));
context.renderLocation({...located,loc_quality_supported:1,loc_reason:0,loc_valid:1,loc_grid:250,loc_seq:10});
assert(element('dot').style.display==='block');
assert(Math.abs(parseFloat(element('dot').style.left)-2600/31)<1e-8);
console.log('LOCATION_QUALITY_UI_PASS: rejection explanation, confidence is not accuracy, expiry and confirmed reacquisition');
