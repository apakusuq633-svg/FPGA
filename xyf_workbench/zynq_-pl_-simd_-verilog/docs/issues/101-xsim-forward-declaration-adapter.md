# 101：XSim 复核副本漏掉 FFT 信号赋值

状态：已修，首帧完整 SoC 的 Icarus / XSim 交叉复核通过。

## 症状

Icarus 运行真实16麦定位固件通过；XSim复核在样点2323失败：DAS返回0，参考值−8220，同时编译警告 `second declaration 'xr' ignored`。

## 误判

失败发生在FFT执行期间，曾怀疑定位和音频共用核内资源导致丢样。两个仿真器之间有临时声明转换，必须先检查其是否保留信号赋值。

## 根因

旧RTL先使用xr/xi再声明；XSim适配脚本将声明移到前方，但用固定空格字符串替换原带初始化声明，和源文件空格不匹配。重复声明留在临时副本里，XSim忽略它及其赋值，FFT数据异常。生产RTL没有被这段适配修改，Icarus通过与Vivado位流仍对应原RTL。

## 修法

`check_live16_xsim.ps1` 改用允许空白差异的正则，显式生成xr/xi连续赋值，并检查两条赋值存在。ROM使用绝对路径，前置声明调整仅限build内临时副本。

## 复现指纹

`powershell -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1`。

修后XSim和Icarus均输出 `LIVE16_SOC_PASS samples=11014 steered_samples=256 drops=0 all_1024_scores_match=1`；首帧计算9968351拍、总耗时11015972拍一致。修后编译日志没有xr/xi重复声明警告。原始XSim通过日志 `build/das16_loc/xsim/simulation.log`；持续生产固件多帧验证另使用 `-Natural`，独立输出xsim_natural。
