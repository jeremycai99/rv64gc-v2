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
    input  logic clk,
    input  logic rst_n,

    // Enqueue from rename (up to 6 per cycle)
    input  logic [2:0]    enq_count,
    input  renamed_insn_t enq_data [0:PIPE_WIDTH-1],
    output logic          full,          // backpressure to rename

    // Dequeue to issue queues (up to 6 per cycle)
    output logic [2:0]    deq_count,
    output renamed_insn_t deq_data [0:PIPE_WIDTH-1],
    output logic [1:0]    deq_iq_target [0:PIPE_WIDTH-1],  // 0,1,2 = int IQ; 3 = mem IQ
    input  logic [NUM_INT_IQS-1:0] iq_full,                // per-IQ backpressure

    // Flush
    input  logic          flush_valid,
    input  logic          flush_full
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

    // =========================================================================
    // Integer FIFO
    // =========================================================================
    renamed_insn_t                   int_fifo  [0:INT_DEPTH-1];
    logic [INT_IDX_BITS-1:0]         int_head;
    logic [INT_IDX_BITS-1:0]         int_tail;
    logic [INT_CNT_BITS-1:0]         int_count;

    // =========================================================================
    // Memory FIFO
    // =========================================================================
    renamed_insn_t                   mem_fifo  [0:MEM_DEPTH-1];
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

    always_comb begin : deq_count_comb
        logic [2:0] max_int, max_mem, rem_slots;

        all_int_iq_full = (iq_full == {NUM_INT_IQS{1'b1}});

        // How many int entries available (capped at PIPE_WIDTH)
        if (int_count >= INT_CNT_BITS'(PIPE_WIDTH))
            max_int = 3'(PIPE_WIDTH);
        else
            max_int = int_count[2:0];

        // Cannot dequeue int if all IQs full
        actual_deq_int = all_int_iq_full ? 3'd0 : max_int;

        // Remaining slots for mem
        rem_slots = 3'(PIPE_WIDTH) - actual_deq_int;
        if (mem_count >= MEM_CNT_BITS'(rem_slots))
            max_mem = rem_slots;
        else
            max_mem = mem_count[2:0];

        actual_deq_mem = max_mem;
    end

    // =========================================================================
    // Round-robin IQ target assignment (combinational)
    // =========================================================================
    logic [1:0] rr_target [0:PIPE_WIDTH-1];
    logic [1:0] rr_next;

    always_comb begin : rr_assign_comb
        logic [1:0] rr_cur;
        rr_cur = rr_ptr;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            rr_target[i] = 2'd0;
            if (i < int'(actual_deq_int)) begin
                // Skip full IQs (scan up to NUM_INT_IQS times)
                for (int k = 0; k < NUM_INT_IQS; k++) begin
                    if (iq_full[rr_cur])
                        rr_cur = (rr_cur == 2'(NUM_INT_IQS-1)) ? 2'd0 : rr_cur + 2'd1;
                end
                rr_target[i] = rr_cur;
                rr_cur = (rr_cur == 2'(NUM_INT_IQS-1)) ? 2'd0 : rr_cur + 2'd1;
            end
        end
        rr_next = rr_cur;
    end

    // =========================================================================
    // Dequeue output assembly (combinational)
    // Use local index variables typed to the right width to avoid WIDTHEXPAND
    // =========================================================================
    // Precompute FIFO read addresses for int (up to PIPE_WIDTH entries)
    logic [INT_IDX_BITS-1:0] int_rd_addr [0:PIPE_WIDTH-1];
    logic [MEM_IDX_BITS-1:0] mem_rd_addr [0:PIPE_WIDTH-1];

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            int_rd_addr[i] = int_head + INT_IDX_BITS'(i);
            mem_rd_addr[i] = mem_head + MEM_IDX_BITS'(i);
        end
    end

    always_comb begin : deq_output_comb
        int mem_slot;

        deq_count = actual_deq_int + actual_deq_mem;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            deq_data[i]      = '0;
            deq_iq_target[i] = 2'd0;
        end

        // Integer slots: indices 0 .. actual_deq_int-1
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (i < int'(actual_deq_int)) begin
                deq_data[i]      = int_fifo[int_rd_addr[i]];
                deq_iq_target[i] = rr_target[i];
            end
        end

        // Memory slots: indices actual_deq_int .. actual_deq_int+actual_deq_mem-1
        mem_slot = 0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (i >= int'(actual_deq_int) && i < int'(actual_deq_int) + int'(actual_deq_mem)) begin
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
    // Sequential: FIFO updates and pointer maintenance
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_valid) begin
            int_head  <= '0;
            int_tail  <= '0;
            int_count <= '0;
            mem_head  <= '0;
            mem_tail  <= '0;
            mem_count <= '0;
            rr_ptr    <= 2'd0;
        end else begin
            // -------------------------------------------------------------------
            // Enqueue: sort uops into int or mem FIFO using precomputed addresses
            // -------------------------------------------------------------------
            begin
                automatic int i_int = 0;
                automatic int i_mem = 0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (i < int'(enq_count)) begin
                        if (is_mem[i]) begin
                            mem_fifo[mem_wr_addr[i_mem]] <= enq_data[i];
                            i_mem = i_mem + 1;
                        end else begin
                            int_fifo[int_wr_addr[i_int]] <= enq_data[i];
                            i_int = i_int + 1;
                        end
                    end
                end
            end

            // Advance tails
            int_tail <= int_tail + INT_IDX_BITS'(enq_int_count);
            mem_tail <= mem_tail + MEM_IDX_BITS'(enq_mem_count);

            // -------------------------------------------------------------------
            // Dequeue: advance heads
            // -------------------------------------------------------------------
            int_head <= int_head + INT_IDX_BITS'(actual_deq_int);
            mem_head <= mem_head + MEM_IDX_BITS'(actual_deq_mem);

            // -------------------------------------------------------------------
            // Update occupancy counts (net = enq - deq)
            // -------------------------------------------------------------------
            int_count <= int_count + {3'b000, enq_int_count} - {3'b000, actual_deq_int};
            mem_count <= mem_count + {3'b000, enq_mem_count} - {3'b000, actual_deq_mem};

            // -------------------------------------------------------------------
            // Advance round-robin pointer
            // -------------------------------------------------------------------
            if (actual_deq_int > 3'd0)
                rr_ptr <= rr_next;
        end
    end

endmodule

`endif
