/* file: store_queue.sv
 Description: Store queue with store-to-load forwarding.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef STORE_QUEUE_SV
`define STORE_QUEUE_SV

module store_queue
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Allocate (from rename, up to 6 per cycle)
    input logic [2:0] alloc_count,
    input logic [ROB_IDX_BITS-1:0] alloc_rob_idx [0:PIPE_WIDTH-1],
    output logic [SQ_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1],
    output logic full,

    // STA fill (store address computed by store AGU)
    input logic sta_valid,
    input logic [SQ_IDX_BITS-1:0] sta_idx,
    input logic [ROB_IDX_BITS-1:0] sta_rob_idx,
    input logic [63:0] sta_addr,
    input logic [1:0] sta_size,

    // STD fill (store data from register file)
    input logic std_valid,
    input logic [SQ_IDX_BITS-1:0] std_idx,
    input logic [ROB_IDX_BITS-1:0] std_rob_idx,
    input logic [63:0] std_data,
    input logic [7:0] std_byte_mask,

    // Store-to-load forwarding (from load queue)
    input logic fwd_req_valid,
    input logic [63:0] fwd_req_addr,
    input logic [1:0] fwd_req_size,
    input logic [ROB_IDX_BITS-1:0] fwd_req_rob_idx,
    output logic fwd_hit,
    output logic fwd_partial,
    output logic fwd_wait,
    output logic fwd_wait_addr_unknown,
    output logic fwd_wait_data_missing,
    output logic [63:0] fwd_data,

    // Address-known / data-not-ready hazard check for a second load request
    input logic wait_req_valid,
    input logic [63:0] wait_req_addr,
    input logic [1:0] wait_req_size,
    input logic [ROB_IDX_BITS-1:0] wait_req_rob_idx,
    output logic wait_fwd_hit,
    output logic wait_partial,
    output logic wait_wait,
    output logic wait_wait_addr_unknown,
    output logic wait_wait_data_missing,
    output logic [63:0] wait_data,
    output logic wait_hit,
    input logic [ROB_IDX_BITS-1:0] rob_head,

    // Commit (from commit unit)
    input logic [2:0] commit_count,

    // Drain to committed store buffer
    output logic drain_valid,
    output sq_entry_t drain_entry,
    input logic drain_ready,

    // Flush
    input logic flush_valid,
    input logic [ROB_IDX_BITS-1:0] flush_rob_tail,
    input logic flush_full
);

`ifndef SYNTHESIS
    bit trace_sq_alloc_fill;
    bit trace_sq_fill_check;
    bit trace_stack_store;
    logic                    sta_fill_check_pending_r;
    logic [SQ_IDX_BITS-1:0]  sta_fill_check_idx_r;
    logic [ROB_IDX_BITS-1:0] sta_fill_check_rob_r;
    logic                    std_fill_check_pending_r;
    logic [SQ_IDX_BITS-1:0]  std_fill_check_idx_r;
    initial trace_sq_alloc_fill = $test$plusargs("TRACE_SQ_ALLOC_FILL");
    initial trace_sq_fill_check = $test$plusargs("TRACE_SQ_FILL_CHECK");
    initial trace_stack_store   = $test$plusargs("TRACE_STACK_STORE");

    function automatic logic trace_stack_addr(input logic [63:0] addr);
        trace_stack_addr = (addr[63:12] == 52'h800ff);
    endfunction
`endif

    // =========================================================================
    // Storage
    // =========================================================================
    sq_entry_t queue [0:SQ_DEPTH-1];

    // Head = oldest entry (drain side). Tail = next free slot (alloc side).
    // commit_ptr = next entry to be marked committed.
    // count has one extra bit to distinguish full from empty.
    logic [SQ_IDX_BITS-1:0] head_r;
    logic [SQ_IDX_BITS-1:0] tail_r;
    logic [SQ_IDX_BITS-1:0] commit_ptr_r;
    logic [SQ_IDX_BITS:0]   count_r;

    // =========================================================================
    // Alloc index combinational outputs
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_alloc_idx
            assign alloc_idx[gi] = SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(gi));
        end
    endgenerate

    // Not enough space for a full PIPE_WIDTH allocation
    assign full = (count_r >= (SQ_IDX_BITS+1)'(SQ_DEPTH - PIPE_WIDTH + 1));

    // =========================================================================
    // Drain logic (combinational)
    // =========================================================================
    assign drain_valid = queue[head_r].valid & queue[head_r].committed
                       & queue[head_r].addr_valid & queue[head_r].data_valid;
    assign drain_entry = queue[head_r];

    logic sta_fill_accept;
    logic std_fill_accept;

    assign sta_fill_accept = sta_valid &&
                             queue[sta_idx].valid &&
                             (queue[sta_idx].rob_idx == sta_rob_idx);
    assign std_fill_accept = std_valid &&
                             queue[std_idx].valid &&
                             (queue[std_idx].rob_idx == std_rob_idx);

    // =========================================================================
    // Forwarding: byte mask for the load request
    // =========================================================================
    logic [7:0] fwd_req_bmask;
    logic [2:0] fwd_req_off;
    assign fwd_req_off = fwd_req_addr[2:0];

    always_comb begin
        case (fwd_req_size)
            2'd0:    fwd_req_bmask = 8'h01 << fwd_req_off;
            2'd1:    fwd_req_bmask = 8'h03 << fwd_req_off;
            2'd2:    fwd_req_bmask = 8'h0F << fwd_req_off;
            default: fwd_req_bmask = 8'hFF;
        endcase
    end

    logic [7:0] wait_req_bmask;
    logic [2:0] wait_req_off;
    assign wait_req_off = wait_req_addr[2:0];

    always_comb begin
        case (wait_req_size)
            2'd0:    wait_req_bmask = 8'h01 << wait_req_off;
            2'd1:    wait_req_bmask = 8'h03 << wait_req_off;
            2'd2:    wait_req_bmask = 8'h0F << wait_req_off;
            default: wait_req_bmask = 8'hFF;
        endcase
    end

    // =========================================================================
    // Forwarding: per-entry CAM
    // =========================================================================
    localparam int ROB_AGE_BITS = ROB_IDX_BITS + 1;

    function automatic logic [ROB_AGE_BITS-1:0] rob_age_from_head(
        input logic [ROB_IDX_BITS-1:0] idx
    );
        if (idx >= rob_head)
            rob_age_from_head = {1'b0, idx} - {1'b0, rob_head};
        else
            rob_age_from_head = ROB_DEPTH[ROB_AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, idx};
    endfunction

    always_comb begin
        logic [ROB_AGE_BITS-1:0] fwd_req_age;
        logic [7:0]              fwd_cover_mask;
        logic [7:0]              fwd_wait_mask;
        logic [7:0]              fwd_wait_addr_mask;
        logic [7:0]              fwd_wait_data_mask;
        logic                    fwd_cross_block;
        logic                    fwd_req_cross_dword;
        logic [3:0]              fwd_req_size_bytes;
        logic [63:0]             fwd_req_last_addr;

        fwd_req_age   = rob_age_from_head(fwd_req_rob_idx);
        fwd_cover_mask = '0;
        fwd_wait_mask  = '0;
        fwd_wait_addr_mask = '0;
        fwd_wait_data_mask = '0;
        fwd_cross_block = 1'b0;
        case (fwd_req_size)
            2'd0: begin
                fwd_req_size_bytes = 4'd1;
                fwd_req_cross_dword = 1'b0;
            end
            2'd1: begin
                fwd_req_size_bytes = 4'd2;
                fwd_req_cross_dword = (fwd_req_addr[2:0] > 3'd6);
            end
            2'd2: begin
                fwd_req_size_bytes = 4'd4;
                fwd_req_cross_dword = (fwd_req_addr[2:0] > 3'd4);
            end
            default: begin
                fwd_req_size_bytes = 4'd8;
                fwd_req_cross_dword = (fwd_req_addr[2:0] != 3'd0);
            end
        endcase
        fwd_req_last_addr = fwd_req_addr + {60'd0, fwd_req_size_bytes} - 64'd1;
        fwd_data       = '0;

        for (int step = 0; step < SQ_DEPTH; step++) begin
            if (step < int'(count_r)) begin
                logic [SQ_IDX_BITS-1:0] scan_idx;
                logic [7:0]             scan_bmask;
                logic [7:0]             overlap_mask;
                logic [7:0]             uncovered_mask;
                logic [ROB_AGE_BITS-1:0] store_age;
                logic                   store_is_older;
	                logic                   addr_match;
	                logic                   data_ready;
	                logic                   std_match_scan;
	                logic                   sta_match_scan;
	                logic                   scan_addr_valid;
	                logic [63:0]            scan_addr;
	                logic [1:0]             scan_size;
	                logic [63:0]            data_value;
	                logic                   scan_cross_dword;
                    logic [3:0]             scan_size_bytes;
                    logic [63:0]            scan_last_addr;
                    logic                   range_overlap;
	                int                     idx_int;

                idx_int = int'(tail_r) - step - 1;
                if (idx_int < 0)
                    idx_int = idx_int + SQ_DEPTH;
                scan_idx = SQ_IDX_BITS'(idx_int);

	                std_match_scan = std_valid &&
	                                 queue[scan_idx].valid &&
	                                 (std_idx == scan_idx) &&
	                                 (queue[scan_idx].rob_idx == std_rob_idx);
	                sta_match_scan = sta_valid &&
	                                 queue[scan_idx].valid &&
	                                 (sta_idx == scan_idx) &&
	                                 (queue[scan_idx].rob_idx == sta_rob_idx);
	                scan_addr_valid = queue[scan_idx].addr_valid || sta_match_scan;
	                scan_addr       = sta_match_scan ? sta_addr : queue[scan_idx].addr;
	                scan_size       = sta_match_scan ? sta_size : queue[scan_idx].size;
	
	                case (scan_size)
	                    2'd0:    scan_bmask = 8'h01 << scan_addr[2:0];
	                    2'd1:    scan_bmask = 8'h03 << scan_addr[2:0];
	                    2'd2:    scan_bmask = 8'h0F << scan_addr[2:0];
	                    default: scan_bmask = 8'hFF;
	                endcase
	                case (scan_size)
	                    2'd0: begin
                            scan_size_bytes = 4'd1;
                            scan_cross_dword = 1'b0;
                        end
	                    2'd1: begin
                            scan_size_bytes = 4'd2;
                            scan_cross_dword = (scan_addr[2:0] > 3'd6);
                        end
	                    2'd2: begin
                            scan_size_bytes = 4'd4;
                            scan_cross_dword = (scan_addr[2:0] > 3'd4);
                        end
	                    default: begin
                            scan_size_bytes = 4'd8;
                            scan_cross_dword = (scan_addr[2:0] != 3'd0);
                        end
	                endcase
                    scan_last_addr = scan_addr + {60'd0, scan_size_bytes} - 64'd1;
	
	                store_age      = rob_age_from_head(queue[scan_idx].rob_idx);
	                store_is_older = fwd_req_valid &&
	                                 queue[scan_idx].valid &&
	                                 (queue[scan_idx].committed || (store_age < fwd_req_age));
	                addr_match     = store_is_older &&
	                                 scan_addr_valid &&
	                                 (scan_addr[63:3] == fwd_req_addr[63:3]);
                    range_overlap  = store_is_older &&
                                     scan_addr_valid &&
                                     (scan_addr <= fwd_req_last_addr) &&
                                     (fwd_req_addr <= scan_last_addr);
	                overlap_mask   = addr_match ? (scan_bmask & fwd_req_bmask) : 8'h00;
	                if (range_overlap &&
	                    (scan_cross_dword || fwd_req_cross_dword || !addr_match))
	                    fwd_cross_block = 1'b1;
	                uncovered_mask = (store_is_older && !scan_addr_valid)
	                               ? (fwd_req_bmask & ~fwd_cover_mask)
	                               : (overlap_mask & ~fwd_cover_mask);
	                data_ready     = queue[scan_idx].data_valid ||
	                                 std_match_scan;
	                data_value     = std_match_scan
	                               ? std_data
	                               : queue[scan_idx].data;

	                if (store_is_older && !scan_addr_valid) begin
	                    fwd_wait_mask = fwd_wait_mask | uncovered_mask;
	                    fwd_wait_addr_mask = fwd_wait_addr_mask | uncovered_mask;
	                end else if (data_ready) begin
	                    for (int b = 0; b < 8; b++) begin
	                        if (uncovered_mask[b] &&
	                            (b >= int'(scan_addr[2:0]))) begin
	                            fwd_data[b*8 +: 8] =
	                                data_value[(b - int'(scan_addr[2:0])) * 8 +: 8];
	                        end
	                    end
	                    fwd_cover_mask = fwd_cover_mask | uncovered_mask;
                end else begin
                    fwd_wait_mask = fwd_wait_mask | uncovered_mask;
                    fwd_wait_data_mask = fwd_wait_data_mask | uncovered_mask;
                end
            end
        end

        fwd_hit               = fwd_req_valid && !fwd_cross_block &&
                                (fwd_cover_mask == fwd_req_bmask);
        fwd_partial           = fwd_req_valid &&
                                (((fwd_cover_mask != 8'h00) && !fwd_hit) ||
                                 fwd_cross_block);
        fwd_wait              = fwd_req_valid && (fwd_wait_mask != 8'h00);
        fwd_wait_addr_unknown = fwd_req_valid && (fwd_wait_addr_mask != 8'h00);
        fwd_wait_data_missing = fwd_req_valid && (fwd_wait_data_mask != 8'h00);
    end

    always_comb begin
        logic [ROB_AGE_BITS-1:0] wait_req_age_now;
        logic [7:0]              wait_cover_mask;
        logic [7:0]              wait_wait_mask;
        logic [7:0]              wait_wait_addr_mask;
        logic [7:0]              wait_wait_data_mask;
        logic                    wait_cross_block;
        logic                    wait_req_cross_dword;
        logic [3:0]              wait_req_size_bytes;
        logic [63:0]             wait_req_last_addr;

        wait_req_age_now = rob_age_from_head(wait_req_rob_idx);
        wait_cover_mask  = '0;
        wait_wait_mask   = '0;
        wait_wait_addr_mask = '0;
        wait_wait_data_mask = '0;
        wait_cross_block = 1'b0;
        case (wait_req_size)
            2'd0: begin
                wait_req_size_bytes = 4'd1;
                wait_req_cross_dword = 1'b0;
            end
            2'd1: begin
                wait_req_size_bytes = 4'd2;
                wait_req_cross_dword = (wait_req_addr[2:0] > 3'd6);
            end
            2'd2: begin
                wait_req_size_bytes = 4'd4;
                wait_req_cross_dword = (wait_req_addr[2:0] > 3'd4);
            end
            default: begin
                wait_req_size_bytes = 4'd8;
                wait_req_cross_dword = (wait_req_addr[2:0] != 3'd0);
            end
        endcase
        wait_req_last_addr = wait_req_addr + {60'd0, wait_req_size_bytes} - 64'd1;
        wait_data        = '0;

        for (int step = 0; step < SQ_DEPTH; step++) begin
            if (step < int'(count_r)) begin
                logic [SQ_IDX_BITS-1:0] scan_idx;
                logic [7:0]             scan_bmask;
                logic [7:0]             overlap_mask;
                logic [7:0]             uncovered_mask;
                logic [ROB_AGE_BITS-1:0] store_age;
                logic                   store_is_older;
	                logic                   addr_match;
	                logic                   data_ready;
	                logic                   std_match_scan;
	                logic                   sta_match_scan;
	                logic                   scan_addr_valid;
	                logic [63:0]            scan_addr;
	                logic [1:0]             scan_size;
	                logic [63:0]            data_value;
	                logic                   scan_cross_dword;
                    logic [3:0]             scan_size_bytes;
                    logic [63:0]            scan_last_addr;
                    logic                   range_overlap;
	                int                     idx_int;

                idx_int = int'(tail_r) - step - 1;
                if (idx_int < 0)
                    idx_int = idx_int + SQ_DEPTH;
                scan_idx = SQ_IDX_BITS'(idx_int);

	                std_match_scan = std_valid &&
	                                 queue[scan_idx].valid &&
	                                 (std_idx == scan_idx) &&
	                                 (queue[scan_idx].rob_idx == std_rob_idx);
	                sta_match_scan = sta_valid &&
	                                 queue[scan_idx].valid &&
	                                 (sta_idx == scan_idx) &&
	                                 (queue[scan_idx].rob_idx == sta_rob_idx);
	                scan_addr_valid = queue[scan_idx].addr_valid || sta_match_scan;
	                scan_addr       = sta_match_scan ? sta_addr : queue[scan_idx].addr;
	                scan_size       = sta_match_scan ? sta_size : queue[scan_idx].size;
	
	                case (scan_size)
	                    2'd0:    scan_bmask = 8'h01 << scan_addr[2:0];
	                    2'd1:    scan_bmask = 8'h03 << scan_addr[2:0];
	                    2'd2:    scan_bmask = 8'h0F << scan_addr[2:0];
	                    default: scan_bmask = 8'hFF;
	                endcase
	                case (scan_size)
	                    2'd0: begin
                            scan_size_bytes = 4'd1;
                            scan_cross_dword = 1'b0;
                        end
	                    2'd1: begin
                            scan_size_bytes = 4'd2;
                            scan_cross_dword = (scan_addr[2:0] > 3'd6);
                        end
	                    2'd2: begin
                            scan_size_bytes = 4'd4;
                            scan_cross_dword = (scan_addr[2:0] > 3'd4);
                        end
	                    default: begin
                            scan_size_bytes = 4'd8;
                            scan_cross_dword = (scan_addr[2:0] != 3'd0);
                        end
	                endcase
                    scan_last_addr = scan_addr + {60'd0, scan_size_bytes} - 64'd1;
	
	                store_age      = rob_age_from_head(queue[scan_idx].rob_idx);
	                store_is_older = wait_req_valid &&
	                                 queue[scan_idx].valid &&
	                                 (queue[scan_idx].committed || (store_age < wait_req_age_now));
	                addr_match     = store_is_older &&
	                                 scan_addr_valid &&
	                                 (scan_addr[63:3] == wait_req_addr[63:3]);
                    range_overlap  = store_is_older &&
                                     scan_addr_valid &&
                                     (scan_addr <= wait_req_last_addr) &&
                                     (wait_req_addr <= scan_last_addr);
	                overlap_mask   = addr_match ? (scan_bmask & wait_req_bmask) : 8'h00;
	                if (range_overlap &&
	                    (scan_cross_dword || wait_req_cross_dword || !addr_match))
	                    wait_cross_block = 1'b1;
	                uncovered_mask = (store_is_older && !scan_addr_valid)
	                               ? (wait_req_bmask & ~wait_cover_mask)
	                               : (overlap_mask & ~wait_cover_mask);
	                data_ready     = queue[scan_idx].data_valid ||
	                                 std_match_scan;
	                data_value     = std_match_scan
	                               ? std_data
	                               : queue[scan_idx].data;

	                if (store_is_older && !scan_addr_valid) begin
	                    wait_wait_mask = wait_wait_mask | uncovered_mask;
	                    wait_wait_addr_mask = wait_wait_addr_mask | uncovered_mask;
	                end else if (data_ready) begin
	                    for (int b = 0; b < 8; b++) begin
	                        if (uncovered_mask[b] &&
	                            (b >= int'(scan_addr[2:0]))) begin
	                            wait_data[b*8 +: 8] =
	                                data_value[(b - int'(scan_addr[2:0])) * 8 +: 8];
	                        end
	                    end
                    wait_cover_mask = wait_cover_mask | uncovered_mask;
                end else begin
                    wait_wait_mask = wait_wait_mask | uncovered_mask;
                    wait_wait_data_mask = wait_wait_data_mask | uncovered_mask;
                end
            end
        end

        wait_fwd_hit           = wait_req_valid && !wait_cross_block &&
                                 (wait_cover_mask == wait_req_bmask);
        wait_partial           = wait_req_valid &&
                                 (((wait_cover_mask != 8'h00) && !wait_fwd_hit) ||
                                  wait_cross_block);
        wait_wait              = wait_req_valid && (wait_wait_mask != 8'h00);
        wait_wait_addr_unknown = wait_req_valid && (wait_wait_addr_mask != 8'h00);
        wait_wait_data_missing = wait_req_valid && (wait_wait_data_mask != 8'h00);
    end

    assign wait_hit     = wait_wait;

    // =========================================================================
    // Flush-path commit pointer and bitmap (combinational, for ff flush path)
    // =========================================================================
    logic [SQ_IDX_BITS-1:0] flush_new_commit_ptr;
    logic [SQ_DEPTH-1:0]   flush_newly_committed;
    logic                  drain_fire_c;
    logic [SQ_IDX_BITS-1:0] full_flush_head;
    logic [SQ_IDX_BITS-1:0] full_flush_tail;
    logic [SQ_IDX_BITS:0]  full_flush_base_count;
    logic [SQ_IDX_BITS:0]  full_flush_count;
    logic [SQ_DEPTH-1:0]   full_flush_keep;
    logic [SQ_IDX_BITS-1:0] partial_flush_head;
    logic [SQ_IDX_BITS-1:0] partial_flush_tail;
    logic [SQ_IDX_BITS:0]   partial_flush_base_count;
    logic [SQ_IDX_BITS:0]   partial_flush_count;
    logic [SQ_DEPTH-1:0]    partial_flush_keep;

    assign drain_fire_c = drain_valid && drain_ready;

    always_comb begin
        flush_new_commit_ptr = SQ_IDX_BITS'(commit_ptr_r + commit_count);
        flush_newly_committed = '0;
        for (int c = 0; c < PIPE_WIDTH; c++) begin
            if (c < int'(commit_count)) begin
                flush_newly_committed[SQ_IDX_BITS'(commit_ptr_r + SQ_IDX_BITS'(c))] = 1'b1;
            end
        end
    end

    always_comb begin
        logic [ROB_AGE_BITS-1:0] flush_tail_age;
        logic [ROB_AGE_BITS-1:0] entry_age;
        logic [SQ_IDX_BITS-1:0]  scan_idx;
        logic                    entry_committed_after;

        partial_flush_head       = SQ_IDX_BITS'(head_r + SQ_IDX_BITS'(drain_fire_c));
        partial_flush_tail       = partial_flush_head;
        partial_flush_base_count = '0;
        partial_flush_count      = '0;
        partial_flush_keep       = '0;

        if (count_r >= (SQ_IDX_BITS+1)'(drain_fire_c))
            partial_flush_base_count = count_r - (SQ_IDX_BITS+1)'(drain_fire_c);

        flush_tail_age = rob_age_from_head(flush_rob_tail);

        for (int step = 0; step < SQ_DEPTH; step++) begin
            if (step < int'(partial_flush_base_count)) begin
                scan_idx = SQ_IDX_BITS'(partial_flush_head + SQ_IDX_BITS'(step));
                entry_committed_after = queue[scan_idx].committed ||
                                        flush_newly_committed[scan_idx];
                entry_age = rob_age_from_head(queue[scan_idx].rob_idx);
                if (queue[scan_idx].valid &&
                    (entry_committed_after || (entry_age < flush_tail_age))) begin
                    partial_flush_keep[scan_idx] = 1'b1;
                    partial_flush_count          = partial_flush_count + (SQ_IDX_BITS+1)'(1);
                end
            end
        end

        partial_flush_tail = SQ_IDX_BITS'(partial_flush_head + SQ_IDX_BITS'(partial_flush_count));
    end

    always_comb begin
        logic [SQ_IDX_BITS-1:0] scan_idx;
        logic                   entry_committed_after;

        full_flush_head       = SQ_IDX_BITS'(head_r + SQ_IDX_BITS'(drain_fire_c));
        full_flush_tail       = full_flush_head;
        full_flush_base_count = '0;
        full_flush_count      = '0;
        full_flush_keep       = '0;

        if (count_r >= (SQ_IDX_BITS+1)'(drain_fire_c))
            full_flush_base_count = count_r - (SQ_IDX_BITS+1)'(drain_fire_c);

        for (int step = 0; step < SQ_DEPTH; step++) begin
            if (step < int'(full_flush_base_count)) begin
                scan_idx = SQ_IDX_BITS'(full_flush_head + SQ_IDX_BITS'(step));
                entry_committed_after = queue[scan_idx].committed ||
                                        flush_newly_committed[scan_idx];
                if (queue[scan_idx].valid && entry_committed_after) begin
                    full_flush_keep[scan_idx] = 1'b1;
                    full_flush_count          = full_flush_count + (SQ_IDX_BITS+1)'(1);
                end
            end
        end

        full_flush_tail = SQ_IDX_BITS'(full_flush_head + SQ_IDX_BITS'(full_flush_count));
    end

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_r       <= '0;
            tail_r       <= '0;
            commit_ptr_r <= '0;
            count_r      <= '0;
            for (int i = 0; i < SQ_DEPTH; i++) begin
                queue[i] <= '0;
            end
`ifndef SYNTHESIS
            sta_fill_check_pending_r <= 1'b0;
            std_fill_check_pending_r <= 1'b0;
`endif
        end else if (flush_valid && flush_full) begin
            // Full redirect recovery keeps only stores that are committed
            // after this cycle's commit markings.  A same-cycle drain has
            // already been handed to the CSB, so drop it from the SQ here.
            head_r       <= full_flush_head;
            tail_r       <= full_flush_tail;
            commit_ptr_r <= full_flush_tail;
            count_r      <= full_flush_count;

            for (int i = 0; i < SQ_DEPTH; i++) begin
                if (full_flush_keep[i]) begin
                    if (flush_newly_committed[i])
                        queue[i].committed <= 1'b1;
                end else begin
                    queue[i] <= '0;
                end
            end
`ifndef SYNTHESIS
            sta_fill_check_pending_r <= 1'b0;
            std_fill_check_pending_r <= 1'b0;
`endif
        end else if (flush_valid) begin
            // Partial flush: preserve committed stores plus speculative stores
            // older than the ROB flush tail. Same-cycle drain and commit are
            // accounted before survivor selection; allocation is suppressed.
            head_r       <= partial_flush_head;
            tail_r       <= partial_flush_tail;
            commit_ptr_r <= flush_new_commit_ptr;
            count_r      <= partial_flush_count;

            for (int i = 0; i < SQ_DEPTH; i++) begin
                if (partial_flush_keep[i]) begin
                    if (flush_newly_committed[i])
                        queue[i].committed <= 1'b1;
                end else begin
                    queue[i] <= '0;
                end
            end

            if (sta_fill_accept && partial_flush_keep[sta_idx]) begin
                queue[sta_idx].addr       <= sta_addr;
                queue[sta_idx].size       <= sta_size;
                queue[sta_idx].addr_valid <= 1'b1;
            end

            if (std_fill_accept && partial_flush_keep[std_idx]) begin
                queue[std_idx].data       <= std_data;
                queue[std_idx].byte_mask  <= std_byte_mask;
                queue[std_idx].data_valid <= 1'b1;
            end
`ifndef SYNTHESIS
            if (trace_stack_store) begin
                if (sta_valid && !(sta_fill_accept && partial_flush_keep[sta_idx])) begin
                    $display("[SQ_STA_REJECT] t=%0t idx=%0d fill_rob=%0d entry_valid=%0b entry_rob=%0d flush=1 keep=%0b addr=%016h",
                             $time, sta_idx, sta_rob_idx,
                             queue[sta_idx].valid, queue[sta_idx].rob_idx,
                             partial_flush_keep[sta_idx], sta_addr);
                end
                if (std_valid && !(std_fill_accept && partial_flush_keep[std_idx])) begin
                    $display("[SQ_STD_REJECT] t=%0t idx=%0d fill_rob=%0d entry_valid=%0b entry_rob=%0d flush=1 keep=%0b data=%016h mask=%02h",
                             $time, std_idx, std_rob_idx,
                             queue[std_idx].valid, queue[std_idx].rob_idx,
                             partial_flush_keep[std_idx], std_data, std_byte_mask);
                end
            end
`endif
`ifndef SYNTHESIS
            sta_fill_check_pending_r <= 1'b0;
            std_fill_check_pending_r <= 1'b0;
`endif
        end else begin
`ifndef SYNTHESIS
            if (trace_sq_fill_check) begin
                if (sta_fill_check_pending_r && !queue[sta_fill_check_idx_r].addr_valid) begin
                    $display("[SQ_STA_FILL_MISS] t=%0t idx=%0d rob=%0d valid=%0b committed=%0b data_valid=%0b",
                             $time, sta_fill_check_idx_r, sta_fill_check_rob_r,
                             queue[sta_fill_check_idx_r].valid,
                             queue[sta_fill_check_idx_r].committed,
                             queue[sta_fill_check_idx_r].data_valid);
                end
                if (std_fill_check_pending_r && !queue[std_fill_check_idx_r].data_valid) begin
                    $display("[SQ_STD_FILL_MISS] t=%0t idx=%0d valid=%0b committed=%0b addr_valid=%0b rob=%0d",
                             $time, std_fill_check_idx_r,
                             queue[std_fill_check_idx_r].valid,
                             queue[std_fill_check_idx_r].committed,
                             queue[std_fill_check_idx_r].addr_valid,
                             queue[std_fill_check_idx_r].rob_idx);
                end
                if (sta_valid && !queue[sta_idx].valid) begin
                    $display("[SQ_STA_TO_INVALID] t=%0t idx=%0d rob=%0d tail=%0d count=%0d",
                             $time, sta_idx, sta_rob_idx, tail_r, count_r);
                end
                if (std_valid && !queue[std_idx].valid) begin
                    $display("[SQ_STD_TO_INVALID] t=%0t idx=%0d tail=%0d count=%0d",
                             $time, std_idx, tail_r, count_r);
                end
            end
`endif
            // --- Drain head committed entry ---
            if (drain_valid && drain_ready) begin
                queue[head_r].valid     <= 1'b0;
                queue[head_r].committed <= 1'b0;
                head_r  <= SQ_IDX_BITS'(head_r + 1'b1);
                count_r <= count_r - (SQ_IDX_BITS+1)'(1);
            end

            // --- Mark committed entries ---
            for (int c = 0; c < PIPE_WIDTH; c++) begin
                if (c < int'(commit_count)) begin
                    queue[SQ_IDX_BITS'(commit_ptr_r + SQ_IDX_BITS'(c))].committed <= 1'b1;
                end
            end
            if (commit_count != '0) begin
                commit_ptr_r <= SQ_IDX_BITS'(commit_ptr_r + commit_count);
            end

            // --- STA fill ---
            if (sta_fill_accept) begin
                queue[sta_idx].addr       <= sta_addr;
                queue[sta_idx].size       <= sta_size;
                queue[sta_idx].addr_valid <= 1'b1;
            end

            // --- STD fill ---
            if (std_fill_accept) begin
                queue[std_idx].data       <= std_data;
                queue[std_idx].byte_mask  <= std_byte_mask;
                queue[std_idx].data_valid <= 1'b1;
            end

`ifndef SYNTHESIS
            if (trace_stack_store) begin
                if (sta_valid && !sta_fill_accept) begin
                    $display("[SQ_STA_REJECT] t=%0t idx=%0d fill_rob=%0d entry_valid=%0b entry_rob=%0d addr=%016h",
                             $time, sta_idx, sta_rob_idx,
                             queue[sta_idx].valid, queue[sta_idx].rob_idx, sta_addr);
                end
                if (std_valid && !std_fill_accept) begin
                    $display("[SQ_STD_REJECT] t=%0t idx=%0d fill_rob=%0d entry_valid=%0b entry_rob=%0d data=%016h mask=%02h",
                             $time, std_idx, std_rob_idx,
                             queue[std_idx].valid, queue[std_idx].rob_idx, std_data, std_byte_mask);
                end
                if (sta_fill_accept && trace_stack_addr(sta_addr)) begin
                    $display("[SQ_STA_FILL] t=%0t idx=%0d rob=%0d addr=%016h size=%0d",
                             $time, sta_idx, sta_rob_idx, sta_addr, sta_size);
                end
                if (drain_valid && drain_ready && trace_stack_addr(queue[head_r].addr)) begin
                    $display("[SQ_DRAIN] t=%0t idx=%0d rob=%0d addr=%016h data=%016h mask=%02h",
                             $time, head_r, queue[head_r].rob_idx,
                             queue[head_r].addr, queue[head_r].data,
                             queue[head_r].byte_mask);
                end
            end
`endif

`ifndef SYNTHESIS
            if (trace_sq_alloc_fill) begin
                if (sta_valid) begin
                    for (int a = 0; a < PIPE_WIDTH; a++) begin
                        if ((a < int'(alloc_count)) &&
                            (sta_idx == SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a)))) begin
                            $display("[SQ_STA_ALLOC_COLLIDE] t=%0t sta_idx=%0d tail=%0d alloc_count=%0d sta_rob=%0d addr=%016h size=%0d",
                                     $time, sta_idx, tail_r, alloc_count, sta_rob_idx, sta_addr, sta_size);
                        end
                    end
                end
                if (std_valid) begin
                    for (int a = 0; a < PIPE_WIDTH; a++) begin
                        if ((a < int'(alloc_count)) &&
                            (std_idx == SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a)))) begin
                            $display("[SQ_STD_ALLOC_COLLIDE] t=%0t std_idx=%0d tail=%0d alloc_count=%0d mask=%02h data=%016h",
                                     $time, std_idx, tail_r, alloc_count, std_byte_mask, std_data);
                        end
                    end
                end
            end
`endif

            // --- Allocate new entries ---
            for (int a = 0; a < PIPE_WIDTH; a++) begin
                if (a < int'(alloc_count)) begin
                    queue[SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a))].valid      <= 1'b1;
                    queue[SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a))].rob_idx    <= alloc_rob_idx[a];
                    queue[SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a))].addr_valid <= 1'b0;
                    queue[SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a))].data_valid <= 1'b0;
                    queue[SQ_IDX_BITS'(tail_r + SQ_IDX_BITS'(a))].committed  <= 1'b0;
                end
            end
            if (alloc_count != '0) begin
                tail_r <= SQ_IDX_BITS'(tail_r + alloc_count);
                // count: +alloc_count, -1 if draining this cycle
                if (drain_valid && drain_ready) begin
                    count_r <= count_r + {4'b0, alloc_count} - (SQ_IDX_BITS+1)'(1);
                end else begin
                    count_r <= count_r + {4'b0, alloc_count};
                end
            end
`ifndef SYNTHESIS
            sta_fill_check_pending_r <= sta_valid;
            sta_fill_check_idx_r     <= sta_idx;
            sta_fill_check_rob_r     <= sta_rob_idx;
            std_fill_check_pending_r <= std_valid;
            std_fill_check_idx_r     <= std_idx;
`endif
        end
    end

endmodule

`endif
