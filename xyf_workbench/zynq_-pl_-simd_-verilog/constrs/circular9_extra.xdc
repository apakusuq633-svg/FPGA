# Fifth DATA: proposed J3.31/Y16, requires physical pin/VCCO validation.
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[4]}]
