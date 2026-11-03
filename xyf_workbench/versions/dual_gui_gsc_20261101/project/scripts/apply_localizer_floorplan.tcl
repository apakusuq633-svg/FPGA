# Post-opt hook: neighboring regions, with placement escape allowed for congestion.
if {![info exists ::env(LOCALIZER_FLOORPLAN)] || $::env(LOCALIZER_FLOORPLAN) ne "1"} {return}
foreach region {X0Y0 X0Y2 X1Y0 X1Y2} {
    if {[llength [get_clock_regions -quiet $region]] != 1} {error "Missing localizer region $region"}
}
set srp_cells [get_cells -hier -quiet -filter {IS_PRIMITIVE && NAME =~ */u_soc/u_srp/*}]
set data_cells [get_cells -hier -quiet -filter {IS_PRIMITIVE && (NAME =~ */u_soc/g_localizer* || NAME =~ */u_soc/u_core/u_fft_bfly/* || NAME =~ */u_soc/u_core/u_acoustic_ext/*)}]
if {[llength $srp_cells]==0 || [llength $data_cells]==0} {error "Localizer floorplan hierarchy missing"}
foreach {group cells region} [list loc_srp $srp_cells CLOCKREGION_X0Y0:CLOCKREGION_X0Y2 loc_data $data_cells CLOCKREGION_X1Y0:CLOCKREGION_X1Y2] {
    create_pblock $group
    resize_pblock [get_pblocks $group] -add $region
    add_cells_to_pblock [get_pblocks $group] $cells
    set_property IS_SOFT true [get_pblocks $group]
    puts "LOCALIZER_FLOORPLAN group=$group cells=[llength $cells] region=$region soft=1"
}
