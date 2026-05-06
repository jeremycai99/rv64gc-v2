/* file: bru.sv
 Description: Branch resolution unit for conditional and indirect branches.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module bru
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic [63:0] operand_a,     // rs1 value
    input  logic [63:0] operand_b,     // rs2 value
    input  logic [63:0] pc,
    input  logic [63:0] imm,           // branch offset or JAL/JALR target offset
    input  br_op_e      op,
    input  logic        is_fused,      // fused compare-and-branch uop
    input  logic [2:0]  fusion_type,   // which fused pattern
    input  logic [63:0] fused_imm,      // first-op immediate for fused SLTI/SLTIU
    input  logic        bp_taken,      // predicted taken
    input  logic [63:0] bp_target,     // predicted target
    input  logic        is_rvc,        // compressed instruction (PC+2 for link)
    output logic [63:0] result,        // link address (PC+4 for JAL/JALR, unused for branches)
    output logic        taken,         // actual branch outcome
    output logic [63:0] target,        // actual redirect target
    output logic [63:0] taken_target,  // static taken target (pc+imm / jalr dest)
    output logic        mispredict     // taken != bp_taken || target != bp_target
);

    // =========================================================================
    // Standard branch condition evaluation
    // =========================================================================
    logic std_taken;
    always_comb begin
        std_taken = 1'b0;
        case (op)
            BR_EQ:   std_taken = (operand_a == operand_b);
            BR_NE:   std_taken = (operand_a != operand_b);
            BR_LT:   std_taken = ($signed(operand_a) < $signed(operand_b));
            BR_GE:   std_taken = ($signed(operand_a) >= $signed(operand_b));
            BR_LTU:  std_taken = (operand_a < operand_b);
            BR_GEU:  std_taken = (operand_a >= operand_b);
            BR_JAL:  std_taken = 1'b1;
            BR_JALR: std_taken = 1'b1;
            default: std_taken = 1'b0;
        endcase
    end

    // =========================================================================
    // Fused compare-and-branch evaluation
    // =========================================================================
    // Fusion patterns combine SLT/SLTU/SLTI/SLTIU + BEQ/BNE into a single uop.
    // Conditional-branch imm remains the redirect offset; fused_imm carries the
    // compare immediate for SLTI/SLTIU forms.
    logic fused_taken;
    logic fused_slti_signed_lt;
    logic fused_sltiu_lt;
    assign fused_slti_signed_lt = ($signed(operand_a) < $signed(fused_imm));
    assign fused_sltiu_lt       = (operand_a < fused_imm);

    always_comb begin
        fused_taken = 1'b0;
        case (fusion_type)
            3'd0: fused_taken = ($signed(operand_a) < $signed(operand_b));   // SLT + BNE  -> branch if a < b signed
            3'd1: fused_taken = (operand_a < operand_b);                     // SLTU + BNE -> branch if a < b unsigned
            3'd2: fused_taken = ($signed(operand_a) >= $signed(operand_b));  // SLT + BEQ  -> branch if a >= b signed
            3'd3: fused_taken = (operand_a >= operand_b);                    // SLTU + BEQ -> branch if a >= b unsigned
            3'd4: fused_taken = (op == BR_EQ) ? !fused_slti_signed_lt
                                               :  fused_slti_signed_lt;       // SLTI + BEQ/BNE
            3'd5: fused_taken = (op == BR_EQ) ? !fused_sltiu_lt
                                               :  fused_sltiu_lt;             // SLTIU + BEQ/BNE
            3'd6: fused_taken = (operand_a[31:0] != 32'd0);                // SEXT.W + BNE -> branch if word != 0
            3'd7: fused_taken = (operand_a[31:0] == 32'd0);                // SEXT.W + BEQ -> branch if word == 0
            default: fused_taken = 1'b0;
        endcase
    end

    // Select between standard and fused paths
    assign taken = is_fused ? fused_taken : std_taken;

    // =========================================================================
    // Target computation
    //
    // For conditional branches, the target stored in the ROB is the
    // *redirect* target — the address the pipeline should fetch from on
    // mispredict. When the branch is actually taken, that is the branch
    // target (pc + imm). When the branch is actually not-taken, that is
    // the fall-through address (pc + 4 or pc + 2 for RVC).
    //
    // JAL and JALR are unconditional: their target is always the jump
    // destination and is used for mispredict-recovery of the target address.
    // =========================================================================
    logic [63:0] branch_target;
    logic [63:0] fallthrough;

    always_comb begin
        case (op)
            BR_JALR: branch_target = (operand_a + imm) & ~64'd1;
            default: branch_target = pc + imm;
        endcase
    end

    assign taken_target = branch_target;

    assign fallthrough = pc + (is_rvc ? 64'd2 : 64'd4);

    always_comb begin
        case (op)
            BR_JAL:  target = branch_target;
            BR_JALR: target = branch_target;
            default: target = taken ? branch_target : fallthrough;
        endcase
    end

    // =========================================================================
    // Link address (PC + 4 for 32-bit, PC + 2 for RVC)
    // =========================================================================
    assign result = pc + (is_rvc ? 64'd2 : 64'd4);

    // =========================================================================
    // Mispredict detection
    // =========================================================================
    // Mispredicted if:
    //   - taken/not-taken differs from prediction, OR
    //   - taken but branch target differs from predicted target
    assign mispredict = (taken != bp_taken) || (taken && (branch_target != bp_target));

`ifdef BRU_DEBUG
    always_comb begin
        if (op == BR_JALR) begin
            $display("BRU JALR: pc=%016h opa=%016h opb=%016h imm=%016h target=%016h misp=%b bp_t=%016h bp_taken=%b",
                pc, operand_a, operand_b, imm, branch_target, mispredict, bp_target, bp_taken);
        end
        if (op == BR_JAL) begin
            $display("BRU JAL : pc=%016h imm=%016h target=%016h result=%016h",
                pc, imm, branch_target, result);
        end
    end
`endif

endmodule
