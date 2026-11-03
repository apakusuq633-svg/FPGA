module rv32_branch_predictor (
  input         clk_i,
  input         rst_n_i,
  input         test_en_i,
  input  [31:0] fetch_pc_i,
  input  [31:0] fetch_imm_i,
  input         fetch_branch_i,
  input         fetch_jal_i,
  input         fetch_jalr_i,
  input         fetch_return_i,
  output        predict_taken_o,
  output [31:0] predict_target_o,
  output [5:0]  predict_pht_index_o,
  input         update_valid_i,
  input  [31:0] update_pc_i,
  input  [31:0] update_target_i,
  input  [5:0]  update_pht_index_i,
  input         update_taken_i,
  input         update_branch_i,
  input         update_call_i,
  input         update_return_i,
  input  [31:0] update_return_address_i
);

  wire btb_hit;
  wire [31:0] btb_target;
  wire pht_taken;
  wire ras_valid;
  wire [31:0] ras_target;
  wire branch_predict;
  wire jalr_predict;
  wire btb_update;
  wire pht_update;
  wire ras_push;
  wire ras_pop;
  wire [31:0] direct_target;

  assign direct_target  = fetch_pc_i + fetch_imm_i;
  assign branch_predict = fetch_branch_i & btb_hit & pht_taken;
  assign jalr_predict   = fetch_jalr_i &
                          ((fetch_return_i & ras_valid) |
                           (~fetch_return_i & btb_hit));
  assign predict_taken_o = fetch_jal_i | branch_predict | jalr_predict;
  assign predict_target_o = fetch_jal_i ? direct_target :
                            (fetch_return_i & ras_valid) ? ras_target :
                            btb_target;

  assign btb_update = update_valid_i & update_taken_i;
  assign pht_update = update_valid_i & update_branch_i;
  assign ras_push   = update_valid_i & update_call_i;
  assign ras_pop    = update_valid_i & update_return_i;

  rv32_btb u_btb (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .test_en_i       (test_en_i),
    .lookup_pc_i     (fetch_pc_i),
    .hit_o           (btb_hit),
    .target_o        (btb_target),
    .update_valid_i  (btb_update),
    .update_pc_i     (update_pc_i),
    .update_target_i (update_target_i)
  );

  rv32_pht_gshare u_pht (
    .clk_i            (clk_i),
    .rst_n_i          (rst_n_i),
    .test_en_i        (test_en_i),
    .lookup_pc_i      (fetch_pc_i),
    .lookup_index_o   (predict_pht_index_o),
    .predict_taken_o  (pht_taken),
    .update_valid_i   (pht_update),
    .update_index_i   (update_pht_index_i),
    .update_taken_i   (update_taken_i)
  );

  rv32_ras u_ras (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .test_en_i      (test_en_i),
    .push_i         (ras_push),
    .pop_i          (ras_pop),
    .push_address_i (update_return_address_i),
    .valid_o        (ras_valid),
    .top_address_o  (ras_target)
  );

endmodule
