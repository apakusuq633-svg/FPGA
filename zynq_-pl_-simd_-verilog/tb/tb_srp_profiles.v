`timescale 1ns/1ps
module tb_srp_profiles;
 rv32_soc current_production();
 rv32_soc #(.DAS_ACTIVE_CHANNELS(16)) production();
 rv32_soc #(.DAS_ACTIVE_CHANNELS(16),.LIVE16_LOCALIZATION(0)) fixed_debug();
 rv32_soc #(.DAS_ACTIVE_CHANNELS(4)) four();
 initial begin
  #1;
  if(current_production.DAS_ACTIVE_CHANNELS!=8 || current_production.PDM_CHANNELS!=8 ||
     current_production.PDM_MICS_PER_LINE!=2 || current_production.u_srp.N_PAIR!=28 ||
     current_production.u_srp.N_GRID!=1024 || current_production.u_steer.N_MIC!=8 ||
     $bits(current_production.pdm_din_i)!=4 || current_production.u_pdm_cap.WORDS!=4)
    $fatal(1,"production default must be eight microphones / four lines / 28 pairs");
  if(production.LIVE16_LOCALIZATION!=1 || production.u_srp.N_GRID!=1024 ||
     production.u_srp.N_PAIR!=120 || production.u_steer.GRID_W!=32)
    $fatal(1,"default sixteen microphone localization is not 120 pairs / 1024 cells");
  if(fixed_debug.LIVE16_LOCALIZATION!=0 || four.u_srp.N_GRID!=256)
    $fatal(1,"legacy diagnostic profile changed");
  $display("SRP_PROFILES_PASS default8=28x1024 legacy16=120x1024 four=4x256 fixed16=explicit_off");
  $finish;
 end
endmodule
