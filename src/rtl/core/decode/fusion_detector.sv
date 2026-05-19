/* file: fusion_detector.sv
 Description: Macro-op fusion detector for PIPE_WIDTH-wide decode stage (4-wide refactor).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef FUSION_DETECTOR_SV
`define FUSION_DETECTOR_SV

module fusion_detector
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  decoded_insn_t dec_in [0:PIPE_WIDTH-1],
    input  logic [2:0]    dec_count_in,
    output decoded_insn_t dec_out [0:PIPE_WIDTH-1],
    output logic [2:0]    dec_count_out
);

    // =========================================================================
    // Per-slot classification wires (replaces classification functions)
    // =========================================================================
    logic [PIPE_WIDTH-1:0] w_is_lui, w_is_auipc, w_is_addi, w_is_jalr;
    logic [PIPE_WIDTH-1:0] w_is_load_insn, w_is_store_insn;
    logic [PIPE_WIDTH-1:0] w_is_slt, w_is_sltu, w_is_slti, w_is_sltiu;
    logic [PIPE_WIDTH-1:0] w_is_bne, w_is_beq;
    logic [PIPE_WIDTH-1:0] w_is_sextw;  // ADDIW rd, rs, 0 (sign-extend word)

    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_classify
            assign w_is_lui[gi]        = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_LUI);
            assign w_is_auipc[gi]      = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_PASS2) && dec_in[gi].use_imm;
            assign w_is_addi[gi]       = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_ADD) && dec_in[gi].use_imm;
            assign w_is_jalr[gi]       = (dec_in[gi].fu_type == FU_BRU) && (dec_in[gi].br_op == BR_JALR);
            assign w_is_load_insn[gi]  = dec_in[gi].is_load;
            assign w_is_store_insn[gi] = dec_in[gi].is_store;
            assign w_is_slt[gi]        = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_SLT) && !dec_in[gi].use_imm;
            assign w_is_sltu[gi]       = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_SLTU) && !dec_in[gi].use_imm;
            assign w_is_slti[gi]       = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_SLT) && dec_in[gi].use_imm;
            assign w_is_sltiu[gi]      = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_SLTU) && dec_in[gi].use_imm;
            assign w_is_bne[gi]        = (dec_in[gi].fu_type == FU_BRU) && (dec_in[gi].br_op == BR_NE);
            assign w_is_beq[gi]        = (dec_in[gi].fu_type == FU_BRU) && (dec_in[gi].br_op == BR_EQ);
            assign w_is_sextw[gi]      = (dec_in[gi].fu_type == FU_ALU) && (dec_in[gi].alu_op == ALU_ADD)
                                          && dec_in[gi].use_imm && dec_in[gi].is_w_op && (dec_in[gi].imm == 64'd0);
        end
    endgenerate

    // =========================================================================
    // Pass 1: determine which adjacent pairs fuse
    // =========================================================================
    // fusable[k] => pair (k, k+1) can fuse.
    // For 4-wide (PIPE_WIDTH=4): 3 pairs — (0,1), (1,2), (2,3).
    localparam int NUM_FUSE_PAIRS = PIPE_WIDTH - 1;  // 3 for 4-wide
    logic [NUM_FUSE_PAIRS-1:0] fusable;

    // fused_uop[k] holds the merged uop when fusable[k] is asserted.
    decoded_insn_t fused_uop [0:NUM_FUSE_PAIRS-1];

    // Precomputed same-cacheline check for each adjacent pair
    logic same_line [0:NUM_FUSE_PAIRS-1];

    genvar k;
    generate
        for (k = 0; k < NUM_FUSE_PAIRS; k++) begin : gen_same_line
            assign same_line[k] = (dec_in[k].pc[63:6] == dec_in[k+1].pc[63:6]);
        end
    endgenerate

    // =========================================================================
    // LUI + ADDI/ADDIW fusion helper: compute the fused 64-bit immediate.
    // For ADDI (is_w_op=0): plain 64-bit sum.
    // For ADDIW (is_w_op=1): sum modulo 2^32 then sign-extend bit 31.
    // Inline always_comb replaces the former function automatic.
    // =========================================================================
    logic [63:0] lui_add_imm_result [0:NUM_FUSE_PAIRS-1];
    logic [63:0] lui_add_sum64     [0:NUM_FUSE_PAIRS-1];
    logic [31:0] lui_add_sum32     [0:NUM_FUSE_PAIRS-1];

    always_comb begin
        for (int p = 0; p < NUM_FUSE_PAIRS; p++) begin
            lui_add_sum64[p] = dec_in[p].imm + dec_in[p+1].imm;
            lui_add_sum32[p] = lui_add_sum64[p][31:0];
            if (dec_in[p+1].is_w_op)
                lui_add_imm_result[p] = {{32{lui_add_sum32[p][31]}}, lui_add_sum32[p]};
            else
                lui_add_imm_result[p] = lui_add_sum64[p];
        end
    end

    // -------------------------------------------------------------------------
    // Fusion eligibility and uop construction — one block per pair
    // -------------------------------------------------------------------------

    // Macro to reduce repetition: common structural guards for pair (I, J=I+1)
    // Both valid, same cache line, rd_arch != 0, rd_arch matches next's source.
    // Source for: ADDI/JALR/LOAD => rs1_arch; STORE => rs1_arch (base register).
    // Compare-and-branch second insn uses rs1_arch (the rd of first).

    // ---------- pair 0,1 ----------
    always_comb begin : pair_0_1
        fusable[0]   = 1'b0;
        fused_uop[0] = dec_in[0];  // default: copy first insn, modified below

        if (dec_in[0].valid && dec_in[1].valid && same_line[0] &&
            (dec_in[0].rd_arch != 5'd0)) begin

            // ---------------------------------------------------------------
            // Tier 1a: LUI rd + ADDI rd, rd, imm  => 32-bit imm load
            // ---------------------------------------------------------------
            if (w_is_lui[0] && w_is_addi[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                // LUI+ADDI  -> 64-bit sum
                // LUI+ADDIW -> sign-extend the low-32 bits of the sum
                fused_uop[0].imm        = lui_add_imm_result[0];
                fused_uop[0].is_w_op    = 1'b0;  // ALU_LUI ignores is_w_op
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 1b: AUIPC rd + JALR ra, rd, imm  => PC-relative call
            // ---------------------------------------------------------------
            end else if (w_is_auipc[0] && w_is_jalr[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_JALR;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].is_jalr    = 1'b1;
                fused_uop[0].rd_arch    = dec_in[1].rd_arch;
                fused_uop[0].rd_valid   = dec_in[1].rd_valid;
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].use_imm    = 1'b1;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 1c: AUIPC rd + ADDI rd, rd, imm  => PC-relative address
            // ---------------------------------------------------------------
            end else if (w_is_auipc[0] && w_is_addi[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // AUIPC plus load or store is intentionally left unfused. This
            // pipeline has one destination per uop and no partial commit path,
            // so memory faults or store forms would lose the AUIPC result.

            // ---------------------------------------------------------------
            // Tier 2a: SLT rd, rs1, rs2 + BNE rd, x0  => fused signed lt-branch
            // ---------------------------------------------------------------
            end else if (w_is_slt[0] && w_is_bne[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_NE;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;  // SLT+BNE

            // ---------------------------------------------------------------
            // Tier 2b: SLTU rd + BNE rd, x0  => unsigned lt-branch
            // ---------------------------------------------------------------
            end else if (w_is_sltu[0] && w_is_bne[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_NE;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd1;  // SLTU+BNE

            // ---------------------------------------------------------------
            // Tier 2c: SLT rd + BEQ rd, x0  => inverted signed lt-branch
            // ---------------------------------------------------------------
            end else if (w_is_slt[0] && w_is_beq[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_EQ;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd2;  // SLT+BEQ

            // ---------------------------------------------------------------
            // Tier 2d: SLTU rd + BEQ rd, x0  => inverted unsigned lt-branch
            // ---------------------------------------------------------------
            end else if (w_is_sltu[0] && w_is_beq[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_EQ;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd3;  // SLTU+BEQ

            // ---------------------------------------------------------------
            // Tier 2e: SLTI rd + BNE/BEQ rd, x0  => imm signed compare-branch
            // ---------------------------------------------------------------
            end else if (w_is_slti[0] && w_is_bne[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_NE;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].fused_imm  = 32'(dec_in[0].imm);
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd4;  // SLTI+BNE

            end else if (w_is_slti[0] && w_is_beq[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_EQ;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].fused_imm  = 32'(dec_in[0].imm);
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd4;  // SLTI+BEQ (reuse type 4 slot)

            // ---------------------------------------------------------------
            // Tier 2f: SLTIU rd + BNE/BEQ rd, x0
            // ---------------------------------------------------------------
            end else if (w_is_sltiu[0] && w_is_bne[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_NE;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].fused_imm  = 32'(dec_in[0].imm);
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd5;  // SLTIU+BNE

            end else if (w_is_sltiu[0] && w_is_beq[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_EQ;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].fused_imm  = 32'(dec_in[0].imm);
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd5;  // SLTIU+BEQ (reuse type 5)

            // ---------------------------------------------------------------
            // Tier 3a: SEXT.W rd + BNE rd, x0  => fused word-nonzero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[0] && w_is_bne[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_NE;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd6;  // SEXT.W+BNE

            // ---------------------------------------------------------------
            // Tier 3b: SEXT.W rd + BEQ rd, x0  => fused word-zero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[0] && w_is_beq[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[1].rs2_arch == 5'd0)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_EQ;
                fused_uop[0].is_branch  = 1'b1;
                fused_uop[0].rd_valid   = 1'b0;
                fused_uop[0].imm        = dec_in[1].imm;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd7;  // SEXT.W+BEQ
            end
        end

        if (fusable[0] && (fused_uop[0].fu_type == FU_BRU)) begin
            // The fused uop executes the control transfer from slot 1, so it
            // must inherit that slot's branch metadata and PC-relative base.
            fused_uop[0].bp_taken  = dec_in[1].bp_taken;
            fused_uop[0].bp_target = dec_in[1].bp_target;
            fused_uop[0].bp_owner  = dec_in[1].bp_owner;
            fused_uop[0].bp_from_subgroup = dec_in[1].bp_from_subgroup;
            fused_uop[0].bp_lookup_pc = dec_in[1].bp_lookup_pc;
            fused_uop[0].bp_ras_tos = dec_in[1].bp_ras_tos;
            fused_uop[0].bp_ras_top = dec_in[1].bp_ras_top;
            fused_uop[0].bp_ghr   = dec_in[1].bp_ghr;
            fused_uop[0].pc        = dec_in[1].pc;
            fused_uop[0].trap_pc   = dec_in[0].trap_pc;
            fused_uop[0].is_rvc    = dec_in[1].is_rvc;

            // AUIPC+JALR folds the producer's PC into the fused immediate
            // because the BRU's JALR target path computes operand_a + imm.
            if (w_is_auipc[0] && w_is_jalr[1] &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fused_uop[0].imm = dec_in[0].pc + dec_in[0].imm + dec_in[1].imm;
            end else begin
                fused_uop[0].rd_valid = dec_in[0].rd_valid;
            end
        end
    end : pair_0_1

    // ---------- pair 1,2 ----------
    always_comb begin : pair_1_2
        fusable[1]   = 1'b0;
        fused_uop[1] = dec_in[1];

        // Pair (1,2) cannot fuse if pair (0,1) already consumed slot 1
        if (!fusable[0] &&
            dec_in[1].valid && dec_in[2].valid && same_line[1] &&
            (dec_in[1].rd_arch != 5'd0)) begin

            if (w_is_lui[1] && w_is_addi[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].imm        = lui_add_imm_result[1];
                fused_uop[1].is_w_op    = 1'b0;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (w_is_auipc[1] && w_is_jalr[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_JALR;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].is_jalr    = 1'b1;
                fused_uop[1].rd_arch    = dec_in[2].rd_arch;
                fused_uop[1].rd_valid   = dec_in[2].rd_valid;
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].use_imm    = 1'b1;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (w_is_auipc[1] && w_is_addi[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (w_is_slt[1] && w_is_bne[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_NE;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (w_is_sltu[1] && w_is_bne[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_NE;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd1;

            end else if (w_is_slt[1] && w_is_beq[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_EQ;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd2;

            end else if (w_is_sltu[1] && w_is_beq[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_EQ;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd3;

            end else if (w_is_slti[1] && w_is_bne[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_NE;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd4;

            end else if (w_is_slti[1] && w_is_beq[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_EQ;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd4;

            end else if (w_is_sltiu[1] && w_is_bne[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_NE;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd5;

            end else if (w_is_sltiu[1] && w_is_beq[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_EQ;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd5;

            // ---------------------------------------------------------------
            // Tier 3a: SEXT.W rd + BNE rd, x0  => fused word-nonzero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[1] && w_is_bne[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_NE;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd6;  // SEXT.W+BNE

            // ---------------------------------------------------------------
            // Tier 3b: SEXT.W rd + BEQ rd, x0  => fused word-zero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[1] && w_is_beq[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[2].rs2_arch == 5'd0)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_EQ;
                fused_uop[1].is_branch  = 1'b1;
                fused_uop[1].rd_valid   = 1'b0;
                fused_uop[1].imm        = dec_in[2].imm;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd7;  // SEXT.W+BEQ
            end
        end

        if (fusable[1] && (fused_uop[1].fu_type == FU_BRU)) begin
            fused_uop[1].bp_taken  = dec_in[2].bp_taken;
            fused_uop[1].bp_target = dec_in[2].bp_target;
            fused_uop[1].bp_owner  = dec_in[2].bp_owner;
            fused_uop[1].bp_from_subgroup = dec_in[2].bp_from_subgroup;
            fused_uop[1].bp_lookup_pc = dec_in[2].bp_lookup_pc;
            fused_uop[1].bp_ras_tos = dec_in[2].bp_ras_tos;
            fused_uop[1].bp_ras_top = dec_in[2].bp_ras_top;
            fused_uop[1].bp_ghr   = dec_in[2].bp_ghr;
            fused_uop[1].pc        = dec_in[2].pc;
            fused_uop[1].trap_pc   = dec_in[1].trap_pc;
            fused_uop[1].is_rvc    = dec_in[2].is_rvc;

            if (w_is_auipc[1] && w_is_jalr[2] &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fused_uop[1].imm = dec_in[1].pc + dec_in[1].imm + dec_in[2].imm;
            end else begin
                fused_uop[1].rd_valid = dec_in[1].rd_valid;
            end
        end
    end : pair_1_2

    // ---------- pair 2,3 ----------
    always_comb begin : pair_2_3
        fusable[2]   = 1'b0;
        fused_uop[2] = dec_in[2];

        // Blocked if pair (1,2) consumed slot 2
        if (!fusable[1] &&
            dec_in[2].valid && dec_in[3].valid && same_line[2] &&
            (dec_in[2].rd_arch != 5'd0)) begin

            if (w_is_lui[2] && w_is_addi[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].imm        = lui_add_imm_result[2];
                fused_uop[2].is_w_op    = 1'b0;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (w_is_auipc[2] && w_is_jalr[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_JALR;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].is_jalr    = 1'b1;
                fused_uop[2].rd_arch    = dec_in[3].rd_arch;
                fused_uop[2].rd_valid   = dec_in[3].rd_valid;
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].use_imm    = 1'b1;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (w_is_auipc[2] && w_is_addi[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (w_is_slt[2] && w_is_bne[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_NE;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (w_is_sltu[2] && w_is_bne[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_NE;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd1;

            end else if (w_is_slt[2] && w_is_beq[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_EQ;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd2;

            end else if (w_is_sltu[2] && w_is_beq[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_EQ;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd3;

            end else if (w_is_slti[2] && w_is_bne[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_NE;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd4;

            end else if (w_is_slti[2] && w_is_beq[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_EQ;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd4;

            end else if (w_is_sltiu[2] && w_is_bne[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_NE;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd5;

            end else if (w_is_sltiu[2] && w_is_beq[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_EQ;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd5;

            // ---------------------------------------------------------------
            // Tier 3a: SEXT.W rd + BNE rd, x0  => fused word-nonzero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[2] && w_is_bne[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_NE;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd6;  // SEXT.W+BNE

            // ---------------------------------------------------------------
            // Tier 3b: SEXT.W rd + BEQ rd, x0  => fused word-zero branch
            // ---------------------------------------------------------------
            end else if (w_is_sextw[2] && w_is_beq[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[3].rs2_arch == 5'd0)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_EQ;
                fused_uop[2].is_branch  = 1'b1;
                fused_uop[2].rd_valid   = 1'b0;
                fused_uop[2].imm        = dec_in[3].imm;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd7;  // SEXT.W+BEQ
            end
        end

        if (fusable[2] && (fused_uop[2].fu_type == FU_BRU)) begin
            fused_uop[2].bp_taken  = dec_in[3].bp_taken;
            fused_uop[2].bp_target = dec_in[3].bp_target;
            fused_uop[2].bp_owner  = dec_in[3].bp_owner;
            fused_uop[2].bp_from_subgroup = dec_in[3].bp_from_subgroup;
            fused_uop[2].bp_lookup_pc = dec_in[3].bp_lookup_pc;
            fused_uop[2].bp_ras_tos = dec_in[3].bp_ras_tos;
            fused_uop[2].bp_ras_top = dec_in[3].bp_ras_top;
            fused_uop[2].bp_ghr   = dec_in[3].bp_ghr;
            fused_uop[2].pc        = dec_in[3].pc;
            fused_uop[2].trap_pc   = dec_in[2].trap_pc;
            fused_uop[2].is_rvc    = dec_in[3].is_rvc;

            if (w_is_auipc[2] && w_is_jalr[3] &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fused_uop[2].imm = dec_in[2].pc + dec_in[2].imm + dec_in[3].imm;
            end else begin
                fused_uop[2].rd_valid = dec_in[2].rd_valid;
            end
        end
    end : pair_2_3



    // =========================================================================
    // Pass 2: Compaction network
    //
    // Build an intermediate array that removes the consumed "second" slot of
    // each fused pair, then count how many fusions occurred.
    //
    // Strategy: walk the input slots 0..PIPE_WIDTH-1 in order.  Each slot is either:
    //   - A first-of-fused-pair  → emit fused_uop[k]
    //   - A second-of-fused-pair → skip (consumed)
    //   - Unfused               → emit dec_in[i] as-is
    //
    // We use a running write pointer into dec_out[].
    // =========================================================================

    // Intermediate: which input slot is "consumed" (second of fused pair)
    // consumed[i] = 1 means input slot i was the second member of a fused pair.
    // For 4-wide (PIPE_WIDTH=4): 4 slots, 3 pairs.
    logic consumed [0:PIPE_WIDTH-1];

    always_comb begin : gen_consumed
        // Slot 0 is never consumed (no pair (-1,0))
        consumed[0] = 1'b0;
        consumed[1] = fusable[0];        // pair (0,1) consumed slot 1
        consumed[2] = fusable[1];        // pair (1,2) consumed slot 2
        consumed[3] = fusable[2];        // pair (2,3) consumed slot 3
    end : gen_consumed

    // What to output for input slot i when it is NOT consumed:
    //   - If it starts a fused pair (fusable[i-1] would have been set for
    //     the pair anchored at i-1, but we need the pair anchored at i):
    //     fusable[k] covers pair (k, k+1), so input slot i is the FIRST of
    //     a fused pair when fusable[i] is set (for i in 0..4).
    //   - Otherwise: dec_in[i] as-is.
    // slot_output logic inlined in compaction block below

    // Compaction: shift valid (non-consumed) slots to fill the array.
    // We unroll this combinationally.  Output slots are filled sequentially.

    // Number of fusions = popcount(fusable) — 3 pairs for 4-wide
    logic [2:0] num_fused;
    always_comb begin
        num_fused = 3'(fusable[0]) + 3'(fusable[1]) + 3'(fusable[2]);
    end

    assign dec_count_out = (dec_count_in >= num_fused)
                           ? (dec_count_in - num_fused)
                           : 3'd0;

    // Compaction: purely combinational priority-encode non-consumed slots
    // into output positions.  We unroll across all PIPE_WIDTH input/output slots.

    // Use a fixed-size candidate array: slot indices in input order,
    // skipping consumed ones.
    // For 4-wide (PIPE_WIDTH=4): fully unrolled over 4 slots.

    // out_src[j] = index into dec_in[] (or fused_uop[]) for output slot j
    // We fill out_src by scanning input slots 0..PIPE_WIDTH-1, skipping consumed ones.

    decoded_insn_t compact [0:PIPE_WIDTH-1];
    logic          compact_v [0:PIPE_WIDTH-1]; // whether this compacted slot is used

    always_comb begin : compaction
        // Default: all outputs are the zeroed-out first input (won't matter,
        // valid will be 0).
        int wr;
        wr = 0;

        for (int j = 0; j < PIPE_WIDTH; j++) begin
            compact[j]   = dec_in[0];
            compact_v[j] = 1'b0;
        end

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (!consumed[i]) begin
                // This slot is either a fused uop (i is first of pair) or passthru
                if ((i < NUM_FUSE_PAIRS) && fusable[i])
                    compact[wr] = fused_uop[i];
                else
                    compact[wr] = dec_in[i];
                compact_v[wr] = 1'b1;
                wr = wr + 1;
            end
        end
    end : compaction

    // Assign outputs: use compacted array, clear valid on unused tail slots
    always_comb begin : output_assign
        for (int j = 0; j < PIPE_WIDTH; j++) begin
            if (compact_v[j]) begin
                dec_out[j]       = compact[j];
            end else begin
                dec_out[j]       = compact[j];  // don't-care data
                dec_out[j].valid = 1'b0;
            end
        end
    end : output_assign

endmodule

`endif
