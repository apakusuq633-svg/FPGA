var c9busy = false;
async function c9view() {
  if (paused || c9busy || !latest || latest.input_channels !== 9) return;
  c9busy = true;
  try {
    if (!el('c9map')) {
      var box = document.createElement('section');
      box.innerHTML = '<h3>9 麦声源热力图</h3><canvas id="c9map" width="320" height="320"></canvas><p id="c9note"></p><p id="c9gsc"></p><button id="c9on">启用自适应拾音</button> <button id="c9off">原始定向拾音</button> <button id="c9freeze">冻结更新</button> <button id="c9adapt">继续更新</button>';
      document.querySelector('main').appendChild(box);
      var timing = document.createElement('p');timing.id='c9latency';box.appendChild(timing);
      var autoButton=document.createElement('button');autoButton.textContent='恢复自动定位跟踪';
      autoButton.onclick=function(){fetch('/api/target/auto',{cache:'no-store'});};box.appendChild(autoButton);
      el('c9map').onclick=async function(e){
        var r=this.getBoundingClientRect(),x=Math.floor((e.clientX-r.left)*32/r.width),y=31-Math.floor((e.clientY-r.top)*32/r.height);
        if(x<0||x>31||y<0||y>31)return;
        try{var q=await fetch('/api/target?grid='+(y*32+x),{cache:'no-store'});if(!q.ok)throw Error('目标选择失败');
          el('c9gsc').textContent='已申请手动定向拾音，仍需通过几何和输入质量检查。';
        }catch(err){el('c9gsc').textContent=String(err);}
      };
      ['on', 'off', 'freeze', 'adapt'].forEach(function(k) {
        el('c9' + k).onclick = function() {
          fetch('/api/gsc/' + k, {cache: 'no-store'}).catch(function(e) { el('c9gsc').textContent = String(e); });
        };
      });
    }
    var r = await fetch('/api/heatmap', {cache: 'no-store'});
    if (r.status === 200) {
      var m = await r.json(), v = m.scores;
      if (v && v.length === 1024) {
        var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), g = el('c9map').getContext('2d');
        for (var i = 0; i < 1024; i++) {
          var t = hi > lo ? (v[i] - lo) / (hi - lo) : 0;
          g.fillStyle = 'hsl(' + (240 - 240 * t) + ',85%,45%)';
          g.fillRect(i % 32 * 10, (31 - Math.floor(i / 32)) * 10, 10, 10);
        }
        el('c9note').textContent = (m.accepted ? '已通过定位判定' : '候选声源图，尚未通过定位判定') +
          '；平面距离 ' + m.plane_z_m + ' m；每轴范围 ±' + m.half_width_m + ' m；帧 ' + m.frame;
      }
    }
    var q = await fetch('/api/gsc', {cache: 'no-store'});
    if (q.ok) {
      var z = await q.json();
      el('c9latency').textContent = '首个 PCM → PS 首次收到结果：目标 ' +
        (z.single_window_deadline_us / 1000).toFixed(2) + ' ms；' +
        (z.latency_samples ? '本次 ' + (z.pcm_to_ps_us / 1000).toFixed(3) +
          ' ms，最大 ' + (z.pcm_to_ps_max_us / 1000).toFixed(3) +
          ' ms，P95/P99 上界 ' + (z.pcm_to_ps_p95_upper_us / 1000).toFixed(3) +
          '/' + (z.pcm_to_ps_p99_upper_us / 1000).toFixed(3) +
          ' ms；超时 ' + z.deadline_misses + '/' + z.latency_samples +
          ' 帧；未读到的发布 ' + z.skipped_publications : '等待首次结果') +
        '。' + (z.location_stale ? '当前结果已过期。' : '') +
        ' 整链路实物验收：' + (z.board_validated ? '已完成' : '未完成');
      el('c9gsc').textContent = (!z.geometry_confirmed || !z.calibration_version ?
        '阵列几何或标定待验收，自适应输出旁路。' : '自适应拾音状态 ' + z.gsc_reason + '。') +
        ' 连续录音：UDP 1234；已发送 ' + z.udp_sent + ' 包；采集丢样 ' + z.dma_drops;
    }
  } catch (e) {
    if (el('c9note')) el('c9note').textContent = '热力图读取失败：' + String(e);
  } finally { c9busy = false; }
}
setInterval(c9view, 100);
