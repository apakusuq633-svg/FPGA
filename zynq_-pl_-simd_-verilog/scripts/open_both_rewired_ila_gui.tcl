set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
foreach filename {both_rewired_take1_pcm0.ila both_rewired_take1_raw.ila} {
  set data [read_hw_ila_data [file join $out $filename]]
  display_hw_ila_data $data
  puts "BOTH_REWIRED_ILA_DISPLAYED $filename"
}
puts "BOTH_REWIRED_ILA_GUI_READY saved_data_only=1"
