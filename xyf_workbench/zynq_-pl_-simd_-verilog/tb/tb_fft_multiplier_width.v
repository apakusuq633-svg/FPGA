`timescale 1ns/1ps
// Full signed operand range, including conjugation of -32768.
module tb_fft_multiplier_width;
  reg signed [15:0] wr,wi,ar,ai,br,bi;
  reg inv;
  wire signed [31:0] old_wi=inv?-{{16{wi[15]}},wi}:{{16{wi[15]}},wi};
  wire signed [16:0] new_wi=inv?-{wi[15],wi}:{wi[15],wi};
  wire signed [31:0] old_r=(wr*br-old_wi*bi+32'sd8192)>>>14;
  wire signed [31:0] old_i=(wr*bi+old_wi*br+32'sd8192)>>>14;
  wire signed [31:0] new_r=(wr*br-new_wi*bi+32'sd8192)>>>14;
  wire signed [31:0] new_i=(wr*bi+new_wi*br+32'sd8192)>>>14;
  integer n,checks=0;
  initial begin
    for(n=0;n<100000;n=n+1)begin
      wr=$random;wi=n<65536?n-32768:$random;
      ar=$random;ai=$random;br=$random;bi=$random;inv=n[0];
      if(n%8==0||n%8==1)wi=-32768;
      if(n%16==0||n%16==1)begin br=-32768;bi=-32768;end
      #1;
      if(old_r!==new_r||old_i!==new_i)$fatal(1,"multiply mismatch n=%0d inv=%0d wi=%0d",n,inv,wi);
      checks=checks+1;
    end
    $display("FFT_MULTIPLIER_WIDTH_PASS cases=%0d signed16_conjugate_min=1",checks);
    $finish;
  end
endmodule
