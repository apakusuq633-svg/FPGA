# 110 12麦XDC的条件语句被Vivado忽略

状态：源文件/生成器已修，Tcl正向和反证通过；打开的GUI工程需应用新约束后重跑实现。

**症状**：用户完成12麦位流后截图显示`Designutils 20-1307 Command 'if' is not supported in the xdc constraint file`；另有`tacho_s1_q_reg`找不到的`Vivado 12-4739`。该轮实现报告WNS +0.709ns、WHS +0.048ns、setup/hold/pulse-width违规端点均0，不能用这份旧约束报告代替修正后实现。

**误判**：在XDC中对可选DIN6/7使用普通Tcl条件语句。XDC是受限解释器，文件中的原有警告注释已经明确禁止控制流；这次错误由代理引入。

**根因**：12麦只有6根DIN，旧8线模板需要按配置裁剪；条件逻辑应该放在建工程Tcl而不是XDC。当前RTL仅保留tacho_i输入，没有tacho同步寄存器，旧时序约束没有目标。

**修法**：去掉XDC条件语句及失效tacho路径约束。canonical XDC保留8线引脚模板，`scripts/apply_pdm_constraints.tcl`在普通Tcl中生成只含当前端口的纯XDC，并替换工程的旧约束引用。创建工程脚本调用同一过程。12麦生成6线，旧16麦生成8线，不改变引脚映射；四麦专用换线流程仍使用纯8线模板。

**复现指纹**：`python3 scripts/check_pdm_constraints.py`在真实Tcl解释器运行生成器，12/16麦分别包含6/8条DATA约束且没有控制流；故意注入if被拒绝。`check_pdm_pins.py`的8项反证及模板引脚对照通过。Vivado GUI中执行source后`apply_pdm_constraints 12`，再重新综合/实现/位流；旧Messages记录不代表新运行结果。当前已打开GUI，代理没有重建或覆盖用户的工程运行结果。
