/* file: fusion_detector.sv
 Description: Macro-op fusion detector for 6-wide decode stage.
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
    // Local helper functions / wires for instruction classification
    // =========================================================================

    // Check whether an instruction is LUI  (fu_type==FU_ALU, alu_op==ALU_LUI)
    function automatic logic is_lui(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_LUI);
    endfunction

    // Check whether an instruction is AUIPC (fu_type==FU_ALU, alu_op==ALU_PASS2,
    // use_imm==1).  AUIPC is decoded as PC+imm via ALU_PASS2.
    function automatic logic is_auipc(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_PASS2) && d.use_imm;
    endfunction

    // ADDI: fu_type==FU_ALU, alu_op==ALU_ADD, use_imm==1
    function automatic logic is_addi(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_ADD) && d.use_imm;
    endfunction

    // JALR: fu_type==FU_BRU, br_op==BR_JALR
    function automatic logic is_jalr(input decoded_insn_t d);
        return (d.fu_type == FU_BRU) && (d.br_op == BR_JALR);
    endfunction

    // LOAD: is_load flag set
    function automatic logic is_load_insn(input decoded_insn_t d);
        return d.is_load;
    endfunction

    // STORE: is_store flag set (STA half carries the base address)
    function automatic logic is_store_insn(input decoded_insn_t d);
        return d.is_store;
    endfunction

    // SLT (register): FU_ALU, ALU_SLT, !use_imm
    function automatic logic is_slt(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_SLT) && !d.use_imm;
    endfunction

    // SLTU (register): FU_ALU, ALU_SLTU, !use_imm
    function automatic logic is_sltu(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_SLTU) && !d.use_imm;
    endfunction

    // SLTI (immediate): FU_ALU, ALU_SLT, use_imm
    function automatic logic is_slti(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_SLT) && d.use_imm;
    endfunction

    // SLTIU (immediate): FU_ALU, ALU_SLTU, use_imm
    function automatic logic is_sltiu(input decoded_insn_t d);
        return (d.fu_type == FU_ALU) && (d.alu_op == ALU_SLTU) && d.use_imm;
    endfunction

    // BNE: FU_BRU, BR_NE
    function automatic logic is_bne(input decoded_insn_t d);
        return (d.fu_type == FU_BRU) && (d.br_op == BR_NE);
    endfunction

    // BEQ: FU_BRU, BR_EQ
    function automatic logic is_beq(input decoded_insn_t d);
        return (d.fu_type == FU_BRU) && (d.br_op == BR_EQ);
    endfunction

    // =========================================================================
    // Pass 1: determine which adjacent pairs fuse
    // =========================================================================
    // fusable[k] => pair (k, k+1) can fuse.
    // fusable[4] covers pair (4,5) — 5 pairs total for 6-wide decode.
    logic [4:0] fusable;

    // fused_uop[k] holds the merged uop when fusable[k] is asserted.
    decoded_insn_t fused_uop [0:4];

    // Precomputed same-cacheline check for each adjacent pair
    logic same_line [0:4];

    genvar k;
    generate
        for (k = 0; k < 5; k++) begin : gen_same_line
            assign same_line[k] = (dec_in[k].pc[63:6] == dec_in[k+1].pc[63:6]);
        end
    endgenerate

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
            if (is_lui(dec_in[0]) && is_addi(dec_in[1]) &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 1b: AUIPC rd + JALR ra, rd, imm  => PC-relative call
            // ---------------------------------------------------------------
            end else if (is_auipc(dec_in[0]) && is_jalr(dec_in[1]) &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].fu_type    = FU_BRU;
                fused_uop[0].br_op      = BR_JALR;
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
            end else if (is_auipc(dec_in[0]) && is_addi(dec_in[1]) &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch) &&
                (dec_in[0].rd_arch == dec_in[1].rd_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[0];
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 1d: AUIPC rd + LD rd, imm(rd)  => PC-relative load
            // ---------------------------------------------------------------
            end else if (is_auipc(dec_in[0]) && is_load_insn(dec_in[1]) &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[1];
                fused_uop[0].pc         = dec_in[0].pc;
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].rs1_arch   = dec_in[0].rs1_arch;
                fused_uop[0].rs1_valid  = 1'b0;  // no gpr source; uses PC
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 1e: AUIPC rd + SD/SW/SH/SB rs, imm(rd) => PC-relative store
            // ---------------------------------------------------------------
            end else if (is_auipc(dec_in[0]) && is_store_insn(dec_in[1]) &&
                (dec_in[0].rd_arch == dec_in[1].rs1_arch)) begin
                fusable[0]              = 1'b1;
                fused_uop[0]            = dec_in[1];
                fused_uop[0].pc         = dec_in[0].pc;
                fused_uop[0].imm        = dec_in[0].imm + dec_in[1].imm;
                fused_uop[0].fused_imm  = 32'(dec_in[1].imm);
                fused_uop[0].rs1_arch   = dec_in[0].rs1_arch;
                fused_uop[0].rs1_valid  = 1'b0;
                fused_uop[0].is_fused   = 1'b1;
                fused_uop[0].fusion_type = 3'd0;

            // ---------------------------------------------------------------
            // Tier 2a: SLT rd, rs1, rs2 + BNE rd, x0  => fused signed lt-branch
            // ---------------------------------------------------------------
            end else if (is_slt(dec_in[0]) && is_bne(dec_in[1]) &&
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
            end else if (is_sltu(dec_in[0]) && is_bne(dec_in[1]) &&
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
            end else if (is_slt(dec_in[0]) && is_beq(dec_in[1]) &&
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
            end else if (is_sltu(dec_in[0]) && is_beq(dec_in[1]) &&
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
            end else if (is_slti(dec_in[0]) && is_bne(dec_in[1]) &&
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

            end else if (is_slti(dec_in[0]) && is_beq(dec_in[1]) &&
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
            end else if (is_sltiu(dec_in[0]) && is_bne(dec_in[1]) &&
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

            end else if (is_sltiu(dec_in[0]) && is_beq(dec_in[1]) &&
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

            if (is_lui(dec_in[1]) && is_addi(dec_in[2]) &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[1]) && is_jalr(dec_in[2]) &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].fu_type    = FU_BRU;
                fused_uop[1].br_op      = BR_JALR;
                fused_uop[1].is_jalr    = 1'b1;
                fused_uop[1].rd_arch    = dec_in[2].rd_arch;
                fused_uop[1].rd_valid   = dec_in[2].rd_valid;
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].use_imm    = 1'b1;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[1]) && is_addi(dec_in[2]) &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch) &&
                (dec_in[1].rd_arch == dec_in[2].rd_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[1];
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[1]) && is_load_insn(dec_in[2]) &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[2];
                fused_uop[1].pc         = dec_in[1].pc;
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].rs1_arch   = dec_in[1].rs1_arch;
                fused_uop[1].rs1_valid  = 1'b0;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[1]) && is_store_insn(dec_in[2]) &&
                (dec_in[1].rd_arch == dec_in[2].rs1_arch)) begin
                fusable[1]              = 1'b1;
                fused_uop[1]            = dec_in[2];
                fused_uop[1].pc         = dec_in[1].pc;
                fused_uop[1].imm        = dec_in[1].imm + dec_in[2].imm;
                fused_uop[1].fused_imm  = 32'(dec_in[2].imm);
                fused_uop[1].rs1_arch   = dec_in[1].rs1_arch;
                fused_uop[1].rs1_valid  = 1'b0;
                fused_uop[1].is_fused   = 1'b1;
                fused_uop[1].fusion_type = 3'd0;

            end else if (is_slt(dec_in[1]) && is_bne(dec_in[2]) &&
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

            end else if (is_sltu(dec_in[1]) && is_bne(dec_in[2]) &&
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

            end else if (is_slt(dec_in[1]) && is_beq(dec_in[2]) &&
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

            end else if (is_sltu(dec_in[1]) && is_beq(dec_in[2]) &&
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

            end else if (is_slti(dec_in[1]) && is_bne(dec_in[2]) &&
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

            end else if (is_slti(dec_in[1]) && is_beq(dec_in[2]) &&
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

            end else if (is_sltiu(dec_in[1]) && is_bne(dec_in[2]) &&
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

            end else if (is_sltiu(dec_in[1]) && is_beq(dec_in[2]) &&
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

            if (is_lui(dec_in[2]) && is_addi(dec_in[3]) &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[2]) && is_jalr(dec_in[3]) &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].fu_type    = FU_BRU;
                fused_uop[2].br_op      = BR_JALR;
                fused_uop[2].is_jalr    = 1'b1;
                fused_uop[2].rd_arch    = dec_in[3].rd_arch;
                fused_uop[2].rd_valid   = dec_in[3].rd_valid;
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].use_imm    = 1'b1;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[2]) && is_addi(dec_in[3]) &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch) &&
                (dec_in[2].rd_arch == dec_in[3].rd_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[2];
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[2]) && is_load_insn(dec_in[3]) &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[3];
                fused_uop[2].pc         = dec_in[2].pc;
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].rs1_arch   = dec_in[2].rs1_arch;
                fused_uop[2].rs1_valid  = 1'b0;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[2]) && is_store_insn(dec_in[3]) &&
                (dec_in[2].rd_arch == dec_in[3].rs1_arch)) begin
                fusable[2]              = 1'b1;
                fused_uop[2]            = dec_in[3];
                fused_uop[2].pc         = dec_in[2].pc;
                fused_uop[2].imm        = dec_in[2].imm + dec_in[3].imm;
                fused_uop[2].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[2].rs1_arch   = dec_in[2].rs1_arch;
                fused_uop[2].rs1_valid  = 1'b0;
                fused_uop[2].is_fused   = 1'b1;
                fused_uop[2].fusion_type = 3'd0;

            end else if (is_slt(dec_in[2]) && is_bne(dec_in[3]) &&
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

            end else if (is_sltu(dec_in[2]) && is_bne(dec_in[3]) &&
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

            end else if (is_slt(dec_in[2]) && is_beq(dec_in[3]) &&
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

            end else if (is_sltu(dec_in[2]) && is_beq(dec_in[3]) &&
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

            end else if (is_slti(dec_in[2]) && is_bne(dec_in[3]) &&
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

            end else if (is_slti(dec_in[2]) && is_beq(dec_in[3]) &&
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

            end else if (is_sltiu(dec_in[2]) && is_bne(dec_in[3]) &&
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

            end else if (is_sltiu(dec_in[2]) && is_beq(dec_in[3]) &&
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
            end
        end
    end : pair_2_3

    // ---------- pair 3,4 ----------
    always_comb begin : pair_3_4
        fusable[3]   = 1'b0;
        fused_uop[3] = dec_in[3];

        // Blocked if pair (2,3) consumed slot 3
        if (!fusable[2] &&
            dec_in[3].valid && dec_in[4].valid && same_line[3] &&
            (dec_in[3].rd_arch != 5'd0)) begin

            if (is_lui(dec_in[3]) && is_addi(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[3].rd_arch == dec_in[4].rd_arch)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].imm        = dec_in[3].imm + dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[3]) && is_jalr(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_JALR;
                fused_uop[3].is_jalr    = 1'b1;
                fused_uop[3].rd_arch    = dec_in[4].rd_arch;
                fused_uop[3].rd_valid   = dec_in[4].rd_valid;
                fused_uop[3].imm        = dec_in[3].imm + dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].use_imm    = 1'b1;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[3]) && is_addi(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[3].rd_arch == dec_in[4].rd_arch)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].imm        = dec_in[3].imm + dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[3]) && is_load_insn(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[4];
                fused_uop[3].pc         = dec_in[3].pc;
                fused_uop[3].imm        = dec_in[3].imm + dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].rs1_arch   = dec_in[3].rs1_arch;
                fused_uop[3].rs1_valid  = 1'b0;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[3]) && is_store_insn(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[4];
                fused_uop[3].pc         = dec_in[3].pc;
                fused_uop[3].imm        = dec_in[3].imm + dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].rs1_arch   = dec_in[3].rs1_arch;
                fused_uop[3].rs1_valid  = 1'b0;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_slt(dec_in[3]) && is_bne(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_NE;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd0;

            end else if (is_sltu(dec_in[3]) && is_bne(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_NE;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd1;

            end else if (is_slt(dec_in[3]) && is_beq(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_EQ;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd2;

            end else if (is_sltu(dec_in[3]) && is_beq(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_EQ;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd3;

            end else if (is_slti(dec_in[3]) && is_bne(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_NE;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd4;

            end else if (is_slti(dec_in[3]) && is_beq(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_EQ;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd4;

            end else if (is_sltiu(dec_in[3]) && is_bne(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_NE;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd5;

            end else if (is_sltiu(dec_in[3]) && is_beq(dec_in[4]) &&
                (dec_in[3].rd_arch == dec_in[4].rs1_arch) &&
                (dec_in[4].rs2_arch == 5'd0)) begin
                fusable[3]              = 1'b1;
                fused_uop[3]            = dec_in[3];
                fused_uop[3].fu_type    = FU_BRU;
                fused_uop[3].br_op      = BR_EQ;
                fused_uop[3].is_branch  = 1'b1;
                fused_uop[3].rd_valid   = 1'b0;
                fused_uop[3].fused_imm  = 32'(dec_in[3].imm);
                fused_uop[3].imm        = dec_in[4].imm;
                fused_uop[3].is_fused   = 1'b1;
                fused_uop[3].fusion_type = 3'd5;
            end
        end
    end : pair_3_4

    // ---------- pair 4,5 ----------
    always_comb begin : pair_4_5
        fusable[4]   = 1'b0;
        fused_uop[4] = dec_in[4];

        // Blocked if pair (3,4) consumed slot 4
        if (!fusable[3] &&
            dec_in[4].valid && dec_in[5].valid && same_line[4] &&
            (dec_in[4].rd_arch != 5'd0)) begin

            if (is_lui(dec_in[4]) && is_addi(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[4].rd_arch == dec_in[5].rd_arch)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].imm        = dec_in[4].imm + dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[4]) && is_jalr(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_JALR;
                fused_uop[4].is_jalr    = 1'b1;
                fused_uop[4].rd_arch    = dec_in[5].rd_arch;
                fused_uop[4].rd_valid   = dec_in[5].rd_valid;
                fused_uop[4].imm        = dec_in[4].imm + dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].use_imm    = 1'b1;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[4]) && is_addi(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[4].rd_arch == dec_in[5].rd_arch)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].imm        = dec_in[4].imm + dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[4]) && is_load_insn(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[5];
                fused_uop[4].pc         = dec_in[4].pc;
                fused_uop[4].imm        = dec_in[4].imm + dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].rs1_arch   = dec_in[4].rs1_arch;
                fused_uop[4].rs1_valid  = 1'b0;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_auipc(dec_in[4]) && is_store_insn(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[5];
                fused_uop[4].pc         = dec_in[4].pc;
                fused_uop[4].imm        = dec_in[4].imm + dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].rs1_arch   = dec_in[4].rs1_arch;
                fused_uop[4].rs1_valid  = 1'b0;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_slt(dec_in[4]) && is_bne(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_NE;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd0;

            end else if (is_sltu(dec_in[4]) && is_bne(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_NE;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd1;

            end else if (is_slt(dec_in[4]) && is_beq(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_EQ;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd2;

            end else if (is_sltu(dec_in[4]) && is_beq(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_EQ;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].fused_imm  = 32'(dec_in[5].imm);
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd3;

            end else if (is_slti(dec_in[4]) && is_bne(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_NE;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd4;

            end else if (is_slti(dec_in[4]) && is_beq(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_EQ;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd4;

            end else if (is_sltiu(dec_in[4]) && is_bne(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_NE;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd5;

            end else if (is_sltiu(dec_in[4]) && is_beq(dec_in[5]) &&
                (dec_in[4].rd_arch == dec_in[5].rs1_arch) &&
                (dec_in[5].rs2_arch == 5'd0)) begin
                fusable[4]              = 1'b1;
                fused_uop[4]            = dec_in[4];
                fused_uop[4].fu_type    = FU_BRU;
                fused_uop[4].br_op      = BR_EQ;
                fused_uop[4].is_branch  = 1'b1;
                fused_uop[4].rd_valid   = 1'b0;
                fused_uop[4].fused_imm  = 32'(dec_in[4].imm);
                fused_uop[4].imm        = dec_in[5].imm;
                fused_uop[4].is_fused   = 1'b1;
                fused_uop[4].fusion_type = 3'd5;
            end
        end
    end : pair_4_5

    // =========================================================================
    // Pass 2: Compaction network
    //
    // Build an intermediate array that removes the consumed "second" slot of
    // each fused pair, then count how many fusions occurred.
    //
    // Strategy: walk the input slots 0..5 in order.  Each slot is either:
    //   - A first-of-fused-pair  → emit fused_uop[k]
    //   - A second-of-fused-pair → skip (consumed)
    //   - Unfused               → emit dec_in[i] as-is
    //
    // We use a running write pointer into dec_out[].
    // =========================================================================

    // Intermediate: which input slot is "consumed" (second of fused pair)
    // consumed[i] = 1 means input slot i was the second member of a fused pair.
    logic consumed [0:5];

    always_comb begin : gen_consumed
        // Slot 0 is never consumed (no pair (-1,0))
        consumed[0] = 1'b0;
        consumed[1] = fusable[0];        // pair (0,1) consumed slot 1
        consumed[2] = fusable[1];        // pair (1,2) consumed slot 2
        consumed[3] = fusable[2];        // pair (2,3) consumed slot 3
        consumed[4] = fusable[3];        // pair (3,4) consumed slot 4
        consumed[5] = fusable[4];        // pair (4,5) consumed slot 5
    end : gen_consumed

    // What to output for input slot i when it is NOT consumed:
    //   - If it starts a fused pair (fusable[i-1] would have been set for
    //     the pair anchored at i-1, but we need the pair anchored at i):
    //     fusable[k] covers pair (k, k+1), so input slot i is the FIRST of
    //     a fused pair when fusable[i] is set (for i in 0..4).
    //   - Otherwise: dec_in[i] as-is.
    function automatic decoded_insn_t slot_output(
        input int i,
        input decoded_insn_t di [0:PIPE_WIDTH-1],
        input decoded_insn_t fu  [0:4],
        input logic [4:0]    fus
    );
        if ((i < 5) && fus[i])
            return fu[i];
        else
            return di[i];
    endfunction

    // Compaction: shift valid (non-consumed) slots to fill the array.
    // We unroll this combinationally.  Output slots are filled sequentially.

    // Number of fusions = popcount(fusable)
    logic [2:0] num_fused;
    always_comb begin
        num_fused = 3'(fusable[0]) + 3'(fusable[1]) +
                    3'(fusable[2]) + 3'(fusable[3]) +
                    3'(fusable[4]);
    end

    assign dec_count_out = (dec_count_in >= num_fused)
                           ? (dec_count_in - num_fused)
                           : 3'd0;

    // Compaction: purely combinational priority-encode non-consumed slots
    // into output positions.  We unroll across all 6 input/output slots.

    // Use a fixed-size candidate array: slot indices in input order,
    // skipping consumed ones.
    // Since PIPE_WIDTH=6 is a compile-time constant, fully unroll.

    // out_src[j] = index into dec_in[] (or fused_uop[]) for output slot j
    // We fill out_src by scanning input slots 0..5, skipping consumed ones.

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
                if ((i < 5) && fusable[i])
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
