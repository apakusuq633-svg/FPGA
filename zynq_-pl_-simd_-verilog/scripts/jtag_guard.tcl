# 上板脚本在 `connect` 之前 source 这个：别的项目占着板子就**拒绝往下走**。
#
#   source [file join [file dirname [info script]] jtag_guard.tcl]
#
# 为什么不用 "跑之前 Get-Process 看一眼"：对方（multichannel_acoustic，I2S 那一版）
# 的 XSCT 是**短命、随机启动**的，查的那一刻干净不代表下一秒干净。
# 真正保险的是**在 connect 之前立刻查一次**，并且把判据说清楚。
#
# 判据与详细说明见 scripts/check_jtag_owner.ps1（纯 ASCII，看命令行里的路径，
# 因为两边的可执行文件都叫 rdi_xsct.exe，名字分不出来）。

set _guard [file join [file dirname [info script]] check_jtag_owner.ps1]
if {![file isfile $_guard]} {
    puts "WARN: 找不到 $_guard，跳过 JTAG 占用检查"
} elseif {[catch {exec powershell -NoProfile -ExecutionPolicy Bypass -File $_guard} _out]} {
    puts $_out
    error "JTAG 被别的项目占用，已中止。等对方跑完、或与对方协调时段，再上板。"
} else {
    puts "==> JTAG 占用检查通过"
}
