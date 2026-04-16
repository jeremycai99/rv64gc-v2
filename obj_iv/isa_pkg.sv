/* file: isa_pkg.sv
 Description: ISA-level constants, CSR addresses, and opcode definitions.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef ISA_PKG_SV
`define ISA_PKG_SV
package isa_pkg;

    // =========================================================================
    // Major opcodes (bits [6:0])
    // =========================================================================
    localparam logic [6:0] OP_LUI       = 7'b0110111;
    localparam logic [6:0] OP_AUIPC     = 7'b0010111;
    localparam logic [6:0] OP_JAL       = 7'b1101111;
    localparam logic [6:0] OP_JALR      = 7'b1100111;
    localparam logic [6:0] OP_BRANCH    = 7'b1100011;
    localparam logic [6:0] OP_LOAD      = 7'b0000011;
    localparam logic [6:0] OP_LOAD_FP   = 7'b0000111;
    localparam logic [6:0] OP_STORE     = 7'b0100011;
    localparam logic [6:0] OP_STORE_FP  = 7'b0100111;
    localparam logic [6:0] OP_OP_IMM    = 7'b0010011;
    localparam logic [6:0] OP_OP        = 7'b0110011;
    localparam logic [6:0] OP_OP_IMM_32 = 7'b0011011;
    localparam logic [6:0] OP_OP_32     = 7'b0111011;
    localparam logic [6:0] OP_AMO       = 7'b0101111;
    localparam logic [6:0] OP_MISC_MEM  = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM    = 7'b1110011;
    localparam logic [6:0] OP_FP        = 7'b1010011;
    localparam logic [6:0] OP_FMADD     = 7'b1000011;
    localparam logic [6:0] OP_FMSUB     = 7'b1000111;
    localparam logic [6:0] OP_FNMSUB    = 7'b1001011;
    localparam logic [6:0] OP_FNMADD    = 7'b1001111;

    // =========================================================================
    // Funct3 for BRANCH
    // =========================================================================
    localparam logic [2:0] F3_BEQ  = 3'b000;
    localparam logic [2:0] F3_BNE  = 3'b001;
    localparam logic [2:0] F3_BLT  = 3'b100;
    localparam logic [2:0] F3_BGE  = 3'b101;
    localparam logic [2:0] F3_BLTU = 3'b110;
    localparam logic [2:0] F3_BGEU = 3'b111;

    // =========================================================================
    // Funct3 for LOAD
    // =========================================================================
    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LD  = 3'b011;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;
    localparam logic [2:0] F3_LWU = 3'b110;

    // =========================================================================
    // Funct3 for STORE
    // =========================================================================
    localparam logic [2:0] F3_SB = 3'b000;
    localparam logic [2:0] F3_SH = 3'b001;
    localparam logic [2:0] F3_SW = 3'b010;
    localparam logic [2:0] F3_SD = 3'b011;

    // =========================================================================
    // Funct3 for OP_IMM / OP (base integer)
    // =========================================================================
    localparam logic [2:0] F3_ADD_SUB = 3'b000;
    localparam logic [2:0] F3_SLL     = 3'b001;
    localparam logic [2:0] F3_SLT     = 3'b010;
    localparam logic [2:0] F3_SLTU    = 3'b011;
    localparam logic [2:0] F3_XOR     = 3'b100;
    localparam logic [2:0] F3_SRL_SRA = 3'b101;
    localparam logic [2:0] F3_OR      = 3'b110;
    localparam logic [2:0] F3_AND     = 3'b111;

    // =========================================================================
    // Funct7 for OP (R-type, base integer)
    // =========================================================================
    localparam logic [6:0] F7_NORMAL  = 7'b0000000;
    localparam logic [6:0] F7_SUB_SRA = 7'b0100000;
    localparam logic [6:0] F7_MULDIV  = 7'b0000001;

    // =========================================================================
    // Funct3 for M-extension (funct7 = F7_MULDIV)
    // =========================================================================
    localparam logic [2:0] F3_MUL    = 3'b000;
    localparam logic [2:0] F3_MULH   = 3'b001;
    localparam logic [2:0] F3_MULHSU = 3'b010;
    localparam logic [2:0] F3_MULHU  = 3'b011;
    localparam logic [2:0] F3_DIV    = 3'b100;
    localparam logic [2:0] F3_DIVU   = 3'b101;
    localparam logic [2:0] F3_REM    = 3'b110;
    localparam logic [2:0] F3_REMU   = 3'b111;

    // =========================================================================
    // FP funct7 encodings
    // =========================================================================
    localparam logic [6:0] F7_FADD_S          = 7'b0000000;
    localparam logic [6:0] F7_FADD_D          = 7'b0000001;
    localparam logic [6:0] F7_FSUB_S          = 7'b0000100;
    localparam logic [6:0] F7_FSUB_D          = 7'b0000101;
    localparam logic [6:0] F7_FMUL_S          = 7'b0001000;
    localparam logic [6:0] F7_FMUL_D          = 7'b0001001;
    localparam logic [6:0] F7_FDIV_S          = 7'b0001100;
    localparam logic [6:0] F7_FDIV_D          = 7'b0001101;
    localparam logic [6:0] F7_FSGNJ_S         = 7'b0010000;
    localparam logic [6:0] F7_FSGNJ_D         = 7'b0010001;
    localparam logic [6:0] F7_FMINMAX_S       = 7'b0010100;
    localparam logic [6:0] F7_FMINMAX_D       = 7'b0010101;
    localparam logic [6:0] F7_FSQRT_S         = 7'b0101100;
    localparam logic [6:0] F7_FSQRT_D         = 7'b0101101;
    localparam logic [6:0] F7_FCVT_S_D        = 7'b0100000;
    localparam logic [6:0] F7_FCVT_D_S        = 7'b0100001;
    localparam logic [6:0] F7_FCMP_S          = 7'b1010000;
    localparam logic [6:0] F7_FCMP_D          = 7'b1010001;
    localparam logic [6:0] F7_FCVT_TO_INT_S   = 7'b1100000;
    localparam logic [6:0] F7_FCVT_TO_INT_D   = 7'b1100001;
    localparam logic [6:0] F7_FCVT_FROM_INT_S = 7'b1101000;
    localparam logic [6:0] F7_FCVT_FROM_INT_D = 7'b1101001;
    localparam logic [6:0] F7_FMV_X_W         = 7'b1110000;
    localparam logic [6:0] F7_FMV_X_D         = 7'b1110001;
    localparam logic [6:0] F7_FMV_W_X         = 7'b1111000;
    localparam logic [6:0] F7_FMV_D_X         = 7'b1111001;

    // FP funct3
    localparam logic [2:0] F3_FSGNJ  = 3'b000;
    localparam logic [2:0] F3_FSGNJN = 3'b001;
    localparam logic [2:0] F3_FSGNJX = 3'b010;
    localparam logic [2:0] F3_FMIN   = 3'b000;
    localparam logic [2:0] F3_FMAX   = 3'b001;
    localparam logic [2:0] F3_FLE    = 3'b000;
    localparam logic [2:0] F3_FLT    = 3'b001;
    localparam logic [2:0] F3_FEQ    = 3'b010;
    localparam logic [2:0] F3_FCLASS = 3'b001;
    localparam logic [2:0] F3_FMV    = 3'b000;

    // FP rs2 field encodings
    localparam logic [4:0] FP_RS2_ZERO = 5'd0;
    localparam logic [4:0] FP_RS2_S    = 5'd0;
    localparam logic [4:0] FP_RS2_D    = 5'd1;
    localparam logic [4:0] FP_RS2_W    = 5'd0;
    localparam logic [4:0] FP_RS2_WU   = 5'd1;
    localparam logic [4:0] FP_RS2_L    = 5'd2;
    localparam logic [4:0] FP_RS2_LU   = 5'd3;

    // =========================================================================
    // AMO funct5 encodings (bits [31:27])
    // =========================================================================
    localparam logic [4:0] AMO_LR   = 5'b00010;
    localparam logic [4:0] AMO_SC   = 5'b00011;
    localparam logic [4:0] AMO_SWAP = 5'b00001;
    localparam logic [4:0] AMO_ADD  = 5'b00000;
    localparam logic [4:0] AMO_XOR  = 5'b00100;
    localparam logic [4:0] AMO_AND  = 5'b01100;
    localparam logic [4:0] AMO_OR   = 5'b01000;
    localparam logic [4:0] AMO_MIN  = 5'b10000;
    localparam logic [4:0] AMO_MAX  = 5'b10100;
    localparam logic [4:0] AMO_MINU = 5'b11000;
    localparam logic [4:0] AMO_MAXU = 5'b11100;

    // =========================================================================
    // Funct3 for SYSTEM (CSR)
    // =========================================================================
    localparam logic [2:0] F3_PRIV   = 3'b000;  // ECALL, EBREAK, MRET, SRET, WFI
    localparam logic [2:0] F3_CSRRW  = 3'b001;
    localparam logic [2:0] F3_CSRRS  = 3'b010;
    localparam logic [2:0] F3_CSRRC  = 3'b011;
    localparam logic [2:0] F3_CSRRWI = 3'b101;
    localparam logic [2:0] F3_CSRRSI = 3'b110;
    localparam logic [2:0] F3_CSRRCI = 3'b111;

    // =========================================================================
    // Funct12 for PRIV instructions
    // =========================================================================
    localparam logic [11:0] F12_ECALL  = 12'h000;
    localparam logic [11:0] F12_EBREAK = 12'h001;
    localparam logic [11:0] F12_MRET   = 12'h302;
    localparam logic [11:0] F12_SRET   = 12'h102;
    localparam logic [11:0] F12_WFI    = 12'h105;
    localparam logic [6:0]  F7_SFENCE_VMA = 7'b0001001;

    // =========================================================================
    // Funct3 for MISC_MEM
    // =========================================================================
    localparam logic [2:0] F3_FENCE   = 3'b000;
    localparam logic [2:0] F3_FENCE_I = 3'b001;

    // =========================================================================
    // Privilege modes
    // =========================================================================
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;

    // =========================================================================
    // Zba extension (address generation)
    // =========================================================================
    // sh1add/sh2add/sh3add on OP_OP
    localparam logic [6:0] F7_ZBA       = 7'b0010000;
    localparam logic [2:0] F3_SH1ADD    = 3'b010;
    localparam logic [2:0] F3_SH2ADD    = 3'b100;
    localparam logic [2:0] F3_SH3ADD    = 3'b110;

    // add.uw, sh*add.uw on OP_OP_32
    localparam logic [6:0] F7_ZBA_UW    = 7'b0000100;

    // slli.uw on OP_OP_IMM_32, funct7 = 0000100
    localparam logic [6:0] F7_SLLIUW    = 7'b0000100;

    // =========================================================================
    // Zbb extension (basic bit manipulation)
    // =========================================================================
    // min/max/minu/maxu on OP_OP
    localparam logic [6:0] F7_ZBB_MINMAX = 7'b0000101;
    localparam logic [2:0] F3_MIN        = 3'b100;
    localparam logic [2:0] F3_MAX        = 3'b110;
    localparam logic [2:0] F3_MINU       = 3'b101;
    localparam logic [2:0] F3_MAXU       = 3'b111;

    // andn/orn/xnor on OP_OP: funct7 = F7_SUB_SRA (0x20), funct3 = AND/OR/XOR
    // (reuse F7_SUB_SRA and F3_AND/F3_OR/F3_XOR)

    // rol/ror/rori on OP_OP
    localparam logic [6:0] F7_ZBB_ROT   = 7'b0110000;
    // ROL:  funct7=0x30, funct3=001 on OP_OP
    // ROR:  funct7=0x30, funct3=101 on OP_OP
    // RORI: funct7=0x30, funct3=101 on OP_OP_IMM (6-bit shamt for RV64)

    // clz/ctz/cpop on OP_OP_IMM, funct7=0x30, rs2 field encodes sub-op
    localparam logic [4:0] ZBB_CLZ      = 5'b00000;
    localparam logic [4:0] ZBB_CTZ      = 5'b00001;
    localparam logic [4:0] ZBB_CPOP     = 5'b00010;

    // sext.b/sext.h on OP_OP_IMM, funct7=0x30
    localparam logic [4:0] ZBB_SEXTB    = 5'b00100;
    localparam logic [4:0] ZBB_SEXTH    = 5'b00101;

    // rev8: OP_OP_IMM, funct12 = 0x6B8 (RV64)
    localparam logic [11:0] F12_REV8    = 12'h6B8;

    // orc.b: OP_OP_IMM, funct12 = 0x287
    localparam logic [11:0] F12_ORCB    = 12'h287;

    // clzw/ctzw/cpopw: OP_OP_IMM_32 variants (same rs2 encodings)

    // rolw/rorw: OP_OP_32, funct7=0x30
    // roriw: OP_OP_IMM_32, funct7=0x30

    // zext.h: OP_OP_32, funct7=0x04, funct3=100
    localparam logic [6:0] F7_ZEXTH     = 7'b0000100;
    localparam logic [2:0] F3_ZEXTH     = 3'b100;

    // =========================================================================
    // Zbs extension (single-bit operations)
    // =========================================================================
    // BCLR/BEXT on OP_OP (and BCLRI/BEXTI on OP_OP_IMM)
    localparam logic [6:0] F7_ZBS_BCLR_BEXT = 7'b0100100;
    localparam logic [2:0] F3_BCLR          = 3'b001;
    localparam logic [2:0] F3_BEXT          = 3'b101;

    // BINV on OP_OP (and BINVI on OP_OP_IMM)
    localparam logic [6:0] F7_ZBS_BINV      = 7'b0110100;
    localparam logic [2:0] F3_BINV          = 3'b001;

    // BSET on OP_OP (and BSETI on OP_OP_IMM)
    localparam logic [6:0] F7_ZBS_BSET      = 7'b0010100;
    localparam logic [2:0] F3_BSET          = 3'b001;

    // =========================================================================
    // Zicond extension (conditional operations)
    // =========================================================================
    localparam logic [6:0] F7_ZICOND       = 7'b0000111;
    localparam logic [2:0] F3_CZERO_EQZ    = 3'b101;
    localparam logic [2:0] F3_CZERO_NEZ    = 3'b111;

    // =========================================================================
    // CSR addresses
    // =========================================================================
    // User-level floating-point
    localparam logic [11:0] CSR_FFLAGS       = 12'h001;
    localparam logic [11:0] CSR_FRM          = 12'h002;
    localparam logic [11:0] CSR_FCSR         = 12'h003;

    // User-level counters
    localparam logic [11:0] CSR_CYCLE        = 12'hC00;
    localparam logic [11:0] CSR_TIME         = 12'hC01;
    localparam logic [11:0] CSR_INSTRET      = 12'hC02;

    // Supervisor-level
    localparam logic [11:0] CSR_SSTATUS      = 12'h100;
    localparam logic [11:0] CSR_SIE          = 12'h104;
    localparam logic [11:0] CSR_STVEC        = 12'h105;
    localparam logic [11:0] CSR_SCOUNTEREN   = 12'h106;
    localparam logic [11:0] CSR_SENVCFG      = 12'h10A;
    localparam logic [11:0] CSR_SSCRATCH     = 12'h140;
    localparam logic [11:0] CSR_SEPC         = 12'h141;
    localparam logic [11:0] CSR_SCAUSE       = 12'h142;
    localparam logic [11:0] CSR_STVAL        = 12'h143;
    localparam logic [11:0] CSR_SIP          = 12'h144;
    localparam logic [11:0] CSR_SATP         = 12'h180;

    // Machine-level
    localparam logic [11:0] CSR_MSTATUS      = 12'h300;
    localparam logic [11:0] CSR_MISA         = 12'h301;
    localparam logic [11:0] CSR_MEDELEG      = 12'h302;
    localparam logic [11:0] CSR_MIDELEG      = 12'h303;
    localparam logic [11:0] CSR_MIE          = 12'h304;
    localparam logic [11:0] CSR_MTVEC        = 12'h305;
    localparam logic [11:0] CSR_MCOUNTEREN   = 12'h306;
    localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
    localparam logic [11:0] CSR_MSCRATCH     = 12'h340;
    localparam logic [11:0] CSR_MEPC         = 12'h341;
    localparam logic [11:0] CSR_MCAUSE       = 12'h342;
    localparam logic [11:0] CSR_MTVAL        = 12'h343;
    localparam logic [11:0] CSR_MIP          = 12'h344;

    // Machine-level PMP
    localparam logic [11:0] CSR_PMPCFG0      = 12'h3A0;
    localparam logic [11:0] CSR_PMPADDR0     = 12'h3B0;

    // Machine-level debug/trigger
    localparam logic [11:0] CSR_TSELECT      = 12'h7A0;
    localparam logic [11:0] CSR_TDATA1       = 12'h7A1;
    localparam logic [11:0] CSR_TDATA2       = 12'h7A2;
    localparam logic [11:0] CSR_TCONTROL     = 12'h7A5;

    // Machine-level counters and ID
    localparam logic [11:0] CSR_MCYCLE       = 12'hB00;
    localparam logic [11:0] CSR_MINSTRET     = 12'hB02;
    localparam logic [11:0] CSR_MVENDORID    = 12'hF11;
    localparam logic [11:0] CSR_MARCHID      = 12'hF12;
    localparam logic [11:0] CSR_MIMPID       = 12'hF13;
    localparam logic [11:0] CSR_MHARTID      = 12'hF14;

    // =========================================================================
    // Exception codes (mcause)
    // =========================================================================
    localparam logic [3:0] EXC_INSN_MISALIGN    = 4'd0;
    localparam logic [3:0] EXC_INSN_ACCESS      = 4'd1;
    localparam logic [3:0] EXC_ILLEGAL_INSN     = 4'd2;
    localparam logic [3:0] EXC_BREAKPOINT       = 4'd3;
    localparam logic [3:0] EXC_LOAD_MISALIGN    = 4'd4;
    localparam logic [3:0] EXC_LOAD_ACCESS      = 4'd5;
    localparam logic [3:0] EXC_STORE_MISALIGN   = 4'd6;
    localparam logic [3:0] EXC_STORE_ACCESS     = 4'd7;
    localparam logic [3:0] EXC_ECALL_U          = 4'd8;
    localparam logic [3:0] EXC_ECALL_S          = 4'd9;
    localparam logic [3:0] EXC_ECALL_M          = 4'd11;
    localparam logic [3:0] EXC_INSN_PAGE_FAULT  = 4'd12;
    localparam logic [3:0] EXC_LOAD_PAGE_FAULT  = 4'd13;
    localparam logic [3:0] EXC_STORE_PAGE_FAULT = 4'd15;

    // =========================================================================
    // Interrupt cause codes / mip bit positions
    // =========================================================================
    localparam logic [5:0] IRQ_S_SOFT  = 6'd1;
    localparam logic [5:0] IRQ_M_SOFT  = 6'd3;
    localparam logic [5:0] IRQ_S_TIMER = 6'd5;
    localparam logic [5:0] IRQ_M_TIMER = 6'd7;
    localparam logic [5:0] IRQ_S_EXT   = 6'd9;
    localparam logic [5:0] IRQ_M_EXT   = 6'd11;

endpackage
`endif
