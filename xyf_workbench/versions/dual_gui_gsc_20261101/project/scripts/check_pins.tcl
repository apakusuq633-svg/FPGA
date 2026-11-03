# 用 Xilinx 自己的器件数据核对「封装脚 → IO 站点」，并**对比 7010 与 7020 是否同脚**。
#
#   vivado -mode batch -source scripts/check_pins.tcl
#
# 为什么必须核这一步：整套 xdc 里的 PACKAGE_PIN（R18 / V16 / Y16 …）是从核心板
# 原理图的 PDF 书签树抽出来的，不是 Vivado 报的。board_io.md §4 记过一次抽取
# 正则跨单元误配（B35_IO0 被配到 U1F 上）。**从 7010 换到 7020 之后这件事更危险**：
# 如果两个器件在同一封装下 bank34/35 的脚位不同，那么现有 xdc 会**照常编译通过、
# 照常生成位流，只是全部接错脚** —— 上板现象是「什么都不动」，跟没插电一样。
#
# 所以这里把两个 part 的答案并排列出来，逐脚 diff。
#
# ⚠ 两条都是实测踩出来的：
#   1. `get_package_pins` **必须先 link_design**，只 create_project 会报
#      "No open design" 并返回空 —— 而空对空比较永远「相等」，
#      第一版脚本因此报了个假的 PASS。凡是"全都一致"的结论，
#      先确认每一条都真的取到了值。
#   2. package_pin 对象**没有 SITE 属性**，站点在 `PIN_FUNC` 里
#      （形如 IO_L20N_T3_34）。查 SITE 会抛异常，被 catch 吞掉又变成空值。
#
# ⚠ 本脚本只查器件数据，不跑 synth_design —— docs/issues/039 记的那个原生崩溃
#   发生在综合阶段，这一步不受影响。

# 板级用到的全部 PL 引脚（J3 上的阵列 + 转速）。
# 键 = 封装脚，值 = 我们给它起的名字。
array set pinmap {
    N18 "J3.11 (MRCC, 未分配)"
    R18 "J3.25 tacho_i"
    T17 "J3.26 (备用/PDM DIN5)"
    V18 "J3.27 (备用/PDM DIN6)"
    V17 "J3.28 (备用/PDM DIN7)"
    U17 "J3.29 (备用)"
    T16 "J3.30 (备用)"
    Y16 "J3.31 pdm_din_i\[0\]"
    Y17 "J3.32 pdm_din_i\[1\]"
    T15 "J3.33 pdm_din_i\[2\]"
    T14 "J3.34 pdm_din_i\[3\]"
    W16 "J3.35 pdm_din_i\[4\]"
    V16 "J3.36 pdm_clk_o"
}

set parts [list xc7z010clg400-1 xc7z020clg400-1]
array set result {}
array set got {}

foreach p $parts {
    if {[catch {
        create_project -in_memory -part $p -force
        link_design -part $p
    } err]} {
        puts "PART  $p  ** 建/链工程失败: $err"
        continue
    }
    set missing 0
    foreach pin [lsort [array names pinmap]] {
        if {[catch {set o [get_package_pins -quiet $pin]} e] || $o eq ""} {
            set result($p,$pin) "**查不到**"
            incr missing
        } else {
            set result($p,$pin) [get_property PIN_FUNC $o]
        }
    }
    close_project
    puts "PART  $p  : 13 个脚里 $missing 个查不到"
}

puts ""
puts [format "%-5s %-26s %-22s %-22s %s" "脚" "我们叫什么" "7010 站点" "7020 站点" "判定"]
set mismatches 0
set blanks 0
foreach pin [lsort [array names pinmap]] {
    set a $result(xc7z010clg400-1,$pin)
    set b $result(xc7z020clg400-1,$pin)
    if {$a eq "**查不到**" || $b eq "**查不到**"} { incr blanks }
    set same [expr {$a eq $b}]
    if {!$same} { incr mismatches }
    puts [format "%-5s %-26s %-22s %-22s %s" $pin $pinmap($pin) $a $b \
              [expr {$same ? "同脚" : "**不同脚**"}]]
}

puts ""
if {$blanks > 0} {
    # 空值对空值也是「相等」，所以这一条必须先于下面那条判 —— 第一版就是漏了它
    puts "INVALID: 有 $blanks 个脚根本没查到值，这次比较不作数（空对空永远相等）"
    exit 1
} elseif {$mismatches == 0} {
    puts "PASS: 两个器件在 CLG400 下这 13 个脚位完全相同"
    puts "      => 现有 constrs/*.xdc 可以直接用；换 7020 只需改 part 字符串"
    puts "         和 hardware manager 的 target filter"
} else {
    puts "FAIL: 有 $mismatches 个脚位不同 —— **必须按 7020 重写 constrs/ 下的 xdc**"
    exit 1
}
