# Software generation only. No connect/targets/reset/download/program commands.
if {$argc!=2} {error "Usage: build_stream_platform.tcl matching.xsa new_workspace"}
set xsa [file normalize [lindex $argv 0]]
set ws [file normalize [lindex $argv 1]]
if {![file isfile $xsa]} {error "XSA missing"}
if {[file exists $ws]} {error "Workspace already exists; use a new directory"}
if {[catch {
    file mkdir $ws
    setws $ws
    platform create -name pdm9 -hw $xsa -proc ps7_cortexa9_0 -os standalone -no-boot-bsp
    domain active standalone_domain
    bsp setlib -name lwip211 -ver 1.3
    bsp config api_mode RAW_API
    bsp config lwip_tcp false
    bsp config tcp_queue_ooseq 0
    bsp config lwip_udp true
    bsp config lwip_dhcp false
    platform generate
} error_message]} {
    puts "M9_PLATFORM_FAIL $error_message"
    puts $::errorInfo
    exit 1
}
puts "M9_PLATFORM_PASS XSA=$xsa workspace=$ws board_actions=NONE"
exit
