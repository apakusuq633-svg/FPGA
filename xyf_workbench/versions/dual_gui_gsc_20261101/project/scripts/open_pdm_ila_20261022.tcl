# Offline display of real on-board captures; no hardware programming.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
foreach filename {normal20_20261022_raw.ila normal20_20261022_pcm0.ila sync40_20261022_raw.ila sync40_20261022_pcm0.ila} {
  set data [read_hw_ila_data [file join $out $filename]]
  display_hw_ila_data $data
  puts "PDM_20261022_WAVEFORM_DISPLAYED $filename"
}
puts "PDM_20261022_GUI_READY saved_data_only=1"
