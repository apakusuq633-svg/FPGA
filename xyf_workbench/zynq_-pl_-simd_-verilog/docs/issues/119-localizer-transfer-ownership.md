# 119：自主搬运与核计算提交的所有权

状态：已修（SoC仿真与完整实现，未烧板）。

## 症状

原独立localizer自行启动计算，不能证明复用自研核自定义指令；直接将算子done交给搬运机又可能在CPU HALT/访存等待时提前推进。

## 误判

实例名字在PL不等于通过核指令计算；看到硬件done也不等于CPU已接受并提交该指令。

## 根因

算子IO和运算共用端口，但状态机、流水核和MMIO原先没有共同的阶段所有权/提交协议。

## 修法

CPU_SCHEDULED请求种类加编号，核仅接受当前阶段的计算指令；状态机等待IO ready。对外compute_done同时要求实际核commit及合法compute操作。传输拥有RAM期间拒绝CPU/PS竞争加载，复用现有算子。输入预取在accept时推进，反压保持地址。

## 复现指纹

`check_localizer12.py --windows 256 --tag final256`，3072/16896/16896/16896/256次实际FFT/IFFT/互谱/PHAT/SRP退休；黄金全通过。`--windows 4 --mode halt --tag final_halt4`插入5000拍HALT仍通过；gap/slow负例必须报CAPTURE_LOSS。完整接口及manifest见最终实现报告。
