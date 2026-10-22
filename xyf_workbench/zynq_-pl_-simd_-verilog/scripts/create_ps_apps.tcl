# 在已有的 Vitis 工作区里建/更新两个 PS 侧裸机 app，并构建。
#
# 用法：
#   xsct scripts/create_ps_apps.tcl
#   xsct scripts/create_ps_apps.tcl -ws D:/Vitis          （换工作区）
#   xsct scripts/create_ps_apps.tcl -no-build             （只建工程、拷源码，不编译）
#
# 与其它脚本的分工：
#   create_zynq_project.tcl   建 **Vivado** 工程（BD + 地址钉死）
#   export_xsa.tcl            跑实现 + 导出 **XSA**
#   create_ps_apps.tcl        建 **Vitis** app 并编译 —— 就是本脚本
#   install_ps_app.ps1        把 sw/ 下的源码拷进 app 的 src/，带分叉检查与 RV32_BASE 核对
# 本脚本不自己维护源码清单，而是**调用 install_ps_app.ps1**，免得清单有两份（它一变，
# 两边就对不上了）。所以清单的真值源永远只有 install_ps_app.ps1 里那一处。
#
# 三个 app：
#   rv32_app      第二版验收：把流水灯固件灌进 ITCM、放行 RV32 核、采样读回
#   dualcore_app  从 A9#0 启动 A9#1（boot address + SEV）并证明它在跑
#   fft_app       轴承包络谱流水线跑在 A9#1，逐项对 MATLAB（输入是编译进去的帧）
# 后两个原先不在任何构建链路里，只能手工在 Vitis 里换文件；现在走同一条路。
#
# 平台（platform）不在本脚本的管理范围：它由 XSA 建，通常只需要建一次。不存在时本脚本
# 直接报错并给出重建命令，不会替你猜。
#
# 注意：要打印的字符串一律 ASCII。xsct 在这台机器上按 cp936 读源码，字符串里的中文
# 会打成乱码（和 create_zynq_project.tcl 同一个坑）。注释用中文没问题。
# 方括号在双引号里是**命令替换**：要字面量得写 \[ \]（create_zynq_project.tcl 踩过）。

set ws        D:/Vitis
set platform  PS-PL
# 注意这里是 **domain 名**，不是 CPU 实例名。平台里 CPU 实例是 ps7_cortexa9_0，
# 但 domain 叫 standalone_domain —— 填错了 app create 会报
#   The Domain given "ps7_cortexa9_0" is not valid for the platform ...
# 真值源：<ws>/<platform>/platform.spr 里的 "sysDefaultDom"，或现有 app 的 .sprj。
set domain    standalone_domain
set do_build  1

# xsct 不保证定义了 argv（-source 与脚本参数两条路的处理不同），所以先判存在再解析。
if {[info exists argv]} {
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            -ws       { incr i; set ws [lindex $argv $i] }
            -platform { incr i; set platform [lindex $argv $i] }
            -domain   { incr i; set domain [lindex $argv $i] }
            -no-build { set do_build 0 }
            default   { puts "==> unknown option: $a"; exit 1 }
        }
    }
}

set root [file normalize [file join [file dirname [info script]] ..]]

# {Vitis 工程名} {install_ps_app.ps1 的 -App} {该 app 里定义 RV32_BASE 的源文件}
# 工程名和 -App 不是一回事：前者是 Vitis 里的目录名（沿用已有的 rv32_app 这个名字，
# 免得老工程旁边又多出一个 rv32），后者是 install_ps_app.ps1 里的清单键。
#
# ui_app 的第三项是**头文件**（别的都是 .c）：那个 app 自己不写 RV32_BASE，
# 它访问 DTCM 的那段在 ps_diag.h 里 —— 而那个宏正是这里要比对的东西，
# 所以清单里得指向真正定义它的那一份。下面的扫描只认文件存在与否，扩展名无所谓。
set apps {
    {rv32_app      rv32     ps_main.c}
    {dualcore_app  dualcore ps_dualcore.c}
    {fft_app       fft      ps_fft_test.c}
    {ui_app        ui       ps_diag.h}
}

puts "==> workspace : $ws"
puts "==> platform  : $platform  (domain $domain)"
puts "==> repo root : $root"

if {![file isdirectory $ws]} {
    file mkdir $ws
}

setws $ws

# 平台必须已经存在。它由 XSA 建，重建一次要跑平台生成，不适合塞进本脚本。
set sprj [file join $ws $platform platform.spr]
if {![file exists $sprj]} {
    set fresh_xsa [file join $root vivado_zynq ps_pl_wrapper.xsa]
    if {![file exists $fresh_xsa]} { error "Export the XSA before creating the platform" }
    platform create -name $platform -hw $fresh_xsa -proc ps7_cortexa9_0 -os standalone -out $ws
    platform write
}

platform active $platform

# 先把平台指向仓库里当前的 XSA，再生成。**这两步不能省 updatehw**：单纯 platform generate
# 不会重读硬件描述，改了 BD（比如给 PS7 开 I2C0）却不 updatehw 的话，BSP 会继续按旧的
# handoff 生成 —— 表现就是"BD 里明明开了 I2C0，BSP 里却没有 iicps 驱动"。踩过。
set xsa [file join $root vivado_zynq ps_pl_wrapper.xsa]
if {[file exists $xsa]} {
    puts "==> platform config -updatehw $xsa"
    if {[catch {platform config -updatehw $xsa} err]} {
        puts "==> ERROR: platform config -updatehw failed: $err"
        exit 1
    }
} else {
    error "No current XSA at $xsa; run scripts/export_xsa.tcl first"
}
platform generate

foreach pair $apps {
    set appname [lindex $pair 0]
    set appkey  [lindex $pair 1]
    set srcfile [lindex $pair 2]

    puts ""
    puts "===================== app: $appname (manifest key $appkey) ====================="

    set appdir [file join $ws $appname]
    if {[file isdirectory $appdir]} {
        puts "==> $appname already exists, leaving the project as it is"
    } else {
        # 模板名是 "Empty Application" —— **没有 "(C)" 后缀**。写 "Empty Application(C)"
        # 会被拒：error "... is not valid application template name"。名字的真值源在
        # <Vitis>/data/embeddedsw/lib/sw_apps/empty_application/data/empty_application.tcl
        # 的 swapp_get_name。
        app create -name $appname -platform $platform -domain $domain \
            -template "Empty Application"
        puts "==> created $appname"
    }

    # 拷源码。-Force 是因为 sw/ 才是真值源（README 的约定）；分叉检查照跑，
    # 真有分叉时 install_ps_app.ps1 会报出来，本脚本把它的输出原样透传。
    set src [file join $appdir src]
    set ps1 [file join $root scripts install_ps_app.ps1]
    if {![file exists $src]} {
        puts "==> ERROR: $src does not exist -- app create did not produce a src/"
        exit 1
    }
    puts "==> copying sources via install_ps_app.ps1 -App $appkey"
    if {[catch {
        exec powershell -NoProfile -ExecutionPolicy Bypass -File $ps1 \
            -AppSrc $src -App $appkey -Force
    } err]} {
        puts "==> ERROR: install_ps_app.ps1 failed:"
        puts $err
        exit 1
    }

    # 这个 app 的 RV32_BASE 得和 BD 钉的地址一致。两处都必须对 —— 见下面的汇总。
    set f [file join $src $srcfile]
    if {[file exists $f]} {
        set fp [open $f r]
        set txt [read $fp]
        close $fp
        if {[regexp {define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)} $txt whole b]} {
            puts "==> $appname RV32_BASE = $b"
        } else {
            # dualcore_app / fft_app never touch the AXI slave, so this is normal for them
            # rather than a problem. Only the two that do talk to PL have anything to check.
            puts "==> $appname has no RV32_BASE (it does not touch the AXI slave)"
        }
    }
}

# 两个 app 访问的是同一个 AXI 从端，RV32_BASE 对不上就是有一个错了。
# 真值源是 BD 里的 assign_bd_address -offset，create_zynq_project.tcl 会在日志里打印。
set bases {}
foreach pair $apps {
    set appname [lindex $pair 0]
    set srcfile [lindex $pair 2]
    set f [file join $ws $appname src $srcfile]
    if {![file exists $f]} { continue }
    set fp [open $f r]
    set txt [read $fp]
    close $fp
    if {[regexp {define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)} $txt whole b]} {
        lappend bases [list $appname $b]
    }
}
puts ""
puts "==> RV32_BASE per app:"
foreach e $bases { puts "      [lindex $e 0] = [lindex $e 1]" }
# 三个 app 访问的是同一个 AXI 从端，任意两个对不上就是有一个错了。逐个和第一个比，
# 而不是只比前两个 —— 清单变长之后那条老判断会静默失效。
if {[llength $bases] > 1} {
    set want [lindex $bases 0 1]
    foreach e $bases {
        if {[lindex $e 1] ne $want} {
            puts "==> WARN: [lindex $e 0] has RV32_BASE [lindex $e 1], but [lindex $bases 0 0] has $want"
            puts "==>       (powershell scripts/verify.ps1 -- item 14 checks it against the BD)"
        }
    }
}

if {!$do_build} {
    puts ""
    puts "==> -no-build given: projects are ready, nothing compiled"
    exit 0
}

foreach pair $apps {
    set appname [lindex $pair 0]
    puts ""
    puts "==> building $appname"
    if {[catch {app build -name $appname} err]} {
        puts "==> ERROR: build failed for $appname:"
        puts $err
        exit 1
    }
}

puts ""
puts "==> Done. All apps are built."
puts "==> Next: pick the app in Vitis and Run As -> Launch Hardware (Single Application Debug)."
puts "==>   rv32_app      runs first (it is the PS-PL path check; needs the bitstream loaded)."
puts "==>   dualcore_app  starts A9#1 and proves it runs; no PL interaction."
puts "==>   ui_app        serves the diagnosis over the PS Ethernet port (needs ENET0 in the BD)."
puts "==>   fft_app       runs the bearing pipeline on A9#1 against a compiled-in frame."
