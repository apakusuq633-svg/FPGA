// M 扩展的除法器：恢复余数法，32 拍各出一位商，商和余数共用一条移位链。
//
// 一条除法指令占三态：IDLE（start 那拍锁存操作数）→ RUN（32 拍迭代）→ DONE（结果就绪）。
// stall_o 在 "IDLE 且 start" 和 RUN 上拉高、DONE 拍落下。落下由状态保证，不能写成
// "start | busy"：start 是电平不是脉冲，DONE 拍指令还在 ID/EX 里所以 start 仍为 1，
// 那样 stall 撤不掉，结果永远捕获不进 EX/MEM，FSM 还会重启。
//
// 操作数必须在 start 那拍锁进来。EX 的前递 mux 每拍重算、不锁存，而 MEM/WB 这个前递源
// 每条指令只存在一拍（rv_mem_wb_reg 没有 hold 端口）。32 拍里前递源逐个蒸发，
// 靠前递活着取操作数会从 ID/EX 的陈旧值上取到错的被除数，而且会真的提交。
//
// DONE 要等 commit_i 才回 IDLE。halt 冻结时若无条件回 IDLE，解除后指令仍在 ID/EX、
// start 仍成立，FSM 会拿已经蒸发的前递源重跑一遍并提交错误结果。
module rv32_div_unit (
  input         clk_i,
  input         rst_n_i,
  input         start_i,
  input         keep_i,
  input         commit_i,
  input         signed_i,
  input         is_rem_i,
  input  [31:0] dividend_i,
  input  [31:0] divisor_i,
  output        stall_o,
  output        done_o,
  output [31:0] result_o
);

  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_RUN  = 2'd1;
  localparam [1:0] ST_DONE = 2'd2;

  reg  [1:0]  state_q;
  reg  [4:0]  count_q;
  reg  [31:0] dividend_q;
  reg  [31:0] divisor_q;
  reg  [31:0] rem_q;
  reg  [31:0] quo_q;
  reg         quo_neg_q;
  reg         rem_neg_q;
  reg         div_zero_q;
  reg         rem_sel_q;

  wire [31:0] dividend_abs;
  wire [31:0] divisor_abs;
  wire [32:0] rem_shl;
  wire [33:0] rem_diff;
  wire        rem_ge;
  wire [31:0] rem_next;
  wire [31:0] quo_final;
  wire [31:0] rem_final;

  // 取绝对值。INT_MIN 取负回自己，这不是 bug —— 后面除以 1 得到的商再取负还是它，
  // 正好是规范要求的 INT_MIN / -1 = INT_MIN。
  assign dividend_abs = (signed_i & dividend_i[31]) ? -dividend_i : dividend_i;
  assign divisor_abs  = (signed_i & divisor_i[31])  ? -divisor_i  : divisor_i;

  // 够减判据要把两边都扩到 34 位：rem_shl 可以 >= 2^32，只扩到 33 位的话那一位会被
  // 当成借位，判据恒假。两个操作数最高位都是 0，所以差的最高位就是借位。
  assign rem_shl  = {rem_q, dividend_q[31]};
  assign rem_diff = {1'b0, rem_shl} - {2'b0, divisor_q};
  assign rem_ge   = ~rem_diff[33];
  assign rem_next = rem_ge ? rem_diff[31:0] : rem_shl[31:0];

  // 除零按规范返回全 1，不能走符号取反那条路（负被除数会得到 1）。
  // 余数不用为除零单开一条路：除数一次都没减成，32 拍后 rem_q 恰好是被除数的绝对值，
  // 再按被除数符号取反就还原成被除数本身。
  assign quo_final = div_zero_q ? 32'hffff_ffff : (quo_neg_q ? -quo_q : quo_q);
  assign rem_final = rem_neg_q ? -rem_q : rem_q;
  assign result_o  = rem_sel_q ? rem_final : quo_final;

  assign stall_o = ((state_q == ST_IDLE) & start_i) | (state_q == ST_RUN);
  assign done_o  = (state_q == ST_DONE);

  // 状态与计数是控制，异步复位；下面的移位链是数据，故意不带复位。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      state_q <= ST_IDLE;
      count_q <= 5'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start_i) begin
            state_q <= ST_RUN;
            count_q <= 5'd31;
          end
        end
        ST_RUN: begin
          // keep_i 落下说明这条除法指令刚被冲刷，整轮作废，别拖着流水线走完 32 拍。
          if (~keep_i)              state_q <= ST_IDLE;
          else if (count_q == 5'd0) state_q <= ST_DONE;
          else                      count_q <= count_q - 5'd1;
        end
        default: begin
          if (~keep_i | commit_i) state_q <= ST_IDLE;
        end
      endcase
    end
  end

  always @(posedge clk_i) begin
    if (state_q == ST_IDLE) begin
      if (start_i) begin
        dividend_q <= dividend_abs;
        divisor_q  <= divisor_abs;
        rem_q      <= 32'b0;
        quo_q      <= 32'b0;
        quo_neg_q  <= signed_i & (dividend_i[31] ^ divisor_i[31]);
        rem_neg_q  <= signed_i & dividend_i[31];
        div_zero_q <= (divisor_i == 32'b0);
        rem_sel_q  <= is_rem_i;
      end
    end else if (state_q == ST_RUN) begin
      rem_q      <= rem_next;
      quo_q      <= {quo_q[30:0], rem_ge};
      dividend_q <= {dividend_q[30:0], 1'b0};
    end
  end

endmodule
