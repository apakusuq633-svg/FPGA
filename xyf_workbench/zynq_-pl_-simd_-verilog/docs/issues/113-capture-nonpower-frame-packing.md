# 113：12麦非2次幂帧宽寻址

状态：已修，12麦全部统计、持续音频、PS快照及完整实现通过。日期：2026-10-14。

## 症状

本轮隔离12麦候选固件读取CAP INDEX=6时得到X，随后PC和音频控制受污染。此前已验收的12麦原仓库和产物不受影响。

## 误判

不是DAS等待或SIMD抢占。追加检查也发现未使用的callee-saved寄存器恢复可能为X，不能把所有栈读取都当成采集错误。

## 根因

迁移通用模块时覆盖了12麦原有的按WORDS寻址：`{bank,pos,word}`按8字跨步，而12麦每帧6字，读写布局不一致。

## 修法

共享RTL按`bank*CAPACITY*WORDS+pos*WORDS+word`写，按`bank*CAPACITY*WORDS+index`读；越界索引返回0。4/8/16麦常量乘法仍化为移位。CAP有效数据读取增加X检查，保留指令完整性检查，不检查无关寄存器初值。

## 复现指纹

`twelve_stage2_final/scripts/check_live16_xsim.ps1 -Twelve`：两轮分别1420639/1425655拍，6144次DATA读取、6144次INDEX写入，2780个连续DAS/FIR样点、0丢样、几何关闭。`-Twelve -RawCapture`：12288个原始样点逐位一致，2084个连续音频点、0丢样，release/cancel通过。

最终完整实现40MHz：WNS+0.615ns、WHS+0.029ns，setup/hold端点和TNS/THS均0。追加能量参考时先计算32位样点平方再累加到64位，避免TB混合有符号/无符号表达式错误扩展负样点；生产统计本身未改变。
