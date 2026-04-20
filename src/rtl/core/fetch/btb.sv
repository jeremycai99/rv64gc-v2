/* file: btb.sv
 Description: Set-associative BTB with round-robin replacement.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module btb
    import rv64gc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    // Lookup (combinational, same cycle as fetch)
    input  logic [63:0] lookup_pc,
    output logic        hit,
    output logic [63:0] target,
    output logic [2:0]  branch_type,  // 0=cond, 1=jal, 2=jalr, 3=call, 4=ret
    output logic [5:0]  branch_offset, // byte offset of branch within cache line
    output logic        alt_hit,
    output logic [63:0] alt_target,
    output logic [2:0]  alt_branch_type,
    output logic [5:0]  alt_branch_offset,
    // Update (from commit/BRU resolution)
    input  logic        update_valid,
    input  logic [63:0] update_pc,
    input  logic [63:0] update_target,
    input  logic [2:0]  update_type,
    // Flush
    input  logic        flush
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    // BTB_SETS / BTB_WAYS come from rv64gc_pkg.
    localparam int IDX_BITS = $clog2(BTB_SETS);   // 8
    localparam int TAG_BITS = 64 - IDX_BITS - LINE_BITS; // 50
    localparam int WAY_BITS = $clog2(BTB_WAYS);

    // =========================================================================
    // Storage arrays
    // =========================================================================
    localparam logic [2:0] BTB_TYPE_COND = 3'd0;

    logic                        valid  [BTB_SETS][BTB_WAYS];
    logic [TAG_BITS-1:0]         tags   [BTB_SETS][BTB_WAYS];
    logic [63:0]                 targets[BTB_SETS][BTB_WAYS];
    logic [2:0]                  btypes [BTB_SETS][BTB_WAYS];
    logic [5:0]                  boffs  [BTB_SETS][BTB_WAYS]; // branch byte offset in line

    // Per-set round-robin victim pointer used when every way is valid.
    logic [WAY_BITS-1:0]         victim_rr [BTB_SETS];

    // =========================================================================
    // Lookup logic (combinational)
    // =========================================================================
    logic [IDX_BITS-1:0] lkp_idx;
    logic [TAG_BITS-1:0] lkp_tag;

    assign lkp_idx = lookup_pc[IDX_BITS+LINE_BITS-1:LINE_BITS];
    assign lkp_tag = lookup_pc[63:IDX_BITS+LINE_BITS];

    always_comb begin
        hit           = 1'b0;
        target        = 64'd0;
        branch_type   = 3'd0;
        branch_offset = 6'd0;
        alt_hit           = 1'b0;
        alt_target        = 64'd0;
        alt_branch_type   = 3'd0;
        alt_branch_offset = 6'd0;
        for (int w = 0; w < BTB_WAYS; w++) begin
            if (valid[lkp_idx][w]
                && (tags[lkp_idx][w] == lkp_tag)
                && (boffs[lkp_idx][w] >= lookup_pc[5:0])) begin
                if (!hit || (boffs[lkp_idx][w] < branch_offset)) begin
                    hit           = 1'b1;
                    target        = targets[lkp_idx][w];
                    branch_type   = btypes[lkp_idx][w];
                    branch_offset = boffs[lkp_idx][w];
                end
                if ((btypes[lkp_idx][w] != BTB_TYPE_COND) &&
                    (!alt_hit || (boffs[lkp_idx][w] < alt_branch_offset))) begin
                    alt_hit           = 1'b1;
                    alt_target        = targets[lkp_idx][w];
                    alt_branch_type   = btypes[lkp_idx][w];
                    alt_branch_offset = boffs[lkp_idx][w];
                end
            end
        end
    end

    // =========================================================================
    // Victim selection (combinational, used during update)
    // =========================================================================
    logic [IDX_BITS-1:0] upd_idx;
    logic [TAG_BITS-1:0] upd_tag;
    logic [WAY_BITS-1:0] victim_way;
    logic                upd_hit;
    logic [WAY_BITS-1:0] upd_hit_way;

    assign upd_idx = update_pc[IDX_BITS+LINE_BITS-1:LINE_BITS];
    assign upd_tag = update_pc[63:IDX_BITS+LINE_BITS];

    always_comb begin
        // Check for hit in existing entries
        upd_hit     = 1'b0;
        upd_hit_way = '0;
        for (int w = 0; w < BTB_WAYS; w++) begin
            if (valid[upd_idx][w]
                && (tags[upd_idx][w] == upd_tag)
                && (boffs[upd_idx][w] == update_pc[5:0])) begin
                upd_hit     = 1'b1;
                upd_hit_way = WAY_BITS'(w);
            end
        end

        // Find first invalid way as preferred victim before reusing a valid way.
        victim_way = '0;
        if (!upd_hit) begin
            // Default to the per-set round-robin victim.
            victim_way = victim_rr[upd_idx];
            // Override with first invalid way if any
            for (int w = BTB_WAYS-1; w >= 0; w--) begin
                if (!valid[upd_idx][w]) victim_way = WAY_BITS'(w);
            end
        end
    end

    // =========================================================================
    // Sequential update
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            for (int s = 0; s < BTB_SETS; s++) begin
                for (int w = 0; w < BTB_WAYS; w++) begin
                    valid[s][w] <= 1'b0;
                end
                victim_rr[s] <= '0;
            end
        end else if (update_valid) begin
            if (upd_hit) begin
                // Update existing entry in place
                targets[upd_idx][upd_hit_way] <= update_target;
                btypes [upd_idx][upd_hit_way] <= update_type;
                boffs  [upd_idx][upd_hit_way] <= update_pc[5:0];
            end else begin
                // Allocate new entry at victim way
                valid  [upd_idx][victim_way] <= 1'b1;
                tags   [upd_idx][victim_way] <= upd_tag;
                targets[upd_idx][victim_way] <= update_target;
                btypes [upd_idx][victim_way] <= update_type;
                boffs  [upd_idx][victim_way] <= update_pc[5:0];
                victim_rr[upd_idx]           <= victim_way + WAY_BITS'(1);
            end
        end
    end

endmodule
