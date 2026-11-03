# Read-only connection probe. Does not reset or program any device.
if {[catch {connect -url TCP:127.0.0.1:3121} err]} {
    puts "BOARD_PROBE_NO_CONNECTION: $err"
    exit 1
}
set found [targets]
puts "BOARD_PROBE_TARGETS_BEGIN"
puts $found
puts "BOARD_PROBE_TARGETS_END"
disconnect
if {[string trim $found] eq ""} {
    puts "BOARD_PROBE_NO_TARGET"
    exit 2
}
puts "BOARD_PROBE_TARGET_PRESENT"
