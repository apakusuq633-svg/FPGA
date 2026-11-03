// SRP-PHAT 空间扫描 —— README §23 / §24 / §25。
//
//     P(r) = Σ_{i<j} R_ij( τ_ij(r) )
//
// τ_ij(r) 是浮点样点延迟，拆成整数下标 idx + 小数权重 frac，查表时线性插值：
//
//     P(r) += R_ij[idx] + frac · (R_ij[idx+1] − R_ij[idx])
//
// ── ⚠ 这个模块**不是** SIMD-MAC 的落点，别把它改成那样 ──────────────────
// README §25 画的是「SIMD LOAD → 并行累加 → 归约树」，隐含假设 28 对的
// R_ij[delay] 能一次并行取出来。**实际不能**：每个网格点的 28 个延迟各不相同，
// 这是一次 **gather（查表）**，地址逐 lane 不同，规整阵列帮不上忙。
//
// docs/issues/028 的占比属于历史负载；当前比例由整机周期观察器重新测量。
// 连续 FIR 使用 SIMD-MAC，SRP 保留独立查表内核。
//
//   ⚠ 线性插值不是可选项：实测无插值时定位误差劣化 **3.65×**
//     （0.57 → 2.08 cm），见 scripts/golden/fixed_model.py。
//
// ── 每格 4 拍，末尾另留 1 拍提交同步 RAM 写入 ──────────────────────────
//   稳定期的组合读：lut_r ← LUT[pair*N_GRID+grid]     （地址在整个处理期不变）
//                   p_rd_q ← P[grid]                  （同上）
//                   r_q ← R[sel], sel = (T1 ? idx : idx+1)
//
//   S_T0  等 lut_r 稳定
//   S_T1  lut_r 有效 → 锁 idx_q/frac_q；本拍末 R 读发 idx
//   S_T2  r_q=R[idx] → v0_q；p_rd_q=P[grid] → old_p；本拍末 R 读发 idx+1
//   S_T3  r_q=R[idx+1] 与 v0_q 齐 → 插值 → 登记写入并推进格/对
//   下一格 S_T0 同时提交上一格写入；S_NEXT 仅在最后一格提交后发布 done
//
//   扫描主体：1024 格 × 28 对 × 4 拍 + 1 = 114,689 拍；启动/接口另计。
//
// ── 存储 ────────────────────────────────────────────────────────────────
//   LUT  idx+frac 打包  N_PAIR*N_GRID*(IDX_W+FRAC_W) bit
//   R    N_PAIR*R_LEN*DW bit；相关环独立于搜索网格大小
//   P    累加器 1024 × 32 bit           =  4 KB
// 共享DIN的8麦配置使用28对、1024格、32点相关环。
module rv32_srp_scan #(
  parameter integer N_PAIR = 28,
  parameter integer N_GRID = 1024,
  // ── R 的行长，**默认 = N_GRID（原行为逐位不变）** ────────────────────────
  // ⚠ 它必须单独成为一个参数，不能跟着 N_GRID 走：LUT 是**每格点**一条
  //   （N_GRID 条），而 R 是**整条相关序列**（1024 点 = NFFT 条），两者长度
  //   本来就可以不同。τ 绕回之后 idx 能取到 1000 以上（负延迟绕到序列尾部），
  //   若 R 行只有 N_GRID=256 深，`pair*256 + 1013` 会落到**下一对的 R 行**里
  //   —— 读到的值全都合法、也不报错，只是每一格都算错。
  //   （固件那侧一直是 `idx & 1023` 配 1024 长的 R，见 fw_srp.c:126-127。）
  parameter integer R_LEN  = N_GRID,
  parameter integer IDX_W  = 10,
  parameter integer FRAC_W = 4,
  parameter integer ADDR_W = 15,
  parameter integer GRID_IDX_W = $clog2(N_GRID),
  parameter integer DW     = 16,
  // 0: four cycles/grid/pair; 1: one grid/cycle/pair;
  // 4: four independent pair banks, one grid/cycle per four-pair group.
  parameter integer FAST_SCAN = 0
) (
  input                     clk_i,
  input                     rst_n_i,
  input                     en_i,
  input                     start_i,
  output reg                busy_o,
  output reg                done_o,
  // LUT 装载（PC 侧生成，见 scripts/golden/gen_delay_lut.py）
  input                     lut_we_i,
  input  [ADDR_W-1:0]             lut_addr_i,   // pair*N_GRID + grid
  input  [IDX_W+FRAC_W-1:0] lut_data_i,   // {idx, frac}
  // R 写入（来自 IFFT；逐对写满 1024 点再让扫描进到该对）
  input                     r_we_i,
  input  [ADDR_W-1:0]             r_addr_i,      // pair*N_GRID + grid
  input  signed [DW-1:0]    r_data_i,
  // 累加器外部读出
  input  [GRID_IDX_W-1:0]   p_addr_i,
  output signed [31:0]      p_data_o,
  output reg [31:0]         cycle_cnt_o
);

  localparam integer LUT_W = IDX_W + FRAC_W;
  // The correlation ring, not the grid or the LUT transport width, owns wrap.
  // In particular DECIM=16 uses R_LEN=64 (signed lags -32..31), while legacy
  // profiles use R_LEN=32.  Q4 delay -1/16 addresses R[63] and R[0] in a
  // 64-entry ring. Keeping the increment at R_IDX_W prevents pair-row aliasing.
  localparam integer R_IDX_W = $clog2(R_LEN);

  // synthesis translate_off
  initial begin
    if (R_LEN < 2 || (R_LEN & (R_LEN-1)) != 0)
      $fatal(1, "SRP R_LEN must be a power of two >= 2");
    if (IDX_W < R_IDX_W)
      $fatal(1, "SRP IDX_W cannot represent R_LEN");
    if (N_PAIR*N_GRID > (64'd1 << ADDR_W) || N_PAIR*R_LEN > (64'd1 << ADDR_W))
      $fatal(1, "SRP ADDR_W cannot represent LUT/R memory");
  end
  // synthesis translate_on

  // ── 状态寄存器（全部先声明，下面的 always 要用）────────────────────────
  reg [2:0]           st_q;
  reg [$clog2(N_PAIR)-1:0] pair_q;
  reg [GRID_IDX_W-1:0] grid_q;
  reg [R_IDX_W-1:0]   idx_q;
  reg [FRAC_W-1:0]    frac_q;
  reg signed [DW-1:0] v0_q;
  reg signed [31:0]   old_p_q;
  reg                 p_we;
  reg [GRID_IDX_W-1:0] p_waddr;
  reg signed [31:0]   p_wdata;

  // ── 存储 ──────────────────────────────────────────────────────────────
  (* ram_style="block" *) reg [LUT_W-1:0] lut_mem [0:N_PAIR*N_GRID-1];
  (* ram_style="block" *) reg signed [DW-1:0] r_mem [0:N_PAIR*R_LEN-1];
  (* ram_style="block" *) reg signed [31:0] p_mem [0:N_GRID-1];

  reg [LUT_W-1:0]     lut_r;
  reg signed [DW-1:0] r_q;
  reg signed [31:0]   p_rd_q;      // 扫描用的 P 读口
  reg                result_valid_q;

  localparam [2:0] S_IDLE = 3'd0, S_T0 = 3'd1, S_T1 = 3'd2,
                   S_T2   = 3'd3, S_T3 = 3'd4, S_NEXT = 3'd5;

  // 稳定期组合量（pair_q/grid_q 在整个处理期不变）
  wire [R_IDX_W-1:0]  idx_c  = lut_r[FRAC_W +: R_IDX_W];
  wire [FRAC_W-1:0]   frac_c = lut_r[FRAC_W-1:0];
  // R 的读地址：T1 用本次的 idx，T2 用 idx+1。**必须在发读的那一拍就选对**，
  // 因为同步 BRAM 的数据要到下一拍才有效。
  wire [R_IDX_W-1:0]  r_sel  = (st_q == S_T1) ? idx_c : (idx_q + 1'b1);

  wire signed [DW:0]  diff_w  = r_q - v0_q;
  wire signed [31:0]  interp_w = $signed(v0_q) +
                                 ((diff_w * $signed({1'b0, frac_q})) >>> FRAC_W);

  integer g;

  // LUT 读改写：写口只在装载期用；读口地址在扫描期稳定
  always @(posedge clk_i) begin
    if (FAST_SCAN != 4) begin
    if (lut_we_i && !busy_o && lut_addr_i < N_PAIR*N_GRID) lut_mem[lut_addr_i] <= lut_data_i;
    lut_r <= lut_mem[pair_q * N_GRID + grid_q];
    end
  end

  // A single writer; pair zero supplies the logical clear without resetting RAM.
  always @(posedge clk_i) begin
    if (p_we && rst_n_i && en_i) p_mem[p_waddr] <= p_wdata;
  end

  assign p_data_o = result_valid_q && !busy_o ? p_rd_q : 32'sd0;

  generate if(FAST_SCAN == 4)begin:g_parallel4
  localparam integer GROUPS=(N_PAIR+3)/4;
  localparam integer GROUP_W=GROUPS>1?$clog2(GROUPS):1;
  reg [GROUP_W-1:0] group_q,group0,group1;
  reg [7:0] valid_q;
  reg pause_q,last_group_q;
  reg [GRID_IDX_W-1:0] g0,g1,g2,g3,g4,g5,g6,g7;
  reg z0,z1,z2,z3,z4,z5,z6,z7;
  reg signed [31:0] old3,old4,old5,old6,old7;
  reg signed [31:0] sum01_6,sum23_6,sum7;
  wire signed [31:0] interpolated5 [0:3];
  wire issue=busy_o&&!pause_q;
  genvar lane;
  for(lane=0;lane<4;lane=lane+1)begin:g_lane
    // Adjacent microphone pairs occupy distinct physical banks. This gives
    // four LUT reads and eight correlation reads without replicating memories.
    (* ram_style="block" *) reg [LUT_W-1:0] lut_bank [0:GROUPS*N_GRID-1];
    (* ram_style="block" *) reg signed [DW-1:0] r_bank [0:GROUPS*R_LEN-1];
    reg [LUT_W-1:0] lut_r4,lut_q4;
    reg [FRAC_W-1:0] f2,f3,f4;
    reg signed [DW-1:0] r0,r1,v0,v1,base4;
    reg signed [DW:0] diff4;
    reg signed [31:0] interp5;
    reg active2,active3,active4;
    wire [R_IDX_W-1:0] index0=lut_q4[FRAC_W +: R_IDX_W];
    wire [R_IDX_W-1:0] index1=index0+1'b1;
    wire [ADDR_W-1:0] ra0=group1*R_LEN+index0;
    wire [ADDR_W-1:0] ra1=group1*R_LEN+index1;
    wire load_lut=lut_we_i&&!busy_o&&lut_addr_i<N_PAIR*N_GRID&&
                  ((lut_addr_i/N_GRID)%4)==lane;
    wire load_r=r_we_i&&!busy_o&&r_addr_i<N_PAIR*R_LEN&&
                ((r_addr_i/R_LEN)%4)==lane;
    wire [ADDR_W-1:0] la=(lut_addr_i/(4*N_GRID))*N_GRID+lut_addr_i%N_GRID;
    wire [ADDR_W-1:0] wa=(r_addr_i/(4*R_LEN))*R_LEN+r_addr_i%R_LEN;
    assign interpolated5[lane]=interp5;
    always @(posedge clk_i)begin
      if(load_lut)lut_bank[la]<=lut_data_i;
      lut_r4<=lut_bank[group_q*N_GRID+grid_q];
      lut_q4<=lut_r4;
      // One write/read port plus one read port per R bank, compatible with
      // true dual-port BRAM. The write port is used only while the scan idles.
      if(load_r)r_bank[wa]<=r_data_i;
      r0<=r_bank[load_r?wa:ra0];
      r1<=r_bank[ra1];
      v0<=r0;v1<=r1;
      f2<=lut_q4[FRAC_W-1:0];f3<=f2;f4<=f3;
      active2<=group1*4+lane<N_PAIR;active3<=active2;active4<=active3;
      base4<=v0;diff4<=$signed(v1)-$signed(v0);
      // Round each pair before the reduction, exactly as the serial scanner.
      interp5<=active4?($signed(base4)+((diff4*$signed({1'b0,f4}))>>>FRAC_W)):32'sd0;
    end
  end
  always @(posedge clk_i)begin
    p_rd_q<=p_mem[busy_o?g1:p_addr_i];
  end
  // Synchronous reset keeps all locally generated BRAM addresses/enables
  // synchronous as well; an asynchronous control edge can corrupt RAM access.
  always @(posedge clk_i)begin
    if(!rst_n_i)begin
      st_q<=S_IDLE;busy_o<=0;done_o<=0;pair_q<=0;grid_q<=0;
      p_we<=0;p_waddr<=0;p_wdata<=0;cycle_cnt_o<=0;result_valid_q<=0;
      idx_q<=0;frac_q<=0;v0_q<=0;old_p_q<=0;
      group_q<=0;group0<=0;group1<=0;valid_q<=0;pause_q<=0;last_group_q<=0;
      g0<=0;g1<=0;g2<=0;g3<=0;g4<=0;g5<=0;g6<=0;g7<=0;
      z0<=0;z1<=0;z2<=0;z3<=0;z4<=0;z5<=0;z6<=0;z7<=0;
      old3<=0;old4<=0;old5<=0;old6<=0;old7<=0;
      sum01_6<=0;sum23_6<=0;sum7<=0;
    end else if(!en_i)begin
      st_q<=S_IDLE;busy_o<=0;done_o<=0;p_we<=0;result_valid_q<=0;
      valid_q<=0;pause_q<=0;last_group_q<=0;
    end else begin
      done_o<=0;p_we<=valid_q[7];cycle_cnt_o<=cycle_cnt_o+1;
      valid_q<={valid_q[6:0],issue};
      group0<=group_q;group1<=group0;
      g0<=grid_q;g1<=g0;g2<=g1;g3<=g2;g4<=g3;g5<=g4;g6<=g5;g7<=g6;
      z0<=group_q==0;z1<=z0;z2<=z1;z3<=z2;z4<=z3;z5<=z4;z6<=z5;z7<=z6;
      old3<=p_rd_q;old4<=old3;old5<=old4;old6<=old5;old7<=old6;
      sum01_6<=interpolated5[0]+interpolated5[1];
      sum23_6<=interpolated5[2]+interpolated5[3];
      sum7<=sum01_6+sum23_6;
      p_waddr<=g7;p_wdata<=(z7?32'sd0:old7)+sum7;
      if(!busy_o&&start_i)begin
        busy_o<=1;group_q<=0;grid_q<=0;pause_q<=0;last_group_q<=0;
        valid_q<=0;p_we<=0;result_valid_q<=0;st_q<=S_T0;
      end
      if(issue)begin
        if(grid_q==N_GRID-1)begin
          pause_q<=1;last_group_q<=group_q==GROUPS-1;
        end else grid_q<=grid_q+1'b1;
      end
      // Drain all writes before the next group reads the same P addresses.
      if(busy_o&&pause_q&&valid_q==0&&!p_we)begin
        if(last_group_q)begin busy_o<=0;done_o<=1;result_valid_q<=1;st_q<=S_IDLE;end
        else begin group_q<=group_q+1'b1;grid_q<=0;pause_q<=0;end
      end
    end
  end
  end else if(FAST_SCAN)begin:g_fast
  reg [5:0] valid_q;
  reg pause_q,last_pair_q;
  reg [LUT_W-1:0] lut_q;
  reg [$clog2(N_PAIR)-1:0] pair0,pair1;
  reg [GRID_IDX_W-1:0] g0,g1,g2,g3,g4,g5;
  reg z0,z1,z2,z3,z4,z5;
  reg [FRAC_W-1:0] f2,f3,f4;
  reg signed [DW-1:0] r0,r1,v0,v1,base4;
  reg signed [DW:0] diff4;
  reg signed [31:0] old3,old4,old5,interpolated5;
  wire issue=busy_o&&!pause_q;
  wire [R_IDX_W-1:0] ring_idx=lut_q[FRAC_W +: R_IDX_W];
  wire [R_IDX_W-1:0] next_idx=ring_idx+1'b1;
  wire [ADDR_W-1:0] ra0=pair1*R_LEN+ring_idx;
  wire [ADDR_W-1:0] ra1=pair1*R_LEN+next_idx;
  // Two physical BRAM ports; loading and scanning never overlap.
  always @(posedge clk_i)begin
    if(r_we_i&&!busy_o&&r_addr_i<N_PAIR*R_LEN)r_mem[r_addr_i]<=r_data_i;
    r0<=r_mem[r_we_i&&!busy_o?r_addr_i:ra0];
    r1<=r_mem[ra1];
    v0<=r0;v1<=r1;
    lut_q<=lut_r;
    p_rd_q<=p_mem[busy_o?g1:p_addr_i];
  end
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)begin
      st_q<=S_IDLE;busy_o<=0;done_o<=0;pair_q<=0;grid_q<=0;
      p_we<=0;p_waddr<=0;p_wdata<=0;cycle_cnt_o<=0;result_valid_q<=0;
      idx_q<=0;frac_q<=0;v0_q<=0;old_p_q<=0;
      valid_q<=0;pause_q<=0;last_pair_q<=0;
      pair0<=0;pair1<=0;g0<=0;g1<=0;g2<=0;g3<=0;g4<=0;g5<=0;
      z0<=0;z1<=0;z2<=0;z3<=0;z4<=0;z5<=0;
      f2<=0;f3<=0;f4<=0;old3<=0;old4<=0;old5<=0;
      base4<=0;diff4<=0;interpolated5<=0;
    end else if(!en_i)begin
      st_q<=S_IDLE;busy_o<=0;done_o<=0;p_we<=0;result_valid_q<=0;
      valid_q<=0;pause_q<=0;last_pair_q<=0;
    end else begin
      done_o<=0;p_we<=valid_q[5];cycle_cnt_o<=cycle_cnt_o+1;
      valid_q<={valid_q[4:0],issue};
      pair0<=pair_q;pair1<=pair0;
      g0<=grid_q;g1<=g0;g2<=g1;g3<=g2;g4<=g3;g5<=g4;
      z0<=pair_q==0;z1<=z0;z2<=z1;z3<=z2;z4<=z3;z5<=z4;
      f2<=lut_q[FRAC_W-1:0];f3<=f2;f4<=f3;
      old3<=p_rd_q;old4<=old3;old5<=old4;
      base4<=v0;diff4<=$signed(v1)-$signed(v0);
      interpolated5<=$signed(base4)+((diff4*$signed({1'b0,f4}))>>>FRAC_W);
      p_waddr<=g5;p_wdata<=(z5?32'sd0:old5)+interpolated5;
      if(!busy_o&&start_i)begin
        busy_o<=1;pair_q<=0;grid_q<=0;pause_q<=0;last_pair_q<=0;
        valid_q<=0;p_we<=0;result_valid_q<=0;st_q<=S_T0;
      end
      if(issue)begin
        if(grid_q==N_GRID-1)begin
          pause_q<=1;last_pair_q<=pair_q==N_PAIR-1;
        end else grid_q<=grid_q+1'b1;
      end
      // Drain before changing pairs: no same-grid read/write collision, even N_GRID=1.
      if(busy_o&&pause_q&&valid_q==0&&!p_we)begin
        if(last_pair_q)begin busy_o<=0;done_o<=1;result_valid_q<=1;st_q<=S_IDLE;end
        else begin pair_q<=pair_q+1'b1;grid_q<=0;pause_q<=0;end
      end
    end
  end
  end else begin:g_serial
  always @(posedge clk_i)begin
    if(r_we_i&&!busy_o&&r_addr_i<N_PAIR*R_LEN)r_mem[r_addr_i]<=r_data_i;
    r_q<=r_mem[pair_q*R_LEN+r_sel];
    p_rd_q<=p_we&&p_waddr==(busy_o?grid_q:p_addr_i)?p_wdata:p_mem[busy_o?grid_q:p_addr_i];
  end
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      st_q <= S_IDLE; busy_o <= 1'b0; done_o <= 1'b0;
      pair_q <= 0; grid_q <= {GRID_IDX_W{1'b0}};
      idx_q <= {R_IDX_W{1'b0}}; frac_q <= {FRAC_W{1'b0}}; v0_q <= {DW{1'b0}};
      old_p_q <= 32'sd0; p_we <= 1'b0; p_waddr <= {GRID_IDX_W{1'b0}};
      p_wdata <= 32'sd0; cycle_cnt_o <= 32'd0;
      result_valid_q <= 1'b0;
    end else if (!en_i) begin
      st_q <= S_IDLE; busy_o <= 1'b0; done_o <= 1'b0; p_we <= 1'b0;
      result_valid_q <= 1'b0;
    end else begin
      done_o <= 1'b0;
      p_we   <= 1'b0;
      cycle_cnt_o <= cycle_cnt_o + 1'b1;

      case (st_q)
        S_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            busy_o <= 1'b1;
            pair_q <= 0;
            grid_q <= {GRID_IDX_W{1'b0}};
            result_valid_q <= 1'b0;
            st_q   <= S_T0;
          end
        end

        // T0：lut_r / p_rd_q 在这拍末稳定
        S_T0: st_q <= S_T1;

        // T1：lut_r 有效；本拍末 R 读发 idx
        S_T1: begin
          idx_q  <= idx_c;
          frac_q <= frac_c;
          st_q   <= S_T2;
        end

        // T2：r_q = R[idx]；p_rd_q = P[grid]；本拍末 R 读发 idx+1
        S_T2: begin
          v0_q    <= r_q;
          old_p_q <= pair_q == 0 ? 32'sd0 : p_rd_q;
          st_q    <= S_T3;
        end

        // T3：r_q = R[idx+1]，与 v0_q 齐 → 插值 → 回写
        S_T3: begin
          p_we    <= 1'b1;
          p_waddr <= grid_q;
          p_wdata <= old_p_q + interp_w;
          // Drain the registered write during the next grid's T0.
          if (grid_q == N_GRID - 1) begin
            if (pair_q == N_PAIR - 1) st_q <= S_NEXT;
            else begin
              grid_q <= {GRID_IDX_W{1'b0}};
              pair_q <= pair_q + 1'b1;
              st_q <= S_T0;
            end
          end else begin
            grid_q <= grid_q + 1'b1;
            st_q <= S_T0;
          end
        end

        S_NEXT: begin
          grid_q <= {GRID_IDX_W{1'b0}};
          busy_o <= 1'b0;
          done_o <= 1'b1;
          result_valid_q <= 1'b1;
          st_q <= S_IDLE;
        end

        default: st_q <= S_IDLE;
      endcase
    end
  end

  end endgenerate
endmodule
