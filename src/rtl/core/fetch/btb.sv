/* file: btb.sv
 Description: 1024-entry 4-way BTB with PLRU replacement.
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
    // BTB_SETS = 256, BTB_WAYS = 4  (from rv64gc_pkg)
    localparam int IDX_BITS = $clog2(BTB_SETS);  // 8
    localparam int TAG_BITS = 64 - IDX_BITS - 2; // 54  (skip [1:0] alignment bits)

    // =========================================================================
    // Storage arrays
    // =========================================================================
    logic                        valid  [BTB_SETS][BTB_WAYS];
    logic [TAG_BITS-1:0]         tags   [BTB_SETS][BTB_WAYS];
    logic [63:0]                 targets[BTB_SETS][BTB_WAYS];
    logic [2:0]                  btypes [BTB_SETS][BTB_WAYS];
    logic [5:0]                  boffs  [BTB_SETS][BTB_WAYS]; // branch byte offset in line

    // PLRU state: 3 bits per set for 4-way PLRU tree
    // Bit layout: [2]=root (left=0/right=1), [1]=left-subtree, [0]=right-subtree
    logic [2:0]                  plru   [BTB_SETS];

    // =========================================================================
    // Lookup logic (combinational)
    // =========================================================================
    logic [IDX_BITS-1:0] lkp_idx;
    logic [TAG_BITS-1:0] lkp_tag;

    assign lkp_idx = lookup_pc[IDX_BITS+1:2];   // bits [9:2]
    assign lkp_tag = lookup_pc[63:IDX_BITS+2];  // bits [63:10]

    always_comb begin
        hit           = 1'b0;
        target        = 64'd0;
        branch_type   = 3'd0;
        branch_offset = 6'd0;
        for (int w = 0; w < BTB_WAYS; w++) begin
            if (valid[lkp_idx][w] && (tags[lkp_idx][w] == lkp_tag)) begin
                hit           = 1'b1;
                target        = targets[lkp_idx][w];
                branch_type   = btypes[lkp_idx][w];
                branch_offset = boffs[lkp_idx][w];
            end
        end
    end

    // =========================================================================
    // PLRU victim selection (combinational, used during update)
    // =========================================================================
    // Tree encoding for 4-way PLRU:
    //        [2]
    //       /   \
    //     [1]   [0]
    //    /   \ /   \
    //   W0  W1 W2  W3
    //
    // Bit=0 means "go left" (point to left subtree / MRU side opposite)
    // Victim = way that PLRU bits point toward as LRU

    logic [IDX_BITS-1:0] upd_idx;
    logic [TAG_BITS-1:0] upd_tag;
    logic [1:0]          victim_way;
    logic                upd_hit;
    logic [1:0]          upd_hit_way;

    assign upd_idx = update_pc[IDX_BITS+1:2];
    assign upd_tag = update_pc[63:IDX_BITS+2];

    always_comb begin
        // Check for hit in existing entries
        upd_hit     = 1'b0;
        upd_hit_way = 2'd0;
        for (int w = 0; w < BTB_WAYS; w++) begin
            if (valid[upd_idx][w] && (tags[upd_idx][w] == upd_tag)) begin
                upd_hit     = 1'b1;
                upd_hit_way = 2'(w);
            end
        end

        // Find first invalid way as preferred victim (before PLRU)
        victim_way = 2'd0;
        if (!upd_hit) begin
            // Default to PLRU victim
            victim_way[1] = plru[upd_idx][2];
            victim_way[0] = plru[upd_idx][2] ? plru[upd_idx][0] : plru[upd_idx][1];
            // Override with first invalid way if any
            for (int w = BTB_WAYS-1; w >= 0; w--) begin
                if (!valid[upd_idx][w]) victim_way = 2'(w);
            end
        end
    end

    // =========================================================================
    // PLRU update: inline at each usage site below
    // =========================================================================

    // Precompute PLRU next-state for both hit and victim updates
    logic [2:0] plru_ns_hit, plru_ns_victim;

    always_comb begin
        plru_ns_hit = plru[upd_idx];
        plru_ns_hit[2] = upd_hit_way[1];
        if (!upd_hit_way[1])
            plru_ns_hit[1] = upd_hit_way[0];
        else
            plru_ns_hit[0] = upd_hit_way[0];
    end

    always_comb begin
        plru_ns_victim = plru[upd_idx];
        plru_ns_victim[2] = victim_way[1];
        if (!victim_way[1])
            plru_ns_victim[1] = victim_way[0];
        else
            plru_ns_victim[0] = victim_way[0];
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
                plru[s] <= 3'd0;
            end
        end else if (update_valid) begin
            if (upd_hit) begin
                // Update existing entry in place
                targets[upd_idx][upd_hit_way] <= update_target;
                btypes [upd_idx][upd_hit_way] <= update_type;
                boffs  [upd_idx][upd_hit_way] <= update_pc[5:0];
                plru   [upd_idx]              <= plru_ns_hit;
            end else begin
                // Allocate new entry at victim way
                valid  [upd_idx][victim_way] <= 1'b1;
                tags   [upd_idx][victim_way] <= upd_tag;
                targets[upd_idx][victim_way] <= update_target;
                btypes [upd_idx][victim_way] <= update_type;
                boffs  [upd_idx][victim_way] <= update_pc[5:0];
                plru   [upd_idx]             <= plru_ns_victim;
            end
        end
    end

endmodule
