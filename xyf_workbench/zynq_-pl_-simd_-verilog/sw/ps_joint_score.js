/* Only reads CPU0's accepted formal PS search snapshot. */
(function(){
 document.getElementById("ps_joint_panel").innerHTML="<h3>PS联合空间评分</h3><p id=\"ps_joint_state\">等待正式PS搜索</p><table id=\"ps_joint_values\"></table><details><summary>低／中／高频详情</summary><p id=\"ps_joint_bands\">不可用</p></details><small>原始评分非置信度；S2为球面NMS次峰，非第二声源。边界峰须谨慎解释。</small>";
 let key=null,busy=false;
 function render(s){
  const el=id=>document.getElementById(id),text=(id,v)=>{el(id).textContent=v;};
  if(!s.have||s.mode!=="PS_JOINT_FORMAL"){text("ps_joint_state","尚无正式PS联合评分");el("ps_joint_values").textContent="";text("ps_joint_bands","不可用");return;}
  const k=[s.session,s.epoch,s.sequence,s.first,s.end].join('/'),changed=k!==key;key=k;
  text("ps_joint_state",(s.fresh?(changed?"新评分":"保留同一评分"):"保留旧评分（已过期／采样身份不匹配）")+"；搜索#"+s.sequence+"；窗口["+s.first+","+s.end+")；年龄"+(s.age_ms==null?"未知":s.age_ms.toFixed(1)+" ms"));
  const ps=s.peaks||[],a=ps[0],b=ps[1],fmt=p=>p?(p.az/1000).toFixed(2)+"° / "+(p.el/1000).toFixed(2)+"°":"不可用";
  const rows=[["S1 原始评分",a?a.score:"不可用"],["S1 水平角／俯仰角",fmt(a)],["S2 球面NMS次峰",b?b.score:"不可用"],["S2 方向",fmt(b)],["ΔS = S1 − S2",s.gap==null?"不可用":s.gap]];
  if(ps.some(p=>p.boundary))rows.push(["俯仰边界提示","接近极点，方位角解释受限；不代表第二声源"]);
  el("ps_joint_values").textContent="";rows.forEach(r=>{const tr=document.createElement("tr");r.forEach(v=>{const td=document.createElement("td");td.textContent=String(v);tr.appendChild(td);});el("ps_joint_values").appendChild(tr);});
  text("ps_joint_bands",["低","中","高"].map((name,i)=>name+"频："+(s.scores_at_s1_grid&&s.scores_at_s1_grid[i]!=null?s.scores_at_s1_grid[i]:"不可用")).join("；")+"。仅为S1所在原始网格的同事件评分，不是各带独立主峰。");
 }
 window.c9RenderJointScore=render;
 async function poll(){if(document.hidden||busy||window.paused||typeof paused!=="undefined"&&paused)return;busy=true;try{const r=await fetch('/api/ps-score',{cache:'no-store',signal:AbortSignal.timeout(2000)});if(!r.ok)throw Error(r.status);window.c9RenderJointScore(await r.json());}catch(e){document.getElementById('ps_joint_state').textContent='评分通信不可用；保留旧值，不代表新评分';}finally{busy=false;}}
 setInterval(poll,1000);poll();
})();
