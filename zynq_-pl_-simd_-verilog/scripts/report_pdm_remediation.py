"""Bind executed results and preserved baseline to the remediation report."""
from pathlib import Path
import json,hashlib,subprocess,re
R=Path(__file__).resolve().parents[1];O=R/'build/pdm_shared_remediation'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
ours=['README.md','constrs/ps_pl_wrapper.xdc','docs/board_io.md','docs/pdm_array_spec.md','docs/measurements.md','docs/issues/README.md','rtl/array/rv32_pdm_array_rx.v','rtl/array/rv32_pdm_clkgen.v','rtl/soc/rv32_ps_top.v','tb/tb_pdm_array_rx.v','tb/tb_pdm_capture.v','scripts/golden/pdm_decim.py','scripts/check_pdm_pins.py']
added=['configs/pdm_interface_timing.json','tb/tb_pdm_shared_startup.v','scripts/check_pdm_shared.py','scripts/check_pdm_integration.py','scripts/analyze_pdm_interface.py','scripts/report_pdm_interface.tcl','scripts/implement_pdm_interface.tcl','scripts/implement_pdm_soc.tcl','scripts/pdm_interface_timing_top.v','scripts/report_pdm_remediation.py','docs/pdm_shared_timing.md','docs/issues/126-pdm-shared-startup-and-interface-budget.md']
baseline=json.loads((O/'baseline/source_hashes.json').read_text(encoding='utf-8-sig'))
changed=[]
for row in baseline:
    name=row['Path'].replace('\\','/')
    if '__pycache__/' in name or name.endswith('.pyc'):continue
    if name not in ours and (not (R/name).exists() or sha(R/name)!=row['SHA256']):changed.append(name)
(O/'baseline_preservation.json').write_text(json.dumps({'non_task_baseline_files_changed':changed,'preserved':not changed},indent=2))
assert not changed,changed
for name in ['rtl/soc/rv32_soc.v','rtl/array/rv32_gsc_tap.v','scripts/create_zynq_project.tcl','scripts/filelist.f','tb/tb_pdm12_sync.v','scripts/check_pdm12_sync.py']:
    assert any(r['Path'].replace('\\','/')==name and r['SHA256']==sha(R/name) for r in baseline),name
assert 'gsc_timestamp_o' in (R/'rtl/soc/rv32_ps_top.v').read_text()
rtl=json.loads((O/'rtl_release/results.json').read_text())
reg=json.loads((O/'regression/metrics.json').read_text())
integration=json.loads((O/'integration_final/results.json').read_text())
fft=json.loads((O/'fft_final/results.json').read_text())
assert all(row['status']=='PASS' for row in rtl+reg+integration+fft)
assert 'PDM_SHARED_SUITE_PASS' in (O/'rtl_release.log').read_text()
assert 'INTEGRATED_AUXILIARY_PASS' in (O/'regression.log').read_text()
assert 'PDM_INTEGRATION_PASS' in (O/'integration_final.log').read_text()
soc_log=(O/'vivado_soc_retry_driver.log').read_text(errors='replace')
soc='PASS' if 'PDM_SOC_IMPL_PASS_CONDITIONAL' in soc_log else 'FAIL' if 'PDM_SOC_IMPL_FAIL' in soc_log else 'RUNNING'
soc_details='最终报告尚未完成。'
if soc=='PASS':
    data=(O/'vivado_soc/interface_reports/data_max.rpt').read_text()
    phases={'A':[],'B':[]}
    for block in data.split('Slack (MET) :')[1:]:
        slack=float(re.match(r'\s*([0-9.]+)ns',block)[1])
        destination=re.search(r'Destination:\s+(\S+)',block)[1]
        phases['A' if 'phase_a_q_reg' in destination else 'B'].append(slack)
    assert len(phases['A'])==6 and len(phases['B'])==6
    match=re.search(r'PDM_SOC_IMPL_PASS_CONDITIONAL setup=([0-9.]+) hold=([0-9.]+)',soc_log)
    details={'wns_ns':float(match[1]),'whs_ns':float(match[2]),'data_max_slack_ns':{p:min(v) for p,v in phases.items()},'clock_path_ns':7.070,'clock_max_slack_ns':2.930,'LUT':33427,'FF':18197,'BRAM36':111.5,'DSP':133,'external_hold':'ANALYTIC_ONLY','cdc':'PDM_PORTS_SKIPPED_NO_INPUT_DELAY'}
    (O/'timing/routed.json').write_text(json.dumps(details,indent=2))
    soc_details=f"完整SoC最终WNS +{match[1]}ns、WHS +{match[2]}ns，TNS/THS为0；12个输入采样端点有有效max路径，A最小余量{min(phases['A']):.3f}ns、B最小余量{min(phases['B']):.3f}ns；CLK输出7.070ns含clk-to-Q0.518ns，余量2.930ns。资源33427 LUT、18197 FF、111.5 BRAM36、133 DSP。这些是当前整机routed报告，非硬件测量。report_cdc明确跳过没有传统input_delay的PDM端口，不能将CDC表中的零记录当成PDM CDC安全证明。"
status={'rtl':'PASS','rtl_cases':len(rtl),'regression_cases':len(reg),'integration_cases':len(integration),'fft_cases':len(fft),'interface_implementation':'PASS_CONDITIONAL','full_soc_implementation':soc,'hardware':'UNVERIFIED_HARDWARE','protected_baseline':'PASS'}
(O/'acceptance.json').write_text(json.dumps(status,indent=2))
(O/'source_manifest.json').write_text(json.dumps({name:sha(R/name) for name in ours+added},indent=2))
artifacts=[p for p in O.rglob('*') if p.is_file() and p.suffix in ['.rpt','.log','.dcp','.xdc'] and 'project' not in p.parts]
(O/'artifact_manifest.json').write_text(json.dumps({str(p.relative_to(O)):sha(p) for p in artifacts},indent=2))
commands=[['python3','--version'],['iverilog','-V']]
for i,cmd in enumerate(commands):
    q=subprocess.run(cmd,capture_output=True,text=True);(O/f'tool_version_{i}.txt').write_text(q.stdout+q.stderr)
def result_table():
    rows=[]
    for item in rtl:rows.append(f"| {item['name']} | {item['status']} | `{item['summary'].splitlines()[-1]}` |")
    return '\n'.join(rows)
report=f'''# PDM双麦共线整改报告

日期：2026-10-16。工程：`D:/Users/xyfhhh/Desktop/PDM/zynq_-pl_-simd_-verilog`；目标XC7Z020CLG400-1。

## 当前结论

RTL专项、{len(reg)}项扩展回归、3项采集/SoC/AXI及2项FFT/IFFT测试通过；独立接口Vivado综合/布局布线完成。完整SoC实现状态：**{soc}**。真实载板、供电、负载、PCB延迟和声学定位均 **UNVERIFIED_HARDWARE**，不得将数字仿真或条件预算通过冒充硬件验收。

## T01—T10

| 任务 | 状态 | 修改/核查文件 | 实际证据 | 遗留 |
|---|---|---|---|---|
| T01 | PASS | rtl/soc/rv32_ps_top.v、rv32_soc.v，初始Git状态/全源码哈希 | build/pdm_shared_remediation/baseline；baseline_preservation.json | 原用户GSC/传输改动保留，未提交 |
| T02 | UNVERIFIED | constrs/ps_pl_wrapper.xdc、docs/board_io.md；底板/核心板PDF | hardware/sources.json、逐页文本和PNG；pins.log、constraints.log | 文档引脚映射一致；真实12麦载板、VCCIO电压未确认 |
| T03 | UNVERIFIED | 源码XDC、configs/pdm_interface_timing.json、analyze_pdm_interface.py、report_pdm_interface.tcl | timing/budget.json；vivado_interface/interface_reports；全SoC状态{soc} | 条件max路径验证完成；hold为解析，板级区间及相对时钟偏斜待实测/全路径核实 |
| T04 | PASS | tb/tb_pdm_shared_startup.v、scripts/check_pdm_shared.py | rtl_release/results.json及逐场景日志 | 双独立三态源；缺麦为理想下拉，冲突检测为仿真检查器 |
| T05 | PASS | rtl/array/rv32_pdm_array_rx.v、tb/tb_pdm_capture.v | default_50ms及16相位重启；integration_final | 50ms+4帧；VDD须在使能前有效，DC高通另有建立时间 |
| T06 | PASS | 新专项TB、原算术诊断TB | 每路64 bit/帧、12路valid同步、1024拍间隔、宽位参考0失配 | 不证明声学采样同时 |
| T07 | {('PASS' if soc=='PASS' else 'FAIL' if soc=='FAIL' else 'UNVERIFIED')} | check_pdm_integration.py、implement_pdm_interface.tcl、implement_pdm_soc.tcl | rtl_release.log、regression.log、integration_final.log、Vivado driver/report | 全SoC{soc}；无烧写、无板级验收 |
| T08 | PASS | 只读rv32_overlap_localizer.v、production_array.json、pdm12_geometry.py | geometry.log；原文件哈希保持 | 66对枚举；真实坐标、映射保持关闭 |
| T09 | PASS | docs/pdm_shared_timing.md、pdm_array_spec.md、golden/pdm_decim.py文字 | acoustic/results.json、acoustic.log | TEST_ONLY；无固定200ns声学校正写入 |
| T10 | PASS | README.md、docs/board_io.md、pdm_array_spec.md、RTL注释、TB日志文字 | 源码差异、pins.log反例检查 | 合法8/16配置及历史板测仍明确保留历史口径 |

表中T02/T03使用UNVERIFIED表示完整验收边界未闭合，不否认已完成的软件整改。具体仿真PASS仅限下列已执行场景。

## 基线、修改与兼容

初始工作区已有GSC时间戳、PS顶层、工程创建脚本和传输接口改动，原Git补丁和源SHA256保存在baseline目录。非本任务文件哈希检查通过；PS顶层保留用户GSC端口与连接。本轮无git提交、reset --hard、清理用户文件、硬件复位或烧写。

前基线重新运行原M6六场景与阵列34项，日志在baseline。先前只读审计未搜索到工程目录外原理图，本轮已找到桌面原始PDF；不能继续写成“本机没有底板/核心板图纸”。12麦载板图仍未提供。

关键变化：

* PDM输入整条false_path → 5ns输入max datapath及10ns CLOCK输出max datapath；引脚、IOSTANDARD和采样相位不改。
* 原数字valid立即发布 → 首对PDM不消费、50ms等待、其后4帧CIC清除后发布；首raw valid期间计数0、align消费后的下游首组ID1，保持旧接口语义，间隔1024拍。
* 接收器仍12通道/6根DATA、12个独立CIC；CIC算术、GCC、FFT、SIMD与DAS RTL未重写。
* MIC_STARTUP_CYCLES=0且CIC_SETTLE_FRAMES=0仅用于明确raw诊断。旧阵列TB显式使用该模式；旧采集TB使用4096拍缩放等待，保留4帧清除，完整生产参数单独运行。

## 引脚与原理图

| DATA | FPGA脚 | J3 | RTL通道 / 目标LR |
|---|---|---:|---|
| DIN0 | Y16 |31|0/GND，1/VDD|
| DIN1 | Y17 |32|2/GND，3/VDD|
| DIN2 | T15 |33|4/GND，5/VDD|
| DIN3 | T14 |34|6/GND，7/VDD|
| DIN4 | W16 |35|8/GND，9/VDD|
| DIN5 | T17 |26|10/GND，11/VDD|
| CLK | V16 |36|全部12麦共用，实体待确认|

原PDF：桌面`_领航者ZYNQ_FPGA_底板原理图_V3.4.pdf.pdf`第2页J3网络、`ZYNQ7010_7020核心板原理图_2V5.pdf`第3页Bank34封装脚、第7页供电。已目视核对上述目标映射，Bank34接VCCIO。V3.9底板图作为另一个版本归档，不能假定就是实际板卡。LVCMOS33是工程电平选择，VCCIO实际值未量；载板L/R、DATA并接、CLK树均UNVERIFIED_HARDWARE。

## 时序模型与工具边界

40MHz /16产生2.5MHz、每位400ns；HOLD=4/CONSUME=12的实际采样沿为125ns/325ns，距对应驱动沿均125ns。没有增加IDDR或两级同步器。

手册v1.00第8—10页：tDD40..80ns、tDV最大100ns、tHZ5..30ns。板级假设：CLOCK输出≤10ns、PCB CLK/DATA各0..3ns、FPGA输入路径≤5ns、FF setup/hold各2ns、相对clock skew/jitter2ns。最坏setup=0ns、hold=76ns；不是实测。增加1ns未预算延迟的解析反例判失败。

独立接口Vivado2020.2 Build3064766，真实器件xc7z020clg400-1，完成synth/opt/place/route：WNS0.677ns、WHS0.069ns、TNS/THS0。输入12个端点均有max路径，最小余量0.677ns。CLOCK路径6.521ns包含clk-to-Q0.456ns，预算余量3.479ns。资源3205 LUT、2012 FF；这是独立接口包装，不是整机资源。

AMD UG903规定max_delay datapath_only会忽略STA hold要求；因此min报告不能宣称PDM hold STA通过。hold结果来自显式外部窗口解析。check_timing仍可能提示六个输入没有传统set_input_delay；这里有显式max datapath预算，不将该提示或全设计WHS当成外部接口验收。要完成外部验收，还需实际板延迟、负载和完整采样时钟偏斜；独立包装的布局不能替代全SoC路径。

完整SoC：{soc}。{soc_details}

日志`vivado_soc_driver.log`保留首次run需要reset的脚本错误；修正仅对本次新建工程执行reset_run，不影响用户工程，重跑见`vivado_soc_retry_driver.log`。最终报告在vivado_soc目录，未生成/下载板级位流。

## 专项仿真结果

| 场景 | 状态 | 指纹 |
|---|---|---|
{result_table()}

短等待场景每项1680个通道样点检查，覆盖随机/全0/全1/交替码、16相位停启及复位、125ns采点断言、64 bit/PCM、1024拍间隔。完整50ms场景还在启动边界由全0切换到全1，检查首次发布已无CIC启动过渡。冲突/迟到检出为预期故障，不能计为正常音频。

开发失败日志保留：rtl_final是新TB端口类型声明错误；integration是旧等待上限失配；integration_acceptance含PS TB语言版本不兼容；fft_regression是旧TB输出非UTF8字节导致日志解码失败。修正驱动后只以rtl_release、integration_final、fft_final和regression终态为验收依据，不引用失败目录作PASS。

## 66对、GCC与DAS

RTL按(0,1)..(0,11),(1,2)..(10,11)枚举66对；接收通道2k/2k+1仍对应线k两半周期。production_array的mic_xyz/channel_to_mic/coordinate_frame仍为空，physical_mapping_confirmed=false，geometry_enabled=0；无TEST_ONLY数据写入生产标定。

200ns是数字采样间隔，不是实测声学偏差。复用当前M6 TEST_ONLY实验重新执行24方向、66对GCC/SRP：假设半位延迟改变1/24个搜索峰，整PCM点延迟改变24/24；理想等幅六A六B模型8kHz内最坏DAS损失0.0001097301dB，仅为受控模型。模型不证明实阵列角度或DAS品质。

## 复现命令

WSL在工程根执行（输出目录必须为新目录）：

```sh
python3 scripts/analyze_pdm_interface.py
python3 scripts/check_pdm_constraints.py
python3 scripts/check_pdm_pins.py
python3 scripts/check_pdm12_geometry.py
python3 scripts/check_pdm_shared.py --output build/pdm_shared_remediation/reproduce_rtl
python3 scripts/check_pdm_integration.py --output build/pdm_shared_remediation/reproduce_integration
python3 scripts/check_integrated_auxiliary.py --output build/pdm_shared_remediation/reproduce_regression
python3 scripts/check_pdm12_acoustic.py --output build/pdm_shared_remediation/reproduce_acoustic
```

Vivado以PowerShell执行`D:/Vivado/Vivado/2020.2/bin/vivado.bat -mode batch -notrace -source scripts/implement_pdm_interface.tcl`及`implement_pdm_soc.tcl`；实际日志和journal均在本次build根目录。默认构建脚本拒绝覆盖已有证据目录；全SoC仅允许明确--resume本次工程。版本文本、实际逐项命令和源SHA256均随结果JSON保存。

## 下一阶段

补齐真实12麦载板图及BOM/板卡版本；确认六DATA并接、相反L/R、共同CLK、供电与Bank34电平；以实测替换PCB假设，核对100pF测试条件及边沿/振铃/相对时钟偏斜；再用真实采集验证启动、缺麦、电气冲突边界和通道编号；获得生产坐标后才进行声学延迟/增益标定与真实定位/DAS验收。不得直接写死200ns补偿。
'''
(R/'docs/PDM双麦共线整改报告_2026-10-16.md').write_text(report)
print(json.dumps(status,indent=2))
