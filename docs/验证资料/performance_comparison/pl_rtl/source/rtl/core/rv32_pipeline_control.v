module rv32_pipeline_control (
  input  memory_stall_i,
  input  load_use_stall_i,
  input  fetch_pending_i,
  input  redirect_i,
  input  trap_i,
  input  halt_i,
  input  div_stall_i,
  input  vec_stall_i,
  // 声学扩展单元（funct3[2]=1 那半边）的多拍停顿。与 vec_stall_i 同样处理：
  // 冻 fetch / IF-ID / ID-EX，**不冻 EX-MEM**（那边收气泡，理由见 ex_mem_hold_o）。
  input  acou_stall_i,
  // VFFT（核内 FFT 单元）的多拍停顿。处理方式与 vec/acou 完全一致：
  // 冻 fetch / IF-ID / ID-EX，**不冻 EX-MEM**（那边收气泡）。
  input  fft_stall_i,
  output fetch_stall_o,
  output if_id_hold_o,
  output if_id_flush_o,
  output id_ex_hold_o,
  output id_ex_flush_o,
  output ex_mem_hold_o
);

  // 取指等待：存储器（ITCM/BRAM）是同步读，ready 比 req 晚一拍，
  // 在等待的那一拍前端拿不到新指令，IF/ID 必须保持。
  // 但 rv_pipeline_reg 里 hold 的优先级高于 flush，重定向那一拍必须让 flush 生效，
  // 否则错误路径上的指令会被留在 IF/ID 里继续译码，所以这里把 redirect 排除掉。
  wire fetch_hold;
  assign fetch_hold = fetch_pending_i & ~redirect_i;

  // 数据端口反压：DTCM 一个操作占两拍，等待拍同时冻结 EX/MEM（保住读地址）、
  // ID/EX 和 IF/ID。load_use_stall 与 memory_stall 同拍时 id_ex_hold 会吞掉
  // id_ex_flush（hold 优先于 flush），但互锁输入在冻结期间没变、解冻那拍会重新
  // 成立，不会漏 flush；redirect 则被 ex_stage_valid 限定，撞不上这种屏蔽。

  // 陷入同样要压过 hold：MEM 级陷入时 EX 里的年轻指令可能正被 load-use 互锁，
  // 若 hold 吃掉 IF/ID 的 flush，那条错误路径的指令会留到陷入之后执行。
  // PS 的 halt 是硬冻结：整条流水原地停住，解除后从原状态继续。
  // 它压过一切 —— 核侧已经把 trap/ex_redirect/ex_mret 三个重定向源都乘上 ~halt_i，
  // 所以这里不需要 ~redirect_i 那种掩码（掩码写错会让 hold 吃掉 flush，静默吞掉陷阱）。
  // 除法（M 扩展）多拍，期间和 memory_stall 一样冻结前端。div_stall 必须进
  // fetch_stall：漏了会让 PC 在 IF/ID 冻结时一路跑飞，解冻后指令流静默跳段。
  // 也要放在 if_id_hold 的 ~trap_i 掩码里 —— 陷入落在除法启动那拍时仍须能冲刷 IF/ID。
  // 阵列（OP-V）多拍，走的是和除法**完全一样**的路子：stall 进 fetch_stall 与
  // 两个 hold，EX/MEM 收气泡而不是冻结。理由见 rv32_core.v 里 EX/MEM valid_i 那一段。
  assign fetch_stall_o = memory_stall_i | load_use_stall_i | halt_i |
                         div_stall_i | vec_stall_i | acou_stall_i | fft_stall_i;
  assign if_id_hold_o  = (memory_stall_i | load_use_stall_i | fetch_hold | halt_i |
                          div_stall_i | vec_stall_i | acou_stall_i |
                          fft_stall_i) & ~trap_i;
  assign if_id_flush_o = redirect_i;
  assign id_ex_hold_o  = (memory_stall_i | halt_i | div_stall_i |
                          vec_stall_i | acou_stall_i | fft_stall_i) & ~trap_i;
  // IF/ID 一旦保持，ID 就会把同一条指令连续译码两拍，ID/EX 必须同时清空，
  // 否则这条指令会被重复送进 EX 执行两次（memory_stall/halt 时由 id_ex_hold 整体冻结，不受影响）。
  assign id_ex_flush_o = redirect_i | load_use_stall_i | fetch_hold;
  // 故意不加 div_stall：除法期间 EX/MEM 要能收气泡、MEM 里的老指令要能正常退休。
  assign ex_mem_hold_o = memory_stall_i | halt_i;

endmodule
