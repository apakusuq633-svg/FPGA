OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
 ITCM (rx) : ORIGIN = 0, LENGTH = 16K
 DTCM (rw) : ORIGIN = 0, LENGTH = 16K
 DLMA (rw) : ORIGIN = 0x10000000, LENGTH = 16K
}
SECTIONS {
 .text : { KEEP(*(.text.start)) *(.text*) . = ALIGN(4); } > ITCM
 .data 0 : { *(.rodata*) *(.srodata*) *(.data*) *(.sdata*) . = ALIGN(4); } > DTCM AT> DLMA
 .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > DTCM
 ASSERT(_bss_end <= 0x2800, "live16 data overlaps results")
 .results 0x2800 (NOLOAD) : { . += 0x400; } > DTCM
 _stack_top = 0x3ff0;
 /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
