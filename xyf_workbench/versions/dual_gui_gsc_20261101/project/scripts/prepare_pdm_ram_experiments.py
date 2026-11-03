"""Generate isolated RAM-shape experiments. No production RTL is written."""
from pathlib import Path
import argparse,hashlib,json
R=Path(__file__).resolve().parents[1];p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
srp=(R/'rtl/srp/rv32_srp_scan.v').read_text();loc=(R/'rtl/array/rv32_overlap_localizer.v').read_text()
old='''  always @(posedge clk_i) begin
    if (lut_we_i && !busy_o && lut_addr_i < N_PAIR*N_GRID) lut_mem[lut_addr_i] <= lut_data_i;
    lut_r <= lut_mem[pair_q * N_GRID + grid_q];
  end'''
assert srp.count(old)==1
banked='''  generate if(N_PAIR==66 && N_GRID==1024 && ADDR_W==17)begin:g_banked
    (* ram_style="block" *) reg [LUT_W-1:0] lut_lo[0:32767];
    (* ram_style="block" *) reg [LUT_W-1:0] lut_mid[0:32767];
    (* ram_style="block" *) reg [LUT_W-1:0] lut_tail[0:2047];
    wire[16:0] rd_addr=pair_q*N_GRID+grid_q;
    reg[1:0] bank_q;
    reg[LUT_W-1:0] q0,q1,q2;
    always @(posedge clk_i)begin
      bank_q<=rd_addr[16:15];
      q0<=lut_lo[rd_addr[14:0]];q1<=lut_mid[rd_addr[14:0]];q2<=lut_tail[rd_addr[10:0]];
      if(lut_we_i&&!busy_o&&lut_addr_i<67584)begin
        case(lut_addr_i[16:15])
          0:lut_lo[lut_addr_i[14:0]]<=lut_data_i;
          1:lut_mid[lut_addr_i[14:0]]<=lut_data_i;
          2:lut_tail[lut_addr_i[10:0]]<=lut_data_i;
        endcase
      end
    end
    assign lut_r=bank_q==0?q0:bank_q==1?q1:q2;
  end else begin:g_original
    (* ram_style="block" *) reg[LUT_W-1:0] lut_mem[0:N_PAIR*N_GRID-1];
    reg[LUT_W-1:0] q;
    always @(posedge clk_i)begin
      if(lut_we_i&&!busy_o&&lut_addr_i<N_PAIR*N_GRID)lut_mem[lut_addr_i]<=lut_data_i;
      q<=lut_mem[pair_q*N_GRID+grid_q];
    end
    assign lut_r=q;
  end endgenerate'''
candidate_srp=srp.replace('  (* ram_style="block" *) reg [LUT_W-1:0] lut_mem [0:N_PAIR*N_GRID-1];','').replace('reg [LUT_W-1:0]     lut_r;','wire [LUT_W-1:0]     lut_r;').replace(old,banked)
raw=''' (* ram_style="block" *) reg[31:0] raw_lo[0:4095],raw_mid[0:4095],raw_tail[0:4095];
 reg[31:0] raw_lo_q,raw_mid_q,raw_tail_q;
 reg[1:0] raw_bank_q;
 wire[13:0] raw_wr_addr=wr_sample*6+wr_word;
 wire[31:0] raw_q=raw_bank_q==0?raw_lo_q:raw_bank_q==1?raw_mid_q:raw_tail_q;
 always @(posedge clk_i)begin
   raw_bank_q<=raw_addr[13:12];
   raw_lo_q<=raw_lo[raw_addr[11:0]];raw_mid_q<=raw_mid[raw_addr[11:0]];raw_tail_q<=raw_tail[raw_addr[11:0]];
   if(wr_active)case(raw_wr_addr[13:12])
     0:raw_lo[raw_wr_addr[11:0]]<=wr_pcm[wr_word*32+:32];
     1:raw_mid[raw_wr_addr[11:0]]<=wr_pcm[wr_word*32+:32];
     2:raw_tail[raw_wr_addr[11:0]]<=wr_pcm[wr_word*32+:32];
   endcase
 end'''
assert loc.count(' (* ram_style="block" *) reg [31:0] raw_mem[0:12287];')==1
candidate_loc=loc.replace(' (* ram_style="block" *) reg [31:0] raw_mem[0:12287];',raw).replace('reg [31:0] raw_q,prep_q,cache_a,cache_b,phi_q;','reg [31:0] prep_q,cache_a,cache_b,phi_q;').replace('  if(wr_active)raw_mem[wr_sample*6+wr_word]<=wr_pcm[wr_word*32+:32];','').replace('  raw_q<=raw_mem[raw_addr];hann_q<=hann[n];','  hann_q<=hann[n];')
manifest={}
for name,s,l in [('baseline',srp,loc),('srp_banked',candidate_srp,loc),('raw_banked',srp,candidate_loc),('combined',candidate_srp,candidate_loc)]:
    dest=O/name;dest.mkdir()
    (dest/'rv32_srp_scan.v').write_text(s);(dest/'rv32_overlap_localizer.v').write_text(l)
    manifest[name]={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in dest.iterdir()}
(O/'manifest.json').write_text(json.dumps(manifest,indent=2))
print('PDM_RAM_EXPERIMENTS_PREPARED production_rtl_unchanged=1')
