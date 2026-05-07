/* file: ras.sv
 Description: Return address stack for call/return prediction.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module ras
    import rv64gc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        push_valid,    // CALL detected (JAL/JALR with rd=x1 or rd=x5)
    input  logic [63:0] push_addr,     // return address (PC + 4 or PC + 2 for RVC)
    input  logic        pop_valid,     // RET detected (JALR with rs1=x1/x5, rd=x0)
    output logic [63:0] pop_addr,      // predicted return target (top of stack)
    output logic [4:0]  tos,           // top-of-stack pointer (for checkpoint save)
    // Restore on mispredict
    input  logic        restore_valid,
    input  logic [4:0]  restore_tos,   // saved TOS pointer from checkpoint
    input  logic        restore_top_valid,
    input  logic [63:0] restore_top_addr
);

    // =========================================================================
    // Storage
    // =========================================================================
    // RAS_DEPTH = 24  (from rv64gc_pkg)
    logic [63:0] stack [RAS_DEPTH];

    // tos points to the next free slot (push writes to stack[tos], then tos++)
    // pop_addr reads stack[tos-1]  (the most recently pushed entry)
    logic [4:0] tos_r;

    assign tos = tos_r;

    // =========================================================================
    // Combinational read: top of stack
    // =========================================================================
    // tos_r - 1, wrapped modulo RAS_DEPTH
    logic [4:0] top_idx;
    logic [4:0] restore_top_idx;
    assign top_idx = (tos_r == 5'd0) ? 5'(RAS_DEPTH - 1) : (tos_r - 5'd1);
    assign restore_top_idx =
        (restore_tos == 5'd0) ? 5'(RAS_DEPTH - 1) : (restore_tos - 5'd1);
    assign pop_addr = (tos_r == 5'd0) ? 64'd0 : stack[top_idx];

    // =========================================================================
    // Sequential push / pop / restore
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tos_r <= 5'd0;
            for (int i = 0; i < RAS_DEPTH; i++) begin
                stack[i] <= 64'd0;
            end
        end else if (restore_valid) begin
            // Restore the pointer and, when available, repair the visible top
            // entry that may have been overwritten by wrong-path pushes.
            tos_r <= restore_tos;
            if (restore_top_valid && (restore_tos != 5'd0))
                stack[restore_top_idx] <= restore_top_addr;
        end else begin
            // Push takes priority over simultaneous pop (CALL within RET)
            if (push_valid) begin
                stack[tos_r] <= push_addr;
                // Wrap pointer modulo RAS_DEPTH
                tos_r <= (tos_r == 5'(RAS_DEPTH - 1)) ? 5'd0 : (tos_r + 5'd1);
            end else if (pop_valid) begin
                // Ignore empty-stack pops; otherwise decrement one level.
                if (tos_r != 5'd0)
                    tos_r <= tos_r - 5'd1;
            end
        end
    end

endmodule
