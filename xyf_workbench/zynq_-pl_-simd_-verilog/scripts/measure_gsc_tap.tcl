# Optional pre-DMA stream block, separate from the PS top where unused ports prune.
set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] != 1} {error "Expected a fresh output directory"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Output already exists"}
file mkdir $out
cd $out
read_verilog [file join $root rtl array rv32_gsc_tap.v]
read_verilog [file join $root tb tb_gsc_registered_ooc.v]
synth_design -top tb_gsc_registered_ooc -flatten_hierarchy none -mode out_of_context -part xc7z020clg400-1
create_clock -name stream_clk -period 25 [get_ports clk_i]
# There are no external functional data inputs: every stream port is driven by
# an actual same-clock source FF. This avoids inventing board I/O arrival times.
set_output_delay 0 -clock stream_clk [get_ports -filter {DIRECTION == OUT}]
set_false_path -from [get_ports rst_n_i]
opt_design
place_design
route_design
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out hierarchy.rpt]
report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
write_checkpoint [file join $out gsc_tap.dcp]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
if {$wns < 0 || $whs < 0} {error "GSC tap OOC timing failed"}
puts "GSC_TAP_OOC_PASS WNS=$wns WHS=$whs clock_mhz=40"
