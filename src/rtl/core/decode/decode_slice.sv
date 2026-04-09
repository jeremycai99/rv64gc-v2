/* file: decode_slice.sv
 Description: Single-slot RV64GC instruction decoder.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module decode_slice
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic [31:0]   insn,
    input  logic [63:0]   pc,
    input  logic          is_rvc,     // was this a compressed insn (PC+2 vs PC+4)
    output decoded_insn_t decoded
);

    // ---------------------------------------------------------------
    // Field extraction
    // ---------------------------------------------------------------
    wire [6:0]  opcode  = insn[6:0];
    wire [4:0]  rd_f    = insn[11:7];
    wire [2:0]  funct3  = insn[14:12];
    wire [4:0]  rs1_f   = insn[19:15];
    wire [4:0]  rs2_f   = insn[24:20];
    wire [6:0]  funct7  = insn[31:25];
    wire [11:0] funct12 = insn[31:20];

    // ---------------------------------------------------------------
    // Immediate generation
    // ---------------------------------------------------------------
    wire [63:0] imm_i = {{52{insn[31]}}, insn[31:20]};
    wire [63:0] imm_s = {{52{insn[31]}}, insn[31:25], insn[11:7]};
    wire [63:0] imm_b = {{51{insn[31]}}, insn[31], insn[7],
                          insn[30:25], insn[11:8], 1'b0};
    wire [63:0] imm_u = {{32{insn[31]}}, insn[31:12], 12'b0};
    wire [63:0] imm_j = {{43{insn[31]}}, insn[31], insn[19:12],
                          insn[20], insn[30:21], 1'b0};

    // ---------------------------------------------------------------
    // Main decode logic
    // ---------------------------------------------------------------
    always_comb begin
        // --- Default all fields ---
        decoded.valid          = 1'b1;
        decoded.pc             = pc;
        decoded.insn           = insn;
        decoded.rs1_arch       = rs1_f;
        decoded.rs2_arch       = rs2_f;
        decoded.rd_arch        = rd_f;
        decoded.rs1_valid      = 1'b0;
        decoded.rs2_valid      = 1'b0;
        decoded.rd_valid       = 1'b0;
        decoded.imm            = 64'd0;
        decoded.fu_type        = FU_ALU;
        decoded.alu_op         = ALU_ADD;
        decoded.br_op          = BR_EQ;
        decoded.mul_op         = MUL_MUL;
        decoded.div_op         = DIV_DIV;
        decoded.mem_size       = MEM_BYTE;
        decoded.csr_op         = CSR_NONE;
        decoded.csr_addr       = 12'd0;
        decoded.is_branch      = 1'b0;
        decoded.is_jal         = 1'b0;
        decoded.is_jalr        = 1'b0;
        decoded.is_load        = 1'b0;
        decoded.is_store       = 1'b0;
        decoded.is_csr         = 1'b0;
        decoded.is_mul         = 1'b0;
        decoded.is_div         = 1'b0;
        decoded.is_w_op        = 1'b0;
        decoded.is_unsigned    = 1'b0;
        decoded.use_imm        = 1'b0;
        decoded.is_fence       = 1'b0;
        decoded.is_fence_i     = 1'b0;
        decoded.is_ecall       = 1'b0;
        decoded.is_ebreak      = 1'b0;
        decoded.is_mret        = 1'b0;
        decoded.is_sret        = 1'b0;
        decoded.is_sfence_vma  = 1'b0;
        decoded.is_wfi         = 1'b0;
        decoded.is_amo         = 1'b0;
        decoded.amo_op         = 5'd0;
        decoded.amo_aq         = 1'b0;
        decoded.amo_rl         = 1'b0;
        decoded.is_rvc         = is_rvc;
        decoded.bp_taken       = 1'b0;
        decoded.bp_target      = 64'd0;
        decoded.has_exception  = 1'b0;
        decoded.exc_code       = 4'd0;
        // v2 fusion fields (initialized to 0, fusion_detector fills later)
        decoded.is_fused       = 1'b0;
        decoded.fused_imm      = 32'd0;
        decoded.fusion_type    = 3'd0;

        case (opcode)
            // =============================================================
            // LUI
            // =============================================================
            OP_LUI: begin
                decoded.alu_op   = ALU_LUI;
                decoded.rd_valid = 1'b1;
                decoded.imm      = imm_u;
                decoded.use_imm  = 1'b1;
            end

            // =============================================================
            // AUIPC
            // =============================================================
            OP_AUIPC: begin
                decoded.alu_op   = ALU_PASS2;
                decoded.rd_valid = 1'b1;
                decoded.imm      = imm_u;
                decoded.use_imm  = 1'b1;
            end

            // =============================================================
            // JAL
            // =============================================================
            OP_JAL: begin
                decoded.fu_type   = FU_BRU;
                decoded.br_op     = BR_JAL;
                decoded.rd_valid  = 1'b1;
                decoded.is_jal    = 1'b1;
                decoded.imm       = imm_j;
            end

            // =============================================================
            // JALR
            // =============================================================
            OP_JALR: begin
                decoded.fu_type   = FU_BRU;
                decoded.br_op     = BR_JALR;
                decoded.rs1_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.is_jalr   = 1'b1;
                decoded.imm       = imm_i;
                decoded.use_imm   = 1'b1;
                if (funct3 != 3'b000) begin
                    decoded.has_exception = 1'b1;
                    decoded.exc_code      = EXC_ILLEGAL_INSN;
                end
            end

            // =============================================================
            // BRANCH
            // =============================================================
            OP_BRANCH: begin
                decoded.fu_type   = FU_BRU;
                decoded.rs1_valid = 1'b1;
                decoded.rs2_valid = 1'b1;
                decoded.is_branch = 1'b1;
                decoded.imm       = imm_b;
                case (funct3)
                    F3_BEQ:  decoded.br_op = BR_EQ;
                    F3_BNE:  decoded.br_op = BR_NE;
                    F3_BLT:  decoded.br_op = BR_LT;
                    F3_BGE:  decoded.br_op = BR_GE;
                    F3_BLTU: decoded.br_op = BR_LTU;
                    F3_BGEU: decoded.br_op = BR_GEU;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // LOAD
            // =============================================================
            OP_LOAD: begin
                decoded.fu_type   = FU_LOAD;
                decoded.rs1_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.is_load   = 1'b1;
                decoded.imm       = imm_i;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_LB:  decoded.mem_size = MEM_BYTE;
                    F3_LH:  decoded.mem_size = MEM_HALF;
                    F3_LW:  decoded.mem_size = MEM_WORD;
                    F3_LD:  decoded.mem_size = MEM_DWORD;
                    F3_LBU: begin decoded.mem_size = MEM_BYTE; decoded.is_unsigned = 1'b1; end
                    F3_LHU: begin decoded.mem_size = MEM_HALF; decoded.is_unsigned = 1'b1; end
                    F3_LWU: begin decoded.mem_size = MEM_WORD; decoded.is_unsigned = 1'b1; end
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // STORE
            // =============================================================
            OP_STORE: begin
                decoded.fu_type   = FU_STA;
                decoded.rs1_valid = 1'b1;
                decoded.rs2_valid = 1'b1;
                decoded.is_store  = 1'b1;
                decoded.imm       = imm_s;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_SB: decoded.mem_size = MEM_BYTE;
                    F3_SH: decoded.mem_size = MEM_HALF;
                    F3_SW: decoded.mem_size = MEM_WORD;
                    F3_SD: decoded.mem_size = MEM_DWORD;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // AMO
            // =============================================================
            OP_AMO: begin
                decoded.amo_op = insn[31:27];
                decoded.amo_aq = insn[26];
                decoded.amo_rl = insn[25];
                decoded.imm    = 64'd0;
                case (funct3)
                    3'b010: decoded.mem_size = MEM_WORD;
                    3'b011: decoded.mem_size = MEM_DWORD;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
                if (!decoded.has_exception) begin
                    if (insn[31:27] == AMO_LR) begin
                        decoded.fu_type   = FU_LOAD;
                        decoded.rs1_valid = 1'b1;
                        decoded.rd_valid  = 1'b1;
                        decoded.is_load   = 1'b1;
                        decoded.rs2_valid = 1'b0;
                        decoded.is_amo    = 1'b1;
                    end else begin
                        decoded.fu_type   = FU_STA;
                        decoded.rs1_valid = 1'b1;
                        decoded.rs2_valid = 1'b1;
                        decoded.rd_valid  = 1'b1;
                        decoded.is_store  = 1'b1;
                        decoded.is_amo    = 1'b1;
                    end
                end
            end

            // =============================================================
            // LOAD_FP (FLD/FLW)
            // =============================================================
            OP_LOAD_FP: begin
                decoded.fu_type   = FU_LOAD;
                decoded.rs1_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.is_load   = 1'b1;
                decoded.imm       = imm_i;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_LW:   decoded.mem_size = MEM_WORD;
                    F3_LD:   decoded.mem_size = MEM_DWORD;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // STORE_FP (FSD/FSW)
            // =============================================================
            OP_STORE_FP: begin
                decoded.fu_type   = FU_STA;
                decoded.rs1_valid = 1'b1;
                decoded.rs2_valid = 1'b1;
                decoded.is_store  = 1'b1;
                decoded.imm       = imm_s;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_SW:   decoded.mem_size = MEM_WORD;
                    F3_SD:   decoded.mem_size = MEM_DWORD;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // OP_IMM (ADDI, SLTI, etc. + Zbb RORI/CLZ/CTZ/CPOP/SEXTB/SEXTH/REV8/ORCB
            //         + Zbs BSETI/BCLRI/BINVI/BEXTI)
            // =============================================================
            OP_OP_IMM: begin
                decoded.rs1_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.imm       = imm_i;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_ADD_SUB: begin
                        // ADDI (no funct7 check for OP_IMM add)
                        decoded.alu_op = ALU_ADD;
                    end
                    F3_SLT: begin
                        decoded.alu_op = ALU_SLT;
                    end
                    F3_SLTU: begin
                        decoded.alu_op = ALU_SLTU;
                    end
                    F3_XOR: begin
                        // XOR or ORC.B (funct12=0x287)
                        if (funct12 == F12_ORCB) begin
                            decoded.alu_op = ALU_ORCB;
                            decoded.rs2_arch = 5'd0; // no rs2
                        end else begin
                            decoded.alu_op = ALU_XOR;
                        end
                    end
                    F3_OR: begin
                        decoded.alu_op = ALU_OR;
                    end
                    F3_AND: begin
                        // AND or REV8 (funct12=0x6B8)
                        if (funct12 == F12_REV8) begin
                            decoded.alu_op = ALU_REV8;
                            decoded.rs2_arch = 5'd0; // no rs2
                        end else begin
                            decoded.alu_op = ALU_AND;
                        end
                    end
                    F3_SLL: begin
                        // SLL / CLZ / CTZ / CPOP / SEXTB / SEXTH / BSET(I)
                        if (insn[31:26] == 6'b000000) begin
                            decoded.alu_op = ALU_SLL;    // SLLI
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CLZ) begin
                            decoded.alu_op = ALU_CLZ;    // CLZ
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CTZ) begin
                            decoded.alu_op = ALU_CTZ;    // CTZ
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CPOP) begin
                            decoded.alu_op = ALU_CPOP;   // CPOP
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_SEXTB) begin
                            decoded.alu_op = ALU_SEXTB;  // SEXT.B
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_SEXTH) begin
                            decoded.alu_op = ALU_SEXTH;  // SEXT.H
                        end else if (insn[31:26] == F7_ZBS_BSET[6:1]) begin
                            decoded.alu_op = ALU_BSET;   // BSETI
                        end else if (insn[31:26] == F7_ZBS_BCLR_BEXT[6:1]) begin
                            decoded.alu_op = ALU_BCLR;   // BCLRI
                        end else if (insn[31:26] == F7_ZBS_BINV[6:1]) begin
                            decoded.alu_op = ALU_BINV;   // BINVI
                        end else begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    end
                    F3_SRL_SRA: begin
                        // SRLI / SRAI / RORI / BEXTI
                        if (insn[31:26] == 6'b000000) begin
                            decoded.alu_op = ALU_SRL;    // SRLI
                        end else if (insn[31:26] == 6'b010000) begin
                            decoded.alu_op = ALU_SRA;    // SRAI
                        end else if (insn[31:26] == F7_ZBB_ROT[6:1]) begin
                            decoded.alu_op = ALU_ROR;    // RORI (6-bit shamt)
                        end else if (insn[31:26] == F7_ZBS_BCLR_BEXT[6:1]) begin
                            decoded.alu_op = ALU_BEXT;   // BEXTI
                        end else begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    end
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // OP (R-type: base ALU + M-ext + Zba/Zbb/Zbs/Zicond)
            // =============================================================
            OP_OP: begin
                decoded.rs1_valid = 1'b1;
                decoded.rs2_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                if (funct7 == F7_MULDIV) begin
                    // M extension
                    case (funct3)
                        F3_MUL:    begin decoded.fu_type = FU_MUL; decoded.is_mul = 1'b1; decoded.mul_op = MUL_MUL;    end
                        F3_MULH:   begin decoded.fu_type = FU_MUL; decoded.is_mul = 1'b1; decoded.mul_op = MUL_MULH;   end
                        F3_MULHSU: begin decoded.fu_type = FU_MUL; decoded.is_mul = 1'b1; decoded.mul_op = MUL_MULHSU; end
                        F3_MULHU:  begin decoded.fu_type = FU_MUL; decoded.is_mul = 1'b1; decoded.mul_op = MUL_MULHU;  end
                        F3_DIV:    begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_DIV;    end
                        F3_DIVU:   begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_DIVU;   end
                        F3_REM:    begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_REM;    end
                        F3_REMU:   begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_REMU;   end
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBA) begin
                    // Zba: sh1add / sh2add / sh3add
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_SH1ADD: decoded.alu_op = ALU_SH1ADD;
                        F3_SH2ADD: decoded.alu_op = ALU_SH2ADD;
                        F3_SH3ADD: decoded.alu_op = ALU_SH3ADD;
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBB_MINMAX) begin
                    // Zbb: min / max / minu / maxu
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_MIN:  decoded.alu_op = ALU_MIN;
                        F3_MAX:  decoded.alu_op = ALU_MAX;
                        F3_MINU: decoded.alu_op = ALU_MINU;
                        F3_MAXU: decoded.alu_op = ALU_MAXU;
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBB_ROT) begin
                    // Zbb: ROL / ROR
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_SLL:     decoded.alu_op = ALU_ROL; // ROL: f7=0x30, f3=001
                        F3_SRL_SRA: decoded.alu_op = ALU_ROR; // ROR: f7=0x30, f3=101
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBS_BSET) begin
                    // Zbs: BSET
                    decoded.fu_type = FU_ALU;
                    if (funct3 == F3_BSET) decoded.alu_op = ALU_BSET;
                    else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                end else if (funct7 == F7_ZBS_BCLR_BEXT) begin
                    // Zbs: BCLR / BEXT
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_BCLR: decoded.alu_op = ALU_BCLR;
                        F3_BEXT: decoded.alu_op = ALU_BEXT;
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBS_BINV) begin
                    // Zbs: BINV
                    decoded.fu_type = FU_ALU;
                    if (funct3 == F3_BINV) decoded.alu_op = ALU_BINV;
                    else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                end else if (funct7 == F7_ZICOND) begin
                    // Zicond: czero.eqz / czero.nez
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_CZERO_EQZ: decoded.alu_op = ALU_CZERO_EQZ;
                        F3_CZERO_NEZ: decoded.alu_op = ALU_CZERO_NEZ;
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else begin
                    // Base integer R-type
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_ADD_SUB: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_ADD;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_SUB;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SLL: begin
                            if (funct7 == F7_NORMAL) decoded.alu_op = ALU_SLL;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SLT: begin
                            if (funct7 == F7_NORMAL) decoded.alu_op = ALU_SLT;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SLTU: begin
                            if (funct7 == F7_NORMAL) decoded.alu_op = ALU_SLTU;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_XOR: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_XOR;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_XNOR; // Zbb XNOR
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SRL_SRA: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_SRL;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_SRA;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_OR: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_OR;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_ORN; // Zbb ORN
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_AND: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_AND;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_ANDN; // Zbb ANDN
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        default: begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    endcase
                end
            end

            // =============================================================
            // OP_IMM_32 (ADDIW, SLLIW, SRLIW, SRAIW
            //            + Zbb CLZW/CTZW/CPOPW/RORIW
            //            + Zba SLLI.UW)
            // =============================================================
            OP_OP_IMM_32: begin
                decoded.rs1_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.is_w_op   = 1'b1;
                decoded.imm       = imm_i;
                decoded.use_imm   = 1'b1;
                case (funct3)
                    F3_ADD_SUB: begin
                        decoded.alu_op = ALU_ADD; // ADDIW
                    end
                    F3_SLL: begin
                        if (funct7 == F7_NORMAL) begin
                            decoded.alu_op = ALU_SLL; // SLLIW
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CLZ) begin
                            decoded.alu_op = ALU_CLZ; // CLZW
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CTZ) begin
                            decoded.alu_op = ALU_CTZ; // CTZW
                        end else if (funct7 == F7_ZBB_ROT && rs2_f == ZBB_CPOP) begin
                            decoded.alu_op = ALU_CPOP; // CPOPW
                        end else if (funct7 == F7_SLLIUW) begin
                            decoded.alu_op = ALU_SLL; // SLLI.UW (Zba)
                            // The ALU should treat this as unsigned word shift
                            // is_w_op already set, execution handles UW semantics
                            decoded.is_unsigned = 1'b1;
                        end else begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    end
                    F3_SRL_SRA: begin
                        if (funct7 == F7_NORMAL) begin
                            decoded.alu_op = ALU_SRL; // SRLIW
                        end else if (funct7 == F7_SUB_SRA) begin
                            decoded.alu_op = ALU_SRA; // SRAIW
                        end else if (funct7 == F7_ZBB_ROT) begin
                            decoded.alu_op = ALU_ROR; // RORIW
                        end else begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    end
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // OP_32 (ADDW, SUBW, SLLW, SRLW, SRAW, MULW, DIVW, etc.
            //        + Zba ADD.UW/SH*ADD.UW
            //        + Zbb ROLW/RORW/ZEXT.H)
            // =============================================================
            OP_OP_32: begin
                decoded.rs1_valid = 1'b1;
                decoded.rs2_valid = 1'b1;
                decoded.rd_valid  = 1'b1;
                decoded.is_w_op   = 1'b1;
                if (funct7 == F7_MULDIV) begin
                    // M extension W variants
                    case (funct3)
                        F3_MUL:  begin decoded.fu_type = FU_MUL; decoded.is_mul = 1'b1; decoded.mul_op = MUL_MUL;  end
                        F3_DIV:  begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_DIV;  end
                        F3_DIVU: begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_DIVU; end
                        F3_REM:  begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_REM;  end
                        F3_REMU: begin decoded.fu_type = FU_DIV; decoded.is_div = 1'b1; decoded.div_op = DIV_REMU; end
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBA_UW) begin
                    // Zba: add.uw / sh1add.uw / sh2add.uw / sh3add.uw
                    decoded.fu_type    = FU_ALU;
                    decoded.is_unsigned = 1'b1;
                    case (funct3)
                        F3_ADD_SUB: decoded.alu_op = ALU_ADD;    // ADD.UW
                        F3_SH1ADD:  decoded.alu_op = ALU_SH1ADD; // SH1ADD.UW
                        F3_SH2ADD:  decoded.alu_op = ALU_SH2ADD; // SH2ADD.UW
                        F3_SH3ADD:  decoded.alu_op = ALU_SH3ADD; // SH3ADD.UW
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZBB_ROT) begin
                    // Zbb: ROLW / RORW
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_SLL:     decoded.alu_op = ALU_ROL; // ROLW
                        F3_SRL_SRA: decoded.alu_op = ALU_ROR; // RORW
                        default: begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                    endcase
                end else if (funct7 == F7_ZEXTH && funct3 == F3_ZEXTH && rs2_f == 5'd0) begin
                    // Zbb: ZEXT.H
                    decoded.fu_type = FU_ALU;
                    decoded.alu_op  = ALU_AND;
                    // ZEXT.H is pack rd, rs1, zero with mask = 0xFFFF
                    // Implement as AND with immediate 0xFFFF; re-use ALU_AND
                    // but set imm and use_imm
                    decoded.rs2_valid  = 1'b0;
                    decoded.imm        = 64'h0000_0000_0000_FFFF;
                    decoded.use_imm    = 1'b1;
                end else begin
                    // Base integer W-type R-format
                    decoded.fu_type = FU_ALU;
                    case (funct3)
                        F3_ADD_SUB: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_ADD;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_SUB;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SLL: begin
                            if (funct7 == F7_NORMAL) decoded.alu_op = ALU_SLL;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        F3_SRL_SRA: begin
                            if (funct7 == F7_NORMAL)       decoded.alu_op = ALU_SRL;
                            else if (funct7 == F7_SUB_SRA) decoded.alu_op = ALU_SRA;
                            else begin decoded.has_exception = 1'b1; decoded.exc_code = EXC_ILLEGAL_INSN; end
                        end
                        default: begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    endcase
                end
            end

            // =============================================================
            // MISC_MEM (FENCE, FENCE.I)
            // =============================================================
            OP_MISC_MEM: begin
                case (funct3)
                    F3_FENCE:   decoded.is_fence   = 1'b1;
                    F3_FENCE_I: decoded.is_fence_i = 1'b1;
                    default: begin
                        decoded.has_exception = 1'b1;
                        decoded.exc_code      = EXC_ILLEGAL_INSN;
                    end
                endcase
            end

            // =============================================================
            // SYSTEM (ECALL, EBREAK, MRET, SRET, WFI, SFENCE.VMA, CSR*)
            // =============================================================
            OP_SYSTEM: begin
                if (funct3 == F3_PRIV) begin
                    if ((funct7 == F7_SFENCE_VMA) && (rd_f == 5'd0)) begin
                        decoded.fu_type      = FU_ALU;
                        decoded.is_fence     = 1'b1;
                        decoded.is_sfence_vma = 1'b1;
                    end else begin
                        case (funct12)
                            F12_ECALL: begin
                                decoded.is_ecall      = 1'b1;
                                decoded.has_exception = 1'b1;
                                decoded.exc_code      = EXC_ECALL_M;
                            end
                            F12_EBREAK: begin
                                decoded.is_ebreak     = 1'b1;
                                decoded.has_exception = 1'b1;
                                decoded.exc_code      = EXC_BREAKPOINT;
                            end
                            F12_MRET: decoded.is_mret = 1'b1;
                            F12_SRET: decoded.is_sret = 1'b1;
                            F12_WFI:  decoded.is_wfi  = 1'b1;
                            default: begin
                                decoded.has_exception = 1'b1;
                                decoded.exc_code      = EXC_ILLEGAL_INSN;
                            end
                        endcase
                    end
                end else begin
                    // CSR instructions
                    decoded.fu_type  = FU_CSR;
                    decoded.is_csr   = 1'b1;
                    decoded.csr_addr = funct12;
                    decoded.rd_valid = 1'b1;
                    case (funct3)
                        F3_CSRRW:  begin decoded.csr_op = CSR_RW; decoded.rs1_valid = 1'b1; end
                        F3_CSRRS:  begin decoded.csr_op = CSR_RS; decoded.rs1_valid = 1'b1; end
                        F3_CSRRC:  begin decoded.csr_op = CSR_RC; decoded.rs1_valid = 1'b1; end
                        F3_CSRRWI: begin decoded.csr_op = CSR_RW; decoded.imm = {59'd0, rs1_f}; decoded.use_imm = 1'b1; end
                        F3_CSRRSI: begin decoded.csr_op = CSR_RS; decoded.imm = {59'd0, rs1_f}; decoded.use_imm = 1'b1; end
                        F3_CSRRCI: begin decoded.csr_op = CSR_RC; decoded.imm = {59'd0, rs1_f}; decoded.use_imm = 1'b1; end
                        default: begin
                            decoded.has_exception = 1'b1;
                            decoded.exc_code      = EXC_ILLEGAL_INSN;
                        end
                    endcase
                end
            end

            // =============================================================
            // FP opcodes: pass through as illegal for now (FPU decode TBD)
            // =============================================================
            OP_FP, OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD: begin
                // FP instructions decoded as illegal until FPU decode is added
                decoded.has_exception = 1'b1;
                decoded.exc_code      = EXC_ILLEGAL_INSN;
            end

            // =============================================================
            // Default: illegal instruction
            // =============================================================
            default: begin
                decoded.has_exception = 1'b1;
                decoded.exc_code      = EXC_ILLEGAL_INSN;
            end
        endcase

        // ---------------------------------------------------------------
        // rd == x0 suppression (writes to x0 are discarded)
        // ---------------------------------------------------------------
        if (rd_f == 5'd0)
            decoded.rd_valid = 1'b0;
    end

endmodule
