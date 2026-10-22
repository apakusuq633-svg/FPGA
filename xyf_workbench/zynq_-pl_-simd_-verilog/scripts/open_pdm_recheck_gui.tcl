# Show saved on-board captures only; leave the device and clock untouched.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
# Open PCM first so the raw CLK/DATA window is initially selected.
foreach filename {recheck_20261022_pcm0.ila recheck_20261022_pcm1.ila recheck_20261022_pcm2.ila recheck_20261022_raw.ila recheck_20261022_raw1.ila recheck_20261022_raw2.ila} {
  set data [read_hw_ila_data [file join $out $filename]]
  display_hw_ila_data $data
  puts "PDM_RECHECK_WAVEFORM_DISPLAYED $filename"
}
puts "PDM_RECHECK_GUI_READY saved_data_only=1"
