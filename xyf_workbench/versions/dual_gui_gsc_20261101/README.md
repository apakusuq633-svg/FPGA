# 九麦双层GUI + 固定方向GSC（未做双模式）

归档日期：2026-11-01。只包含演示总览/高级调试、手动固定目标GSC及G9A1连续音频；**没有DAS巡检/GSC双模式、B身份补丁或D调度原型**。

## 先读风险

这不是已完成长期稳定性和声学效果验收的发布。历史存在真实GSC运行造成DMA丢帧、搜索/诊断停止的失败，详见 [撤回记录](docs/VALIDATION_REVOKED.md)。2026-11-01的短时复测中搜索/诊断持续推进、DMA丢帧未增加，但仅干扰相对DAS衰减约0.1–0.3dB，尚未证明明显抑制收益；不能由短时正常推翻历史失败。

GSC只处理连续UDP音频，不接入正式PS联合定位或C9S3诊断。GUI诊断频谱/包络谱仍来自C9S3，不能作为GSC效果图。

## 目录

- `project/`：独立源码快照，含configs、profiles、rtl、scripts、sw。原基线commit与覆盖版本见SOURCE_PROVENANCE.json。已有上游旧模块/脚本保留，不表示全部路径处于当前启用状态。
- `release/`：原双层GUI归档的ELF、bit、初始化及加载脚本，逐字节保持原文件；当前上传没有重新构建或访问板卡。
- `pc/receive_audio.py`：G9A1接收器，同时保存DAS/GSC两路；该旧接收器只保存原因码汇总。
- `tests/`：GUI联合评分状态测试、原不变性记录。测试路径为适应归档目录而调整；不改变正式算法。
- `docs/`：历史合并说明、撤回记录和架构图。历史说明须结合本页风险阅读。
- `FILE_SHA256.json`：本次快照文件清单与哈希（不含其自身）。

## 本地检查与部署

PowerShell在本目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release\program.ps1
```

默认仅本地核验归档哈希，不访问板卡。真正下载必须由操作者明确决定，脚本只有加`-Program`才会复位/加载，需Xilinx XSCT工具；这次Git上传未执行该操作。

不要将此版本的控制命令直接用于双模式候选。不要覆盖其他已验证ELF或bit。

## 编译依赖

源码目录的`project/scripts/build_ui_pipeline.ps1`支持参数化ToolDir、BspDir、AppDir及IndependentOutput。需要外部Xilinx Vitis 2020.2 ARM工具链、对应standalone/lwIP BSP；该归档不包含工具链或完整BSP，不能宣称克隆后可无依赖重建。源码脚本内有历史机器路径，需按本机配置参数。GUI资源嵌入ELF，不能仅更换本地HTML部署。

当前正式九麦构建使用Live、MatchingPlWindow、ActiveChannels=9、FstfExperimental和JointFormal等配置；具体行为以SOURCE_PROVENANCE、源码和原归档ELF为准。本次上传没有重新编译ARM或改变构建产物。

## 连续音频

原始九路PCM=156250Hz；音频支路127tap抗混叠后/8=19531.25Hz。约4.6kHz以上明显衰减，不是完整保留7.5kHz的GSC。G9A1经UDP1234同时传DAS与处理输出，不含九路原始PCM。

PC在本目录执行（输出目录必须新建）：

```powershell
python .\pc\receive_audio.py --out .\recordings\test_001 --seconds 8
```

GUI固定目标指向要保留的目标，允许自适应，再开启GSC/UDP。reason0只是进入GSC处理路径，reason8同时可能是保护/发散；guard=1表示保护启用，guard=3才表示保护活动。停止测试后关闭UDP。该版本/api/raw/start由连续UDP路由接管，不按旧原始快照脚本能力解释。

## 回退

本版本在独立分支和versions目录中保存，不改变远端master，也不改本机原latest4。源码查看可切回其他分支；真实板卡回退须由操作者另行选择匹配的已验证发布包，不由Git切换自动完成。
