# SEARCH/FOCUS GUI联动修复候选

2026-11-03。独立副本基于通过20分钟实测的search_focus_20261103。参考ELF SHA256 4b138ebfa3a7fe589597242fbf8c2d9f056a960d5f0544b6098a84adab19141d。新候选 SHA256 f4004bb80001171a7a3a8f5f56e9075f6e226e688f81d5b4e2de7765bc2b7269，状态 OFFLINE_PASS_BOARD_UNTESTED。

原调用链：circular9_listen_js.h的手动/正式/当前方向锁定调用GET /api/listen/lock?rev=...，旧ps_circular9_listen.h置MANUAL_GSC并开启UDP。它不改变系统模式。ps_circular9_live.h仍以sf_audio_allowed门控真实GSC，故旧GUI的GSC显示不能证明实际并发抵消。旧退出为GET /api/listen/back?rev=...，原监听命令成功路径保持recording，UDP不随旧back关闭。独立系统卡此前有自己的按钮和轮询，两套入口互相脱节。

新调用链：所有锁定入口共用focus()，验证合法整数角度及SEARCH状态，通过GET /api/system/focus?az=...&el=...请求。HTTP成功仅表示接受。轮询GET /api/system/state及GET /api/listen，确认FOCUS、CPU1静止、暂停、GSC许可、MANUAL_GSC、pending清除及应用方向版本和角度一致后显示成功。系统真实状态覆盖旧监听模式，失败后重新读状态。12秒轮询预算、每请求3秒超时，双击由共享busy防重。合并旧独立系统卡与主监听入口。FOCUS时标注定位和诊断区域所保留的历史数据，原有效性逻辑仍在。

退出：GET /api/system/search后等待SEARCH、静止解除、暂停解除、GSC许可关闭及PATROL_DAS。若遇到SEARCH下旧MANUAL_GSC，则走现有合法back接口。没有在FOCUS下调用/api/listen/写命令。若进入前UDP关闭，成功提交FOCUS后由本标签页sessionStorage记录接管，退出时使用GET /api/recording/off并读回确认。进入前已开则保留。普通DAS停止或暂停沿用原接口，不触发关闭。UDP关闭失败提示SEARCH已恢复而UDP未确认，可从退出按钮重试。刷新本标签页恢复状态及收尾记录。外部进入FOCUS或新标签页无所有权记录时保留UDP，可用高级调试关闭。

所有权限制：现有固件无服务端所有权令牌，sessionStorage是客户端记录。并行控制者在FOCUS期间启停UDP无法精确归属；实板人工复验应使用一个控制标签页。请求响应丢失时无法确认是否受理，界面重读实际状态，未知所有权的UDP由高级调试手动收尾。未引入跨标签页或服务端仲裁。

修改文件：独立副本observer/sw/circular9_listen_js.h。listen.js是解码后的可读资源，listen.diff是可审查差异，test_gui.cjs运行实际资源与模拟DOM和接口。其余sw文件逐字节比较未变。原DAS巡检命令、调试录音和freeze/adapt后端未改，未改状态机核心、算法或采集链路。

验证：Node语法检查通过。实际JS模拟验证了进入、退出、刷新、预先开启UDP、拒绝、超时及取消、重复操作、非法角度、UDP关闭失败、普通DAS停止。调试按钮真实浏览器行为和跨标签页并发未验证。ARM全量编译链接通过，text566496、data3662、bss51746896。检查实际ELF包含精确JS资源，独立bundle哈希校验通过。未接触板卡。

人工复验：经另行授权用本目录bundle按既有RAM JTAG流程加载；核验新ELF哈希和/listen.js。真实浏览器分别在UDP预先关闭和预先开启两种条件下进入，输入合法方向并确认切换中、ack、版本与实际方向；刷新当前页，检查状态及历史提示。用GUI退出，检查SEARCH和搜索推进；验证本次接管UDP关闭、预开UDP保留。验证普通DAS暂停/停止不改UDP以及高级调试独立控制。保存Console、Network、状态与截图。异常时先保存证据并正常退出，不自动加载其他版本。

回退：现有阶段1 bundle_stage1完整保留。若以后加载候选后需要回退，按授权用原bundle的完整匹配BIT/init/ELF进行RAM加载。此新ELF尚无真实浏览器或实板验收记录。
