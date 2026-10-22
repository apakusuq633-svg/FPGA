# Independent PS/PL top synthesis; full board implementation is a separate gate.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out [file join $root build das12]
file mkdir $out
if {[catch {
  read_verilog [glob [file join $root rtl * *.v]]
  synth_design -top rv32_ps_top -part xc7z020clg400-1 -mode out_of_context \
    -include_dirs [list [file join $root rtl]]
  create_clock -name clk -period 25 [get_ports clk_i]
  report_utilization -file [file join $out utilization_synth.rpt]
  write_checkpoint -force [file join $out ps_top_synth.dcp]
  puts "LIVE12_SYNTH_PASS channels=12 lines=6 pairs=66"
} reason]} {
  puts "LIVE12_SYNTH_FAIL reason=$reason"
  exit 1
}
exit 0
