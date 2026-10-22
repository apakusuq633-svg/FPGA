// Cycle-driven SoC probes for long runs on Verilator 4.x (no timed SV required).
module tb_localizer12_verilator(
 input clk,rst_n,halt,input valid,input[287:0]pcm,input[31:0]sample_id,
 input cw,input[8:0]ci,input[15:0]cd,input cfg_wr,input cfg_rd,input[6:0]cfg_addr,input[31:0]cfg_data,
 input srp_wr,input[6:0]srp_addr,input[31:0]srp_data,
 output enabled,done,output[3:0]fault,output retire_valid,output[31:0]retire_instr,retire_pc,
 output[31:0]window_id,first,latency,compute_cycles,raw_drop,window_drop,
 output[31:0]active_first,output[3:0]channel,output[9:0]n,index,
 output[6:0]pair,output[4:0]transfer_state,output raw_check,prep_check,fft_check,phi_check,ring_check,score_check,
 output[15:0]raw_value,prepared_value,ring_value,output[31:0]fft_value,phi_value,score_value,
 output[16:0]ring_addr,output[9:0]score_addr,output[1919:0]statistics,
 output audio_push,output[31:0]audio_word,audio_drop,audio_max,output[8:0]audio_count,
 output fw_done,compute_wait,output[31:0]fw_error
);
 rv32_soc #(.ITCM_FILE("build/localizer12/fw/itcm.hex"),.DTCM_FILE("build/localizer12/fw/dtcm.hex")) dut(
 .clk_i(clk),.rst_n_i(rst_n),.halt_i(halt),.test_en_i(1'b0),.fromhost_i(32'b0),
 .test_pcm_i(pcm),.test_pcm_valid_i(valid),.test_sample_id_i(sample_id),
 .retire_fault_o(fault),.retire_valid_o(retire_valid),.retire_instr_o(retire_instr),.retire_pc_o(retire_pc),
 .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
 .tacho_i(1'b0),.pdm_din_i(6'b0),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),
 .coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
 .pdm_cfg_wr_i(cfg_wr),.pdm_cfg_rd_i(cfg_rd),.pdm_cfg_addr_i(cfg_addr),.pdm_cfg_wdata_i(cfg_data),
 .srp_cfg_wr_i(srp_wr),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(srp_addr),.srp_cfg_wdata_i(srp_data),
 .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
 .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
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
 assign phi_check=dut.g_localizer.u_transfer.state==15&&dut.loc_ac_ready;
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
endmodule
