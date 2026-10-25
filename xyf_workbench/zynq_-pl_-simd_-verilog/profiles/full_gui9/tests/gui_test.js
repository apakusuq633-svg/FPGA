const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(__dirname+'/full_gui.html','utf8');
class Node{constructor(tag){this.tag=tag;this.children=[];this.style={};this.value='';this.text='';this.width=560;this.height=250;this.disabled=false;}set textContent(x){this.text=String(x);this.children=[];}get textContent(){return this.text;}appendChild(n){this.children.push(n);if(this.tag==='select'&&!this.value)this.value=n.value;return n;}getContext(){return new Proxy({},{get:()=>()=>{}});}getBoundingClientRect(){return {left:0,top:0,width:this.width,height:this.height};}click(){}}
let nodes=new Map();for(const m of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)){assert(!nodes.has(m[2]),'duplicate '+m[2]);let n=new Node(m[1]);nodes.set(m[2],n);}
nodes.get('history_range').value='300';
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
 console.log('C9_GUI_DOM_PASS ids='+nodes.size+' source=mocked_offline_only');}
run().catch(e=>{console.error(e);process.exitCode=1;});
