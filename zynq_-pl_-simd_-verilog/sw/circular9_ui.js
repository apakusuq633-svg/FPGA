var c9busy = false, c9candidateAt = 0, c9lastCandidatesOk = 0, c9candidates = null;
var c9hiddenSections = [], c9changedText = [];
function c9live(s) { return !!(s && s.input_channels === 9 && s.input_mode === 2); }
function c9text(node, text) {
  if (!node) return;
  if (!c9changedText.some(function(p) {return p.node === node;})) c9changedText.push({node:node,text:node.textContent});
  node.textContent = text;
}
function c9legacyPanels(hide) {
  if (!hide) {
    c9hiddenSections.forEach(function(p) {p.node.hidden = p.hidden;});c9hiddenSections = [];
    c9changedText.forEach(function(p) {p.node.textContent = p.text;});c9changedText = [];
    if (el('c9section')) el('c9section').hidden = true;
    return;
  }
  ['position','diagnosis','spectrum_plot','envelope_plot','raw_button'].forEach(function(id) {
    var node = el(id), section = node && node.closest('section');
    if (section && !c9hiddenSections.some(function(p) {return p.node === section;})) {
      c9hiddenSections.push({node:section,hidden:section.hidden});section.hidden = true;
    }
  });
  if (el('c9section')) el('c9section').hidden = false;
  var levelSection = el('levels') && el('levels').closest('section');
  c9text(levelSection && levelSection.querySelector('h2'), '各方向分离音频电平');
  c9text(levelSection && levelSection.querySelector('.muted'), 'RMS 来自对应轨迹的 1.024 秒分离音频；以满量程百分比表示。过期结果仅供回看，不能作为当前故障方向。');
  var runtimeSection = el('runtime') && el('runtime').closest('section');
  c9text(runtimeSection && runtimeSection.querySelector('.muted'), 'CPU0 持续采集并读取 FPGA 定位；CPU1 在同一原始快照上分离候选方向，再执行诊断。定位延迟和诊断观察时间分别统计。');
  c9text(el('mic_note'), '9 路同步输入，5 根共享 DATA；外圈 8 麦加中心 1 麦。以下为各通道的 PDM 活动及输入快照电平，通道顺序、几何和标定须按实物验收。');
}
function c9status(s) {
  if (!c9live(s)) return;
  var state = c9candidates;
  el('source').textContent = '输入：9 麦同步 PDM；FPGA 方向定位 → PS 候选分离与诊断';
  el('state').textContent = s.input_error ? '音频输入错误：' + s.input_error :
    !state ? '采集中，等待方向与诊断接口' : (state.candidates || []).length ? '方向候选与诊断已更新' : '采集中，等待稳定候选方向';
  el('age').textContent = state ? '诊断快照 #' + state.sequence + ' | 收到距今：' + state.result_age_ms + ' ms' : '';
  el('runtime').textContent = '';
  [['已接收音频块',s.received_blocks],['PL / 数据源丢失采样点',s.pl_dropped],['PS 丢失采样点',s.ps_dropped],
    ['音频段重置次数',s.discontinuities],['CPU1 正在分离 / 诊断',s.computing],
    ['最近候选分离与诊断处理耗时（ms）',state ? state.processing_ms : '等待首个候选快照'],
    ['诊断观察窗（ms）',1024]].forEach(function(v) {runtimeRow(v[0],v[1] === undefined ? '未提供' : v[1]);});
  var table = el('levels');table.textContent = '';
  (state && state.candidates || []).forEach(function(c) {
    var d = c.diagnosis || {}, tr = document.createElement('tr');
    ['轨迹 ' + c.track_id + (c.stale ? '（过期）' : ''),
      Number.isFinite(d.rms) ? (d.rms * 100).toFixed(4) + ' %FS RMS' : '等待分离音频'].forEach(function(v) {
      var td = document.createElement('td');td.textContent = v;tr.appendChild(td);
    });table.appendChild(tr);
  });
  if (!table.childNodes.length) {
    var tr = document.createElement('tr'), td = document.createElement('td');td.textContent = '等待候选方向的分离音频';tr.appendChild(td);table.appendChild(tr);
  }
}
/* Keep legacy DOM nodes for the shared renderer; only the live nine-mic path
 * substitutes the newer direction/candidate panels and data source. */
var c9legacyRender = render, c9legacyRenderLocation = renderLocation;
render = function(s) {
  if (!c9live(s) && c9hiddenSections.length) c9legacyPanels(false);
  c9legacyRender(s);
  if (c9live(s)) {c9legacyPanels(true);c9status(s);}
};
renderLocation = function(s) {if (!c9live(s)) c9legacyRenderLocation(s);};
function c9angle(mdeg) { return Number.isFinite(mdeg) ? (mdeg / 1000).toFixed(2) + '°' : '未知'; }
function c9fault(c, state) {
  return !!(c.diagnosis && c.diagnosis.fault_direction_valid && c.diagnosis.binding &&
    c.diagnosis.binding.track_id === c.track_id && c.diagnosis.binding.grid === c.grid &&
    c.diagnosis.model_version === state.model_version && c.stable && c.separation_ready && !c.stale &&
    state.geometry_confirmed && state.calibration_version && state.model_validated);
}
function c9candidateView(state) {
  var proposals = el('c9proposals');proposals.textContent = '';
  var stages = {1:'已连续观测',2:'短暂缺测，保留身份并暂停故障定向',3:'正在恢复确认'};
  (state.proposals || []).forEach(function(p) {
    var line = document.createElement('p');
    line.textContent = '候选轨迹 ' + p.track_id + '：水平角 ' + c9angle(p.azimuth_mdeg) +
      '，俯仰角 ' + c9angle(p.elevation_mdeg) + '；' + (stages[p.track_state] || '方向待确认') +
      (p.angle_refined ? '；已局部拟合，实际精度待实测' : '');
    proposals.appendChild(line);
  });
  var list = el('c9candidates');list.textContent = '';
  (state.candidates || []).forEach(function(c) {
    var d = c.diagnosis || {}, item = document.createElement('p');
    var names = {normal:'正常',fault:'故障',interference:'干扰',anomaly:'异常（未确认故障）',unknown:'未知'};
    var fault = c9fault(c, state), label = fault ? '故障方向已确认' :
      d.label === 'fault' ? '方向诊断待重新确认' : names[d.label] || '未知';
    item.style.color = fault ? '#dc2626' : d.label === 'normal' ? '#15803d' : 'inherit';
    item.textContent = '轨迹 ' + c.track_id + '：方位角 ' + c9angle(c.azimuth_mdeg) +
      '，俯仰角 ' + c9angle(c.elevation_mdeg) + '；' + label +
      '；' + (c.stale ? '轨迹已过期' : c.stable ? '轨迹稳定' : '方向待稳定') +
      '；' + (c.separation_ready ? '已有定向分离音频' : '分离条件待满足') +
      (d.reason && d.reason !== 'ok' ? '；诊断状态 ' + d.reason : '');
    var button = document.createElement('button');button.textContent = '拾取此方向';
    button.disabled = !!c.stale;
    button.onclick = function() {
      fetch('/api/target?grid=' + c.grid, {cache:'no-store'})
        .then(function(r) { if (!r.ok) throw Error('目标选择失败'); })
        .catch(function(e) { el('c9gsc').textContent = String(e); });
    };
    item.appendChild(document.createTextNode(' '));item.appendChild(button);list.appendChild(item);
  });
  if (!(state.candidates || []).length) list.textContent = '等待满足方向与输入质量条件的候选声源。';
  el('c9model').textContent = 'PS 诊断模型：' + (!state.model_version ? '未配置，结果保持未知' :
    '版本 ' + state.model_version + (state.model_validated ? '，已通过指定测试域验收' : '，尚未验收，仅供试验')) +
    '。转速：' + (state.shaft_confirmed ? ((state.shaft_millihz || 0) * 0.06).toFixed(0) + ' rpm（人工设置或转速输入）' : '未确认') +
    '。诊断快照 ' + state.sequence + '；处理 ' + state.processing_ms + ' ms；结果年龄 ' + state.result_age_ms + ' ms。';
  c9status(latest);
}
async function c9view() {
  if (paused || c9busy || !c9live(latest)) return;
  c9busy = true;
  try {
    if (!el('c9map')) {
      var box = document.createElement('section');
      box.id = 'c9section';box.className = 'card';
      box.innerHTML = '<h3>9 麦方向热力图与声源诊断</h3><p>横轴：方位角 −90° → +90°；纵轴：俯仰角 −90° → +90°。0° 指向阵列正前方；本图不扫描距离。</p>' +
        '<canvas id="c9map" width="320" height="320"></canvas><p>蓝至黄表示定位评分；红框仅表示已确认的故障方向。点击网格可手动定向拾音。</p>' +
        '<p id="c9note"></p><div id="c9proposals"></div><p id="c9model"></p><div id="c9candidates"></div><p id="c9gsc"></p>' +
        '<button id="c9on">启用自适应拾音</button> <button id="c9off">原始定向拾音</button> ' +
        '<button id="c9freeze">冻结更新</button> <button id="c9adapt">继续更新</button> ' +
        '<button id="c9auto">跟踪最强定位峰</button> <button id="c9faultauto">跟踪已诊断故障方向</button>' +
        '<p><label>实际转速 rpm <input id="c9rpm" type="number" min="600" max="1800" value="1500" step="1"></label> <button id="c9rpmset">确认实际转速</button></p>';
      var main = document.querySelector('main');main.insertBefore(box, main.querySelector('.layout'));
      var timing = document.createElement('p');timing.id = 'c9latency';box.appendChild(timing);
      ['auto','faultauto'].forEach(function(k) {
        el('c9' + k).onclick = function() {
          fetch('/api/target/' + (k === 'auto' ? 'auto' : 'fault'), {cache:'no-store'})
            .then(function(r) {if (!r.ok) throw Error('目标模式设置失败');})
            .catch(function(e) {el('c9gsc').textContent = String(e);});
        };
      });
      el('c9rpmset').onclick = function() {
        var rpm = Number(el('c9rpm').value);
        if (!Number.isInteger(rpm) || rpm < 600 || rpm > 1800) {el('c9model').textContent = '请输入实际转速，范围 600–1800 rpm。';return;}
        fetch('/api/rpm?value=' + rpm, {cache:'no-store'})
          .then(function(r) {if (!r.ok) throw Error('转速设置失败');c9candidateAt = 0;})
          .catch(function(e) {el('c9model').textContent = String(e);});
      };
      el('c9map').onclick = async function(e) {
        var r = this.getBoundingClientRect(), x = Math.floor((e.clientX - r.left) * 32 / r.width), y = 31 - Math.floor((e.clientY - r.top) * 32 / r.height);
        if (x < 0 || x > 31 || y < 0 || y > 31) return;
        try {
          var q = await fetch('/api/target?grid=' + (y * 32 + x), {cache:'no-store'});
          if (!q.ok) throw Error('目标选择失败');
          el('c9gsc').textContent = '已申请手动定向拾音，仍需通过几何和输入质量检查。';
        } catch (err) {el('c9gsc').textContent = String(err);}
      };
      ['on','off','freeze','adapt'].forEach(function(k) {
        el('c9' + k).onclick = function() {
          fetch('/api/gsc/' + k, {cache:'no-store'}).catch(function(e) {el('c9gsc').textContent = String(e);});
        };
      });
    }
    if (Date.now() - c9candidateAt >= 500) {
      var cr = await fetch('/api/candidates', {cache:'no-store'});
      if (cr.ok) {c9candidates = await cr.json();c9lastCandidatesOk = Date.now();c9candidateView(c9candidates);}
      c9candidateAt = Date.now();
    }
    var r = await fetch('/api/heatmap', {cache:'no-store'});
    if (r.status === 200) {
      var m = await r.json(), v = m.scores;
      if (v && v.length === 1024) {
        var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), g = el('c9map').getContext('2d');
        for (var i = 0; i < 1024; i++) {
          var t = hi > lo ? (v[i] - lo) / (hi - lo) : 0;
          g.fillStyle = 'hsl(' + (240 - 180 * t) + ',85%,45%)';
          g.fillRect(i % 32 * 10, (31 - Math.floor(i / 32)) * 10, 10, 10);
        }
        if (c9candidates) (c9candidates.candidates || []).forEach(function(c) {
          if (c.stale || c.grid < 0 || c.grid >= 1024) return;
          var px = Number.isFinite(c.azimuth_mdeg) ? (c.azimuth_mdeg / 1000 + 90) * 320 / 180 : c.grid % 32 * 10 + 5;
          var py = Number.isFinite(c.elevation_mdeg) ? (90 - c.elevation_mdeg / 1000) * 320 / 180 : (31 - Math.floor(c.grid / 32)) * 10 + 5;
          g.strokeStyle = c9fault(c, c9candidates) ? '#ff0000' : '#ffffff';g.lineWidth = 2;
          g.strokeRect(px - 4, py - 4, 8, 8);
          g.fillStyle = '#ffffff';g.font = '12px sans-serif';
          g.fillText(String(c.track_id), px + 5, py + 4);
        });
        el('c9note').textContent = (m.accepted ? '已通过定位判定' : '候选方向图，尚未通过定位判定') +
          '；前半空间角度扫描；帧 ' + m.frame + '。定位峰表示声音方向，不直接表示故障。';
      }
    }
    var q = await fetch('/api/gsc', {cache:'no-store'});
    if (q.ok) {
      var z = await q.json();
      el('c9latency').textContent = '首个 PCM → PS 首次收到定位结果：目标 ' +
        (z.single_window_deadline_us / 1000).toFixed(2) + ' ms；' +
        (z.latency_samples ? '本次 ' + (z.pcm_to_ps_us / 1000).toFixed(3) +
          ' ms，最大 ' + (z.pcm_to_ps_max_us / 1000).toFixed(3) +
          ' ms，P95/P99 上界 ' + (z.pcm_to_ps_p95_upper_us / 1000).toFixed(3) +
          '/' + (z.pcm_to_ps_p99_upper_us / 1000).toFixed(3) +
          ' ms；超时 ' + z.deadline_misses + '/' + z.latency_samples +
          ' 帧；未读到的发布 ' + z.skipped_publications : '等待首次结果') +
        '。' + (z.location_stale ? '当前结果已过期。' : '') +
        ' 诊断采用独立的 1.024 秒观察窗。整链路实物验收：' + (z.board_validated ? '已完成' : '未完成');
      el('c9gsc').textContent = (!z.geometry_confirmed || !z.calibration_version ?
        '阵列几何或标定待验收，自适应输出旁路。' : '自适应拾音状态 ' + z.gsc_reason + '。') +
        ' 连续录音：UDP 1234；已发送 ' + z.udp_sent + ' 包；采集丢样 ' + z.dma_drops;
    }
  } catch (e) {
    if (el('c9note')) el('c9note').textContent = '方向或诊断读取失败：' + String(e);
  } finally {c9busy = false;}
}
setInterval(c9view, 100);
setInterval(function() {
  if (c9candidates && Date.now() - c9lastCandidatesOk > 2000) {
    c9candidates = null;
    if (el('c9candidates')) el('c9candidates').textContent = '候选诊断连接已过期，等待刷新。';
    c9status(latest);
  }
}, 500);
