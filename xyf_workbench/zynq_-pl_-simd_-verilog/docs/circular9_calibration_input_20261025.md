# 九麦实测坐标、通道和幅相标定输入

当前用户确认的几何是外圈八个声孔、声孔圆半径30mm、中心一个声孔。旧方案的25mm保留为历史假设。配置中的30mm名义PCB半径不构成麦克风封装到板边的净距证明；本工具始终保留 `clearance_unverified: true`，也始终输出 `board_tested: false`。

本轮补齐的是**实测记录进入同一套方向LUT、RV32/PS头文件和发布身份的通路**，不自动估计增益或时延，不生成测量结论，不设置实板验收通过。未审核记录可以生成受保护的外置配置；不能凭模板或者理想圆坐标解除保护。

## 坐标与通道约定

面对阵列声孔正面：`+x` 向右、`+y` 向上、`+z` 指向正面声源，坐标单位米。原点取中心声孔附近、声孔所在平面；声孔坐标应由PCB资料或实际测量取得。二维扫描仍只覆盖正面半空间，不做距离扫描。

`microphones` 按实物标签 `mic_id: 0..8` 记录声孔中心坐标，不要求外圈仍是精确理想圆，也不要求物理mic0恰好在最右边。`channel_to_mic[ch]` 表示FPGA原始PCM采集通道ch实际接到哪个实物麦。外圈0..7可置换，必须通过逐麦敲击/近场声音和通道能量验证。

**中心mic8必须对应capture slot8。** 当前GSC和有效通道掩码采用这个约定；若实物中心落在其他槽，先核对并修正接线，工具会拒绝用置换掩盖该问题。第9槽是未使用的第十个采集时隙，其生成增益固定为0。

工具把物理麦坐标按上述映射转换为 `channel_positions_m`；生成器中的几何位置、幅度修正和传感器时延均按**原始采集通道顺序**解释。

## 创建待填写记录

在工程根目录运行，输出文件使用新路径：

```powershell
& C:/msys64/ucrt64/bin/python.exe scripts/circular9_calibration.py template --config configs/circular9_array.json --output measurements/circular9_20261025/record.json
```

模板中的实际坐标、映射、采样契约、增益、时延和残差全部为 `null`，六个确认项全部为false。`expected_capture_contract` 仅是当前工程预期值，不能当作测量结果。实际 `capture_contract` 要根据所用时钟、抽取设置和采集时间戳核对后填写，并在 `sources.clock` 中记录依据。

记录绑定创建时源配置文件的原始字节SHA256。若源配置发生变化，工具会拒绝沿用旧记录；应重新生成模板并人工复核相关测量。

## 幅度与传感器相对时延

`channel_gain_q14[9]` 是施加到原始PCM的正幅度修正系数：修正倍率为 `gain/16384`。未标定默认值是16384。实际对齐器用有符号16位Q2.14，允许范围8192..32767；**32768会变为负数，禁止使用。** 超出约±6dB的通道应先检查麦克风、供电和接线，不能用极端增益掩盖坏通道。

`channel_delay_samples[9]` 是**去除已知几何传播后，传感器本身相对参考通道的到达时延**，参考ch0必须为0，绝对值不能超过4个原始PCM采样周期。当前156250Hz下一个周期为6.4μs。数值允许小数；较晚到达的传感器取正数。不能把诊断降采样后的采样数填进来，也不能把几何传播时延再重复填一次。

生成器统一计算：

```text
arrival[ch] = -dot(position[ch], direction) * Fs / sound_speed
              + channel_delay_samples[ch]
SRP pair(a,b) = floor((arrival[a] - arrival[b]) * 16)
steer[ch]    = floor((arrival[0] - arrival[ch]) * 16)
```

因此SRP定位、方向拾音和PS分离使用同一个总到达模型。合法的系数也可能使64点相关窗口溢出；生成器会拒绝这种组合，不能截断后继续使用。

增益/时延可以由独立声场测量和离线拟合提供，本工具不负责拟合。应保存实际录音、已知声源方向、坐标、频率响应和拟合报告，使用另一段数据复核残差。拟合的带内覆盖至少300Hz至配置的上限频率，当前为8000Hz。记录九路的 `gain_rms_db`、`phase_rms_deg`、`delay_rms_samples`；现有保守门限分别为0.5dB、10°、0.25个原始采样。超限意味着当前恒增益/恒时延模型未得到支持，不能通过勾选确认绕过。

## 来源、证据和审核

填写阵列实物标识 `array_id`、测量人 `operator` 和带时区的ISO8601时间，例如 `2026-10-25T15:30:00+08:00`。`sources` 分别说明坐标、映射、时钟、增益和时延的来源。

`evidence_files` 引用实际文件，条目格式为：

```json
{
  "path": "gain_delay_fit.csv",
  "sha256": "填写该实际文件的64位小写SHA256",
  "roles": ["gain", "delay", "fit"]
}
```

相对路径以测量记录所在目录为基准。外置配置保存该目录的绝对路径 `geometry_measurement.evidence_root`。工具会读取证据文件并核对哈希，正式构建及 `--validate-only` 也会重新读取和核对；生成配置后删除或修改证据，构建将拒绝确认。审核记录至少要有gain、delay、fit三类证据引用。来源文字和哈希用于可追溯，不能自行证明测量方法正确。

只有真实测量和残差复核完成后，才把六个 `confirmations` 设为true。此时输出 `measured_reviewed`、非零标定版本以及已确认几何。只要任一项未确认，输出仍为 `unmeasured`、版本0和未确认几何。空着的增益/时延仅在未声称已测量的草稿中转成unity/0，以保留开发通路；它们不会因此成为实测值。

## 校验、生成外置配置与正式构建

```powershell
& C:/msys64/ucrt64/bin/python.exe scripts/circular9_calibration.py validate --config configs/circular9_array.json --record measurements/circular9_20261025/record.json
& C:/msys64/ucrt64/bin/python.exe scripts/circular9_calibration.py build --config configs/circular9_array.json --record measurements/circular9_20261025/record.json --output measurements/circular9_20261025/calibrated.json
& C:/msys64/ucrt64/bin/python.exe scripts/build_circular9.py --config measurements/circular9_20261025/calibrated.json --validate-only
```

外置配置和旁边的 `.manifest.json` 使用新文件名，工具不覆盖已有记录。`--validate-only` 不写固件、LUT或头文件。确认使用该记录后，正式生成必须显式指定同一文件：

```powershell
& C:/msys64/ucrt64/bin/python.exe scripts/build_circular9.py --config measurements/circular9_20261025/calibrated.json
```

正式构建输出的 `build/circular9/build_manifest.json` 记录原输入的绝对路径 `config_path` 和原始字节摘要 `config_sha256`；运行时geometry版本也来自同一原始文件。`calibration_evidence_sha256` 保存实际核对过的证据绝对路径到摘要的映射，证据同时进入源文件摘要清单。发布时必须复制这份原配置文件字节，不能把重序列化的 `profile.json` 当成同一版本身份。`profile.json` 是带默认增益、时延和状态的有效配置快照。

正式头文件包含 `acoustic_gain_q14[10]`、`ACOUSTIC_CALIBRATION_STATUS`、标定版本与同源SRP/steer LUT。工具不会自动改写默认 `configs/circular9_array.json`，也不会自动下载FPGA或设置 `board_tested`。

## 软件验证范围

```powershell
& C:/msys64/ucrt64/bin/python.exe scripts/check_circular9_calibration.py
```

独立测试使用明确标识的合成坐标、合成增益/时延和临时证据文件，验证外圈置换、中心槽限制、30mm声孔圆、有限数、平面和二维孔径退化、来源绑定、残差门限、证据变更、保护状态，以及SRP/steer的独立数学期望。它不会运行生产固件生成，也不代表真实九麦已完成幅相标定或实板验收。
