// Cycle-driven SoC probes for long runs on Verilator 4.x (no timed SV required).
module tb_localizer12_safety(
 input[16:0]debug_addr,input op_block,mem_block, input clk,rst_n,halt,input valid,input[287:0]pcm,input[31:0]sample_id,
 input gsc_ready,output gsc_valid,output[511:0]gsc_data,output[31:0]gsc_overflow,gsc_errors,output[2:0]gsc_count,output gsc_pending,
 input steer_wr,input[6:0]steer_addr,input[31:0]steer_data,
 output direction_applied,output[31:0]direction_version,effective_sample,audio_seq,
 output[9:0]direction_grid,result_grid,output[31:0]direction_group_delay,result_score,
 input cw,input[8:0]ci,input[15:0]cd,input cfg_wr,input cfg_rd,input[6:0]cfg_addr,input[31:0]cfg_data,
 input srp_wr,input[6:0]srp_addr,input[31:0]srp_data,
 output enabled,done,output[31:0]recovery_epoch,recovery_fault_events,output[2:0]recovery_state,
 output[3:0]fault,output retire_valid,output[31:0]retire_instr,retire_pc,
 output[31:0]window_id,first,latency,compute_cycles,raw_drop,window_drop,
 output[31:0]active_first,output[3:0]channel,output[9:0]n,index,
 output[6:0]pair,output[4:0]transfer_state,output raw_check,prep_check,fft_check,phi_check,ring_check,score_check,
 output[15:0]raw_value,prepared_value,ring_value,output[31:0]fft_value,phi_value,score_value,
 output[16:0]ring_addr,output[9:0]score_addr,output[1919:0]statistics,
 output audio_push,output[31:0]audio_word,audio_drop,audio_max,output[8:0]audio_count,
 output fw_done,compute_wait,output[31:0]fw_error,
 output wr_active,output[2:0]wr_word,output[10:0]wr_sample,output[31:0]sample_count,
 output[13:0]raw_addr,output[1:0]raw_pass,output raw_use,output[31:0]raw_q,
 output mem_stall,fft_ready,ac_ready,output[31:0]request_id,output[2:0]request_kind,output srp_start,srp_busy,scan_start,ac_done,fft_done,output[15:0]debug_r,output[8:0]debug_lut,output[31:0]fft_data,ac_data
);
 rv32_soc #(.ITCM_FILE("build/localizer12_safety/fw/itcm.hex"),.DTCM_FILE("build/localizer12_safety/fw/dtcm.hex")) dut(
 .safety_op_block(op_block),.safety_mem_block(mem_block),.clk_i(clk),.rst_n_i(rst_n),.halt_i(halt),.test_en_i(1'b0),.fromhost_i(32'b0),
 .gsc_ready_i(gsc_ready),.gsc_valid_o(gsc_valid),.gsc_data_o(gsc_data),.gsc_overflow_o(gsc_overflow),.gsc_alignment_errors_o(gsc_errors),
 .test_pcm_i(pcm),.test_pcm_valid_i(valid),.test_sample_id_i(sample_id),
 .retire_fault_o(fault),.retire_valid_o(retire_valid),.retire_instr_o(retire_instr),.retire_pc_o(retire_pc),
 .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
 .tacho_i(1'b0),.pdm_din_i(6'b0),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),
 .coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
 .pdm_cfg_wr_i(cfg_wr),.pdm_cfg_rd_i(cfg_rd),.pdm_cfg_addr_i(cfg_addr),.pdm_cfg_wdata_i(cfg_data),
 .srp_cfg_wr_i(srp_wr),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(srp_addr),.srp_cfg_wdata_i(srp_data),
 .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
 .steer_cfg_wr_i(steer_wr),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(steer_addr),.steer_cfg_wdata_i(steer_data));
 assign enabled=dut.localizer_enable;
 assign done=dut.loc_done;assign window_id=dut.loc_window;assign first=dut.loc_first;
 assign latency=dut.loc_latency;assign compute_cycles=dut.loc_compute_cycles;
 assign raw_drop=dut.loc_raw_drop;assign window_drop=dut.loc_window_drop;
 assign active_first=dut.g_localizer.u_transfer.active_first;
 assign channel=dut.g_localizer.u_transfer.channel;assign n=dut.g_localizer.u_transfer.n;
 assign index=dut.g_localizer.u_transfer.index;assign pair=dut.g_localizer.u_transfer.pair;
 assign transfer_state=dut.g_localizer.u_transfer.state;
 assign raw_check=dut.g_localizer.u_transfer.state==2&&dut.g_localizer.u_transfer.pass==0;
 assign prep_check=dut.g_localizer.u_transfer.state==2&&dut.g_localizer.u_transfer.pass==2;
 assign raw_value=dut.g_localizer.u_transfer.sample;assign prepared_value=dut.g_localizer.u_transfer.window_sample;
 assign fft_check=dut.u_core.u_fft_bfly.io_fire&&dut.u_core.u_fft_bfly.io_sel_i&&!dut.u_core.u_fft_bfly.io_seek_i&&!dut.u_core.u_fft_bfly.inv_i;
 assign fft_value=dut.loc_fft_result;
 // A ready port is not an accepted transfer: loss_now suppresses ac_start
 // before sticky window_drop becomes visible on the following clock.
 assign phi_check=dut.g_localizer.u_transfer.state==15&&dut.loc_ac_start&&dut.loc_ac_ready;
 assign phi_value=dut.loc_ac_result;
 assign ring_check=dut.loc_r_we;assign ring_addr=dut.loc_r_addr;assign ring_value=dut.loc_r_data;
 assign score_check=dut.g_localizer.u_transfer.state==27;assign score_addr=dut.loc_score_addr;assign score_value=dut.loc_srp_score;
 genvar k;generate for(k=0;k<60;k=k+1)begin:g_stats
 assign statistics[k*32+:32]=dut.g_localizer.u_transfer.statistics[k];
 end endgenerate
 assign audio_push=dut.u_beam.push;assign audio_word={dut.beam_fir_result,dut.u_beam.das_q};
 assign audio_count=dut.u_beam.count;assign audio_drop=dut.u_beam.drop_q;assign audio_max=dut.u_beam.max_ticks;
 assign fw_done=dut.tohost_q==32'h4c4f4302;assign fw_error=dut.u_dtcm.memory['ha03];
 assign compute_wait=dut.u_core.fft_hw_stall||dut.u_core.ac_hw_stall;
assign wr_active=dut.g_localizer.u_transfer.wr_active;
 assign wr_word=dut.g_localizer.u_transfer.wr_word;assign wr_sample=dut.g_localizer.u_transfer.wr_sample;
 assign sample_count=dut.g_localizer.u_transfer.sample_count;
 assign raw_addr=dut.g_localizer.u_transfer.raw_addr;assign raw_pass=dut.g_localizer.u_transfer.pass;
 assign raw_use=dut.g_localizer.u_transfer.state==2;assign raw_q=dut.g_localizer.u_transfer.raw_q;
 assign mem_stall=dut.u_core.memory_stall;assign fft_ready=dut.loc_fft_ready;assign ac_ready=dut.loc_ac_ready;
 assign recovery_epoch=dut.recovery_epoch;assign recovery_fault_events=dut.fault_events;assign recovery_state=dut.recovery_state;
 assign gsc_count=dut.g_gsc.u_tap.count;assign gsc_pending=dut.g_gsc.u_tap.pending;
 assign direction_applied=dut.direction_applied;assign direction_version=dut.applied_version;
 assign effective_sample=dut.effective_sample;assign audio_seq=dut.audio_sample_seq;
 assign direction_grid=dut.applied_direction_id;assign direction_group_delay=dut.group_delay;
 assign result_grid=dut.loc_grid;assign result_score=dut.loc_score;
 assign request_id=dut.loc_request_id;assign request_kind=dut.loc_request;
assign srp_start=dut.core_srp_start;assign srp_busy=dut.srp_busy;assign scan_start=dut.u_srp.scan_start;
 assign ac_done=dut.loc_ac_done;assign fft_done=dut.loc_fft_done;
assign debug_r=dut.u_srp.u_scan.r_mem[debug_addr];assign debug_lut=dut.u_srp.u_scan.lut_mem[debug_addr];
assign fft_data=dut.loc_fft_data;assign ac_data=dut.loc_ac_data;
endmodule
