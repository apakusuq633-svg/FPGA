function gccFft(re,im,inverse){
 var n=re.length;for(var i=1,j=0;i<n;i++){var bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){var t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
 for(var len=2;len<=n;len*=2){var angle=(inverse?2:-2)*Math.PI/len,wr=Math.cos(angle),wi=Math.sin(angle);
  for(var start=0;start<n;start+=len){var ur=1,ui=0;for(j=0;j<len/2;j++){var a=start+j,b=a+len/2,vr=re[b]*ur-im[b]*ui,vi=re[b]*ui+im[b]*ur;re[b]=re[a]-vr;im[b]=im[a]-vi;re[a]+=vr;im[a]+=vi;var next=ur*wr-ui*wi;ui=ur*wi+ui*wr;ur=next;}}}
 if(inverse)for(i=0;i<n;i++){re[i]/=n;im[i]/=n;}
}
function gccPeak(curve,limit,mode,fs){
 var lag=0,best=-Infinity;for(var k=-limit;k<=limit;k++){var v=curve[k+64],score=mode==='negative'?-v:mode==='absolute'?Math.abs(v):v;if(score>best){best=score;lag=k;}}
 var center=curve[lag+64];if((mode==='positive'&&center<=0)||(mode==='negative'&&center>=0)||Math.abs(center)<1e-12)return null;
 var polarity=mode==='negative'?-1:mode==='absolute'?(center<0?-1:1):1;
 var local=polarity*center>=polarity*curve[lag+63]&&polarity*center>=polarity*curve[lag+65]&&
  (polarity*center>polarity*curve[lag+63]||polarity*center>polarity*curve[lag+65]);
 var delta=0,edge=Math.abs(lag)===limit,refined=false;
 if(!edge){var sign=mode==='negative'?-1:mode==='absolute'?(center<0?-1:1):1,l=sign*curve[lag+63],m=sign*center,r=sign*curve[lag+65],den=l-2*m+r;
  if(den<-1e-15){delta=Math.max(-.5,Math.min(.5,.5*(l-r)/den));refined=true;}}
 return {integer_samples:lag,samples:lag+delta,microseconds:(lag+delta)*1e6/fs,value:center,sign:center<0?-1:1,boundary:edge,interpolated:refined,local_extremum:local};
}
function gccAnalyze(samples,fs,positions){
 var n=2048,frames=samples[0].length,cache=[],records=[];
 samples.forEach(function(x){var re=new Float64Array(n),im=new Float64Array(n),mean=0;for(var i=0;i<frames;i++)mean+=x[i]/frames;
  for(i=0;i<frames;i++)re[i]=(x[i]-mean)*(.5-.5*Math.cos(2*Math.PI*i/(frames-1)));gccFft(re,im,false);cache.push({re:re,im:im});});
 for(var a=0;a<samples.length;a++)for(var b=a+1;b<samples.length;b++){
  var re=new Float64Array(n),im=new Float64Array(n),mag=new Float64Array(n),max=0;
  // B*conj(A): positive lag means B arrives later than A.
  for(var k=0;k<n;k++){var f=Math.min(k,n-k)*fs/n;if(f<200||f>8000)continue;
   re[k]=cache[b].re[k]*cache[a].re[k]+cache[b].im[k]*cache[a].im[k];im[k]=cache[b].im[k]*cache[a].re[k]-cache[b].re[k]*cache[a].im[k];mag[k]=Math.hypot(re[k],im[k]);max=Math.max(max,mag[k]);}
  var bins=0;for(k=0;k<n;k++){if(mag[k]>Math.max(max*1e-9,1e-12)){re[k]/=mag[k];im[k]/=mag[k];bins++;}else{re[k]=0;im[k]=0;}}
  gccFft(re,im,true);var curve=[];for(k=-64;k<=64;k++)curve.push(re[(k+n)%n]);
  var distance=Math.hypot(positions[b][0]-positions[a][0],positions[b][1]-positions[a][1],positions[b][2]-positions[a][2]);
  var physical=distance*fs/343,limit=Math.min(63,Math.ceil(physical)),valid=bins>0;
  var r={a:a,b:b,same_din:Math.floor(a/2)===Math.floor(b/2),distance_mm:distance*1000,max_physical_samples:physical,limit:limit,bins:bins,curve:curve,
   positive:valid?gccPeak(curve,limit,'positive',fs):null,negative:valid?gccPeak(curve,limit,'negative',fs):null,absolute:valid?gccPeak(curve,limit,'absolute',fs):null};
  ['positive','negative','absolute'].forEach(function(name){var p=r[name];if(p){p.outside_physical=Math.abs(p.samples)>physical+1e-9;p.rejection_reasons=[];if(p.boundary)p.rejection_reasons.push('搜索边界');if(p.outside_physical)p.rejection_reasons.push('超几何界限');if(!p.local_extremum)p.rejection_reasons.push('非局部极值');p.candidate_usable=p.rejection_reasons.length===0;}});records.push(r);
 }return records;
}
function gccEstimateText(p){if(!p)return '无有效峰';return (p.candidate_usable?'候选 '+p.samples.toFixed(3)+' 点 / '+p.microseconds.toFixed(2)+' us':'无有效时延候选\n诊断极值 '+p.samples.toFixed(3)+' 点')+'\n值 '+p.value.toFixed(5)+(p.rejection_reasons.length?' ['+p.rejection_reasons.join(' / ')+']':'\n尚未验证为声学时延');}
