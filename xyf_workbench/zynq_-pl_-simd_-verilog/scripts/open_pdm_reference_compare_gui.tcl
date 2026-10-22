# Offline display only, no hardware connection or programming.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
foreach label {all_mics_current_take1 reference768_all_take1 reference768_pd_all_take1} {
  foreach suffix {pcm0 raw} {
    set filename ${label}_${suffix}.ila
    set data [read_hw_ila_data [file join $out $filename]]
    display_hw_ila_data $data
    puts "PDM_REFERENCE_COMPARE_DISPLAYED $filename"
  }
}
puts "PDM_REFERENCE_COMPARE_GUI_READY saved_data_only=1"
