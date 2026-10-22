// Execute the production PS acceptance program against real AXI + RV32 RTL.
// The simulated BSP below drives RTL, unlike compile-only sw/cstub/.
#include "Vrv32_ps_top.h"
#include "verilated.h"
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <cstdint>
#include <fstream>
#include <vector>

// 两份镜像共用一个 PS 程序：
//   默认        → sw/acoustic_image.h      （FW_ACCEL=1，加速镜像）
//   -DACOUSTIC_BASELINE_IMAGE → sw/acoustic_image_base.h（FW_ACCEL=0，全标量）
// 整机加速比就是这两次运行报的 clocks 之比，见 scripts/test_whole_machine.sh。
#define main acoustic_ps_main
#include "../sw/ps_main.c"
#undef main

static Vrv32_ps_top *dut;
static uint64_t clocks, push_count, vred_count, vupd_count, vfft_count, fault_count;
static uint32_t mem_index;
static bool running, poison_fir;
static bool microphone;
static uint32_t pdm_bits, density[8];
static bool pdm_previous;

static void tick()
{
    dut->clk_i = 0;
    dut->eval();
    if (microphone && dut->pdm_clk_o && !pdm_previous) {
        uint32_t pins = 0;
        for (unsigned ch=0; ch<8; ++ch) {
            uint32_t frame = pdm_bits / 64;
            uint32_t h = (frame-ch)*1664525u+1013904223u;
            h ^= h >> 13; h *= 0x85ebca6bu; h ^= h >> 16;
            density[ch] += (h >> 16);
            if (density[ch] >= 65536u) { density[ch] -= 65536u; pins |= 1u << ch; }
        }
        dut->pdm_din_i=pins;
        ++pdm_bits;
    }
    pdm_previous=dut->pdm_clk_o;
    if (dut->rst_n_i && dut->retire_valid_o) {
        if (dut->retire_fault_o) ++fault_count;
        const uint32_t instruction = dut->retire_instr_o;
        if ((instruction & 127) == 11) {
            switch ((instruction >> 12) & 7) {
            case 0: ++push_count; break;
            case 1: ++vred_count; break;
            case 2: ++vupd_count; break;
            case 7: ++vfft_count; break;
            }
        }
    }
    dut->clk_i = 1;
    dut->eval();
    ++clocks;
}

void Xil_Out32(uint32_t address, uint32_t value)
{
    const uint32_t off = address - RV32_BASE;
    dut->s_axi_awaddr = off;
    dut->s_axi_wdata = value;
    dut->s_axi_wstrb = 15;
    dut->s_axi_awvalid = 1;
    dut->s_axi_wvalid = 1;
    bool aw = false, w = false;
    for (unsigned timeout = 0; !(aw && w); ++timeout) {
        if (timeout == 1000) throw std::runtime_error("AXI write handshake timeout");
        dut->clk_i = 0; dut->eval();
        const bool aw_now = dut->s_axi_awvalid && dut->s_axi_awready;
        const bool w_now = dut->s_axi_wvalid && dut->s_axi_wready;
        tick();
        if (aw_now) { aw = true; dut->s_axi_awvalid = 0; }
        if (w_now) { w = true; dut->s_axi_wvalid = 0; }
    }
    for (unsigned timeout = 0; !dut->s_axi_bvalid; ++timeout) {
        if (timeout == 1000) throw std::runtime_error("AXI write response timeout");
        tick();
    }
    if (dut->s_axi_bresp != 0) throw std::runtime_error("AXI rejected write");
    dut->s_axi_bready = 1; tick(); dut->s_axi_bready = 0;
    if (off == R_CTRL) running = (value & (CTRL_HALT | CTRL_SOFT_RST)) == 0;
    if (off == R_MEM_ADDR) mem_index = value;
    if (off == R_MEM_WDATA) ++mem_index;
}

uint32_t Xil_In32(uint32_t address)
{
    const uint32_t off = address - RV32_BASE;
    // Model time spent between polls; no artificial result values are supplied.
    if (running && off == R_TOHOST) for (unsigned i = 0; i < 10000; ++i) tick();
    dut->s_axi_araddr = off;
    dut->s_axi_arvalid = 1;
    for (unsigned timeout = 0;; ++timeout) {
        if (timeout == 1000) throw std::runtime_error("AXI read handshake timeout");
        dut->clk_i = 0; dut->eval();
        const bool accepted = dut->s_axi_arready;
        tick();
        if (accepted) break;
    }
    dut->s_axi_arvalid = 0;
    for (unsigned timeout = 0; !dut->s_axi_rvalid; ++timeout) {
        if (timeout == 1000) throw std::runtime_error("AXI read response timeout");
        tick();
    }
    if (dut->s_axi_rresp != 0) throw std::runtime_error("AXI rejected read");
    uint32_t value = dut->s_axi_rdata;
    dut->s_axi_rready = 1; tick(); dut->s_axi_rready = 0;
    if (off == R_MEM_RDATA) {
        if (poison_fir && mem_index == (MEM_SEL_DTCM | (0x38C8u >> 2))) value = 0;
        ++mem_index;
    }
    return value;
}

int xil_printf(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    const int result = vprintf(format, args);
    va_end(args);
    return result;
}

static std::vector<uint32_t> image_words(const char *path)
{
    std::ifstream file(path);
    if (!file) throw std::runtime_error("live image missing");
    std::vector<uint32_t> words;
    uint32_t value;
    while(file >> std::hex >> value) words.push_back(value);
    if(words.empty() || words.size()>4096) throw std::runtime_error("invalid live image");
    return words;
}

static void reset_live()
{
    microphone=false;
    wr(R_CTRL,CTRL_SOFT_RST|CTRL_HALT);
    for(unsigned i=0;i<20;++i) tick();
    pdm_bits=0; pdm_previous=false;
    for(unsigned ch=0;ch<8;++ch) density[ch]=0;
    wr(R_MEM_CTRL,2u);
    wr(R_COEF_ADDR,0x400u);
    for(unsigned i=0;i<ACOUSTIC_FIR_COEFF_WORDS;++i) wr(R_COEF_WDATA,acoustic_fir_coeff[i]);
}

static void pipeline_test()
{
    // Real PDM pins -> CIC -> alignment -> capture and DAS -> the SAME core array.
    reset_live();
    wr(0x308u,64u); wr(0x380u,1u);
    microphone=true; wr(0x300u,3u);
    unsigned wait;
    for(wait=0;wait<100000;++wait) {
        tick();
        if(wait%1024==0 && rd(0x388u)>=64u) break;
    }
    if(wait==100000) throw std::runtime_error("PDM pipeline timeout");
    microphone=false; wr(0x380u,0u);
    for(unsigned i=0;i<128;++i) tick();
    wr(0x30Cu,0u);
    if(!(rd(0x304u)&1u)) throw std::runtime_error("raw capture missing");
    int32_t history[32]={};
    unsigned nonzero=0;
    for(unsigned n=0;n<64;++n) {
        int32_t sum=0;
        for(unsigned word=0;word<4;++word) {
            wr(0x31Cu,n*4+word);
            const uint32_t raw=rd(0x320u);
            sum+=static_cast<int16_t>(raw);
            sum+=static_cast<int16_t>(raw>>16);
        }
        int32_t das=(sum+4)>>3, dot=0;
        history[n&31]=das;
        for(unsigned k=0;k<32;++k)
            dot+=static_cast<int16_t>(acoustic_fir_coeff[k])*history[(n-k)&31];
        int32_t fir=dot>>15;
        if(fir>32767) fir=32767;
        if(fir< -32768) fir=-32768;
        uint32_t packed=rd(0x38Cu);
        if(static_cast<int16_t>(packed)!=das || static_cast<int16_t>(packed>>16)!=fir)
            throw std::runtime_error("PDM -> DAS/FIR bit-exact comparison failed");
        nonzero += das!=0;
    }
    if(!nonzero || rd(0x390u)) throw std::runtime_error("empty or dropped PDM stream");
    printf("PDM_DAS_FIR_PASS samples=64 nonzero=%u max_cycles=%u\n",nonzero,rd(0x394u));
    // Independent live firmware runs localization on owned 1024-sample snapshots.
    reset_live();
    auto itcm=image_words("sw/fw/fw_live_itcm.hex");
    auto dtcm_image=image_words("sw/fw/fw_live_dtcm.hex");
    if(!download(itcm.data(),itcm.size(),0) ||
       !download(dtcm_image.data(),dtcm_image.size(),MEM_SEL_DTCM))
        throw std::runtime_error("live image readback failed");
    wr(R_STEER_CTRL,2u); wr(R_STEER_ADDR,0);
    for(unsigned i=0;i<ACOUSTIC_STEER_LUT_WORDS;++i) wr(R_STEER_DATA,acoustic_steer_lut[i]);
    wr(0x380u,5u); microphone=true;
    wr(R_CTRL,CTRL_START|CTRL_HALT); wr(R_CTRL,0u);
    uint32_t consumed=0;
    unsigned snapshots=0, locked_seen=0;
    for(unsigned round=0;round<30000 && (snapshots<3 || !locked_seen);++round) {
        for(unsigned i=0;i<1024;++i) tick();
        uint32_t stat=rd(0x384u), count=(stat>>3)&511u;
        while(count--) { (void)rd(0x38Cu); ++consumed; }
        if(stat&4u || rd(R_TRAP_CNT) || (rd(R_TOHOST)&0xffff0000u)==0xDA5F0000u)
            throw std::runtime_error("live firmware/stream error");
        if(round%128==0) snapshots=dtcm(0x2804u);
        locked_seen |= stat & 2u;
    }
    if(snapshots<3 || !locked_seen || !consumed || rd(0x390u) || rd(0x394u)>819u)
        throw std::runtime_error("live localization/audio did not meet acceptance");
    wr(0x380u,4u);
    for(unsigned i=0;i<128;++i) tick();
    wr(R_CTRL,CTRL_HALT); microphone=false;
    printf("LIVE_LOCALIZATION_PASS snapshots=%u audio=%u grid=%u max_cycles=%u locked=1 error=%u compute_cycles=%u snapshot_cycles=%u\n",
           snapshots,consumed,dtcm(0x2808u),rd(0x394u),dtcm(0x280Cu),dtcm(0x2810u),dtcm(0x2814u));
}

static void sequence_negative()
{
    reset_live();
    auto itcm=image_words("sw/fw/fw_live_itcm.hex");
    auto data=image_words("sw/fw/fw_live_dtcm.hex");
    if(!download(itcm.data(),itcm.size(),0) ||
       !download(data.data(),data.size(),MEM_SEL_DTCM))
        throw std::runtime_error("sequence negative image readback failed");
    microphone=true;
    wr(R_CTRL,CTRL_START|CTRL_HALT); wr(R_CTRL,0u);
    unsigned n;
    for(n=0;n<100;++n) if(rd(R_TOHOST)==0xDA500001u) break;
    if(n==100) throw std::runtime_error("sequence negative boot timeout");
    for(n=0;n<2000;++n) {
        for(unsigned i=0;i<1024;++i) tick();
        wr(R_CTRL,CTRL_HALT);
        if((rd(0x304u)&3u)==1u) break;
        wr(R_CTRL,0u);
    }
    if(n==2000) throw std::runtime_error("sequence negative capture timeout");
    // Halt the owner before deliberately replacing its first bank through PS AXI.
    wr(0x30Cu,0u);
    uint32_t first=rd(0x314u), seq=rd(0x310u);
    // Let bank1 begin: releasing bank0 before that would merely shift both banks.
    for(unsigned i=0;i<2048;++i) tick();
    wr(0x324u,seq); wr(0x328u,1u);
    for(n=0;n<2000;++n) {
        for(unsigned i=0;i<1024;++i) tick();
        if((rd(0x304u)&3u)==3u) break;
    }
    if(n==2000 || rd(0x314u)==first)
        throw std::runtime_error("sequence negative did not replace the first bank");
    uint32_t first0=rd(0x314u), seq0=rd(0x310u);
    wr(0x30Cu,1u);
    uint32_t first1=rd(0x314u), seq1=rd(0x310u);
    printf("SEQUENCE_NEGATIVE_INPUT first0=%u first1=%u seq0=%u seq1=%u\n",first0,first1,seq0,seq1);
    if(first1-first0==512u && seq1-seq0==1u)
        throw std::runtime_error("sequence negative accidentally built a contiguous snapshot");
    wr(R_CTRL,0u);
    for(n=0;n<100;++n) if(rd(R_TOHOST)==0xDA5F0002u) break;
    wr(R_CTRL,CTRL_HALT); microphone=false;
    if(n==100 || dtcm(0x280Cu)!=2u || dtcm(0x2804u)!=0u || rd(R_TRAP_CNT)) {
        printf("SEQUENCE_NEGATIVE_DEBUG polls=%u mailbox=%08x error=%u snapshots=%u trap=%u\n",
               n,rd(R_TOHOST),dtcm(0x280Cu),dtcm(0x2804u),rd(R_TRAP_CNT));
        throw std::runtime_error("noncontiguous snapshot was not rejected");
    }
    printf("LIVE_SEQUENCE_REJECTED error=2 snapshots=0\n");
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    poison_fir = argc > 1 && std::strcmp(argv[1], "--corrupt-fir") == 0;
    dut = new Vrv32_ps_top;
    dut->rst_n_i = 0;
    for (unsigned i = 0; i < 20; ++i) tick();
    dut->rst_n_i = 1;
    int result = 1;
    try {
        result = acoustic_ps_main();
        printf("ACOUSTIC_RETIRED: PUSH=%llu VRED=%llu VUPD=%llu VFFT=%llu faults=%llu clocks=%llu\n",
               (unsigned long long)push_count, (unsigned long long)vred_count,
               (unsigned long long)vupd_count, (unsigned long long)vfft_count,
               (unsigned long long)fault_count, (unsigned long long)clocks);
        // 一次完整 VFFT 退休 512 PUSH + 1 RUN + 513 POP = 1026 条 —— **逆变换
        // 也是 1026**（513 PUSH + 1 RUN + 512 POP）。所以判据写成"整台整数倍"
        // 而不是钉死一个数：固件里多接一次变换（比如生产链改走硬件、或者加上
        // 逆变换）就该照常通过，而**半台 FFT** 永远是错的。
#ifdef ACOUSTIC_BASELINE_IMAGE
        // 基线镜像反过来判：四条自定义指令的退休数**必须全为 0**。
        // 这是"加速器真的关干净了"的正面证据 —— 任一非零，整机对照比的
        // 就不是"关了加速器"，而对照表上不会显示这件事。
        if (push_count || vred_count || vupd_count || vfft_count) result = 1;
#else
        if (push_count != 512u || vred_count != 512u ||
            vupd_count != 0u || vfft_count == 0u ||
            (vfft_count % 1026u) != 0u) result = 1;
#endif
        if (fault_count) result = 1;
#if !defined(ACOUSTIC_MEASURE_ONLY) && !defined(ACOUSTIC_BASELINE_IMAGE)
        if(result==0 && !poison_fir) { pipeline_test(); sequence_negative(); }
#endif
    } catch (const std::exception &error) {
        result = 1;
        printf("FAIL: %s\n", error.what());
    }
    // 计量模式**不许**打 PASS：那一次判据是主动放过的（基线镜像本就该在
    // VFFT/SIMD 那几条上不成立），打 PASS 等于宣称验过了。单独一个标记。
#ifdef ACOUSTIC_MEASURE_ONLY
    printf("ACOUSTIC_RTL_%s\n", result == 0 ? "MEASURED" : "FAIL");
#else
    printf("ACOUSTIC_RTL_%s\n", result == 0 ? "PASS" : "FAIL");
#endif
    dut->final();
    delete dut;
    return result;
}
