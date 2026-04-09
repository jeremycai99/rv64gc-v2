/* file: rvc_decompress.sv
 Description: RV64C compressed instruction decompressor.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rvc_decompress
    import isa_pkg::*;
(
    input  logic [15:0] insn_in,
    output logic [31:0] insn_out,
    output logic        is_rvc,      // 1 if input was a valid compressed insn
    output logic        illegal      // 1 if compressed encoding is illegal/reserved
);

    // ---------------------------------------------------------------
    // Shorthand signals
    // ---------------------------------------------------------------
    logic [1:0] quadrant;
    logic [2:0] cop;
    logic [4:0] rc1;
    logic [4:0] rc2;
    logic [4:0] rp1;
    logic [4:0] rp2;
    logic [5:0] shamt6;

    assign quadrant = insn_in[1:0];
    assign cop      = insn_in[15:13];
    assign rc1      = insn_in[11:7];
    assign rc2      = insn_in[6:2];
    assign rp1      = {2'b01, insn_in[9:7]};
    assign rp2      = {2'b01, insn_in[4:2]};
    assign shamt6   = {insn_in[12], insn_in[6:2]};

    // A compressed instruction has bits [1:0] != 2'b11
    assign is_rvc = (insn_in[1:0] != 2'b11);

    // ---------------------------------------------------------------
    // Pre-computed immediates
    // ---------------------------------------------------------------

    // c_addi4spn_imm: 10-bit zero-extended
    logic [9:0] c_addi4spn_imm;
    always_comb begin
        c_addi4spn_imm       = 10'd0;
        c_addi4spn_imm[2]    = insn_in[6];
        c_addi4spn_imm[3]    = insn_in[5];
        c_addi4spn_imm[5:4]  = insn_in[12:11];
        c_addi4spn_imm[9:6]  = insn_in[10:7];
    end

    // c_ci_imm12: sign-extended 6-bit CI immediate -> 12-bit
    logic [11:0] c_ci_imm12;
    always_comb begin
        c_ci_imm12 = {{6{insn_in[12]}}, insn_in[12], insn_in[6:2]};
    end

    // c_addi16sp_imm12: sign-extended 10-bit -> 12-bit
    logic [9:0]  addi16sp_raw;
    logic [11:0] c_addi16sp_imm12;
    always_comb begin
        addi16sp_raw      = 10'd0;
        addi16sp_raw[4]   = insn_in[6];
        addi16sp_raw[5]   = insn_in[2];
        addi16sp_raw[6]   = insn_in[5];
        addi16sp_raw[8:7] = insn_in[4:3];
        addi16sp_raw[9]   = insn_in[12];
        c_addi16sp_imm12  = {{2{addi16sp_raw[9]}}, addi16sp_raw};
    end

    // c_lui_imm20: sign-extended 6-bit -> 20-bit
    logic [19:0] c_lui_imm20;
    always_comb begin
        c_lui_imm20 = {{14{insn_in[12]}}, insn_in[12], insn_in[6:2]};
    end

    // c_j_imm21: sign-extended 12-bit -> 21-bit
    logic [11:0] j_raw;
    logic [20:0] c_j_imm21;
    always_comb begin
        j_raw       = 12'd0;
        j_raw[1]    = insn_in[3];
        j_raw[2]    = insn_in[4];
        j_raw[3]    = insn_in[5];
        j_raw[4]    = insn_in[11];
        j_raw[5]    = insn_in[2];
        j_raw[6]    = insn_in[7];
        j_raw[7]    = insn_in[6];
        j_raw[9:8]  = insn_in[10:9];
        j_raw[10]   = insn_in[8];
        j_raw[11]   = insn_in[12];
        c_j_imm21   = {{9{j_raw[11]}}, j_raw};
    end

    // c_b_imm13: sign-extended 9-bit -> 13-bit
    logic [8:0]  b_raw;
    logic [12:0] c_b_imm13;
    always_comb begin
        b_raw       = 9'd0;
        b_raw[1]    = insn_in[3];
        b_raw[2]    = insn_in[4];
        b_raw[4:3]  = insn_in[11:10];
        b_raw[5]    = insn_in[2];
        b_raw[7:6]  = insn_in[6:5];
        b_raw[8]    = insn_in[12];
        c_b_imm13   = {{4{b_raw[8]}}, b_raw};
    end

    // c_lw_imm12: zero-extended load-word offset
    logic [11:0] c_lw_imm12;
    always_comb begin
        c_lw_imm12      = 12'd0;
        c_lw_imm12[2]   = insn_in[6];
        c_lw_imm12[5:3] = insn_in[12:10];
        c_lw_imm12[6]   = insn_in[5];
    end

    // c_ld_imm12: zero-extended load-double offset
    logic [11:0] c_ld_imm12;
    always_comb begin
        c_ld_imm12      = 12'd0;
        c_ld_imm12[5:3] = insn_in[12:10];
        c_ld_imm12[7:6] = insn_in[6:5];
    end

    // c_lwsp_imm12: zero-extended LWSP offset
    logic [11:0] c_lwsp_imm12;
    always_comb begin
        c_lwsp_imm12      = 12'd0;
        c_lwsp_imm12[4:2] = insn_in[6:4];
        c_lwsp_imm12[5]   = insn_in[12];
        c_lwsp_imm12[7:6] = insn_in[3:2];
    end

    // c_ldsp_imm12: zero-extended LDSP offset
    logic [11:0] c_ldsp_imm12;
    always_comb begin
        c_ldsp_imm12      = 12'd0;
        c_ldsp_imm12[4:3] = insn_in[6:5];
        c_ldsp_imm12[5]   = insn_in[12];
        c_ldsp_imm12[8:6] = insn_in[4:2];
    end

    // c_swsp_imm12: zero-extended SWSP offset
    logic [11:0] c_swsp_imm12;
    always_comb begin
        c_swsp_imm12      = 12'd0;
        c_swsp_imm12[5:2] = insn_in[12:9];
        c_swsp_imm12[7:6] = insn_in[8:7];
    end

    // c_sdsp_imm12: zero-extended SDSP offset
    logic [11:0] c_sdsp_imm12;
    always_comb begin
        c_sdsp_imm12      = 12'd0;
        c_sdsp_imm12[5:3] = insn_in[12:10];
        c_sdsp_imm12[8:6] = insn_in[9:7];
    end

    // ---------------------------------------------------------------
    // Main decode
    // ---------------------------------------------------------------
    always_comb begin
        illegal  = 1'b0;
        insn_out = 32'h00000013; // NOP default

        case (quadrant)
            2'b00: begin
                case (cop)
                    3'b000: begin
                        if (c_addi4spn_imm == 10'd0) begin
                            illegal  = 1'b1;
                            insn_out = 32'h00000000;
                        end else begin
                            // C.ADDI4SPN -> addi rd', x2, nzuimm
                            insn_out = {{2'b00, c_addi4spn_imm}, 5'd2,
                                         F3_ADD_SUB, rp2, OP_OP_IMM};
                        end
                    end
                    3'b001: begin
                        // C.FLD -> fld rd', offset(rs1')
                        insn_out = {c_ld_imm12, rp1, F3_LD, rp2, OP_LOAD_FP};
                    end
                    3'b010: begin
                        // C.LW -> lw rd', offset(rs1')
                        insn_out = {c_lw_imm12, rp1, F3_LW, rp2, OP_LOAD};
                    end
                    3'b011: begin
                        // C.LD -> ld rd', offset(rs1')
                        insn_out = {c_ld_imm12, rp1, F3_LD, rp2, OP_LOAD};
                    end
                    3'b101: begin
                        // C.FSD -> fsd rs2', offset(rs1')
                        insn_out = {c_ld_imm12[11:5], rp2, rp1, F3_SD,
                                     c_ld_imm12[4:0], OP_STORE_FP};
                    end
                    3'b110: begin
                        // C.SW -> sw rs2', offset(rs1')
                        insn_out = {c_lw_imm12[11:5], rp2, rp1, F3_SW,
                                     c_lw_imm12[4:0], OP_STORE};
                    end
                    3'b111: begin
                        // C.SD -> sd rs2', offset(rs1')
                        insn_out = {c_ld_imm12[11:5], rp2, rp1, F3_SD,
                                     c_ld_imm12[4:0], OP_STORE};
                    end
                    default: begin
                        illegal  = 1'b1;
                        insn_out = 32'h00000000;
                    end
                endcase
            end
            2'b01: begin
                case (cop)
                    3'b000: begin
                        // C.ADDI / C.NOP -> addi rd, rd, nzimm
                        insn_out = {c_ci_imm12, rc1, F3_ADD_SUB, rc1,
                                     OP_OP_IMM};
                    end
                    3'b001: begin
                        if (rc1 == 5'd0) begin
                            illegal  = 1'b1;
                            insn_out = 32'h00000000;
                        end else begin
                            // C.ADDIW -> addiw rd, rd, imm
                            insn_out = {c_ci_imm12, rc1, F3_ADD_SUB, rc1,
                                         OP_OP_IMM_32};
                        end
                    end
                    3'b010: begin
                        // C.LI -> addi rd, x0, imm
                        insn_out = {c_ci_imm12, 5'd0, F3_ADD_SUB, rc1,
                                     OP_OP_IMM};
                    end
                    3'b011: begin
                        if (rc1 == 5'd2) begin
                            if (c_addi16sp_imm12 == 12'd0) begin
                                illegal  = 1'b1;
                                insn_out = 32'h00000000;
                            end else begin
                                // C.ADDI16SP -> addi x2, x2, nzimm
                                insn_out = {c_addi16sp_imm12, 5'd2,
                                             F3_ADD_SUB, 5'd2, OP_OP_IMM};
                            end
                        end else begin
                            if ((rc1 == 5'd0) ||
                                (c_lui_imm20 == 20'd0)) begin
                                illegal  = 1'b1;
                                insn_out = 32'h00000000;
                            end else begin
                                // C.LUI -> lui rd, nzimm
                                insn_out = {c_lui_imm20, rc1, OP_LUI};
                            end
                        end
                    end
                    3'b100: begin
                        case (insn_in[11:10])
                            2'b00: begin
                                // C.SRLI -> srli rd', rd', shamt
                                insn_out = {6'b000000, shamt6, rp1,
                                             F3_SRL_SRA, rp1, OP_OP_IMM};
                            end
                            2'b01: begin
                                // C.SRAI -> srai rd', rd', shamt
                                insn_out = {6'b010000, shamt6, rp1,
                                             F3_SRL_SRA, rp1, OP_OP_IMM};
                            end
                            2'b10: begin
                                // C.ANDI -> andi rd', rd', imm
                                insn_out = {c_ci_imm12, rp1, F3_AND, rp1,
                                             OP_OP_IMM};
                            end
                            2'b11: begin
                                if (!insn_in[12]) begin
                                    case (insn_in[6:5])
                                        2'b00: insn_out = {F7_SUB_SRA, rp2,
                                            rp1, F3_ADD_SUB, rp1, OP_OP};   // C.SUB
                                        2'b01: insn_out = {F7_NORMAL, rp2,
                                            rp1, F3_XOR, rp1, OP_OP};       // C.XOR
                                        2'b10: insn_out = {F7_NORMAL, rp2,
                                            rp1, F3_OR, rp1, OP_OP};        // C.OR
                                        2'b11: insn_out = {F7_NORMAL, rp2,
                                            rp1, F3_AND, rp1, OP_OP};       // C.AND
                                        default: begin
                                            illegal  = 1'b1;
                                            insn_out = 32'h00000000;
                                        end
                                    endcase
                                end else begin
                                    case (insn_in[6:5])
                                        2'b00: insn_out = {F7_SUB_SRA, rp2,
                                            rp1, F3_ADD_SUB, rp1, OP_OP_32}; // C.SUBW
                                        2'b01: insn_out = {F7_NORMAL, rp2,
                                            rp1, F3_ADD_SUB, rp1, OP_OP_32}; // C.ADDW
                                        default: begin
                                            illegal  = 1'b1;
                                            insn_out = 32'h00000000;
                                        end
                                    endcase
                                end
                            end
                            default: begin
                                illegal  = 1'b1;
                                insn_out = 32'h00000000;
                            end
                        endcase
                    end
                    3'b101: begin
                        // C.J -> jal x0, offset
                        insn_out = {c_j_imm21[20], c_j_imm21[10:1],
                                     c_j_imm21[11], c_j_imm21[19:12],
                                     5'd0, OP_JAL};
                    end
                    3'b110: begin
                        // C.BEQZ -> beq rs1', x0, offset
                        insn_out = {c_b_imm13[12], c_b_imm13[10:5], 5'd0,
                                     rp1, F3_BEQ, c_b_imm13[4:1],
                                     c_b_imm13[11], OP_BRANCH};
                    end
                    3'b111: begin
                        // C.BNEZ -> bne rs1', x0, offset
                        insn_out = {c_b_imm13[12], c_b_imm13[10:5], 5'd0,
                                     rp1, F3_BNE, c_b_imm13[4:1],
                                     c_b_imm13[11], OP_BRANCH};
                    end
                    default: begin
                        illegal  = 1'b1;
                        insn_out = 32'h00000000;
                    end
                endcase
            end
            2'b10: begin
                case (cop)
                    3'b000: begin
                        // C.SLLI -> slli rd, rd, shamt
                        insn_out = {6'b000000, shamt6, rc1, F3_SLL, rc1,
                                     OP_OP_IMM};
                    end
                    3'b001: begin
                        // C.FLDSP -> fld rd, offset(x2)
                        insn_out = {c_ldsp_imm12, 5'd2, F3_LD, rc1,
                                     OP_LOAD_FP};
                    end
                    3'b010: begin
                        if (rc1 == 5'd0) begin
                            illegal  = 1'b1;
                            insn_out = 32'h00000000;
                        end else begin
                            // C.LWSP -> lw rd, offset(x2)
                            insn_out = {c_lwsp_imm12, 5'd2, F3_LW, rc1,
                                         OP_LOAD};
                        end
                    end
                    3'b011: begin
                        if (rc1 == 5'd0) begin
                            illegal  = 1'b1;
                            insn_out = 32'h00000000;
                        end else begin
                            // C.LDSP -> ld rd, offset(x2)
                            insn_out = {c_ldsp_imm12, 5'd2, F3_LD, rc1,
                                         OP_LOAD};
                        end
                    end
                    3'b100: begin
                        if (!insn_in[12]) begin
                            if (rc2 == 5'd0) begin
                                if (rc1 == 5'd0) begin
                                    illegal  = 1'b1;
                                    insn_out = 32'h00000000;
                                end else begin
                                    // C.JR -> jalr x0, 0(rs1)
                                    insn_out = {12'd0, rc1, F3_ADD_SUB,
                                                 5'd0, OP_JALR};
                                end
                            end else begin
                                // C.MV -> add rd, x0, rs2
                                insn_out = {12'd0, rc2, F3_ADD_SUB, rc1,
                                             OP_OP_IMM};
                            end
                        end else begin
                            if (rc2 == 5'd0) begin
                                if (rc1 == 5'd0) begin
                                    // C.EBREAK
                                    insn_out = 32'h00100073;
                                end else begin
                                    // C.JALR -> jalr x1, 0(rs1)
                                    insn_out = {12'd0, rc1, F3_ADD_SUB,
                                                 5'd1, OP_JALR};
                                end
                            end else begin
                                // C.ADD -> add rd, rd, rs2
                                insn_out = {F7_NORMAL, rc2, rc1,
                                             F3_ADD_SUB, rc1, OP_OP};
                            end
                        end
                    end
                    3'b101: begin
                        // C.FSDSP -> fsd rs2, offset(x2)
                        insn_out = {c_sdsp_imm12[11:5], rc2, 5'd2, F3_SD,
                                     c_sdsp_imm12[4:0], OP_STORE_FP};
                    end
                    3'b110: begin
                        // C.SWSP -> sw rs2, offset(x2)
                        insn_out = {c_swsp_imm12[11:5], rc2, 5'd2, F3_SW,
                                     c_swsp_imm12[4:0], OP_STORE};
                    end
                    3'b111: begin
                        // C.SDSP -> sd rs2, offset(x2)
                        insn_out = {c_sdsp_imm12[11:5], rc2, 5'd2, F3_SD,
                                     c_sdsp_imm12[4:0], OP_STORE};
                    end
                    default: begin
                        illegal  = 1'b1;
                        insn_out = 32'h00000000;
                    end
                endcase
            end
            default: begin
                // quadrant == 2'b11: not a compressed instruction
                illegal  = 1'b1;
                insn_out = 32'h00000000;
            end
        endcase
    end

endmodule
