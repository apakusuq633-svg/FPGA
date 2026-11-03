# Only the current receiver defaults and the screenshot-matching PDM project.
# All files are saved board captures. No connection to the powered device.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_hw_manager
foreach filename {current_default_for_pdm_named_take1_pcm0.ila original_pdm_stock_take1_stock0.ila current_default_for_pdm_named_take1_raw.ila original_pdm_edge_named_take1_edge0.ila} {
  set data [read_hw_ila_data [file join $out $filename]]
  display_hw_ila_data $data
  puts "PDM_EXACT_COMPARISON_DISPLAYED $filename"
}
puts "PDM_EXACT_COMPARISON_GUI_READY only_current_and_PDM=1"
