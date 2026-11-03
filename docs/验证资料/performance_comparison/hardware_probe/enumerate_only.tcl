# Read-only cable/target enumeration. Never open a target, program, or reset.
set rc 0
open_hw_manager
if {[catch {connect_hw_server -url 127.0.0.1:3124} problem]} {
    puts "TIMING_PROBE_CONNECT_ERROR $problem"
    set rc 2
} else {
    set found [get_hw_targets -quiet]
    puts "TIMING_PROBE_TARGET_COUNT [llength $found]"
    foreach item $found { puts "TIMING_PROBE_TARGET $item" }
    disconnect_hw_server
}
close_hw_manager
puts "TIMING_PROBE_READ_ONLY_DONE no_open_target=1 no_programming=1 no_reset=1"
exit $rc
