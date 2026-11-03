const fs=require('fs'),vm=require('vm'),assert=require('assert');
class El{constructor(){this.children=[];this.value='';}set textContent(s){this.value=String(s);this.children=[];}get textContent(){return this.value;}appendChild(e){this.children.push(e);}}
const els={};global.document={hidden:false,getElementById:id=>els[id]||(els[id]=new El()),createElement:()=>new El()};global.window={};global.setInterval=()=>0;global.fetch=()=>new Promise(()=>{});
vm.runInThisContext(fs.readFileSync('project/sw/ps_joint_score.js','utf8'));
const f=JSON.parse(fs.readFileSync('tests/score_api_fixtures.json','utf8'));window.c9RenderJointScore(f[0]);assert(els.ps_joint_state.textContent.includes('尚无'));
window.c9RenderJointScore(f[2]);assert(els.ps_joint_state.textContent.includes('新评分'));assert(els.ps_joint_bands.textContent.includes('中频：不可用'));
window.c9RenderJointScore(f[2]);assert(els.ps_joint_state.textContent.includes('保留同一评分'));
window.c9RenderJointScore(f[3]);assert(els.ps_joint_state.textContent.includes('已过期'));
window.c9RenderJointScore(f[1]);assert(els.ps_joint_values.children[2].children[1].textContent==='不可用');
window.c9RenderJointScore(f[4]);assert(els.ps_joint_state.textContent.includes('年龄未知'));console.log('SCORE_VIEW_STATE_PASS');
