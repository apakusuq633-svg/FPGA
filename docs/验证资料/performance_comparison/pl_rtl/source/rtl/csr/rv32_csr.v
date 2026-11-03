`include "rv32_defines.vh"

// 机器模式 CSR 堆 + Zicntr 计数器。仅支持 M 模式，故 mstatus.MPP 恒为 11。
// rdata_o 是纯组合读口，读地址由 EX 级给出：CSR 写在该级时钟沿提交，
// 紧随其后的 CSR 读正好在下一拍看到新值，无需前递。
module rv32_csr (
  input         clk_i,
  input         rst_n_i,
  input  [11:0] addr_i,
  output [31:0] rdata_o,
  input         we_i,
  input  [31:0] wdata_i,
  input         trap_i,
  input  [31:0] trap_pc_i,
  input  [3:0]  trap_cause_i,
  input  [31:0] trap_value_i,
  input         mret_i,
  input         retire_i,
  output [31:0] mtvec_o,
  output [31:0] mepc_o
);

  localparam [31:0] MSTATUS_RESET = 32'h0000_1800;  // MPP = 11
  localparam [31:0] MISA_VALUE    = 32'h4000_1100;  // MXL = 32, 扩展 I + M

  reg [31:0] mstatus;
  reg [31:0] mtvec;
  reg [31:0] mepc;
  reg [31:0] mcause;
  reg [31:0] mtval;
  reg [31:0] mie;
  reg [31:0] mscratch;
  reg [63:0] mcycle;
  reg [63:0] minstret;

  reg [31:0] rdata;
  wire [63:0] mcycle_inc;
  wire [63:0] minstret_inc;

  assign mcycle_inc   = mcycle + 64'd1;
  assign minstret_inc = minstret + 64'd1;

  // mstatus 只实现 MIE[3] / MPIE[7]，MPP[12:11] 恒 11，其余位读 0。
  // 分裂写 64 位计数器时另一半取 +1 后的值，低位向高位的进位在写高半字那一拍会丢，
  // 这是 mcycle/mcycleh 分开写固有的竞争，软件按低后高的顺序写即可。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      mstatus  <= MSTATUS_RESET;
      mtvec    <= 32'b0;
      mepc     <= 32'b0;
      mcause   <= 32'b0;
      mtval    <= 32'b0;
      mie      <= 32'b0;
      mscratch <= 32'b0;
      mcycle   <= 64'b0;
      minstret <= 64'b0;
    end else begin
      mcycle <= mcycle_inc;
      if (retire_i) begin
        minstret <= minstret_inc;
      end

      if (trap_i) begin
        mepc    <= trap_pc_i;
        mcause  <= {28'b0, trap_cause_i};
        mtval   <= trap_value_i;
        mstatus <= {19'b0, 2'b11, 3'b0, mstatus[3], 3'b0, 1'b0, 3'b0};
      end else if (mret_i) begin
        mstatus <= {19'b0, 2'b11, 3'b0, 1'b1, 3'b0, mstatus[7], 3'b0};
      end else if (we_i) begin
        case (addr_i)
          `CSR_MSTATUS:   mstatus  <= {19'b0, 2'b11, 3'b0, wdata_i[7], 3'b0, wdata_i[3], 3'b0};
          `CSR_MIE:       mie      <= wdata_i;
          `CSR_MTVEC:     mtvec    <= {wdata_i[31:2], 2'b00};
          `CSR_MSCRATCH:  mscratch <= wdata_i;
          `CSR_MEPC:      mepc     <= {wdata_i[31:2], 2'b00};
          `CSR_MCAUSE:    mcause   <= wdata_i;
          `CSR_MTVAL:     mtval    <= wdata_i;
          `CSR_MCYCLE:    mcycle   <= {mcycle_inc[63:32], wdata_i};
          `CSR_MCYCLEH:   mcycle   <= {wdata_i, mcycle_inc[31:0]};
          `CSR_MINSTRET:  minstret <= {minstret_inc[63:32], wdata_i};
          `CSR_MINSTRETH: minstret <= {wdata_i, minstret_inc[31:0]};
          default: ;
        endcase
      end
    end
  end

  // mip 恒 0：没有接任何中断源，中断永远不会被受理。
  // time/timeh 是 cycle/cycleh 的别名：没有 CLINT 提供真实时间基准。
  always @* begin
    case (addr_i)
      `CSR_MSTATUS:  rdata = mstatus;
      `CSR_MISA:     rdata = MISA_VALUE;
      `CSR_MIE:      rdata = mie;
      `CSR_MTVEC:    rdata = mtvec;
      `CSR_MSCRATCH: rdata = mscratch;
      `CSR_MEPC:     rdata = mepc;
      `CSR_MCAUSE:   rdata = mcause;
      `CSR_MTVAL:    rdata = mtval;
      `CSR_MIP:      rdata = 32'b0;
      `CSR_MCYCLE, `CSR_CYCLE, `CSR_TIME:
                     rdata = mcycle[31:0];
      `CSR_MCYCLEH, `CSR_CYCLEH, `CSR_TIMEH:
                     rdata = mcycle[63:32];
      `CSR_MINSTRET, `CSR_INSTRET:
                     rdata = minstret[31:0];
      `CSR_MINSTRETH, `CSR_INSTRETH:
                     rdata = minstret[63:32];
      default:       rdata = 32'b0;
    endcase
  end

  assign rdata_o = rdata;
  assign mtvec_o = mtvec;
  assign mepc_o  = mepc;

endmodule
