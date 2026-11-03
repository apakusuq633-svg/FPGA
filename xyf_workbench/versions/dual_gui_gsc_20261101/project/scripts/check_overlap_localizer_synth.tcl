# Isolated candidate feasibility only. Does not modify a project or program a board.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out [file join $root build strict_overlap ooc]
file mkdir $out
set f [open [file join $out overlap_ooc.v] w]
puts $f {
module overlap_ooc(
 input clk,input rst_n,input enable,input valid,input[287:0] pcm,input[31:0] sample_id,
 input lut_we,input[16:0] lut_addr,input[8:0] lut_data,
 output busy,output done,output[31:0] window_id,first,latency,raw_drop,window_drop,
 output[9:0] best_grid,output signed[31:0] best_score
);
wire fs,fi,finv,fp,fseek,fdone,rw,ss,sbusy,sdone;
wire[31:0] fdata,fresult;wire[16:0] ra;wire[15:0] rd;
wire[9:0] pa;wire signed[31:0] pd;
rv32_overlap_localizer dut(
 .clk_i(clk),.rst_n_i(rst_n),.enable_i(enable),.valid_i(valid),.pcm_i(pcm),.sample_id_i(sample_id),
 .busy_o(busy),.done_o(done),.window_id_o(window_id),.first_o(first),.latency_o(latency),
 .raw_drop_o(raw_drop),.window_drop_o(window_drop),.best_grid_o(best_grid),.best_score_o(best_score),
 .fft_start_o(fs),.fft_io_o(fi),.fft_inv_o(finv),.fft_pop_o(fp),.fft_seek_o(fseek),.fft_data_o(fdata),
 .fft_done_i(fdone),.fft_result_i(fresult),.srp_r_we_o(rw),.srp_r_addr_o(ra),.srp_r_data_o(rd),
 .srp_start_o(ss),.srp_done_i(sdone),.srp_busy_i(sbusy),.srp_score_addr_o(pa),.srp_score_i(pd));
rv32_fft_bfly fft(.clk_i(clk),.rst_n_i(rst_n),.start_i(fs),.keep_i(1'b1),.commit_i(1'b1),
 .inv_i(finv),.is_io_i(fi),.io_sel_i(fp),.io_seek_i(fseek),.scalar_i(fdata),
 .stall_o(),.done_o(fdone),.result_o(fresult));
rv32_srp_scan #(.N_PAIR(66),.N_GRID(1024),.R_LEN(32),.IDX_W(5),.FRAC_W(4),
 .ADDR_W(17),.GRID_IDX_W(10),.FAST_SCAN(1)) srp(
 .clk_i(clk),.rst_n_i(rst_n),.en_i(1'b1),.start_i(ss),.busy_o(sbusy),.done_o(sdone),
 .lut_we_i(lut_we),.lut_addr_i(lut_addr),.lut_data_i(lut_data),.r_we_i(rw),.r_addr_i(ra),
 .r_data_i($signed(rd)),.p_addr_i(pa),.p_data_o(pd),.cycle_cnt_o());
endmodule
}
close $f
set sources [list rtl/array/rv32_overlap_localizer.v rtl/acoustic/rv32_fft_bfly.v \
 rtl/acoustic/rv32_fft_addr.v rtl/acoustic/rv32_acoustic_ext.v rtl/srp/rv32_srp_scan.v \
 [file join $out overlap_ooc.v]]
if {[catch {
 read_verilog $sources
 set_property include_dirs [list [file join $root rtl]] [current_fileset]
 synth_design -top overlap_ooc -part xc7z020clg400-1 -mode out_of_context
 create_clock -period 25.000 -name clk [get_ports clk]
 report_utilization -file [file join $out utilization_synth.rpt]
 opt_design
 place_design
 route_design
 report_utilization -file [file join $out utilization_routed.rpt]
 report_timing_summary -delay_type min_max -file [file join $out timing_routed.rpt]
 write_checkpoint -force [file join $out routed.dcp]
 set setup [get_timing_paths -delay_type max -max_paths 1]
 set hold [get_timing_paths -delay_type min -max_paths 1]
 if {[llength $setup] == 0 || [llength $hold] == 0} {error "Missing timing paths"}
 set wns [get_property SLACK $setup]
 set whs [get_property SLACK $hold]
 puts "OVERLAP_OOC_COMPLETE part=xc7z020clg400-1 period_ns=25 wns=$wns whs=$whs scope=ISOLATED_MODULE"
 if {$wns < 0 || $whs < 0} {error "OOC timing failed"}
 puts "OVERLAP_OOC_PASS"
} reason]} {
 puts "OVERLAP_OOC_FAIL $reason"
 exit 1
}
exit 0
