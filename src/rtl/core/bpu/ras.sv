/* file: ras.sv
 Description: Return address stack for call/return prediction.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module ras
    import rv64gc_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        push_valid,    // CALL detected (JAL/JALR with rd=x1 or rd=x5)
    input  wire [63:0] push_addr,     // return address (PC + 4 or PC + 2 for RVC)
    input  wire        pop_valid,     // RET detected (JALR with rs1=x1/x5, rd=x0)
    output reg [63:0] pop_addr,      // predicted return target (top of stack)
    output reg [4:0]  tos,           // top-of-stack pointer (for checkpoint save)
    input  wire        clear,
    // Restore on mispredict
    input  wire        restore_valid,
    input  wire [4:0]  restore_tos,   // saved TOS pointer from checkpoint
    input  wire        restore_top_valid,
    input  wire [63:0] restore_top_addr
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
        end else if (clear) begin
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

`ifdef SIMULATION
    // ---- sim-only RAS recovery instrumentation (no synth effect) ----
    // gap = net wrong-path pointer movement at restore = how deep recovery corruption can reach.
    // Decides RAS FIX-B (gap<=1 dominant -> top-repair suffices) vs FIX-A (long tail -> full-stack
    // restore needed). top_repair_skipped = the population the FIX-B guard-removal would help.
    integer ras_restore_cnt;
    integer ras_gap0, ras_gap1, ras_gap2_3, ras_gap4_7, ras_gap8p, ras_gap_max;
    integer ras_top_applied, ras_top_skipped;
    integer ras_wrap_cnt;   // push wrap (tos: DEPTH-1 -> 0): depth-24 overflow indicator
    logic [4:0] ras_gap_c;
    always_comb ras_gap_c = (tos_r >= restore_tos) ? (tos_r - restore_tos)
                                                   : (5'(RAS_DEPTH) - (restore_tos - tos_r));
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ras_restore_cnt <= 0;
            ras_gap0 <= 0; ras_gap1 <= 0; ras_gap2_3 <= 0; ras_gap4_7 <= 0; ras_gap8p <= 0;
            ras_gap_max <= 0; ras_top_applied <= 0; ras_top_skipped <= 0; ras_wrap_cnt <= 0;
        end else begin
            if (restore_valid && !clear) begin
                ras_restore_cnt <= ras_restore_cnt + 1;
                if      (ras_gap_c == 5'd0) ras_gap0   <= ras_gap0 + 1;
                else if (ras_gap_c == 5'd1) ras_gap1   <= ras_gap1 + 1;
                else if (ras_gap_c <= 5'd3) ras_gap2_3 <= ras_gap2_3 + 1;
                else if (ras_gap_c <= 5'd7) ras_gap4_7 <= ras_gap4_7 + 1;
                else                        ras_gap8p  <= ras_gap8p + 1;
                if (integer'(ras_gap_c) > ras_gap_max) ras_gap_max <= integer'(ras_gap_c);
                if (restore_top_valid)        ras_top_applied <= ras_top_applied + 1;
                else if (restore_tos != 5'd0) ras_top_skipped <= ras_top_skipped + 1;
            end
            if (!restore_valid && !clear && push_valid && (tos_r == 5'(RAS_DEPTH - 1)))
                ras_wrap_cnt <= ras_wrap_cnt + 1;
        end
    end
    final begin
        $display("=== RAS RECOVERY SUMMARY (restores=%0d DEPTH=%0d) ===", ras_restore_cnt, RAS_DEPTH);
        $display("  gap hist: 0=%0d 1=%0d 2-3=%0d 4-7=%0d 8+=%0d  max=%0d",
                 ras_gap0, ras_gap1, ras_gap2_3, ras_gap4_7, ras_gap8p, ras_gap_max);
        $display("  top-repair: applied=%0d skipped(FIX-B addressable)=%0d", ras_top_applied, ras_top_skipped);
        $display("  push-wrap (depth-24 overflow): %0d", ras_wrap_cnt);
    end
`endif

endmodule
