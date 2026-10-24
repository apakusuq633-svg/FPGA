# Isolated TCP+UDP standalone BSP; no target or deployment commands.
if {$argc!=2} {error "Usage: build_circular9_platform.tcl matching.xsa new_workspace"}
set xsa [file normalize [lindex $argv 0]]
set ws [file normalize [lindex $argv 1]]
if {![file isfile $xsa]||[file exists $ws]} {error "Require existing XSA and fresh workspace"}
if {[catch {
    setws $ws
    platform create -name circular9 -hw $xsa -proc ps7_cortexa9_0 -os standalone -no-boot-bsp
    domain active standalone_domain
    bsp setlib -name lwip211 -ver 1.3
    bsp config api_mode RAW_API
    bsp config lwip_tcp true
    bsp config lwip_udp true
    bsp config lwip_dhcp false
    bsp config tcp_queue_ooseq 0
    platform generate
} message]} {puts "CIRCULAR9_PLATFORM_FAIL $message";puts $::errorInfo;exit 1}
puts "CIRCULAR9_PLATFORM_PASS";exit
