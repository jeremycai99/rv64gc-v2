/* file: free_list.sv
 Description: Physical register free list with 6-wide alloc/dealloc.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module free_list
    import rv64gc_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Allocate: up to 6 per cycle
    input logic [2:0] alloc_req_count,
    output logic [PHYS_REG_BITS-1:0] alloc_preg [0:PIPE_WIDTH-1],
    output logic [2:0] alloc_avail_count,

    // Release: up to 6 per cycle (from commit, old_pdst returns to free)
    input logic [2:0] release_count,
    input logic [PHYS_REG_BITS-1:0] release_preg [0:PIPE_WIDTH-1],

    // Commit pdst (new dest preg, to mark in-use in committed bitmap)
    input logic [PIPE_WIDTH-1:0]          commit_wr_valid,
    input logic [PHYS_REG_BITS-1:0]       commit_pdst [0:PIPE_WIDTH-1],

    // Checkpoint save
    input logic ckpt_save,
    input logic [CHECKPOINT_BITS-1:0] ckpt_save_id,
    // Checkpoint restore
    input logic ckpt_restore,
    input logic [CHECKPOINT_BITS-1:0] ckpt_restore_id,
    // Full flush
    input logic flush
);

    // -------------------------------------------------------------------------
    // Free bitmap: bit i = 1 means physical register i is free
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] free_bitmap;

    // Initial state constant: regs 0-31 in use, 32-255 free
    localparam logic [INT_PRF_DEPTH-1:0] INIT_BITMAP = {{(INT_PRF_DEPTH - ARCH_REGS){1'b1}}, {ARCH_REGS{1'b0}}};

    // -------------------------------------------------------------------------
    // Committed free bitmap: tracks which pregs are free in the committed
    // architectural state.  Updated on every commit cycle.
    // On full flush the speculative bitmap is restored from this.
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] committed_bitmap;

    // -------------------------------------------------------------------------
    // Checkpoint storage
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] ckpt_bitmap [0:NUM_CHECKPOINTS-1];

    // -------------------------------------------------------------------------
    // Cascading priority encoder for allocation
    //
    // Each stage finds the lowest set bit in a working bitmap, records it,
    // then clears that bit for the next stage.
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] work_bitmap [0:PIPE_WIDTH];
    logic [PHYS_REG_BITS-1:0] found_idx [0:PIPE_WIDTH-1];
    logic found_valid [0:PIPE_WIDTH-1];

    always_comb begin
        work_bitmap[0] = free_bitmap;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Default: nothing found
            found_idx[i]   = '0;
            found_valid[i] = 1'b0;

            // Find lowest set bit via one-hot isolation
            // one_hot = bitmap & (-bitmap) isolates the lowest set bit
            // Then encode it to an index with a priority scan
            if (work_bitmap[i] != '0) begin
                found_valid[i] = 1'b1;
                found_idx[i]   = '0;
                for (int b = 0; b < INT_PRF_DEPTH; b++) begin
                    if (work_bitmap[i][b]) begin
                        found_idx[i] = PHYS_REG_BITS'(b);
                        break;
                    end
                end
            end

            // Clear the found bit for the next stage
            if (found_valid[i]) begin
                work_bitmap[i+1] = work_bitmap[i] & ~(INT_PRF_DEPTH'(1) << found_idx[i]);
            end else begin
                work_bitmap[i+1] = work_bitmap[i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output: allocated registers and available count
    // -------------------------------------------------------------------------
    always_comb begin
        alloc_avail_count = 3'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            alloc_preg[i] = found_idx[i];
            if (found_valid[i] && (3'(i) < alloc_req_count)) begin
                alloc_avail_count = 3'(i + 1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // TRACE_LEAK cycle counter + enable (sim-only, inline $display uses these).
    // Separate always_ff to keep the state-change always_ff blocks untouched
    // apart from the inline $display calls.
    // -------------------------------------------------------------------------
`ifdef SIMULATION
    integer leak_cyc;
    logic   trace_leak_en;
    logic   stat_dump_en;
    integer stat_alloc_count;
    integer stat_release_count;
    integer stat_flush_count;
    integer stat_commit_count;
    integer stat_free_min;
    integer stat_committed_min;
    integer stat_free_now, stat_committed_now;

    initial begin
        trace_leak_en = ($test$plusargs("TRACE_LEAK") ? 1'b1 : 1'b0);
        stat_dump_en  = ($test$plusargs("STAT_DUMP")  ? 1'b1 : 1'b0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            leak_cyc           <= 0;
            stat_alloc_count   <= 0;
            stat_release_count <= 0;
            stat_flush_count   <= 0;
            stat_commit_count  <= 0;
            stat_free_min      <= INT_PRF_DEPTH;
            stat_committed_min <= INT_PRF_DEPTH;
        end else begin
            leak_cyc <= leak_cyc + 1;

            // Accumulate counters (approximate; multi-slot cycles count each)
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (found_valid[i] && (3'(i) < alloc_req_count))
                    stat_alloc_count   <= stat_alloc_count + 1;
                if ((3'(i) < release_count) && (release_preg[i] != '0))
                    stat_release_count <= stat_release_count + 1;
                if (commit_wr_valid[i] && (commit_pdst[i] != '0))
                    stat_commit_count  <= stat_commit_count + 1;
            end
            if (flush) stat_flush_count <= stat_flush_count + 1;

            // Popcount sample every 10K cycles
            if (stat_dump_en && ((leak_cyc % 10000) == 9999)) begin
                stat_free_now      = 0;
                stat_committed_now = 0;
                for (int b = 0; b < INT_PRF_DEPTH; b++) begin
                    if (free_bitmap[b])      stat_free_now      = stat_free_now + 1;
                    if (committed_bitmap[b]) stat_committed_now = stat_committed_now + 1;
                end
                if (stat_free_now      < stat_free_min)      stat_free_min      <= stat_free_now;
                if (stat_committed_now < stat_committed_min) stat_committed_min <= stat_committed_now;
                $display("[FL_STATS] cyc=%0d free_cnt=%0d committed_cnt=%0d free_min=%0d committed_min=%0d allocs=%0d releases=%0d flushes=%0d commits=%0d",
                    leak_cyc, stat_free_now, stat_committed_now,
                    stat_free_min, stat_committed_min,
                    stat_alloc_count, stat_release_count, stat_flush_count, stat_commit_count);
            end
        end
    end

    final begin
        $display("");
        $display("=== FREE_LIST FINAL SUMMARY (cyc=%0d) ===", leak_cyc);
        $display("Total allocs:   %0d", stat_alloc_count);
        $display("Total releases: %0d", stat_release_count);
        $display("Total commits:  %0d", stat_commit_count);
        $display("Total flushes:  %0d", stat_flush_count);
        $display("Min free_bitmap popcount (samples): %0d (of %0d)",
            stat_free_min, INT_PRF_DEPTH);
        $display("Min committed_bitmap popcount (samples): %0d (expected: %0d)",
            stat_committed_min, INT_PRF_DEPTH - ARCH_REGS);
    end
`endif

    // -------------------------------------------------------------------------
    // Sequential: bitmap update, release, checkpoint, flush
    // Inline TRACE_LEAK logging attached at each state-change site: the inputs
    // that cause a transition are read in the same cycle they're applied, so
    // no attribution lag.  `was=` shows the bit's pre-update value; a no-op
    // (e.g. was=1 before a release, was=0 before a commit-alloc) indicates
    // a redundant request — frequently a bug signal.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap <= INIT_BITMAP;
        end else if (flush) begin
            // Restore from committed bitmap, then apply same-cycle commit
            // updates so the mispredicting instruction's mapping is captured.
            free_bitmap <= committed_bitmap;
`ifdef SIMULATION
            if (trace_leak_en)
                $display("[FL_FREE_FLUSH] cyc=%0d restore<=committed_bitmap  rel_cnt=%0d  +same_cycle_apply",
                    leak_cyc, release_count);
`endif
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if ((3'(i) < release_count) && (release_preg[i] != '0)) begin
                    free_bitmap[release_preg[i]] <= 1'b1;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[FL_FREE_REL] cyc=%0d slot=%0d pdst=%0d was=%0b flush=1 cmt_wr=%0b cmt_pdst=%0d",
                            leak_cyc, i, release_preg[i], free_bitmap[release_preg[i]],
                            commit_wr_valid[i], commit_pdst[i]);
`endif
                end
                if (commit_wr_valid[i] && (commit_pdst[i] != '0)) begin
                    free_bitmap[commit_pdst[i]] <= 1'b0;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[FL_FREE_CMT] cyc=%0d slot=%0d pdst=%0d was=%0b flush=1 rel=%0d",
                            leak_cyc, i, commit_pdst[i], free_bitmap[commit_pdst[i]],
                            release_preg[i]);
`endif
                end
            end
        end else if (ckpt_restore) begin
            free_bitmap <= ckpt_bitmap[ckpt_restore_id];
`ifdef SIMULATION
            if (trace_leak_en)
                $display("[FL_FREE_CKPT] cyc=%0d restore_id=%0d", leak_cyc, ckpt_restore_id);
`endif
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                // Allocations: clear bits that were allocated
                if (found_valid[i] && (3'(i) < alloc_req_count)) begin
                    free_bitmap[found_idx[i]] <= 1'b0;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[FL_FREE_ALC] cyc=%0d slot=%0d pdst=%0d was=%0b alc_req=%0d",
                            leak_cyc, i, found_idx[i], free_bitmap[found_idx[i]], alloc_req_count);
`endif
                end
                // Releases: set bits back to free (never release p0)
                if ((3'(i) < release_count) && (release_preg[i] != '0)) begin
                    free_bitmap[release_preg[i]] <= 1'b1;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[FL_FREE_REL] cyc=%0d slot=%0d pdst=%0d was=%0b flush=0 cmt_wr=%0b cmt_pdst=%0d rel_cnt=%0d",
                            leak_cyc, i, release_preg[i], free_bitmap[release_preg[i]],
                            commit_wr_valid[i], commit_pdst[i], release_count);
`endif
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Committed bitmap update: track committed state for full-flush recovery
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            committed_bitmap <= INIT_BITMAP;
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                // Release old_pdst (becomes free in committed state)
                if ((3'(i) < release_count) && (release_preg[i] != '0)) begin
                    committed_bitmap[release_preg[i]] <= 1'b1;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[CB_REL] cyc=%0d slot=%0d pdst=%0d was=%0b cmt_wr=%0b cmt_pdst=%0d rel_cnt=%0d",
                            leak_cyc, i, release_preg[i], committed_bitmap[release_preg[i]],
                            commit_wr_valid[i], commit_pdst[i], release_count);
`endif
                end
                // Mark pdst as in-use (committed destination)
                if (commit_wr_valid[i] && (commit_pdst[i] != '0)) begin
                    committed_bitmap[commit_pdst[i]] <= 1'b0;
`ifdef SIMULATION
                    if (trace_leak_en)
                        $display("[CB_CMT] cyc=%0d slot=%0d pdst=%0d was=%0b rel=%0d rel_cnt=%0d",
                            leak_cyc, i, commit_pdst[i], committed_bitmap[commit_pdst[i]],
                            release_preg[i], release_count);
`endif
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Checkpoint save (independent of bitmap update)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < NUM_CHECKPOINTS; c++) begin
                ckpt_bitmap[c] <= INIT_BITMAP;
            end
        end else if (ckpt_save) begin
            ckpt_bitmap[ckpt_save_id] <= free_bitmap;
        end
    end

endmodule
