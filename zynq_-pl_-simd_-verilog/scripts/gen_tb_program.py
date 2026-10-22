def R(f7,rs2,rs1,f3,rd,op): return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def I(imm,rs1,f3,rd,op):    return ((imm&0xFFF)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def S(imm,rs2,rs1,f3,op):
    i=imm&0xFFF; return ((i>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((i&0x1F)<<7)|op
def J(imm,rd,op):
    i=imm&0x1FFFFF
    return (((i>>20)&1)<<31)|(((i>>1)&0x3FF)<<21)|(((i>>11)&1)<<20)|(((i>>12)&0xFF)<<12)|(rd<<7)|op

ADDI=lambda rd,rs1,i: I(i,rs1,0,rd,0x13)
ADD =lambda rd,a,b: R(0,b,a,0,rd,0x33)
SUB =lambda rd,a,b: R(0x20,b,a,0,rd,0x33)
LUI =lambda rd,i20: ((i20&0xFFFFF)<<12)|(rd<<7)|0x37
# M 扩展：funct7 = 0000001，只用 funct3 分流。
MUL   =lambda rd,a,b: R(0x01,b,a,0,rd,0x33)
MULH  =lambda rd,a,b: R(0x01,b,a,1,rd,0x33)
MULHSU=lambda rd,a,b: R(0x01,b,a,2,rd,0x33)
MULHU =lambda rd,a,b: R(0x01,b,a,3,rd,0x33)
DIV   =lambda rd,a,b: R(0x01,b,a,4,rd,0x33)
DIVU  =lambda rd,a,b: R(0x01,b,a,5,rd,0x33)
REM   =lambda rd,a,b: R(0x01,b,a,6,rd,0x33)
REMU  =lambda rd,a,b: R(0x01,b,a,7,rd,0x33)
SW  =lambda rs2,off,rs1: S(off,rs2,rs1,2,0x23)
LW  =lambda rd,off,rs1: I(off,rs1,2,rd,0x03)
CSRRW=lambda rd,csr,rs1: I(csr,rs1,1,rd,0x73)
CSRRS=lambda rd,csr,rs1: I(csr,rs1,2,rd,0x73)
CSRRWI=lambda rd,csr,u: I(csr,u,5,rd,0x73)
CSRRCI=lambda rd,csr,u: I(csr,u,7,rd,0x73)
CSRR=lambda rd,csr: CSRRS(rd,csr,0)
CSRW=lambda csr,rs1: CSRRW(0,csr,rs1)
ECALL=0x00000073
EBREAK=0x00100073
MRET=I(0x302,0,0,0,0x73)

MSTATUS=0x300; MISA=0x301; MTVEC=0x305; MSCRATCH=0x340
MEPC=0x341; MCAUSE=0x342; MTVAL=0x343; CYCLE=0xC00

prog=[]
def e(w,c): prog.append((w,c))

e(ADDI(28,0,0),'addi x28, x0, 0      # trap count')
e(ADDI(29,0,0),'addi x29, x0, 0      # mcause sum')
e(ADDI(31,0,0),'addi x31, x0, 0      # mepc sum')
e(ADDI(27,0,0),'addi x27, x0, 0      # mtval sum')
e(ADDI(25,0,0),'addi x25, x0, 0      # mstatus sum')
e(ADDI(1,0,8),'addi x1, x0, 8       # MIE')
e(CSRRS(0,MSTATUS,1),'csrrs x0, mstatus, x1')
e(ADDI(2,0,0x123),'addi x2, x0, 0x123')
e(CSRRW(3,MSCRATCH,2),'csrrw x3, mscratch, x2')
e(CSRRS(4,MSCRATCH,0),'csrrs x4, mscratch, x0')
e(CSRRWI(5,MSCRATCH,31),'csrrwi x5, mscratch, 31')
e(CSRRCI(6,MSCRATCH,1),'csrrci x6, mscratch, 1')
e(CSRR(7,MSCRATCH),'csrr x7, mscratch')
e(SW(3,400,0),'sw x3, 400(x0)')
e(SW(4,404,0),'sw x4, 404(x0)')
e(SW(5,408,0),'sw x5, 408(x0)')
e(SW(6,412,0),'sw x6, 412(x0)')
e(SW(7,416,0),'sw x7, 416(x0)')
e(CSRR(8,MISA),'csrr x8, misa')
e(SW(8,420,0),'sw x8, 420(x0)')
e(CSRR(9,CYCLE),'csrr x9, cycle')
e(ADDI(16,0,0),'addi x16, x0, 0      # 8 条填充，拉开两次 rdcycle')
for k in range(7):
    e(ADDI(16,16,1),'addi x16, x16, 1')
e(CSRR(10,CYCLE),'csrr x10, cycle')
e(SUB(11,10,9),'sub x11, x10, x9')
e(SW(11,424,0),'sw x11, 424(x0)')
e(ECALL,'ecall')
e(ADDI(12,0,0xE),'addi x12, x0, 0xE')
e(SW(12,428,0),'sw x12, 428(x0)')
e(EBREAK,'ebreak')
e(ADDI(13,0,0xB),'addi x13, x0, 0xB')
e(SW(13,432,0),'sw x13, 432(x0)')
e(0xFFFFFFFF,'.word 0xffffffff')
e(ADDI(14,0,0x11),'addi x14, x0, 0x11')
e(SW(14,436,0),'sw x14, 436(x0)')
e(ADDI(15,0,0xBAD),'addi x15, x0, 0xBAD  # 非对齐 store 若漏写会落到 word 0')
e(LW(15,2,0),'lw x15, 2(x0)')
e(ADDI(1,0,0x22),'addi x1, x0, 0x22')
e(SW(1,440,0),'sw x1, 440(x0)')
e(SW(15,2,0),'sw x15, 2(x0)')
e(ADDI(2,0,0x33),'addi x2, x0, 0x33')
e(SW(2,444,0),'sw x2, 444(x0)')
e(CSRRW(0,CYCLE,2),'csrrw x0, cycle, x2')
e(ADDI(3,0,0x44),'addi x3, x0, 0x44')
e(SW(3,448,0),'sw x3, 448(x0)')
e(CSRR(4,0x999),'csrr x4, 0x999')
e(ADDI(5,0,0x55),'addi x5, x0, 0x55')
e(SW(5,452,0),'sw x5, 452(x0)')
e(SW(28,456,0),'sw x28, 456(x0)')
e(SW(29,460,0),'sw x29, 460(x0)')
e(SW(31,464,0),'sw x31, 464(x0)')
e(SW(27,468,0),'sw x27, 468(x0)')
e(SW(25,472,0),'sw x25, 472(x0)')

# ── T8：M 扩展 ───────────────────────────────────────────────────────────────
# 这一段插在 done 标志之前、陷阱序列之后，所以前面那些陷阱 PC 偏移不受影响。
# DTCM 结果落在字 120 起，避开前面用掉的 0~5 和 100~118。
e(ADDI(1,0,100),'addi x1, x0, 100')
e(ADDI(2,0,7),'addi x2, x0, 7')
e(DIV(3,1,2),'div  x3, x1, x2        # 100/7 = 14')
e(SW(3,480,0),'sw x3, 480(x0)')
e(REM(4,1,2),'rem  x4, x1, x2        # 100%7 = 2')
e(SW(4,484,0),'sw x4, 484(x0)')
e(MUL(5,1,2),'mul  x5, x1, x2        # 700')
e(SW(5,488,0),'sw x5, 488(x0)')

# 关键一条：DIV 的 rs1 由上一条 addi 产生，中间隔着一条不相关的 lw。
# DIV 进 EX 那拍 lw 正在 MEM 等 DTCM，此时唯一能给出 x20 的前递源是刚退休的
# 那条 addi（MEM/WB）。若 start 被 memory_stall 推后一拍，前递源消失，
# 会退回 ID/EX 里读到的旧 x20 = 7，算出 7/7 = 1 而不是 100/7 = 14。
e(ADDI(21,0,7),'addi x21, x0, 7       # 除数先备好')
e(ADDI(20,0,7),'addi x20, x0, 7')
e(ADDI(20,0,100),'addi x20, x0, 100     # DIV 的 rs1 来自这一条')
e(LW(24,64,0),'lw   x24, 64(x0)      # 不相关访存，占住 MEM 两拍')
e(DIV(22,20,21),'div  x22, x20, x21    # 必须是 14，退化成 1 就说明前递丢了')
e(SW(22,492,0),'sw x22, 492(x0)')

# 背靠背：DONE 退出后要能立刻接下一次，且第二条要吃到第一条的 rd。
e(DIV(10,1,2),'div  x10, x1, x2       # 14')
e(DIV(11,10,2),'div  x11, x10, x2     # 14/7 = 2')
e(SW(11,496,0),'sw x11, 496(x0)')

# 规范强制的边界
e(DIVU(12,0,0),'divu x12, x0, x0       # 除零 → 商全 1')
e(SW(12,500,0),'sw x12, 500(x0)')
e(ADDI(13,0,-5),'addi x13, x0, -5')
e(REM(14,13,0),'rem  x14, x13, x0     # 除零余数 = 被除数')
e(SW(14,504,0),'sw x14, 504(x0)')
e(LUI(15,0x80000),'lui  x15, 0x80000     # INT_MIN')
e(ADDI(16,0,-1),'addi x16, x0, -1')
e(DIV(17,15,16),'div  x17, x15, x16    # INT_MIN/-1 不陷入')
e(SW(17,508,0),'sw x17, 508(x0)')

# 高半字通路：mulh 和 mulhsu 的符号修正
e(MULH(18,15,15),'mulh x18, x15, x15    # 2^62 的高半字')
e(SW(18,512,0),'sw x18, 512(x0)')
e(ADDI(23,0,2),'addi x23, x0, 2')
e(MULHSU(19,15,23),'mulhsu x19, x15, x23  # -2^32 的高半字')
e(SW(19,516,0),'sw x19, 516(x0)')

e(ADDI(11,0,1),'addi x11, x0, 1')
e(SW(11,20,0),'sw x11, 20(x0)')
e(J(0,0,0x6F),'jal x0, 0')

h=[]
h.append((CSRR(26,MSTATUS),'csrr x26, mstatus'))
h.append((ADD(25,25,26),'add x25, x25, x26'))
h.append((CSRR(26,MTVAL),'csrr x26, mtval'))
h.append((ADD(27,27,26),'add x27, x27, x26'))
h.append((CSRR(26,MCAUSE),'csrr x26, mcause'))
h.append((ADD(29,29,26),'add x29, x29, x26'))
h.append((ADDI(28,28,1),'addi x28, x28, 1'))
h.append((CSRR(30,MEPC),'csrr x30, mepc'))
h.append((ADD(31,31,30),'add x31, x31, x30'))
h.append((ADDI(30,30,4),'addi x30, x30, 4'))
h.append((CSRW(MEPC,30),'csrw mepc, x30'))
h.append((MRET,'mret'))

base=100
# 处理程序地址从 200 上移到 220：T8 段把程序撑到字 217，200 会撞上。
# 上移后 mtvec 要跟着改成 220*4 = 0x370（TB 里那条 addi x1, x0, 0x370）。
HANDLER_BASE=220
for k,(w,c) in enumerate(prog):
    print("    u_dut.u_itcm.memory[%d] = 32'h%08x; // %s" % (base+k, w, c))
print()
for k,(w,c) in enumerate(h):
    print("    u_dut.u_itcm.memory[%d] = 32'h%08x; // %s" % (HANDLER_BASE+k, w, c))
print()
print("prog 占字 %d..%d，处理程序占字 %d..%d"
      % (base, base+len(prog)-1, HANDLER_BASE, HANDLER_BASE+len(h)-1))

trap_off=[32,35,38,42,45,48,51]
pcs=[(base+k)*4 for k in trap_off]
mc=[11,3,2,4,6,2,2]
tv=[0,0,0xFFFFFFFF,2,2,prog[48][0],prog[51][0]]
print("count   = %d" % len(pcs))
print("mcause  = %d (0x%x)" % (sum(mc), sum(mc)))
print("mepc    = %d (0x%x)" % (sum(pcs), sum(pcs)))
print("mtval   = 0x%08x" % (sum(tv) & 0xFFFFFFFF))
print("mstatus = 0x%08x" % ((0x1880*7) & 0xFFFFFFFF))
print("pcs     =", ["0x%x"%p for p in pcs])
print("enc ro-write = 0x%08x, enc unknown = 0x%08x" % (prog[41][0], prog[44][0]))
print("jal-to-100 = 0x%08x" % J(8,0,0x6F))
