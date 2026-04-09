/* file: bru.sv
 * Description: Branch Resolution Unit. Evaluates branch conditions,
 *              computes branch/jump targets, detects mispredictions.
 *              Supports fused compare-and-branch uops where an SLT/SLTU
 *              comparison and BEQ/BNE against zero are performed in one cycle.
 *              Combinational: result available same cycle.
 * Version: 2.0
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
    input  logic        bp_taken,      // predicted taken
    input  logic [63:0] bp_target,     // predicted target
    output logic [63:0] result,        // link address (PC+4 for JAL/JALR, unused for branches)
    output logic        taken,         // actual branch outcome
    output logic [63:0] target,        // actual branch target
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
    // Fusion patterns combine SLT/SLTU + BEQ/BNE into a single uop.
    // The comparison operand is either rs2 (register) or imm (immediate).
    logic fused_taken;
    always_comb begin
        fused_taken = 1'b0;
        case (fusion_type)
            3'd0: fused_taken = ($signed(operand_a) < $signed(operand_b));   // SLT + BNE  -> branch if a < b signed
            3'd1: fused_taken = (operand_a < operand_b);                     // SLTU + BNE -> branch if a < b unsigned
            3'd2: fused_taken = ($signed(operand_a) >= $signed(operand_b));  // SLT + BEQ  -> branch if a >= b signed
            3'd3: fused_taken = (operand_a >= operand_b);                    // SLTU + BEQ -> branch if a >= b unsigned
            3'd4: fused_taken = ($signed(operand_a) < $signed(imm));         // SLTI + BNE -> branch if a < imm signed
            3'd5: fused_taken = (operand_a < imm);                           // SLTIU + BNE -> branch if a < imm unsigned
            default: fused_taken = 1'b0;
        endcase
    end

    // Select between standard and fused paths
    assign taken = is_fused ? fused_taken : std_taken;

    // =========================================================================
    // Target computation
    // =========================================================================
    always_comb begin
        case (op)
            BR_JALR: target = (operand_a + imm) & ~64'd1;
            default: target = pc + imm;  // branches, JAL, and fused ops
        endcase
    end

    // =========================================================================
    // Link address (PC + 4 for JAL/JALR)
    // =========================================================================
    assign result = pc + 64'd4;

    // =========================================================================
    // Mispredict detection
    // =========================================================================
    // Mispredicted if:
    //   - taken/not-taken differs from prediction, OR
    //   - taken but target differs from predicted target
    assign mispredict = (taken != bp_taken) || (taken && (target != bp_target));

endmodule
