// Continuous raw ring and complete 12/1024/66/SRP controller; shared VFFT port.
module rv32_overlap_localizer #(
 parameter HANN_FILE=
`ifdef PDM_HANN_FILE
 `PDM_HANN_FILE,
`else
 "rtl/rom/pdm_hann_q14.hex",
`endif
 parameter CHANNELS=12,
 parameter CAPTURE_SLOTS=2*((CHANNELS+1)/2),
 parameter HOP_SAMPLES=512,
 parameter R_LEN=32,
 parameter BIN_LO=6,
 parameter BIN_COUNT=208,
 parameter BAND_LAST=203,
 parameter FAST_PREP=CHANNELS==9,
 parameter STREAM_STATS=CHANNELS==9,
 parameter SPARSE_FFT_IO=CHANNELS==9,
 parameter CPU_SCHEDULED=0,
 parameter RESULT_OFFSET=0
)(
 input clk_i,input rst_n_i,input enable_i,input rearm_i,
 input valid_i,input [CAPTURE_SLOTS*24-1:0] pcm_i,input [31:0] sample_id_i,
 output busy_o,output reg done_o,output reg [31:0] window_id_o,
 output reg [31:0] first_o,output reg [31:0] latency_o,
 output reg [31:0] raw_drop_o,output reg [31:0] window_drop_o,
 output reg [9:0] best_grid_o,output reg signed [31:0] best_score_o,
 output fft_start_o,output fft_io_o,output fft_inv_o,
 output fft_pop_o,output fft_seek_o,output [31:0] fft_data_o,
 input fft_done_i,input [31:0] fft_result_i,
 output srp_r_we_o,output [16:0] srp_r_addr_o,output [15:0] srp_r_data_o,
 output srp_start_o,input srp_done_i,input srp_busy_i,
 output [9:0] srp_score_addr_o,input signed [31:0] srp_score_i,
 input fft_ready_i,input ac_ready_i,input ac_done_i,input [31:0] ac_result_i,
 output ac_start_o,output [1:0] ac_sel_o,output [31:0] ac_data_o,
 output [2:0] run_request_o,output reg [31:0] request_id_o,
 output reg [31:0] compute_cycles_o,
 input [5:0] statistics_index_i,output [31:0] statistics_data_o
);
 localparam IDLE=0,RAW_REQ=1,RAW_USE=2,SCALE=3,
  F_RD=4,F_PUSH=5,F_RUN=6,F_WAIT=7,F_POP=8,
  C_RD=9,C_PUSH=10,C_RUN=11,C_WAIT=12,H_RUN=13,H_WAIT=14,H_POP=15,
  I_RD=16,I_PUSH=17,I_RUN=18,I_WAIT=19,R_SEEK=20,R_LOW=21,R_HIGH=22,
  R_NEG=23,SRP_RUN=24,SRP_WAIT=25,P_REQ=26,P_USE=27,PUBLISH=28,
  PREP_STATS=29,F_SEEK=30,I_SEEK=31;
 reg [4:0] state;
 reg [31:0] tick,sample_count,source_first,previous_id,active_first,start_tick;
 reg have_source,pending,window_primed;
 reg failed;
 wire source_gap=have_source&&sample_id_i-previous_id!=1;
 reg wr_active;reg [2:0] wr_word;
 wire window_arrival=wr_active&&wr_word==CAPTURE_SLOTS/2-1&&window_primed&&(sample_count & (HOP_SAMPLES-1))==0;
 wire window_busy_loss=window_arrival&&(state!=IDLE||pending);
 wire raw_overrun=state!=IDLE&&state<=F_POP&&sample_count-active_first>2048;
 wire loss_now=(enable_i&&valid_i&&(wr_active||source_gap))||window_busy_loss||raw_overrun;
 wire run_ok=enable_i&&!failed&&!loss_now;
 reg [31:0] pending_first;
 reg [31:0] input_ready_tick,pending_ready_tick,active_ready_tick;
 reg [10:0] wr_sample;reg [CAPTURE_SLOTS*16-1:0] wr_pcm;
 (* ram_style="block" *) reg [31:0] raw_mem[0:2048*(CAPTURE_SLOTS/2)-1];
 (* ram_style="block" *) reg [31:0] prepared[0:511];
 (* ram_style="block" *) reg [31:0] spectrum[0:CHANNELS*BIN_COUNT-1];
 (* ram_style="block" *) reg [31:0] phi[0:BIN_COUNT-1];
 (* ram_style="block" *) reg [15:0] hann[0:1023];
 reg [31:0] raw_q,prep_q,cache_a,cache_b,phi_q;
 reg [15:0] hann_q;
 reg [3:0] channel,a,b;
 reg [6:0] pair;
 reg [9:0] n,index;
 reg [1:0] pass;
 reg operand;
 reg [4:0] left_shift,right_shift;
 reg signed [31:0] sum,mean;
 reg [31:0] peak,bound;
 reg signed [15:0] minimum,maximum;
 reg [63:0] energy;
 reg [31:0] raw_peak,clips;
 reg [31:0] statistics[0:CHANNELS*5-1];
 assign statistics_data_o=statistics_index_i<CHANNELS*5?statistics[statistics_index_i]:32'b0;
 reg [$clog2(R_LEN/2)-1:0] ring_word;
 reg [15:0] ring_high;
 reg [9:0] grid;
 wire [9:0] read_n=(FAST_PREP&&state==RAW_USE&&pass==2)?n+10'd1:n;
 wire [10:0] raw_sample=active_first[10:0]+{1'b0,read_n};
 wire [13:0] raw_addr=raw_sample*(CAPTURE_SLOTS/2)+(channel>>1);
 wire signed [15:0] sample=channel[0]?$signed(raw_q[31:16]):$signed(raw_q[15:0]);
 wire signed [31:0] centered=$signed(sample)-mean;
 wire [31:0] abs_center=centered<0?-centered:centered;
 wire [31:0] abs_raw=sample<0?-$signed({{16{sample[15]}},sample}):{16'b0,sample};
 wire signed [31:0] square=sample*sample;
 wire signed [15:0] next_min=sample<minimum?sample:minimum;
 wire signed [15:0] next_max=sample>maximum?sample:maximum;
 wire signed [31:0] final_mean=($signed(sum)+$signed(sample))/32'sd1024;
 wire signed [31:0] low_center=$signed(next_min)-final_mean;
 wire signed [31:0] high_center=$signed(next_max)-final_mean;
 wire [31:0] low_abs=low_center<0?-low_center:low_center;
 wire [31:0] high_abs=high_center<0?-high_center:high_center;
 // Two 512-sample blocks give exact 1024-sample statistics at either hop.
 // Accumulate during acquisition, so no post-window statistics RAM walk.
 wire signed [31:0] window_sum[0:CHANNELS-1];
 wire [63:0] window_energy[0:CHANNELS-1];
 wire [31:0] window_peak[0:CHANNELS-1],window_clips[0:CHANNELS-1];
 wire signed [15:0] window_min[0:CHANNELS-1],window_max[0:CHANNELS-1];
 genvar sc;
 generate for(sc=0;sc<CHANNELS;sc=sc+1)begin:g_statistics
  reg signed [31:0] cur_sum,prev_sum,win_sum;
  reg [63:0] cur_energy,prev_energy,win_energy;
  reg [31:0] cur_peak,prev_peak,win_peak,cur_clips,prev_clips,win_clips;
  reg signed [15:0] cur_min,cur_max,prev_min,prev_max,win_min,win_max;
  wire signed [15:0] x=pcm_i[sc*24+8+:16];
  wire [31:0] ax=x<0?-$signed({{16{x[15]}},x}):{16'b0,x};
  wire signed [31:0] sq=x*x;
  wire begin_block=sample_count[8:0]==0;
  wire signed [31:0] ns=(begin_block?32'sd0:cur_sum)+$signed(x);
  wire [63:0] ne=(begin_block?64'd0:cur_energy)+{32'b0,sq};
  wire [31:0] np=begin_block||ax>cur_peak?ax:cur_peak;
  wire [31:0] nc=(begin_block?32'd0:cur_clips)+(x==32767||x==-32768);
  wire signed [15:0] nlo=begin_block||x<cur_min?x:cur_min;
  wire signed [15:0] nhi=begin_block||x>cur_max?x:cur_max;
  always @(posedge clk_i)if(STREAM_STATS&&rst_n_i&&enable_i&&valid_i&&!failed&&!loss_now)begin
   cur_sum<=ns;cur_energy<=ne;cur_peak<=np;cur_clips<=nc;cur_min<=nlo;cur_max<=nhi;
   if(sample_count[8:0]==511)begin
    prev_sum<=ns;prev_energy<=ne;prev_peak<=np;prev_clips<=nc;prev_min<=nlo;prev_max<=nhi;
    if((window_primed||sample_count[9:0]==1023)&&(sample_count&(HOP_SAMPLES-1))==HOP_SAMPLES-1)begin
     win_sum<=prev_sum+ns;win_energy<=prev_energy+ne;win_peak<=prev_peak>np?prev_peak:np;
     win_clips<=prev_clips+nc;win_min<=prev_min<nlo?prev_min:nlo;win_max<=prev_max>nhi?prev_max:nhi;
    end
   end
  end
  assign window_sum[sc]=win_sum;assign window_energy[sc]=win_energy;
  assign window_peak[sc]=win_peak;assign window_clips[sc]=win_clips;
  assign window_min[sc]=win_min;assign window_max[sc]=win_max;
 end endgenerate
 wire signed [31:0] stream_mean=$signed(window_sum[channel])/32'sd1024;
 wire signed [31:0] stream_lo=$signed(window_min[channel])-stream_mean;
 wire signed [31:0] stream_hi=$signed(window_max[channel])-stream_mean;
 wire [31:0] stream_abs_lo=stream_lo<0?-stream_lo:stream_lo;
 wire [31:0] stream_abs_hi=stream_hi<0?-stream_hi:stream_hi;
 wire signed [31:0] scaled_wide=centered<<<left_shift;
 wire signed [15:0] scaled=scaled_wide>>>right_shift;
 wire signed [31:0] hann_product=scaled*$signed(hann_q);
 wire signed [15:0] window_sample=hann_product>>>14;
 wire fft_ready=CPU_SCHEDULED?fft_ready_i:1'b1;
 wire ac_ready=CPU_SCHEDULED?ac_ready_i:1'b1;
 wire [9:0] phi_read_index=(state==I_PUSH&&fft_ready)?index+1'b1:index;
 wire [7:0] phi_addr=phi_read_index>=BIN_LO&&phi_read_index<BIN_LO+BIN_COUNT?phi_read_index-BIN_LO:0;
 wire ac_start,ac_done,ac_stall,ac_io;wire [2:0] ac_op;
 wire [1:0] ac_sel;wire [31:0] ac_data,ac_result;
 assign busy_o=state!=IDLE;
 assign ac_start=state==C_PUSH||state==C_RUN||state==H_RUN||state==H_POP;
 assign ac_io=state==C_PUSH||state==H_POP;
 assign ac_sel=state==H_POP?2:operand?1:0;
 assign ac_op=state==H_RUN||state==H_WAIT?1:2;
 assign ac_data=operand?cache_b:cache_a;
 assign ac_start_o=run_ok&&ac_start&&ac_io;
 assign ac_sel_o=ac_sel;assign ac_data_o=ac_data;
 assign run_request_o=!run_ok?3'd0:(state==F_RUN||state==F_WAIT)?3'd1:
   (state==I_RUN||state==I_WAIT)?3'd2:
   (state==C_RUN||state==C_WAIT)?3'd3:
   (state==H_RUN||state==H_WAIT)?3'd4:
   (state==SRP_RUN||state==SRP_WAIT)?3'd5:3'd0;
 generate if(!CPU_SCHEDULED)begin:g_internal
 rv32_acoustic_ext #(.LANES(4),.CN(BIN_COUNT),.BAND_HI(BAND_LAST)) u_gcc(
  .clk_i(clk_i),.rst_n_i(rst_n_i),.start_i(ac_start),.keep_i(1'b1),
  .commit_i(1'b1),.op_i(ac_op),.is_io_i(ac_io),.io_sel_i(ac_sel),
  .scalar_i(ac_data),.stall_o(ac_stall),.done_o(ac_done),.result_o(ac_result));
 end else begin:g_external
 assign ac_done=ac_done_i;assign ac_result=ac_result_i;assign ac_stall=0;
 end endgenerate
 assign fft_start_o=run_ok&&(state==F_PUSH||state==F_POP||state==I_PUSH||
  state==R_SEEK||state==R_NEG||state==R_LOW||state==F_SEEK||state==I_SEEK||(SPARSE_FFT_IO&&state==F_RD)||(!CPU_SCHEDULED&&(state==F_RUN||state==I_RUN)));
 assign fft_io_o=state!=F_RUN&&state!=I_RUN;
 assign fft_inv_o=(state>=I_RD&&state<=R_NEG)||state==I_SEEK;
 assign fft_pop_o=state==F_POP||state==R_SEEK||state==R_NEG||state==R_LOW||state==F_SEEK||state==I_SEEK||(SPARSE_FFT_IO&&state==F_RD);
 assign fft_seek_o=state==R_SEEK||state==R_NEG||state==F_SEEK||state==I_SEEK||(SPARSE_FFT_IO&&state==F_RD);
 assign fft_data_o=(state==F_SEEK||state==I_SEEK)?BIN_LO:state==F_RD||state==R_SEEK?0:state==R_NEG?(512-R_LEN/4):
  state==I_PUSH?(index>=BIN_LO&&index<BIN_LO+BIN_COUNT?phi_q:0):prep_q;
 assign srp_r_we_o=run_ok&&((state==R_LOW&&fft_ready)||state==R_HIGH);
 assign srp_r_addr_o=pair*R_LEN+ring_word*2+(state==R_HIGH);
 assign srp_r_data_o=state==R_HIGH?ring_high:fft_result_i[15:0];
 assign srp_start_o=run_ok&&!CPU_SCHEDULED&&state==SRP_RUN;
 assign srp_score_addr_o=grid;
 initial begin
  if(HOP_SAMPLES!=512&&HOP_SAMPLES!=1024)$fatal(1,"unsupported localizer hop");
  if(R_LEN!=32&&R_LEN!=64)$fatal(1,"unsupported correlation span");
  $readmemh(HANN_FILE,hann);
 end
 // RAM has one writer per array and synchronous reads, without RAM reset.
 always @(posedge clk_i)begin
  if(wr_active)raw_mem[wr_sample*(CAPTURE_SLOTS/2)+wr_word]<=wr_pcm[wr_word*32+:32];
  raw_q<=raw_mem[raw_addr];hann_q<=hann[read_n];
  prep_q<=prepared[(state==F_PUSH&&fft_ready)?(index[8:0]+9'd1):index[8:0]];
  cache_a<=spectrum[a*BIN_COUNT+((state==C_PUSH&&ac_ready)?index+1'b1:index)];
  cache_b<=spectrum[b*BIN_COUNT+((state==C_PUSH&&ac_ready)?index+1'b1:index)];phi_q<=phi[phi_addr];
  if(run_ok&&state==RAW_USE&&pass==2&&!n[0])prepared[n[9:1]][15:0]<=window_sample;
  if(run_ok&&state==RAW_USE&&pass==2&&n[0])prepared[n[9:1]][31:16]<=window_sample;
  if(run_ok&&state==F_POP&&fft_ready&&index>=BIN_LO&&index<BIN_LO+BIN_COUNT)spectrum[channel*BIN_COUNT+index-BIN_LO]<=fft_result_i;
  if(run_ok&&state==H_POP&&ac_ready)phi[index]<=ac_result;
 end
 integer c;
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin
   state<=IDLE;failed<=0;window_primed<=0;tick<=0;sample_count<=0;source_first<=0;previous_id<=0;have_source<=0;
   pending<=0;pending_first<=0;wr_active<=0;wr_word<=0;wr_sample<=0;wr_pcm<=0;
   active_first<=0;start_tick<=0;done_o<=0;window_id_o<=0;first_o<=0;latency_o<=0;
   raw_drop_o<=0;window_drop_o<=0;best_grid_o<=0;best_score_o<=32'h80000000;
   channel<=0;a<=0;b<=1;pair<=0;n<=0;index<=0;pass<=0;operand<=0;
   sum<=0;mean<=0;peak<=0;bound<=0;energy<=0;raw_peak<=0;clips<=0;minimum<=32767;maximum<=-32768;
   left_shift<=0;right_shift<=0;ring_word<=0;ring_high<=0;grid<=0;
   request_id_o<=0;
   input_ready_tick<=0;pending_ready_tick<=0;active_ready_tick<=0;compute_cycles_o<=0;
  end else if(rearm_i===1'b1)begin
   // Called only after shared engines drain. Preserve time and the request ticket.
   state<=IDLE;failed<=0;window_primed<=0;sample_count<=0;source_first<=0;previous_id<=0;have_source<=0;
   pending<=0;pending_first<=0;wr_active<=0;wr_word<=0;wr_sample<=0;wr_pcm<=0;
   active_first<=0;start_tick<=0;done_o<=0;window_id_o<=0;first_o<=0;latency_o<=0;
   raw_drop_o<=0;window_drop_o<=0;best_grid_o<=0;best_score_o<=32'h80000000;
   channel<=0;a<=0;b<=1;pair<=0;n<=0;index<=0;pass<=0;operand<=0;
   sum<=0;mean<=0;peak<=0;bound<=0;energy<=0;raw_peak<=0;clips<=0;minimum<=32767;maximum<=-32768;
   left_shift<=0;right_shift<=0;ring_word<=0;ring_high<=0;grid<=0;
   input_ready_tick<=0;pending_ready_tick<=0;active_ready_tick<=0;compute_cycles_o<=0;
  end else begin
   tick<=tick+1;done_o<=0;
   if(state==F_RUN||state==I_RUN||state==C_RUN||state==H_RUN||state==SRP_RUN)
    request_id_o<=request_id_o+1'b1;
   if(enable_i&&valid_i)begin
    if(wr_active)raw_drop_o<=raw_drop_o+1;
    if(have_source&&sample_id_i-previous_id!=1)raw_drop_o<=raw_drop_o+1;
    if(!have_source)begin source_first<=sample_id_i;have_source<=1;end
    previous_id<=sample_id_i;wr_sample<=sample_count[10:0];sample_count<=sample_count+1;
    if(sample_count[9:0]==1023)window_primed<=1;
    if((window_primed||sample_count[9:0]==1023)&&(sample_count & (HOP_SAMPLES-1))==HOP_SAMPLES-1)input_ready_tick<=tick;
    for(c=0;c<CAPTURE_SLOTS;c=c+1)wr_pcm[c*16+:16]<=c<CHANNELS ? pcm_i[c*24+8+:16] : 16'b0;
    wr_word<=0;wr_active<=1;
   end else if(wr_active)begin
    if(wr_word==CAPTURE_SLOTS/2-1)begin
     wr_active<=0;
     if(window_primed&&(sample_count & (HOP_SAMPLES-1))==0)begin
      if(state!=IDLE||pending)window_drop_o<=window_drop_o+1;
      else begin pending<=1;pending_first<=sample_count-1024;pending_ready_tick<=input_ready_tick;end
     end
    end else wr_word<=wr_word+1;
   end
   if(raw_overrun&&!failed)raw_drop_o<=raw_drop_o+1;
   if(!enable_i)begin
    state<=IDLE;pending<=0;sample_count<=0;have_source<=0;wr_active<=0;window_primed<=0;
   end else if(failed||loss_now)begin
    failed<=1;state<=IDLE;pending<=0;
   end else case(state)
    IDLE:if(enable_i&&pending)begin
     pending<=0;active_first<=pending_first;active_ready_tick<=pending_ready_tick;start_tick<=tick;channel<=0;n<=0;pass<=0;
     sum<=0;peak<=0;energy<=0;raw_peak<=0;clips<=0;minimum<=32767;maximum<=-32768;state<=STREAM_STATS?PREP_STATS:RAW_REQ;
     if(STREAM_STATS)for(c=0;c<CHANNELS;c=c+1)begin
      statistics[c*5]<=window_sum[c];statistics[c*5+1]<=window_energy[c][31:0];
      statistics[c*5+2]<=window_energy[c][63:32];statistics[c*5+3]<=window_peak[c];statistics[c*5+4]<=window_clips[c];
     end
    end
    PREP_STATS:begin
     mean<=stream_mean;bound<=stream_abs_lo>stream_abs_hi?stream_abs_lo:stream_abs_hi;
     left_shift<=0;right_shift<=0;pass<=2;n<=0;state<=SCALE;
    end
    RAW_REQ:state<=RAW_USE;
    RAW_USE:begin
     if(pass==0)begin
      minimum<=next_min;maximum<=next_max;
      sum<=sum+$signed(sample);energy<=energy+{32'b0,square};
      if(abs_raw>raw_peak)raw_peak<=abs_raw;
      if(sample==32767||sample==-32768)clips<=clips+1;
     end
     if(pass==1&&abs_center>peak)peak<=abs_center;
     if(n==1023)begin
      n<=0;
      if(pass==0)begin
       statistics[channel*5]<=sum+$signed(sample);
       statistics[channel*5+1]<=energy+{32'b0,square};
       statistics[channel*5+2]<=(energy+{32'b0,square})>>32;
       statistics[channel*5+3]<=abs_raw>raw_peak?abs_raw:raw_peak;
       statistics[channel*5+4]<=clips+(sample==32767||sample==-32768);
       mean<=final_mean;pass<=1;peak<=0;state<=RAW_REQ;
       // max(abs(x-mean)) occurs at min(x) or max(x): exact, no third pass.
       if(FAST_PREP)begin bound<=low_abs>high_abs?low_abs:high_abs;left_shift<=0;right_shift<=0;state<=SCALE;end
      end else if(pass==1)begin
       bound<=abs_center>peak?abs_center:peak;left_shift<=0;right_shift<=0;state<=SCALE;
      end else begin index<=0;state<=F_RD;end
     end else begin n<=n+1;state<=FAST_PREP&&pass==2?RAW_USE:RAW_REQ;end
    end
    SCALE:begin
     if(bound!=0&&bound<8192&&left_shift<14)begin bound<=bound<<1;left_shift<=left_shift+1;end
     else if(bound>32767)begin bound<=(bound+1)>>1;right_shift<=right_shift+1;end
     else begin pass<=2;state<=RAW_REQ;end
    end
    F_RD:if(!SPARSE_FFT_IO||fft_ready)state<=F_PUSH;
    F_PUSH:if(fft_ready)begin if(index==511)state<=F_RUN;else index<=index+1;end
    F_RUN:state<=F_WAIT;
    F_WAIT:if(fft_done_i)begin index<=SPARSE_FFT_IO?BIN_LO:0;state<=SPARSE_FFT_IO?F_SEEK:F_POP;end
    F_SEEK:if(fft_ready)state<=F_POP;
    F_POP:if(fft_ready)begin if(index==(SPARSE_FFT_IO?BIN_LO+BIN_COUNT-1:512))begin
     if(channel==CHANNELS-1)begin a<=0;b<=1;pair<=0;index<=0;operand<=0;state<=C_RD;end
     else begin channel<=channel+1;n<=0;pass<=0;sum<=0;peak<=0;energy<=0;raw_peak<=0;clips<=0;minimum<=32767;maximum<=-32768;state<=STREAM_STATS?PREP_STATS:RAW_REQ;end
    end else index<=index+1;end
    C_RD:state<=C_PUSH;
    C_PUSH:if(ac_ready)begin if(index==BIN_COUNT-1)begin
     index<=0;
     if(!operand)begin operand<=1;state<=C_RD;end else state<=C_RUN;
    end else index<=index+1;end
    C_RUN:state<=C_WAIT;
    C_WAIT:if(ac_done)state<=H_RUN;
    H_RUN:state<=H_WAIT;
    H_WAIT:if(ac_done)begin index<=0;state<=H_POP;end
    H_POP:if(ac_ready)begin if(index==BIN_COUNT-1)begin index<=SPARSE_FFT_IO?BIN_LO:0;state<=SPARSE_FFT_IO?I_SEEK:I_RD;end else index<=index+1;end
    I_SEEK:if(fft_ready)state<=I_RD;
    I_RD:state<=I_PUSH;
    I_PUSH:if(fft_ready)begin if(index==(SPARSE_FFT_IO?BIN_LO+BIN_COUNT-1:512))state<=I_RUN;else index<=index+1;end
    I_RUN:state<=I_WAIT;
    I_WAIT:if(fft_done_i)begin ring_word<=0;state<=R_SEEK;end
    R_SEEK:if(fft_ready)state<=R_LOW;
    R_NEG:if(fft_ready)state<=R_LOW;
    R_LOW:if(fft_ready)begin ring_high<=fft_result_i[31:16];state<=R_HIGH;end
    R_HIGH:begin
     if(ring_word==R_LEN/2-1)begin
      if(pair==CHANNELS*(CHANNELS-1)/2-1)state<=SRP_RUN;
      else begin pair<=pair+1;if(b==CHANNELS-1)begin a<=a+1;b<=a+2;end else b<=b+1;index<=0;operand<=0;state<=C_RD;end
     end else begin ring_word<=ring_word+1;state<=ring_word==R_LEN/4-1?R_NEG:R_LOW;end
    end
    SRP_RUN:state<=SRP_WAIT;
    SRP_WAIT:if(srp_done_i)begin grid<=0;best_score_o<=32'h80000000;best_grid_o<=0;state<=P_REQ;end
    P_REQ:state<=P_USE;
    P_USE:begin
     if(srp_score_i>best_score_o)begin best_score_o<=srp_score_i;best_grid_o<=grid;end
     if(grid==1023)begin
      compute_cycles_o<=tick-active_ready_tick;
      if(RESULT_OFFSET==0)begin
       first_o<=source_first+active_first;latency_o<=tick-active_ready_tick;window_id_o<=window_id_o+1;done_o<=1;state<=IDLE;
      end else state<=PUBLISH;
     end else begin grid<=grid+1;state<=P_REQ;end
    end
    // Publish only a newly computed window, at a fixed phase to remove poll jitter.
    PUBLISH:if(tick-active_ready_tick>=RESULT_OFFSET)begin
     first_o<=source_first+active_first;latency_o<=tick-active_ready_tick;
     window_id_o<=window_id_o+1;done_o<=1;state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
