# Offline comparison: only-U1 versus only-U2; never connects to hardware.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
foreach label {u2_removed_take1 u2_only_ambient_take1} {
  foreach suffix {raw raw1 raw2} {
    set filename ${label}_${suffix}.ila
    set data [read_hw_ila_data [file join $out $filename]]
    display_hw_ila_data $data
    puts "PDM_SINGLE_MIC_COMPARE_DISPLAYED $filename"
  }
}
puts "PDM_SINGLE_MIC_COMPARE_GUI_READY only_saved_data=1"
