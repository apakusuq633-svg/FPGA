# Inspect saved on-board data without enabling the external microphone clock.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_project [file join $out project pdm_ila.xpr]
open_hw_manager
foreach filename {qualified_raw.ila qualified_pcm0.ila late175_raw.ila late175_pcm0.ila} {
  set d [read_hw_ila_data [file join $out $filename]]
  display_hw_ila_data $d
  puts "PDM_SAVED_WAVEFORM_DISPLAYED $filename"
}
puts "PDM_ILA_GUI_READY saved_data_only=1"
