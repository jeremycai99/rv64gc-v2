/* file: load_queue.sv
 Description: Load queue tracking in-flight loads for ordering.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef LOAD_QUEUE_SV
`define LOAD_QUEUE_SV

module load_queue
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Allocate (from rename)
    input logic [2:0] alloc_count,
    output logic [LQ_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1],
    output logic full,

    // Load execution (from load AGU — address computed)
    input logic exec_valid,
    input logic [LQ_IDX_BITS-1:0] exec_idx,
    input logic [ROB_IDX_BITS-1:0] exec_rob_idx,
    input logic [63:0] exec_addr,
    input logic [1:0] exec_size,
    input logic exec_is_unsigned,

    // Load result (from D-cache or store forwarding)
    input logic result_valid,
    input logic [LQ_IDX_BITS-1:0] result_idx,
    input logic [63:0] result_data,

    // Store-to-load ordering violation check
    input logic st_addr_valid,
    input logic [63:0] st_addr,
    input logic [1:0] st_size,
    input logic [ROB_IDX_BITS-1:0] st_rob_idx,
    output logic ordering_violation,
    output logic [ROB_IDX_BITS-1:0] violation_rob_idx,

    // Commit: retire head entries
    input logic [2:0] commit_count,

    // Flush
    input logic flush_valid,
    input logic flush_full
);

    // =========================================================================
    // Storage
    // =========================================================================
    lq_entry_t queue [0:LQ_DEPTH-1];

    logic [LQ_IDX_BITS-1:0] head_r;
    logic [LQ_IDX_BITS-1:0] tail_r;
    logic [LQ_IDX_BITS:0]   count_r;

    // =========================================================================
    // Alloc index outputs
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_alloc_idx
            assign alloc_idx[gi] = LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(gi));
        end
    endgenerate

    assign full = (count_r >= (LQ_IDX_BITS+1)'(LQ_DEPTH - PIPE_WIDTH + 1));

    // =========================================================================
    // Store byte-mask helper
    // =========================================================================
    logic [7:0] st_bmask;
    logic [2:0] st_off;
    assign st_off = st_addr[2:0];

    always_comb begin
        case (st_size)
            2'd0:    st_bmask = 8'h01 << st_off;
            2'd1:    st_bmask = 8'h03 << st_off;
            2'd2:    st_bmask = 8'h0F << st_off;
            default: st_bmask = 8'hFF;
        endcase
    end

    // =========================================================================
    // Ordering violation: per-entry generation
    // =========================================================================
    // A load violates ordering if:
    //   1. It is valid and executed (address is known).
    //   2. Its address overlaps the incoming store address.
    //   3. Its ROB index is younger than the store's ROB index.
    //
    // Younger-than in circular ROB space: distance = (ld_rob - st_rob) mod ROB_DEPTH.
    // If 0 < distance < ROB_DEPTH/2, the load is younger.

    localparam int ROB_HALF = ROB_DEPTH / 2;

    logic [LQ_DEPTH-1:0]  viol_mask;
    logic [7:0]           ld_bmask [0:LQ_DEPTH-1];

    genvar vi;
    generate
        for (vi = 0; vi < LQ_DEPTH; vi++) begin : gen_viol
            logic [2:0] ld_off;
            assign ld_off = queue[vi].addr[2:0];

            always_comb begin
                case (queue[vi].size)
                    2'd0:    ld_bmask[vi] = 8'h01 << ld_off;
                    2'd1:    ld_bmask[vi] = 8'h03 << ld_off;
                    2'd2:    ld_bmask[vi] = 8'h0F << ld_off;
                    default: ld_bmask[vi] = 8'hFF;
                endcase
            end

            logic addr_overlap;
            assign addr_overlap = (queue[vi].addr[63:3] == st_addr[63:3])
                                & ((ld_bmask[vi] & st_bmask) != 8'h00);

            logic [ROB_IDX_BITS-1:0] rob_dist;
            assign rob_dist = queue[vi].rob_idx - st_rob_idx;

            logic is_younger;
            assign is_younger = (rob_dist != '0) & (rob_dist < ROB_IDX_BITS'(ROB_HALF));

            assign viol_mask[vi] = st_addr_valid
                                 & queue[vi].valid
                                 & queue[vi].executed
                                 & addr_overlap
                                 & is_younger;
        end
    endgenerate

    // =========================================================================
    // Violation reduction: pick youngest violating load
    // =========================================================================
    // We want the entry with the largest (queue[v].rob_idx - st_rob_idx) mod ROB_DEPTH
    // among all entries where viol_mask[v] is set.
    // Use per-entry rob_dist from gen_viol and reduce in always_comb without
    // declaring variables inside conditional branches (avoids latch inference).

    logic [ROB_IDX_BITS-1:0] viol_rob_dist [0:LQ_DEPTH-1];
    logic [ROB_IDX_BITS-1:0] viol_rob_idx_arr [0:LQ_DEPTH-1];

    genvar ri;
    generate
        for (ri = 0; ri < LQ_DEPTH; ri++) begin : gen_viol_rob
            assign viol_rob_dist[ri]    = queue[ri].rob_idx - st_rob_idx;
            assign viol_rob_idx_arr[ri] = queue[ri].rob_idx;
        end
    endgenerate

    logic                    any_viol;
    logic [ROB_IDX_BITS-1:0] best_rob_idx;
    logic [ROB_IDX_BITS-1:0] best_dist;

    always_comb begin
        logic update_best;
        any_viol     = 1'b0;
        best_rob_idx = '0;
        best_dist    = '0;
        update_best  = 1'b0;
        for (int v = 0; v < LQ_DEPTH; v++) begin
            // Pick the youngest (largest rob_dist) violating load.  Use ">=" so
            // the first violating entry overrides the initial best_dist=0.
            any_viol    = any_viol | viol_mask[v];
            update_best = viol_mask[v] & (viol_rob_dist[v] >= best_dist);
            if (update_best) begin
                best_dist    = viol_rob_dist[v];
                best_rob_idx = viol_rob_idx_arr[v];
            end
        end
    end

    assign ordering_violation = any_viol;
    assign violation_rob_idx  = best_rob_idx;

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_r  <= '0;
            tail_r  <= '0;
            count_r <= '0;
            for (int i = 0; i < LQ_DEPTH; i++) begin
                queue[i] <= '0;
            end
        end else if (flush_valid && flush_full) begin
            // Full flush: discard all in-flight loads.
            // Loads are never "committed" to a drain buffer; commit just
            // advances head. On full flush, reset tail to head.
            tail_r  <= head_r;
            count_r <= '0;
            for (int i = 0; i < LQ_DEPTH; i++) begin
                queue[i].valid    <= 1'b0;
                queue[i].executed <= 1'b0;
            end
        end else begin
            // --- Commit: advance head ---
            for (int c = 0; c < PIPE_WIDTH; c++) begin
                if (c < int'(commit_count)) begin
                    queue[LQ_IDX_BITS'(head_r + LQ_IDX_BITS'(c))].valid <= 1'b0;
                end
            end
            if (commit_count != '0) begin
                head_r  <= LQ_IDX_BITS'(head_r + commit_count);
                count_r <= count_r - {4'b0, commit_count};
            end

            // --- Exec fill: record address, size, and ROB index ---
            // The ROB index is needed by the ordering-violation comparison
            // to determine which loads are younger than an incoming store.
            if (exec_valid) begin
                queue[exec_idx].rob_idx     <= exec_rob_idx;
                queue[exec_idx].addr        <= exec_addr;
                queue[exec_idx].size        <= exec_size;
                queue[exec_idx].is_unsigned <= exec_is_unsigned;
                queue[exec_idx].addr_valid  <= 1'b1;
                queue[exec_idx].executed    <= 1'b1;
            end

            // --- Result fill: record loaded data ---
            if (result_valid) begin
                queue[result_idx].data       <= result_data;
                queue[result_idx].has_result <= 1'b1;
            end

            // --- Allocate new entries ---
            for (int a = 0; a < PIPE_WIDTH; a++) begin
                if (a < int'(alloc_count)) begin
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].valid      <= 1'b1;
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].addr_valid <= 1'b0;
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].executed   <= 1'b0;
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].has_result <= 1'b0;
                end
            end
            if (alloc_count != '0) begin
                tail_r <= LQ_IDX_BITS'(tail_r + alloc_count);
                if (commit_count != '0) begin
                    count_r <= count_r + {4'b0, alloc_count} - {4'b0, commit_count};
                end else begin
                    count_r <= count_r + {4'b0, alloc_count};
                end
            end
        end
    end

endmodule

`endif
