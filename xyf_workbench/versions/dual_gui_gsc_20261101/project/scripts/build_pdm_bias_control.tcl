set root [file normalize [file join [file dirname [info script]] ..]]
set base [file join $root build pdm_ila_20261021]
foreach mode {none up} {
  open_checkpoint [file join $base sync40 routed.dcp]
  set out [file join $base controlled_bias_$mode]
  file mkdir $out
  set data [get_ports {pdm_din_i[*]}]
  if {[llength $data] != 4} {error "Expected four DATA inputs"}
  foreach port $data {
    if {[get_property DIRECTION $port] ne "IN"} {error "DATA must remain input"}
  }
  foreach {name pin} {clk_50m U18 rst_n N16 pdm_clk_o V16 {pdm_din_i[0]} T14 {pdm_din_i[1]} Y17 {pdm_din_i[2]} W16 {pdm_din_i[3]} T15} {
    if {[get_property PACKAGE_PIN [get_ports $name]] ne $pin} {error "Pin mismatch: $name"}
    if {[get_property IOSTANDARD [get_ports $name]] ne "LVCMOS33"} {error "IO voltage mismatch"}
  }
  set_property PULLDOWN false $data
  set_property PULLUP [expr {$mode eq "up"}] $data
  set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
  report_io -file [file join $out io.rpt]
  write_debug_probes -force [file join $out pdm_ila.ltx]
  write_checkpoint -force [file join $out routed.dcp]
  write_bitstream -force [file join $out pdm_ila.bit]
  puts "PDM_CONTROLLED_BIAS_BUILD_PASS mode=$mode same_routed_base=sync40 DATA_inputs=4"
  close_design
}
exit
