/* file: dispatch_queue.sv
 Description: Dispatch queue buffering renamed instructions for issue.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef DISPATCH_QUEUE_SV
`define DISPATCH_QUEUE_SV

module dispatch_queue
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire clk,
    input  wire rst_n,

    // Enqueue from rename (up to 6 per cycle)
    input  wire [2:0]    enq_count,
    input  renamed_insn_t enq_data [0:PIPE_WIDTH-1],
    output logic          full,          // backpressure to rename

    // Dequeue to issue queues (up to PIPE_WIDTH per cycle)
    output logic [2:0]    deq_count,
    output renamed_insn_t deq_data [0:PIPE_WIDTH-1],
    output logic [1:0]    deq_iq_target [0:PIPE_WIDTH-1],  // 0,1,2 = int IQ; 3 = mem IQ
    input  wire [NUM_INT_IQS-1:0] iq_full,                // per-IQ backpressure
    input  wire [5:0]    iq_occ [0:NUM_INT_IQS-1],        // per-IQ occupancy (for load-balanced routing)
    input  wire [1:0]    load_iq_credit,                  // load IQ free slots, capped at 2
    input  wire [1:0]    store_iq_credit,                 // STA/STD paired store credits, capped at 2

    // Flush
    input  wire          flush_valid,
    input  wire          flush_full,
    input  wire [ROB_IDX_BITS-1:0] flush_rob_tail,
    input  wire [ROB_IDX_BITS-1:0] rob_head
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int INT_DEPTH    = DQ_INT_DEPTH;         // 32
    localparam int MEM_DEPTH    = DQ_MEM_DEPTH;         // 32
    localparam int INT_IDX_BITS = $clog2(INT_DEPTH);    // 5
    localparam int MEM_IDX_BITS = $clog2(MEM_DEPTH);    // 5
    // Count uses one extra bit beyond index bits
    localparam int INT_CNT_BITS = INT_IDX_BITS + 1;     // 6
    localparam int MEM_CNT_BITS = MEM_IDX_BITS + 1;     // 6

    // IQ target encoding: 3 = memory IQ
    localparam logic [1:0] IQ_MEM_TARGET = 2'd3;
    // Flat-vector width for renamed_insn_t (avoids Verilator packed-struct array bugs)
    localparam int RI_W = $bits(renamed_insn_t);
    localparam int ROB_AGE_BITS = ROB_IDX_BITS + 1;

    // =========================================================================
    // Integer FIFO -- stored as flat bit-vectors to avoid struct corruption
    // =========================================================================
    logic [RI_W-1:0]                 int_fifo_flat [0:INT_DEPTH-1];
    logic [INT_IDX_BITS-1:0]         int_head;
    logic [INT_IDX_BITS-1:0]         int_tail;
    logic [INT_CNT_BITS-1:0]         int_count;

    // Reconstruct structs for read access
    renamed_insn_t                   int_fifo  [0:INT_DEPTH-1];
    always_comb begin
        for (int k = 0; k < INT_DEPTH; k++)
            int_fifo[k] = renamed_insn_t'(int_fifo_flat[k]);
    end

    // =========================================================================
    // Memory FIFO -- stored as flat bit-vectors
    // =========================================================================
    logic [RI_W-1:0]                 mem_fifo_flat [0:MEM_DEPTH-1];
    renamed_insn_t                   mem_fifo  [0:MEM_DEPTH-1];
    always_comb begin
        for (int k = 0; k < MEM_DEPTH; k++)
            mem_fifo[k] = renamed_insn_t'(mem_fifo_flat[k]);
    end
    logic [MEM_IDX_BITS-1:0]         mem_head;
    logic [MEM_IDX_BITS-1:0]         mem_tail;
    logic [MEM_CNT_BITS-1:0]         mem_count;

    // =========================================================================
    // Round-robin pointer for integer IQ targeting
    // =========================================================================
    logic [1:0] rr_ptr;

    // =========================================================================
    // Enqueue classification (combinational)
    // =========================================================================
    logic        is_mem        [0:PIPE_WIDTH-1];
    logic [2:0]  enq_int_count;
    logic [2:0]  enq_mem_count;

    always_comb begin
        enq_int_count = 3'd0;
        enq_mem_count = 3'd0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (i < int'(enq_count)) begin
                is_mem[i] = (enq_data[i].base.fu_type == FU_LOAD) ||
                            (enq_data[i].base.fu_type == FU_STA)  ||
                            (enq_data[i].base.fu_type == FU_STD);
                if (is_mem[i])
                    enq_mem_count = enq_mem_count + 3'd1;
                else
                    enq_int_count = enq_int_count + 3'd1;
            end else begin
                is_mem[i] = 1'b0;
            end
        end
    end

    // =========================================================================
    // Full signal
    // Assert if either FIFO can't accept worst-case 6 new entries
    // Use INT_CNT_BITS+1-wide arithmetic to avoid width mismatch
    // =========================================================================
    localparam int FULL_CHK_BITS = INT_CNT_BITS + 1;  // 7 bits, enough for 32+6=38

    always_comb begin
        logic [FULL_CHK_BITS-1:0] int_after, mem_after;
        int_after = {1'b0, int_count} + FULL_CHK_BITS'(PIPE_WIDTH);
        mem_after = {1'b0, mem_count} + FULL_CHK_BITS'(PIPE_WIDTH);
        full = (int_after > FULL_CHK_BITS'(INT_DEPTH)) ||
               (mem_after > FULL_CHK_BITS'(MEM_DEPTH));
    end

    // =========================================================================
    // Dequeue count computation (combinational)
    // =========================================================================
    logic [2:0] actual_deq_int;
    logic [2:0] actual_deq_mem;
    logic       all_int_iq_full;
    logic       mem_head_has_credit;
    logic       reserve_mem_slot;
    logic       mem_head_older_than_int;
    logic       mem_head_conflict;

    // Per-slot mem FIFO read address for mem_cap loop (formerly automatic)
    logic [MEM_IDX_BITS-1:0] mem_cap_rd_a [0:PIPE_WIDTH-1];

    // Enqueue sorting counters (formerly automatic)
    int enq_i_int;
    int enq_i_mem;

    // Forward declarations (used before full definition)
    logic [INT_IDX_BITS-1:0] int_rd_addr [0:PIPE_WIDTH-1];
    logic [MEM_IDX_BITS-1:0] mem_rd_addr [0:PIPE_WIDTH-1];

    always_comb begin : deq_count_comb
        logic [2:0] max_int;
        logic [2:0] int_slot_limit;
        logic [ROB_AGE_BITS-1:0] int_head_age;
        logic [ROB_AGE_BITS-1:0] mem_head_age;

        all_int_iq_full = (iq_full == {NUM_INT_IQS{1'b1}});
        mem_head_has_credit = 1'b0;
        reserve_mem_slot = 1'b0;
        mem_head_older_than_int = 1'b0;
        mem_head_conflict = 1'b0;

        if (mem_count != '0) begin
            if (mem_fifo[mem_head].base.is_store)
                mem_head_has_credit = (store_iq_credit != 2'd0);
            else
                mem_head_has_credit = (load_iq_credit != 2'd0);
        end

        int_head_age = '0;
        mem_head_age = '0;
        if ((int_count != '0) && (mem_count != '0) && mem_head_has_credit) begin
            int_head_age =
                (int_fifo[int_head].rob_idx >= rob_head)
                    ? ({1'b0, int_fifo[int_head].rob_idx} -
                       {1'b0, rob_head})
                    : ((ROB_AGE_BITS)'(ROB_DEPTH) - {1'b0, rob_head} +
                       {1'b0, int_fifo[int_head].rob_idx});
            mem_head_age =
                (mem_fifo[mem_head].rob_idx >= rob_head)
                    ? ({1'b0, mem_fifo[mem_head].rob_idx} -
                       {1'b0, rob_head})
                    : ((ROB_AGE_BITS)'(ROB_DEPTH) - {1'b0, rob_head} +
                       {1'b0, mem_fifo[mem_head].rob_idx});
            mem_head_older_than_int = (mem_head_age < int_head_age);
        end

        mem_head_conflict =
            mem_head_older_than_int &&
            mem_head_has_credit &&
            !all_int_iq_full &&
            (int_count >= INT_CNT_BITS'(PIPE_WIDTH));

        reserve_mem_slot = mem_head_conflict;

        int_slot_limit = reserve_mem_slot ? 3'(PIPE_WIDTH - 1)
                                          : 3'(PIPE_WIDTH);

        // How many int entries available, capped at the dispatch-width budget
        // left after an older memory head reserves one normal output slot.
        if (int_count >= INT_CNT_BITS'(int_slot_limit))
            max_int = int_slot_limit;
        else
            max_int = int_count[2:0];

        // Cannot dequeue int if all IQs full
        // Note: actual_deq_int is the maximum; accepted_int_count (computed
        // later by rr_assign_comb) may be lower due to per-IQ capacity limits.
        actual_deq_int = all_int_iq_full ? 3'd0 : max_int;
    end

    // =========================================================================
    // Round-robin IQ target assignment (combinational)
    //
    // Certain fu_types MUST go to specific IQs:
    //   FU_BRU  -> IQ0 (BRU is on IQ0 port 0)
    //   FU_MUL  -> IQ1 (MUL shares IQ1 port 0)
    //   FU_DIV  -> IQ2 (DIV shares IQ2 port 0)
    //   FU_CSR  -> IQ2 (CSR shares IQ2 port 0)
    //   FP ops  -> IQ2 (serialized FPU lane shares IQ2 port 0)
    //   FU_ALU  -> round-robin across IQ0/IQ1/IQ2
    // =========================================================================
    logic [1:0] rr_target [0:PIPE_WIDTH-1];
    logic [1:0] rr_next;
    // Pre-read fu_type from int FIFO for IQ routing decisions
    fu_type_e   int_fifo_fu [0:PIPE_WIDTH-1];
    logic       int_fifo_is_fp [0:PIPE_WIDTH-1];

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            int_fifo_fu[i] = int_fifo[int_rd_addr[i]].base.fu_type;
            int_fifo_is_fp[i] = int_fifo[int_rd_addr[i]].base.is_fp_op;
        end
    end

    // Track per-IQ usage to cap at 2 entries per IQ per cycle
    logic [1:0] iq_used [0:NUM_INT_IQS-1];
    logic [PIPE_WIDTH-1:0] slot_accepted;  // which int deq slots actually get accepted
    logic [2:0] accepted_int_count;

    always_comb begin : rr_assign_comb
        logic [1:0] rr_cur;
        logic [1:0] tgt;
        logic       ok;
        logic       stopped;
        rr_cur = rr_ptr;
        stopped = 1'b0;

        for (int q = 0; q < NUM_INT_IQS; q++)
            iq_used[q] = 2'd0;
        accepted_int_count = 3'd0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            rr_target[i] = 2'd0;
            slot_accepted[i] = 1'b0;

            if (!stopped && i < int'(actual_deq_int)) begin
                ok = 1'b0;
                tgt = 2'd0;

                // Force specific IQs for non-ALU functional units.
                if (int_fifo_is_fp[i]) begin
                    tgt = 2'd2;
                    ok = (iq_used[2] < 2'd2) && !iq_full[2];
                end else begin
                    case (int_fifo_fu[i])
                        FU_BRU: begin
                            tgt = 2'd0;  // IQ0 only
                            ok = (iq_used[0] < 2'd2) && !iq_full[0];
                        end
                        FU_MUL: begin
                            tgt = 2'd1;  // IQ1 only
                            ok = (iq_used[1] < 2'd2) && !iq_full[1];
                        end
                        FU_DIV, FU_CSR: begin
                            tgt = 2'd2;  // IQ2 only
                            ok = (iq_used[2] < 2'd2) && !iq_full[2];
                        end
                        default: begin
                        // ALU: pick the least-loaded IQ that can accept this op.
                        // Effective occupancy = current count + in-flight enqueues
                        // this cycle (iq_used[]).  IQ0 is dual-issue (drains 2/cycle);
                        // IQ1/IQ2 are single-issue (drain 1/cycle).  We bias toward
                        // IQ0 by weighting its effective count by 1/2 (shift right 1).
                        // Ties are broken by IQ index (lower wins for deterministic
                        // behavior and slight bias toward IQ0).
                        logic [6:0] eff [0:NUM_INT_IQS-1];
                        logic [1:0] best_q;
                        ok = 1'b0;
                        for (int q = 0; q < NUM_INT_IQS; q++) begin
                            eff[q] = 7'(iq_occ[q]) + 7'(iq_used[q]);
                        end
                        // Weight IQ0 as half occupancy (2x drain rate)
                        eff[0] = eff[0] >> 1;
                        best_q = 2'd0;
                        // Pick the minimum eff[] among non-full IQs
                        for (int q = 0; q < NUM_INT_IQS; q++) begin
                            if (!iq_full[q] && (iq_used[q] < 2'd2) && !ok) begin
                                best_q = 2'(q);
                                ok = 1'b1;
                            end
                        end
                        if (ok) begin
                            for (int q = 0; q < NUM_INT_IQS; q++) begin
                                if (!iq_full[q] && (iq_used[q] < 2'd2)
                                    && (eff[q] < eff[best_q])) begin
                                    best_q = 2'(q);
                                end
                            end
                            tgt = best_q;
                        end
                        // rr_cur kept for backward compat; no longer dominant.
                        rr_cur = (rr_cur == 2'(NUM_INT_IQS-1)) ? 2'd0 : rr_cur + 2'd1;
                        end
                    endcase
                end

                if (ok) begin
                    rr_target[i] = tgt;
                    slot_accepted[i] = 1'b1;
                    iq_used[tgt] = iq_used[tgt] + 2'd1;
                    accepted_int_count = accepted_int_count + 3'd1;
                end else begin
                    // FIFO is in-order: stop dequeuing when an entry can't be routed
                    stopped = 1'b1;
                end
            end
        end
        rr_next = rr_cur;
    end

    // =========================================================================
    // Memory release count
    // =========================================================================
    always_comb begin : mem_deq_count_comb
        logic [2:0] max_mem;
        logic [2:0] rem_slots;
        logic [2:0] candidate_mem;
        logic [2:0] store_cnt;
        logic [2:0] load_cnt;
        logic       stopped_m;

        rem_slots = 3'(PIPE_WIDTH) - accepted_int_count;
        if (mem_count >= MEM_CNT_BITS'(rem_slots))
            candidate_mem = rem_slots;
        else
            candidate_mem = mem_count[2:0];

        max_mem   = 3'd0;
        store_cnt = 3'd0;
        load_cnt  = 3'd0;
        stopped_m = 1'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            mem_cap_rd_a[i] = mem_head + MEM_IDX_BITS'(i);
            if (!stopped_m && 3'(i) < candidate_mem) begin
                if (mem_fifo[mem_cap_rd_a[i]].base.is_store) begin
                    if ((store_cnt < 3'd2) &&
                        (store_cnt < 3'(store_iq_credit))) begin
                        max_mem   = 3'(i) + 3'd1;
                        store_cnt = store_cnt + 3'd1;
                    end else begin
                        stopped_m = 1'b1;
                    end
                end else begin
                    if ((load_cnt < 3'd2) &&
                        (load_cnt < 3'(load_iq_credit))) begin
                        max_mem  = 3'(i) + 3'd1;
                        load_cnt = load_cnt + 3'd1;
                    end else begin
                        stopped_m = 1'b1;
                    end
                end
            end
        end

        actual_deq_mem = max_mem;
    end

    // =========================================================================
    // Dequeue output assembly (combinational)
    // Use local index variables typed to the right width to avoid WIDTHEXPAND
    // =========================================================================
    // int_rd_addr, mem_rd_addr declared earlier (forward decl)

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            int_rd_addr[i] = int_head + INT_IDX_BITS'(i);
            mem_rd_addr[i] = mem_head + MEM_IDX_BITS'(i);
        end
    end

    always_comb begin : deq_output_comb
        int mem_slot;

        // Suppress dequeue on the flush cycle; otherwise stale pre-flush
        // entries can enter the IQs after the ROB metadata has been reset.
        if (flush_valid)
            deq_count = 3'd0;
        else
            deq_count = accepted_int_count + actual_deq_mem;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            deq_data[i]      = '0;
            deq_iq_target[i] = 2'd0;
        end

        // Integer slots: indices 0 .. accepted_int_count-1
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (slot_accepted[i]) begin
                deq_data[i]      = int_fifo[int_rd_addr[i]];
                deq_iq_target[i] = rr_target[i];
            end
        end

        // Memory slots: indices accepted_int_count .. accepted_int_count+actual_deq_mem-1
        mem_slot = 0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (i >= int'(accepted_int_count) && i < int'(accepted_int_count) + int'(actual_deq_mem)) begin
                deq_data[i]      = mem_fifo[mem_rd_addr[mem_slot]];
                deq_iq_target[i] = IQ_MEM_TARGET;
                mem_slot         = mem_slot + 1;
            end
        end
    end

    // =========================================================================
    // Precompute FIFO write addresses for enqueue
    // =========================================================================
    logic [INT_IDX_BITS-1:0] int_wr_addr [0:PIPE_WIDTH-1];
    logic [MEM_IDX_BITS-1:0] mem_wr_addr [0:PIPE_WIDTH-1];

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            int_wr_addr[i] = int_tail + INT_IDX_BITS'(i);
            mem_wr_addr[i] = mem_tail + MEM_IDX_BITS'(i);
        end
    end

    // =========================================================================
    // Partial-flush compaction
    // =========================================================================
    logic [ROB_AGE_BITS-1:0] dq_flush_tail_age;
    logic [ROB_AGE_BITS-1:0] dq_int_entry_age [0:INT_DEPTH-1];
    logic [ROB_AGE_BITS-1:0] dq_mem_entry_age [0:MEM_DEPTH-1];
    logic [INT_IDX_BITS-1:0] int_flush_src [0:INT_DEPTH-1];
    logic [MEM_IDX_BITS-1:0] mem_flush_src [0:MEM_DEPTH-1];
    logic [INT_CNT_BITS-1:0] int_flush_count;
    logic [MEM_CNT_BITS-1:0] mem_flush_count;

    always_comb begin
        dq_flush_tail_age = (flush_rob_tail >= rob_head)
            ? ({1'b0, flush_rob_tail} - {1'b0, rob_head})
            : ((ROB_AGE_BITS)'(ROB_DEPTH) - {1'b0, rob_head} +
               {1'b0, flush_rob_tail});

        int_flush_count = '0;
        for (int i = 0; i < INT_DEPTH; i++) begin
            int_flush_src[i] = '0;
            dq_int_entry_age[i] = '0;
        end
        for (int i = 0; i < INT_DEPTH; i++) begin
            logic [INT_IDX_BITS-1:0] rd_idx;
            rd_idx = int_head + INT_IDX_BITS'(i);
            if (INT_CNT_BITS'(i) < int_count) begin
                dq_int_entry_age[i] =
                    (int_fifo[rd_idx].rob_idx >= rob_head)
                        ? ({1'b0, int_fifo[rd_idx].rob_idx} -
                           {1'b0, rob_head})
                        : ((ROB_AGE_BITS)'(ROB_DEPTH) - {1'b0, rob_head} +
                           {1'b0, int_fifo[rd_idx].rob_idx});
                if (dq_int_entry_age[i] < dq_flush_tail_age) begin
                    int_flush_src[int_flush_count] = rd_idx;
                    int_flush_count = int_flush_count + 1'b1;
                end
            end
        end

        mem_flush_count = '0;
        for (int i = 0; i < MEM_DEPTH; i++) begin
            mem_flush_src[i] = '0;
            dq_mem_entry_age[i] = '0;
        end
        for (int i = 0; i < MEM_DEPTH; i++) begin
            logic [MEM_IDX_BITS-1:0] rd_idx;
            rd_idx = mem_head + MEM_IDX_BITS'(i);
            if (MEM_CNT_BITS'(i) < mem_count) begin
                dq_mem_entry_age[i] =
                    (mem_fifo[rd_idx].rob_idx >= rob_head)
                        ? ({1'b0, mem_fifo[rd_idx].rob_idx} -
                           {1'b0, rob_head})
                        : ((ROB_AGE_BITS)'(ROB_DEPTH) - {1'b0, rob_head} +
                           {1'b0, mem_fifo[rd_idx].rob_idx});
                if (dq_mem_entry_age[i] < dq_flush_tail_age) begin
                    mem_flush_src[mem_flush_count] = rd_idx;
                    mem_flush_count = mem_flush_count + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Sequential: FIFO updates and pointer maintenance
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_valid && flush_full)) begin
            int_head  <= '0;
            int_tail  <= '0;
            int_count <= '0;
            mem_head  <= '0;
            mem_tail  <= '0;
            mem_count <= '0;
            rr_ptr    <= 2'd0;
        end else if (flush_valid) begin
            for (int i = 0; i < INT_DEPTH; i++) begin
                if (INT_CNT_BITS'(i) < int_flush_count)
                    int_fifo_flat[i] <= int_fifo_flat[int_flush_src[i]];
                else
                    int_fifo_flat[i] <= '0;
            end
            for (int i = 0; i < MEM_DEPTH; i++) begin
                if (MEM_CNT_BITS'(i) < mem_flush_count)
                    mem_fifo_flat[i] <= mem_fifo_flat[mem_flush_src[i]];
                else
                    mem_fifo_flat[i] <= '0;
            end

            int_head  <= '0;
            int_tail  <= INT_IDX_BITS'(int_flush_count);
            int_count <= int_flush_count;
            mem_head  <= '0;
            mem_tail  <= MEM_IDX_BITS'(mem_flush_count);
            mem_count <= mem_flush_count;
            rr_ptr    <= 2'd0;
        end else begin
            // -------------------------------------------------------------------
            // Enqueue: sort uops into int or mem FIFO using precomputed addresses
            // -------------------------------------------------------------------
            begin
                enq_i_int = 0;
                enq_i_mem = 0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (i < int'(enq_count)) begin
                        if (is_mem[i]) begin
                            mem_fifo_flat[mem_wr_addr[enq_i_mem]] <= RI_W'(enq_data[i]);
                            enq_i_mem = enq_i_mem + 1;
                        end else begin
                            int_fifo_flat[int_wr_addr[enq_i_int]] <= RI_W'(enq_data[i]);
                            enq_i_int = enq_i_int + 1;
                        end
                    end
                end
            end

            // Advance tails
            int_tail <= int_tail + INT_IDX_BITS'(enq_int_count);
            mem_tail <= mem_tail + MEM_IDX_BITS'(enq_mem_count);

            // -------------------------------------------------------------------
            // Dequeue: advance heads (use accepted counts, not max available)
            // -------------------------------------------------------------------
            int_head <= int_head + INT_IDX_BITS'(accepted_int_count);
            mem_head <= mem_head + MEM_IDX_BITS'(actual_deq_mem);

            // -------------------------------------------------------------------
            // Update occupancy counts (net = enq - deq)
            // -------------------------------------------------------------------
            int_count <= int_count + {3'b000, enq_int_count} - {3'b000, accepted_int_count};
            mem_count <= mem_count +
                         {3'b000, enq_mem_count} -
                         {3'b000, actual_deq_mem};

            // -------------------------------------------------------------------
            // Advance round-robin pointer
            // -------------------------------------------------------------------
            if (actual_deq_int > 3'd0)
                rr_ptr <= rr_next;

        end
    end

endmodule

`endif
