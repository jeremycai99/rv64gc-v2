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
    input logic [ROB_IDX_BITS-1:0] alloc_rob_idx [0:PIPE_WIDTH-1],
    output logic [LQ_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1],
    output logic full,

    // Load execution (from load AGU — address computed)
    input logic exec_valid,
    input logic [LQ_IDX_BITS-1:0] exec_idx,
    input logic [ROB_IDX_BITS-1:0] exec_rob_idx,
    input logic [63:0] exec_addr,
    input logic [1:0] exec_size,
    input logic exec_is_unsigned,

    // Second load execution/address fill port.  Port 1 exists so a dual-load
    // cache issue records both executed load addresses in the LQ in the same
    // cycle; delaying port 1 can hide a younger executed load from a later STA
    // ordering check.
    input logic exec1_valid,
    input logic [LQ_IDX_BITS-1:0] exec1_idx,
    input logic [ROB_IDX_BITS-1:0] exec1_rob_idx,
    input logic [63:0] exec1_addr,
    input logic [1:0] exec1_size,
    input logic exec1_is_unsigned,

    // Load result (from D-cache or store forwarding)
    input logic result0_valid,
    input logic [LQ_IDX_BITS-1:0] result0_idx,
    input logic [ROB_IDX_BITS-1:0] result0_rob_idx,
    input logic [63:0] result0_data,
    input logic result1_valid,
    input logic [LQ_IDX_BITS-1:0] result1_idx,
    input logic [ROB_IDX_BITS-1:0] result1_rob_idx,
    input logic [63:0] result1_data,

    // Store-to-load ordering violation check
    input logic st_addr_valid,
    input logic [63:0] st_addr,
    input logic [1:0] st_size,
    input logic [ROB_IDX_BITS-1:0] st_rob_idx,
    input logic [ROB_IDX_BITS-1:0] rob_head,
    output logic ordering_violation,
    output logic [ROB_IDX_BITS-1:0] violation_rob_idx,

    // Commit: retire head entries
    input logic [2:0] commit_count,

    // Flush
    input logic flush_valid,
    input logic [ROB_IDX_BITS-1:0] flush_rob_tail,
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
    localparam int ROB_AGE_BITS = ROB_IDX_BITS + 1;

    function automatic logic [ROB_AGE_BITS-1:0] rob_age_from_head(
        input logic [ROB_IDX_BITS-1:0] idx
    );
        if (idx >= rob_head)
            rob_age_from_head = {1'b0, idx} - {1'b0, rob_head};
        else
            rob_age_from_head = ROB_DEPTH[ROB_AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, idx};
    endfunction

    logic [LQ_DEPTH-1:0]        viol_mask;
    logic [7:0]                 ld_bmask [0:LQ_DEPTH-1];
    logic [ROB_AGE_BITS-1:0]    st_age;
    logic [ROB_AGE_BITS-1:0]    viol_rob_age [0:LQ_DEPTH-1];
    logic [ROB_IDX_BITS-1:0]    viol_rob_idx_arr [0:LQ_DEPTH-1];
    logic                       any_viol;
    logic [ROB_IDX_BITS-1:0]    best_rob_idx;
    logic [ROB_AGE_BITS-1:0]    best_age;

    always_comb begin
        logic [2:0] ld_off;
        logic [ROB_AGE_BITS-1:0] ld_age;
        logic addr_overlap;
        logic is_younger;

        if (st_rob_idx >= rob_head)
            st_age = {1'b0, st_rob_idx} - {1'b0, rob_head};
        else
            st_age = ROB_DEPTH[ROB_AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, st_rob_idx};

        viol_mask    = '0;
        any_viol     = 1'b0;
        best_rob_idx = '0;
        best_age     = '0;

        for (int v = 0; v < LQ_DEPTH; v++) begin
            ld_off = queue[v].addr[2:0];
            case (queue[v].size)
                2'd0:    ld_bmask[v] = 8'h01 << ld_off;
                2'd1:    ld_bmask[v] = 8'h03 << ld_off;
                2'd2:    ld_bmask[v] = 8'h0F << ld_off;
                default: ld_bmask[v] = 8'hFF;
            endcase

            if (queue[v].rob_idx >= rob_head)
                ld_age = {1'b0, queue[v].rob_idx} - {1'b0, rob_head};
            else
                ld_age = ROB_DEPTH[ROB_AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, queue[v].rob_idx};

            viol_rob_age[v]     = ld_age;
            viol_rob_idx_arr[v] = queue[v].rob_idx;

            addr_overlap = (queue[v].addr[63:3] == st_addr[63:3]) &&
                           ((ld_bmask[v] & st_bmask) != 8'h00);
            is_younger = (ld_age > st_age);

            if (st_addr_valid &&
                queue[v].valid &&
                queue[v].executed &&
                addr_overlap &&
                is_younger) begin
                viol_mask[v] = 1'b1;
                if (!any_viol || (ld_age < best_age)) begin
                    best_age     = ld_age;
                    best_rob_idx = queue[v].rob_idx;
                end
                any_viol = 1'b1;
            end
        end
    end

    assign ordering_violation = any_viol;
    assign violation_rob_idx  = best_rob_idx;

    // =========================================================================
    // LQ owner checks
    // =========================================================================
    logic exec_owner_match;
    logic exec1_owner_match;
    logic result0_owner_match;
    logic result1_owner_match;

    assign exec_owner_match =
        exec_valid &&
        queue[exec_idx].valid &&
        (queue[exec_idx].rob_idx == exec_rob_idx);
    assign exec1_owner_match =
        exec1_valid &&
        queue[exec1_idx].valid &&
        (queue[exec1_idx].rob_idx == exec1_rob_idx);
    assign result0_owner_match =
        result0_valid &&
        queue[result0_idx].valid &&
        (queue[result0_idx].rob_idx == result0_rob_idx);
    assign result1_owner_match =
        result1_valid &&
        queue[result1_idx].valid &&
        (queue[result1_idx].rob_idx == result1_rob_idx);

    // =========================================================================
    // Partial flush survivor map
    // =========================================================================
    logic [LQ_IDX_BITS-1:0] partial_flush_head;
    logic [LQ_IDX_BITS-1:0] partial_flush_tail;
    logic [LQ_IDX_BITS:0]   partial_flush_base_count;
    logic [LQ_IDX_BITS:0]   partial_flush_count;
    logic [LQ_DEPTH-1:0]    partial_flush_keep;

    always_comb begin
        logic [ROB_AGE_BITS-1:0] flush_tail_age;
        logic [ROB_AGE_BITS-1:0] entry_age;
        logic [LQ_IDX_BITS-1:0]  scan_idx;

        partial_flush_head       = LQ_IDX_BITS'(head_r + LQ_IDX_BITS'(commit_count));
        partial_flush_tail       = partial_flush_head;
        partial_flush_base_count = '0;
        partial_flush_count      = '0;
        partial_flush_keep       = '0;

        if (count_r >= (LQ_IDX_BITS+1)'(commit_count))
            partial_flush_base_count = count_r - (LQ_IDX_BITS+1)'(commit_count);

        flush_tail_age = rob_age_from_head(flush_rob_tail);

        for (int step = 0; step < LQ_DEPTH; step++) begin
            if (step < int'(partial_flush_base_count)) begin
                scan_idx  = LQ_IDX_BITS'(partial_flush_head + LQ_IDX_BITS'(step));
                entry_age = rob_age_from_head(queue[scan_idx].rob_idx);
                if (queue[scan_idx].valid && (entry_age < flush_tail_age)) begin
                    partial_flush_keep[scan_idx] = 1'b1;
                    partial_flush_count          = partial_flush_count + (LQ_IDX_BITS+1)'(1);
                end
            end
        end

        partial_flush_tail = LQ_IDX_BITS'(partial_flush_head + LQ_IDX_BITS'(partial_flush_count));
    end

`ifndef SYNTHESIS
    logic trace_ordv_int_en;
    initial begin
        trace_ordv_int_en = 1'b0;
        if ($test$plusargs("TRACE_ORDV_INT"))
            trace_ordv_int_en = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (trace_ordv_int_en && ordering_violation) begin
            logic selected_match;
            selected_match = 1'b0;
            $display("[LQ_ORDV] head=%0d st_rob=%0d st_age=%0d viol_rob=%0d st_addr=%016h st_bmask=%02h",
                rob_head, st_rob_idx, st_age, violation_rob_idx, st_addr, st_bmask);
            for (int d = 0; d < LQ_DEPTH; d++) begin
                if (queue[d].valid && queue[d].executed &&
                    (queue[d].addr[63:3] == st_addr[63:3])) begin
                    logic [ROB_AGE_BITS-1:0] dbg_manual_age;
                    if (queue[d].rob_idx >= rob_head)
                        dbg_manual_age = {1'b0, queue[d].rob_idx} - {1'b0, rob_head};
                    else
                        dbg_manual_age = ROB_DEPTH[ROB_AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, queue[d].rob_idx};
                    $display("[LQ_ORDV_ENT] idx=%0d rob=%0d addr=%016h ld_age=%0d manual_age=%0d overlap=%02h younger=%b manual_younger=%b viol=%b has_result=%b",
                        d,
                        queue[d].rob_idx,
                        queue[d].addr,
                        viol_rob_age[d],
                        dbg_manual_age,
                        (ld_bmask[d] & st_bmask),
                        (viol_rob_age[d] > st_age),
                        (dbg_manual_age > st_age),
                        viol_mask[d],
                        queue[d].has_result);
                end
                if (viol_mask[d] && (queue[d].rob_idx == violation_rob_idx))
                    selected_match = 1'b1;
            end
            if (!selected_match) begin
                $display("[LQ_ORDV_SEL_MISMATCH] viol_rob=%0d had no matching viol_mask entry",
                    violation_rob_idx);
            end
        end
    end
`endif

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
        end else if (flush_valid) begin
            // Partial flush: retire same-cycle committed loads, then keep
            // only entries older than the ROB flush tail. Allocation is
            // intentionally suppressed on the flush cycle.
            head_r  <= partial_flush_head;
            tail_r  <= partial_flush_tail;
            count_r <= partial_flush_count;

            for (int i = 0; i < LQ_DEPTH; i++) begin
                if (!partial_flush_keep[i])
                    queue[i] <= '0;
            end

            if (exec_owner_match && partial_flush_keep[exec_idx]) begin
                queue[exec_idx].addr        <= exec_addr;
                queue[exec_idx].size        <= exec_size;
                queue[exec_idx].is_unsigned <= exec_is_unsigned;
                queue[exec_idx].addr_valid  <= 1'b1;
                queue[exec_idx].executed    <= 1'b1;
            end
            if (exec1_owner_match && partial_flush_keep[exec1_idx]) begin
                queue[exec1_idx].addr        <= exec1_addr;
                queue[exec1_idx].size        <= exec1_size;
                queue[exec1_idx].is_unsigned <= exec1_is_unsigned;
                queue[exec1_idx].addr_valid  <= 1'b1;
                queue[exec1_idx].executed    <= 1'b1;
            end
            if (result0_owner_match && partial_flush_keep[result0_idx]) begin
                queue[result0_idx].data       <= result0_data;
                queue[result0_idx].has_result <= 1'b1;
            end
            if (result1_owner_match && partial_flush_keep[result1_idx]) begin
                queue[result1_idx].data       <= result1_data;
                queue[result1_idx].has_result <= 1'b1;
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
            if (exec_owner_match) begin
                queue[exec_idx].addr        <= exec_addr;
                queue[exec_idx].size        <= exec_size;
                queue[exec_idx].is_unsigned <= exec_is_unsigned;
                queue[exec_idx].addr_valid  <= 1'b1;
                queue[exec_idx].executed    <= 1'b1;
            end
            if (exec1_owner_match) begin
                queue[exec1_idx].addr        <= exec1_addr;
                queue[exec1_idx].size        <= exec1_size;
                queue[exec1_idx].is_unsigned <= exec1_is_unsigned;
                queue[exec1_idx].addr_valid  <= 1'b1;
                queue[exec1_idx].executed    <= 1'b1;
            end

            // --- Result fill: record loaded data ---
            if (result0_owner_match) begin
                queue[result0_idx].data       <= result0_data;
                queue[result0_idx].has_result <= 1'b1;
            end
            if (result1_owner_match) begin
                queue[result1_idx].data       <= result1_data;
                queue[result1_idx].has_result <= 1'b1;
            end

            // --- Allocate new entries ---
            for (int a = 0; a < PIPE_WIDTH; a++) begin
                if (a < int'(alloc_count)) begin
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].valid      <= 1'b1;
                    queue[LQ_IDX_BITS'(tail_r + LQ_IDX_BITS'(a))].rob_idx    <= alloc_rob_idx[a];
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
