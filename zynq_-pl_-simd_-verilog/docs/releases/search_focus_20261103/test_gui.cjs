const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const script=fs.readFileSync(__dirname+'/listen.js','utf8');
async function scenario({udp=0,reject=false,timeout=false,closeFailure=false,storage=new Map(),initial='SEARCH'}={}){
 const nodes=new Map(), calls=[], snapshots=[];
 let now=0,mode=initial,step=0,delay=0;
 const element=()=>({value:'',appendChild(){},querySelector(){return element();}});
 const node=id=>{if(!nodes.has(id))nodes.set(id,element());return nodes.get(id);};
 const sessionStorage={getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)};
 const document={getElementById:node,createElement:element,querySelector:element,querySelectorAll:()=>[]};
 let callback;
 const fetch=async path=>{
  calls.push(path);
  if(path.startsWith('/api/system/focus')){
   if(reject)return {ok:false,status:409};
   mode='ENTERING_FOCUS';step=0;udp=1;
  }else if(path==='/api/system/search'){mode='RECOVERING_SEARCH';step=0;}
  else if(path==='/api/recording/off'){
   if(closeFailure)return {ok:false,status:500};
   udp=0;
  }
  if(path==='/api/system/state'){
   if(!timeout&&mode==='ENTERING_FOCUS'&&++step>=3)mode='FOCUS';
   if(mode==='RECOVERING_SEARCH'&&++step>=2)mode='SEARCH';
   snapshots.push(mode);
  }
  const manual=mode==='FOCUS'||mode==='ENTERING_FOCUS';
  const value=path==='/api/listen'?{udp_enabled:udp,mode:manual?'MANUAL_GSC':'PATROL_DAS',
    revision:1,version:1,applied_version:1,az:50,el:-38,engine:'GSC_ACTIVE',formal_fresh:1,
    formal_az:50,formal_el:-38,points:Array.from({length:8},()=>({enabled:0,az:0,el:0,ms:3000}))}:
    {state:mode,cpu1_quiescent:+(mode==='FOCUS'),gsc_allowed:+(mode==='FOCUS'),search_diagnosis_paused:+(mode!=='SEARCH')};
  return {ok:true,json:async()=>value};
 };
 vm.runInNewContext(script,{document,fetch,sessionStorage,localStorage:{getItem:()=>null},window:{},
   renderMap(){},AbortSignal,performance:{now:()=>now},setTimeout:f=>{now+=1000;f();},setInterval:f=>{callback=f;}});
 await new Promise(setImmediate);
 node('listen-az').value='50';node('listen-el').value='-38';
 return {node,calls,snapshots,storage,enter:()=>node('listen-lock').onclick(),leave:()=>node('listen-back').onclick(),udp:()=>udp,refresh:callback};
}
(async()=>{
 let x=await scenario();
 const first=x.enter();await x.enter();await first;
 assert.equal(x.calls.filter(k=>k.startsWith('/api/system/focus?')).length,1);
 assert.match(x.node('listen-state').textContent,/FOCUS · 精细监听/);
 assert(x.snapshots.includes('ENTERING_FOCUS'));
 const refreshed=await scenario({initial:'FOCUS',udp:1,storage:x.storage});
 assert.match(refreshed.node('listen-state').textContent,/FOCUS · 精细监听/);
 await refreshed.leave();assert.equal(refreshed.udp(),0);assert.match(refreshed.node('listen-state').textContent,/SEARCH/);
 x=await scenario({udp:1});await x.enter();await x.leave();assert.equal(x.udp(),1);assert(!x.calls.includes('/api/recording/off'));
 x=await scenario({reject:true});await x.enter();assert.match(x.node('listen-note').textContent,/409/);
 x=await scenario({timeout:true});await x.enter();assert.match(x.node('listen-note').textContent,/超时/);await x.leave();assert.equal(x.udp(),0);
 x=await scenario({closeFailure:true});await x.enter();await x.leave();assert.match(x.node('listen-note').textContent,/SEARCH已恢复，UDP收尾未确认/);
 x=await scenario();x.node('listen-az').value='999';await x.enter();assert(!x.calls.some(k=>k.startsWith('/api/system/focus?')));
 await x.node('listen-stop').onclick();assert(x.calls.some(k=>k.startsWith('/api/listen/stop?rev=')));assert(!x.calls.includes('/api/recording/off'));
 console.log('PASS: enter/exit, duplicate, reload, preowned UDP, rejection, timeout/cancel, partial cleanup failure, invalid angle, DAS stop');
})().catch(e=>{console.error(e);process.exitCode=1;});
