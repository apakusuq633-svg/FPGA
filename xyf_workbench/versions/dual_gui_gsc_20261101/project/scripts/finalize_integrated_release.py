"""Fail-closed assembly of measured M0-M5 evidence and a NEW local release."""
from pathlib import Path
import collections,csv,hashlib,json,re,shutil,subprocess
from datetime import datetime,timezone
import numpy as np
R=Path(__file__).resolve().parents[1];P=R/'build/zynq12_integrated_plan'
V=P/'m5_validation_release';S=V/'safety';I=P/'m5_impl_release'
def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def check_sources(data):
 for name,want in data.items():assert sha(R/name)==want,('source drift',name)
def case(name):
 d=load(S/(name+'_summary.json'));assert d['status']=='PASS'
 for row in d['results']:assert (R/row['log']).is_file()
 return d['results'][0]
def timing(p):
 t=p.read_text();a=re.search(r'Setup\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+([-\d.]+)ns',t)
 b=re.search(r'Hold\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+([-\d.]+)ns',t)
 assert a and b and float(a[1])>=0 and float(b[1])>=0,p
 return {'wns_ns':float(a[1]),'whs_ns':float(b[1]),'tns_ns':0,'ths_ns':0}
def utilization(p):
 t=p.read_text()
 def value(name):
  m=re.search(r'\|\s*'+re.escape(name)+r'\*?\s*\|\s*([\d.]+)',t);assert m,name;return float(m[1])
 return dict(lut=value('Slice LUTs'),ff=value('Slice Registers'),bram36=value('Block RAM Tile'),dsp=value('DSPs'),lut_as_memory=value('LUT as Memory'))

# Nothing is marked passed until all expected files and provenance exist.
check_sources(load(S/'sources.json'));check_sources(load(I/'source_manifest.json'))
check_sources(load(P/'m5_auxiliary_signed_release/source_manifest.json'))
for k,v in load(P/'m1_release/manifest.json').items():assert sha(P/'m1_release'/k)==v
runs=load(V/'runs.json')
probe_resolution=None
for index,row in enumerate(runs):
 if row['status']!='PASS':
  assert row['test']=='dtcm_probe'
  before=load(V/'dtcm/dtcm50000_summary.json')['results'][0]
  assert before.get('failure')=='DTCM_STALL_NOT_EXERCISED'
  after=load(V/'dtcm_real/dtcm50000_summary.json')['results'][0]
  assert after['status']=='PASS' and after['dtcm_blocked']>45000 and after['dtcm_accepts']>0
  probe_resolution={'before':before,'after':after,'reason':'Probe waits for a true non-MMIO RAM request after arming at the requested stage'}
  runs[index]={**row,'status':'PASS','original_exit_code':row['exit_code'],'exit_code':0,'resolved_by':after['log']}
assert all(r['status']=='PASS' for r in runs)
expected={'smoke4','recovery_gap','recovery_raw_halt','recovery_srp_halt','automatic_recovery','gsc_backpressure',
 'physical0','physical1','physical2','physical3','physical_link','physical_link_halt','normal256','normal1024','matrix183',
 'seed2','sample_wrap','rv32_regression','memory76','mmio8','strict_acceptance','dtcm_probe'}
assert expected<={r['test'] for r in runs}
long=load(V/'extended4096_verified/metrics.json');assert long['status']=='PASS' and long['windows']==4096
fast=load(V/'fast_simulator/metrics.json');assert fast['status']=='PASS'
assert load(V/'extended4096_verified/manifest.json')['binary_sha256']==fast['binary_sha256']
for name,n in [('normal256',256),('normal1024',1024)]:
 d=case(name);assert d['windows']==n and d['raw_drop']==d['window_drop']==d['audio_drop']==0 and d['fixed_phase']
 assert d['gsc_packets']==d['audio_out'] and d['gsc_overflow']==0
matrix=load(S/'matrix183_summary.json');assert matrix['status']=='PASS' and matrix['scenarios']==183
counts=dict(collections.Counter(r['status'] for r in matrix['results']));assert counts.get('ERROR',0)==0
aux=load(P/'m5_auxiliary_signed_release/metrics.json');assert len(aux)==19 and all(r['status']=='PASS' for r in aux)
rv=load(V/'rv32/summary.json');assert len(rv)==9 and all(r['status']=='PASS' for r in rv)
xsim=R/'build/pdm12_runs/integrated_m5_xsim_signed4/simulation.log';assert 'LOCALIZER12_SOC_PASS windows=4' in xsim.read_text()
assert 'FLOW_PASS' in (I/'implementation.log').read_text(errors='replace')
assert 'GSC_TAP_OOC_PASS' in (P/'gsc_ooc_registered.log').read_text(errors='replace')
sta=timing(I/'timing_zynq.rpt');resources=utilization(I/'util_zynq.rpt');ooc_sta=timing(P/'m5_gsc_ooc_registered/timing.rpt')
protect=load(P/'protected_verification.json');assert protect['status']=='PASS'
# Recheck protected deployment artifacts at the actual packaging point.
old=load(P/'audit/m0_20261015/protected_artifacts.json')
protected=[x for x in old if Path(x['path']).suffix.lower() in ['.bit','.xsa','.elf','.log'] or 'manifest' in Path(x['path']).name.lower()]
assert all(sha(R/x['path'])==x['sha256'] for x in protected)
assert load(R/'configs/production_array.json')['mic_xyz'] is None
model=load(P/'m1_release/metrics.json');assert model['status']=='PASS'
angle_components={}
with (P/'m1_release/scenarios.csv').open(newline='') as f:
 rows=list(csv.DictReader(f))
for scenario in sorted({r['scenario'] for r in rows}):
 selected=[r for r in rows if r['scenario']==scenario]
 az=np.array([abs((float(r['az_est'])-float(r['az_true'])+180)%360-180) for r in selected])
 el=np.array([abs(float(r['el_est'])-float(r['el_true'])) for r in selected])
 angle_components[scenario]={axis:{'p50':float(np.percentile(a,50)),'p90':float(np.percentile(a,90)),'p99':float(np.percentile(a,99)),'max':float(max(a))} for axis,a in [('azimuth_deg',az),('elevation_deg',el)]}
precision=load(P/'m2_precision_release/metrics.json');assert precision['status']=='PASS'
quality=load(P/'m2_quality/metrics.json');freq=load(P/'reports/figures_release/fractional_delay_metrics.json')
smooth=load(P/'m3_smooth_ab/metrics.json')[0];transient=load(P/'m3_smooth_ab/transient_comparison.json')
coverage=load(P/'reports/grid_coverage.json');baseline=load(P/'m0_runtime_baseline/baseline4_summary.json')['results'][0]
normal=case('normal1024');smoke=case('smoke4');backpressure=case('gsc_backpressure')
assert backpressure['gsc_overflow']>0 and backpressure['gsc_packets']+backpressure['gsc_overflow']==backpressure['audio_in']
assert backpressure['raw_drop']==backpressure['window_drop']==backpressure['audio_drop']==0
physical=[];grid=np.array(load(P/'m1_release/geometry.json')['grid_directions'])
for k,scene in enumerate(model['rtl_cases']):
 t=(V/f'physical{k}_rtl.log').read_text();m=re.search(r'ACOUSTIC_RESULT grid=(\d+) score=(-?\d+) all_scores_checked=1024',t);assert m
 u=np.array(scene['truth']);g=int(m[1]);error=float(np.degrees(np.arccos(np.clip(u@grid[g],-1,1))))
 assert error<=18
 physical.append(dict(case=k,grid=g,angle_error_deg=error,all_scores_bit_exact=True))
for name in ['recovery_gap','recovery_raw_halt','recovery_srp_halt','automatic_recovery']:
 d=case(name);t=(R/d['log']).read_text();assert 'RECOVERY_PASS epoch=1 fault_events=1' in t
for name in ['physical_link','physical_link_halt']:
 d=case(name);assert 'DIRECTION_APPLIED' in (R/d['log']).read_text()

release=P/'release_artifacts';reports=P/'reports/final';release.mkdir(exist_ok=False);reports.mkdir(exist_ok=False)
bit=next((P/'m5_impl_release_project/rv32_zynq.runs/impl_1').glob('*.bit'))
for src,name in [(bit,'pdm12_integrated.bit'),(I/'das_fir.xsa','pdm12_integrated.xsa'),
 (S/'fw/fw_live12.elf','TEST_ONLY_localizer12_continuous.elf'),(S/'fw/itcm.hex','itcm.hex'),(S/'fw/dtcm.hex','dtcm.hex'),
 (S/'build_manifest.json','firmware_build_manifest.json')]:
 # The build manifest lives next to fw, not inside the simulator model.
 if not src.exists() and src.name=='build_manifest.json':src=S/'build_manifest.json'
 assert src.is_file(),src;shutil.copy2(src,release/name)
delta={k:resources[k]-v for k,v in dict(lut=29781,ff=16856,bram36=111.5,dsp=132,lut_as_memory=2884).items()}
data={'status':'PASS_SIM_IMPL','hardware':'DEFERRED_HARDWARE','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
 'scope':'12 microphones / 1024 FFT / 512 hop / 66 GCC-PHAT+IFFT / 1024 SRP slots / 40 MHz',
 'model':model,'physical_rtl':physical,'normal1024':normal,'long4096':long,'stress_outcomes':counts,
 'timing':sta,'resources':resources,'resource_delta':delta,'gsc_ooc_registered_timing':ooc_sta,
 'gsc_backpressure':backpressure,'auxiliary_tests':aux,'rv32_tests':rv,'protected_artifact_count':len(protected),
 'production_geometry_enabled':False,'automatic_recovery_default_enabled':False,'automatic_recovery_attempt_limit':3,
 'resolved_dtcm_probe_coverage_failure':probe_resolution}
data['host_simulator_optimization']=fast
data['angle_component_errors']=angle_components
(reports/'acceptance.json').write_text(json.dumps(data,indent=2,ensure_ascii=False))

def save(name,text):(reports/name).write_text(text.strip()+'\n',encoding='utf-8')
angle_lines='\n'.join(f"| {name} | {v['p50']:.3f} | {v['p90']:.3f} | {v['p99']:.3f} | {v['max']:.3f} | {100*v['success_within_18deg']:.1f}% |" for name,v in model['angles'].items())
save('M1.md',f'''# M1：声场、三维几何与定位参考

状态：软件模型与所列RTL场景PASS，硬件DEFERRED_HARDWARE。

建立独立物理到达延时合成、浮点GCC-PHAT/SRP和显式TEST_ONLY三维几何。528场景覆盖宽带噪声、合成语音、20/0dB噪声、单次延迟反射、双源、增益/时延偏差、声速、近场失配、极性及通道置换。反射模型不是经过真实房间标定的RIR，语音为合成信号。

修改：scripts/integrated_acoustics.py、localizer12_safety_oracle.h、localizer12_safety.cpp及安全wrapper；新增精度/覆盖分析脚本。修复tau_0m转向表符号，未写入生产配置。

| 场景 | P50° | P90° | P99° | 最大° | 18°内比例 |
|---|---:|---:|---:|---:|---:|
{angle_lines}

方位角误差采用[-180°,180°)环绕差的绝对值，俯仰角误差采用直接差的绝对值；接近极点时方位角本身不稳定，应结合球面夹角判断。完整逐场景真值/估计保存在scenarios.csv，分量P50/P90/P99/max写入最终acceptance.json的angle_component_errors。干净场景方位角P90={angle_components['clean']['azimuth_deg']['p90']:.6f}°、max={angle_components['clean']['azimuth_deg']['max']:.6f}°；俯仰角P90={angle_components['clean']['elevation_deg']['p90']:.6f}°、max={angle_components['clean']['elevation_deg']['max']:.6f}°。

通道置换是预期故障敏感性测试，其大误差不包装为正确定位。生产XYZ与空间映射仍未知。线阵/平面/三维秩为1/2/3，平面镜像延时相同。1024槽对应962个数学不同方向；方位步进11.25°、俯仰180/31°，最近网格的精确最大球面量化误差{coverage['exact_max_nearest_grid_angle_deg']:.6f}°。与算法误差分开报告。

四个物理PCM场景RTL逐格1024分数、实际峰值均匹配独立定点参考：{json.dumps(physical,ensure_ascii=False)}。完整联动另外逐样点比较物理PCM、独立几何补偿与DAS输出，没有以DUT音频反推golden。

依据：m1_release/acceptance.json、geometry.json、scenarios.csv、metrics.json、manifest.json和run.log；m5_validation_release/physical*_rtl.log。下一步已进入M2，真实硬件角误差不由本阶段证明。

![角误差分布](../figures_release/angular_error_cdf.png)
''')
frows='\n'.join(f"| {x['mode']} | {x['phase_rms_deg']:.4f} | {x['delay_error_max_abs_us']:.4f} | {x['worst_amplitude_db']:.4f} |" for x in freq)
save('M2.md',f'''# M2：DAS分数延时与定点品质

状态：参考模型、逐样点RTL与整体实现PASS。

修改rtl/beamformer/rv32_das_stream.v，新增das_lagrange_coeff.vh、check_das_precision.py、tb_das_precision.v。保留原线性模式，CTRL bit3可选三阶Lagrange Q14；每路顺序读取同一历史RAM的四个样点，复用单个串行乘加路径，增加1个DSP，不复制十二套滤波器或历史。后级八lane、32tap SIMD FIR不变。

| 方案 | 相位RMS误差° | 最大等效延时误差μs | 最差幅度dB |
|---|---:|---:|---:|
{frows}

频带300..8000Hz、16种小数相位；三阶已去除增加的1样点公共因果延时（25.6μs）。这些是频率响应残差，不含连续请求延时向1/16样点量化的附加误差；实际小数精度仍为1/16，不宣称提升到16位小数。

复数响应RMS误差线性0.067261→三阶0.014069，下降约79.1%。六个合成声场方向中，最坏目标相对失真约0.06508→0.02425；三阶输出相对输入SNR提升范围4.98..6.68dB，仅针对该干扰模型。目标增益与SNR分别统计，不用音量增加冒充增强。

实际RTL：2048组×12路、全部16种小数相位、满幅正负/静音边界，独立有理数系数、对称舍入及逐通道饱和，逐样点零不匹配。插值单元加测试FIR握手182拍；完整SoC连真实SIMD FIR为197拍，原线性101拍，均小于1024拍预算。三阶合法配置小于61样点，旧线性小于63；模式切换前校验已有延时，同拍方向命令串行化。非法模式反例已保留。

依据：m2_quality/quality.csv、m2_precision_release/{'{run.log,metrics.json}'}、reports/figures_release、das_config_before.log/after.log、完整SoCphysical_link日志。新增逻辑资源与最终时序由M5统一量测。下一阶段原子转向已完成。

![分数延时响应](../figures_release/das_response.png)
''')
save('M3.md',f'''# M3：SRP→DAS原子联动与平滑

状态：模块链路、完整SoC物理黄金比对及带CPU停顿联动PASS。

新增rv32_direction_link.v，连接rv32_soc.v；修改rv32_steer_regs.v、rv32_das_stream.v。SIM1显式测试门控复位关闭，生产几何不启用。方向version来源于已发布窗口，几何向量经过现有转向单元后一次提交，DAS按输入组快照并记录effective_sample_seq。转向单元负责迟滞，新的链接事务交付完整几何向量；样点平滑统一由DAS执行，避免两级渐变元数据不一致。

修复真实反例：迟滞确认新方向时旧committed值使补偿向量滞后一轮；现在验证新提交状态，并对整个十二路补偿向量与独立几何期望逐位核对。完整链路还验证全部音频样点和发布峰值。

| 指标 | 瞬切A | 平滑B |
|---|---:|---:|
| 最大一阶样点跳变LSB | {smooth['baseline_unsmoothed_max_step_lsb']} | {smooth['max_adjacent_step_lsb']} |
| 短时能量比 | {smooth['baseline_unsmoothed_energy_ratio']:.6f} | {smooth['short_energy_ratio']:.6f} |
| 二阶突变量峰值LSB | {transient['step']['peak_second_difference']:.0f} | {transient['smooth']['peak_second_difference']:.0f} |
| >4kHz能量占比dB | {transient['step']['high_frequency_energy_db']:.3f} | {transient['smooth']['high_frequency_energy_db']:.3f} |

平滑限制每组每路延时最多移动1/16样点；版本与生效样点同组更新，transition标识尚未达到目标。一阶最大值略升，不能把所有指标说成改善；其低于预定4096阈值，能量比低于2，二阶突变和高频能量明显下降。二阶/频谱为补充分析，不事后改写原验收阈值。

离线比较瞬切、渐变与32点双波束交叉淡化；选择单波束渐变，避免双次渲染开销。双波束只做软件比较，未同时堆入RTL。fault/恢复期间清可信标志并阻止新方向，低分结果保持既有方向。

依据：m3_smooth_ab/{'{metrics.json,transient_comparison.json,integrated_direction.log,direction_step.log}'}、m3_candidates/comparison.csv、m3_consistency_counterexample、m5_validation_release/safety/physical_link*归档日志。下一阶段可靠性与GSC边界已完成。

![方向切换音频](../figures_release/direction_audio.png)
''')
save('M4.md',f'''# M4：可靠性、恢复与未来GSC接口

状态：长跑、压力、受控/可选自动恢复及仿真sink PASS。

新增rv32_localizer_recovery.v、rv32_gsc_tap.v；修改rv32_overlap_localizer.v和fw_localizer12.c，保留原RAW所有权、window_primed、sticky隔离和真实指令退休机制。core/LSU/DTCM/SIMD/FFT主算子RTL均保持原字节。

恢复路径FAULT_LATCHED→QUIESCE→REARM_WAIT→WARMUP→RUN；共享算子排空后rearm，保留请求票号单调性和累计故障证据，重新收满1024点。修复rearm后一拍旧故障导致重复登记的边界。三类显式恢复及一类完整SoC自动恢复都在新epoch后连续4窗黄金正确、音频不断流。自动恢复默认关闭，AUT1明确启用，最多3次，第四次锁存，人工确认可重开；独立策略测试验证历史不丢失。

正常1024窗：{normal['raw_checks']}次RAW读取，0 raw_drop/0 window_drop/0 audio_drop，1023个间隔均524288拍。4096窗：{long['raw_checks']}次RAW读取、{long['produced']}组输入，覆盖{long['input_duration_seconds']:.6f}秒，所有黄金、峰值和退休次数通过。不是一小时实板运行。另测不同seed、sample_id回卷和控制器tick回卷/重启/碰撞（后三者算子为桩）。

这里的RAW指2048组定位环形缓存；既有PS双bank快照另有占用/ACK语义，不能把本结果解释为慢PS可无限期无损消费所有旁路。

183场景：{counts}。EXPLICIT_LOSS和CORRECT_LATE不计为实时完成。主链数据丢失后禁止发布，错误计数表示事件，不冒充故障期间全部丢窗数。旧69,631拍细边界不直接当作修改后保证值，本轮离散压力表按实际相位和时长列示。

GSC边界提供512bit包，十二路同步PCM、DAS/FIR、sample_seq、方向版本/生效样点、名义群延时、transition/可信、epoch及独立溢出。4包队列，满时显式丢包，绝不反压定位。完整SoC慢sink场景：{backpressure['gsc_packets']}包消费、{backpressure['gsc_overflow']}包显式溢出，主链RAW/window/audio仍0丢失。没有PS DMA、NLMS或完整GSC。

既有PS顶层没有连接DMA流，综合可裁掉该未使用边界。额外用同域寄存器源/接收上下文实现tap，WNS {ooc_sta['wns_ns']:+.3f}ns、WHS {ooc_sta['whs_ns']:+.3f}ns。最初零延迟虚拟输入OOC出现hold失败，保留原报告；补充真实同域寄存器上下文，没有false-path屏蔽功能数据。

依据：m5_validation_release、m5_auxiliary_signed_release、m5_gsc_ooc_registered；详见docs/PS_GSC接口契约_2026-10-15.md。下一阶段统一实现/打包已完成。
''')
rrows='\n'.join(f'| {k} | {oldval} | {resources[k]:g} | {delta[k]:+g} |' for k,oldval in dict(lut=29781,ff=16856,bram36=111.5,dsp=132,lut_as_memory=2884).items())
save('M5.md',f'''# M5：最终回归、40MHz实现与交付

结论：PASS_SIM_IMPL；所有板级项目DEFERRED_HARDWARE。

保持12麦、1024点FFT、512Hop、66对GCC-PHAT/IFFT、1024格完整计算规模，八lane音频FIR保留。256/1024/4096正常场景全部黄金、实际峰值、退休计数、RAW标签和同步音频通过。另有19项辅助RTL测试、9项CPU/PS/算子回归、76项访存、8项MMIO、17项严格验收检查器、真实DTCM等待、原生XSim4窗。

| 系统指标 | M0同seed四窗实跑 | 当前四窗/完整实跑 |
|---|---:|---:|
| 最大计算拍数 | {baseline['max_compute']} | 四窗{smoke['max_compute']}，1024窗{normal['max_compute']} |
| 固定发布延迟拍数 | {baseline['max_latency']} | {normal['max_latency']} |
| 结果间隔拍数 | 524288 | 524288 |
| 正常最小RAW覆盖余量拍数 | {baseline['min_margin']} | {normal['min_margin']} |
| 原线性音频最长拍数 | {baseline['audio_max']} | {normal['audio_max']} |
| 三阶+真实SIMD FIR最长拍数 | 原无该模式 | {case('physical_link')['audio_max']} |

计算变化包含固件调度/代码布局变化，不全部归因于DAS；RAW余量略减与整体计算变快同时存在，不混用概念。任何未测频率/输入都不由这些有限场景保证。

| 资源 | 原历史routed | 新routed | 差值 |
|---|---:|---:|---:|
{rrows}

FPGA xc7z020clg400-1、40MHz、Vivado2020.2完整synth/opt/place/route/bit/XSA FLOW_PASS。原WNS/WHS +0.869/+0.033ns，新{sta['wns_ns']:+.3f}/{sta['whs_ns']:+.3f}ns，TNS/THS0。时序余量缩小，不能说优化了全部时序。内部未约束端点0；既有外部PDM/I2C等I/O未给出的延迟假设仍属硬件边界，不宣布板级I/O验收。

新增插值系数头文件已进入fileset；DAS群延时元数据最大值改为复用通道遍历，消除候选版长组合比较链。失败/终止候选目录全部保留，不混入当前验收。

真实DTCM专项最初因新固件轮询布局变化，只阻塞了MMIO而没有阻塞RAM请求，覆盖检查正确判ERROR。现在先按阶段布防，等待真实RAM请求才开始等待注入；独立dtcm_real目录重新构建并验证数据及实际阻塞周期。原FAIL记录保留，不修改runs.json伪装通过；最终验收显式引用该复测结果。

早期4096窗子进程随上述总驱动失败而中断，按NOT_COMPLETED保留；正式4096窗随后独立运行，避免被其他检查的退出连带终止。仿真器在新目录以O3编译，16窗对照确认全部数值和周期摘要逐项一致；这仅改变主机仿真速度，不是FPGA性能优化。

原有{len(protected)}份bit/XSA/ELF/log/manifest散列一致；生产几何及主要CPU/算子RTL未改。OOC启动参数错误曾写入默认Vivado日志，已从前一会话自动备份逐字节恢复，恢复证明和失败日志另存。未提交、未reset Git、未烧写板卡。

正式artifact在build/zynq12_integrated_plan/release_artifacts，含新bit/XSA、明确TEST_ONLY的连续RV32 ELF/TCM HEX和构建清单。匹配源码/模型/向量/日志/报告由release_manifest.json绑定，旧release保留。

复现命令见docs/声源定位_DAS_集成验证复现.md；真实XYZ、空间映射、实际PDM同步、真实声场精度/音质和长期板测继续挂起，不属于本轮仿真/实现PASS。
''')
summary=f'''# 声源定位与DAS优化 M1–M5 最终实施报告

**结论：PASS_SIM_IMPL。M0–M5本轮数字模型、RTL仿真、完整40MHz实现和接口预留已完成；真实硬件验收DEFERRED_HARDWARE。**

没有减少12路/1024FFT/512Hop/66对/1024格规模，没有修改RISC-V核心、自定义指令执行体、八lane SIMD FIR主算子或生产几何。没有开发UDP、PS DMA或完整GSC，没有Git提交/复位或板卡烧写。

主要结果：528场景独立声场模型；干净场景夹角P90 {model['angles']['clean']['p90']:.3f}°、最大{model['angles']['clean']['max']:.3f}°；4个物理场景RTL全部1024评分与实际峰值正确。三阶分数延时在300..8000Hz复数响应RMS误差下降约79.1%，增加1样点公共因果延时。方向版本/十二路延时在音频组边界一致，完整联动逐样点物理黄金通过；故障显式/可选自动恢复与GSC同步旁路通过。

正常1024和4096窗均0 RAW/window/audio丢失，固定间隔524288拍。4096窗实际覆盖{long['input_duration_seconds']:.6f}秒输入。183压力场景{counts.get('PASS',0)}按时正确/{counts.get('CORRECT_LATE',0)}正确但超时/{counts.get('EXPLICIT_LOSS',0)}显式损失/0未知错误；53显式损失不是53项实时成功。

40MHz routed WNS {sta['wns_ns']:+.3f}ns、WHS {sta['whs_ns']:+.3f}ns。资源{resources['lut']:g} LUT/{resources['ff']:g} FF/{resources['bram36']:g} BRAM36等效/{resources['dsp']:g} DSP。对比旧实现增加{delta['lut']:g} LUT、{delta['ff']:g} FF和{delta['dsp']:g} DSP，BRAM不增加，时序余量有所下降。

## 分阶段完整交付

- [M0：当前架构、功能边界与基线审计](M0_工程审计_2026-10-15.md)
- [M1：模型、几何、角误差、修改与日志](../build/zynq12_integrated_plan/reports/final/M1.md)
- [M2：DAS品质、定点和时延A/B](../build/zynq12_integrated_plan/reports/final/M2.md)
- [M3：方向原子更新及转向瞬态A/B](../build/zynq12_integrated_plan/reports/final/M3.md)
- [M4：长跑、故障恢复及GSC边界](../build/zynq12_integrated_plan/reports/final/M4.md)
- [M5：全量回归、资源/时序和交付](../build/zynq12_integrated_plan/reports/final/M5.md)
- [数据契约](PS_GSC接口契约_2026-10-15.md)与[复现命令](声源定位_DAS_集成验证复现.md)

## 文件与证据

实际主路径为12路PDM/对齐PCM分流到RAW定位与12路DAS；DAS先合成单声道，再由既有八lane SIMD MAC实现32tap固定音频FIR。八lane表示并行乘加吞吐，不是12支麦克风中的八支，亦不改变66对定位规模。测试坐标为右手X/Y/Z；方位角atan2(y,x)、俯仰角asin(z)。当前显式测试三维阵列空间秩3；线阵秩1、平面阵秩2，平面镜像存在相同TDOA。详细几何与通道映射见m1_release/geometry.json。

分数延时质量表同时列出整数、线性、三阶方案。当前完整系统最坏计算{normal['max_compute']}拍、发布延迟{normal['max_latency']}拍，分别为{normal['max_compute']/40000:.6f}ms和{normal['max_latency']/40000:.6f}ms；每Hop为13.1072ms。完整实现只有既有时钟关系，GSC旁路与DAS均工作在40MHz域，没有新增跨域通路。未来GSC需遵守数据契约中的原始PCM/波束历史年龄及渐变对齐，当前接口不宣称已实现Blocking Matrix。

正式结果根目录：build/zynq12_integrated_plan。验收数值见reports/final/acceptance.json；最终绑定清单release_manifest.json；新交付文件release_artifacts。原M0保护清单和最终protected_verification.json保留。

关键修改为rv32_das_stream.v、rv32_steer_regs.v、rv32_soc.v、rv32_overlap_localizer.v、fw_localizer12.c；新增direction_link、localizer_recovery、gsc_tap及系数头文件，配套独立模型、反例、单元与系统驱动。完整逐文件hash及差异列表在manifest，不以模块名称猜能力。

风险边界：真实坐标/接线未提供；测试几何不进入生产；映射错误可造成严重角误判；有限仿真不证明无限运行；GSC内部接口尚未接DMA，PS顶层可裁掉未使用tap；主波束群时延与方向渐变需由未来GSC按契约对齐；I/O与真实声场等待实物。任何旧候选FAIL/中止都保留，只有当前匹配源码的完整结果参与最终PASS。
'''
doc=R/'docs/声源定位_DAS_M1-M5实施报告_2026-10-15.md';assert not doc.exists();doc.write_text(summary,encoding='utf-8')
for name in ['M1.md','M2.md','M3.md','M4.md','M5.md']:
 assert (reports/name).is_file()
files=[]
source_delta=[]
for prior in old:
 q=R/prior['path']
 if q.is_file() and sha(q)!=prior['sha256']:
  source_delta.append({'path':prior['path'],'before_sha256':prior['sha256'],'after_sha256':sha(q)})
tracked={x['path'] for x in old}
new_sources=[]
for folder in ['rtl','sw/fw','scripts','configs','constrs','docs','tb']:
 for q in (R/folder).rglob('*'):
  if q.is_file() and q.suffix.lower() in ['.v','.vh','.hex','.c','.h','.py','.cpp','.tcl','.ps1','.f','.json','.xdc','.md','.s','.ld'] and q.relative_to(R).as_posix() not in tracked:
   new_sources.append({'path':q.relative_to(R).as_posix(),'sha256':sha(q)})
(reports/'source_delta.json').write_text(json.dumps({'changed_since_m0':source_delta,'new_or_not_in_m0_inventory':new_sources},indent=2,ensure_ascii=False))
for folder in ['m1_release','m2_quality','m2_precision_release','m3_smooth_ab','m3_candidates','m3_consistency_counterexample',
               'm5_validation_release','m5_impl_release','m5_gsc_ooc_registered','m5_auxiliary_signed_release','release_artifacts','reports']:
 for q in (P/folder).rglob('*'):
  if q.is_file() and q.suffix.lower() in ['.json','.csv','.log','.rpt','.md','.hex','.bin','.elf','.bit','.xsa','.png','.svg','.h','.v','.vh','.c','.cpp','.dcp','.txt','.map','.py']:
   files.append({'path':q.relative_to(R).as_posix(),'bytes':q.stat().st_size,'sha256':sha(q)})
for folder in ['rtl','sw/fw','scripts','configs','constrs','docs','tb']:
 for q in (R/folder).rglob('*'):
  if q.is_file() and q.suffix.lower() in ['.v','.vh','.hex','.c','.h','.py','.cpp','.tcl','.ps1','.f','.json','.xdc','.md','.s','.ld']:
   files.append({'path':q.relative_to(R).as_posix(),'bytes':q.stat().st_size,'sha256':sha(q)})
for q in [P/'protected_verification.json',P/'default_log_restoration.json',xsim]:
 files.append({'path':q.relative_to(R).as_posix(),'bytes':q.stat().st_size,'sha256':sha(q)})
# Freeze shared ROM/vector inputs that predate this task, without rewriting them.
shared={R/'build/strict_overlap/vectors/lut.hex',R/'build/fft_tw.hex',R/'build/fw_fir_coeff.hex'}
for folder in ['rtl','tb']:
 for source in (R/folder).rglob('*.v'):
  for name in re.findall(r'\$readmemh\s*\(\s*"([^"]+)"',source.read_text()):
   if (R/name).is_file():shared.add(R/name)
for q in sorted(shared):
 if q.is_file():files.append({'path':q.relative_to(R).as_posix(),'bytes':q.stat().st_size,'sha256':sha(q)})
manifest={'stage':'M0-M5','status':'PASS_SIM_IMPL','hardware':'DEFERRED_HARDWARE','created_utc':datetime.now(timezone.utc).isoformat(),
 'head':data['head'],'timing':sta,'resources':resources,'files':list({x['path']:x for x in files}.values()),'report':doc.relative_to(R).as_posix(),
 'tools':{'verilator':subprocess.check_output(['verilator','--version'],text=True).strip(),'vivado':'2020.2 from routed reports','numpy':np.__version__}}
out=P/'release_manifest.json';assert not out.exists();out.write_text(json.dumps(manifest,indent=2,ensure_ascii=False))
assert all(sha(R/x['path'])==x['sha256'] for x in manifest['files'])
print('INTEGRATED_RELEASE_PASS_SIM_IMPL report='+str(doc)+' files='+str(len(manifest['files'])))
