/* file: committed_store_buffer.sv
 Description: Committed store buffer for ordered store retirement.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module committed_store_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,
    // Enqueue from store queue (drain)
    input  logic        enq_valid,
    input  sq_entry_t   enq_data,
    output logic        enq_ready,     // has space
    // Dequeue to D-cache
    output logic        deq_valid,
    output logic [63:0] deq_addr,
    output logic [63:0] deq_data,
    output logic [7:0]  deq_byte_mask,
    output logic [1:0]  deq_size,
    input  logic        deq_ack,       // D-cache accepted the write
    // Store-to-load forwarding (check CSB before going to cache)
    input  logic        fwd_valid,
    input  logic [63:0] fwd_addr,
    input  logic [1:0]  fwd_size,
    output logic        fwd_hit,
    output logic [63:0] fwd_data,
    input  logic        fwd1_valid,
    input  logic [63:0] fwd1_addr,
    input  logic [1:0]  fwd1_size,
    output logic        fwd1_hit,
    output logic [63:0] fwd1_data,
    // Full signal
    output logic        full
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int DEPTH     = CSB_DEPTH;      // 24
    localparam int IDX_BITS  = CSB_IDX_BITS;   // 5

    // =========================================================================
    // Storage
    // =========================================================================
    csb_entry_t buf_q [0:DEPTH-1];

    logic [IDX_BITS-1:0] head_r;   // oldest entry (deq side)
    logic [IDX_BITS-1:0] tail_r;   // next free slot (enq side)
    logic [IDX_BITS:0]   count_r;  // one extra bit to distinguish full/empty

`ifndef SYNTHESIS
    bit     sim_perf_profile;
    integer sim_deq_valid_cyc;
    integer sim_deq_ack_cyc;
    integer sim_deq_wait_cyc;
    integer sim_enq_stall_cyc;
    integer sim_full_cyc;
    integer sim_wait_run_cur;
    integer sim_wait_run_max;
    logic [63:0] sim_wait_addr_r;
    logic [63:0] sim_wait_data_r;
    logic [7:0]  sim_wait_mask_r;
`endif

    // =========================================================================
    // Status
    // =========================================================================
    assign full      = count_r[IDX_BITS];                       // count == DEPTH
    assign enq_ready = (count_r < (IDX_BITS+1)'(DEPTH));

    // =========================================================================
    // Dequeue
    // =========================================================================
    assign deq_valid     = (count_r != '0) && buf_q[head_r].valid;
    assign deq_addr      = buf_q[head_r].addr;
    assign deq_data      = buf_q[head_r].data;
    assign deq_byte_mask = buf_q[head_r].byte_mask;
    assign deq_size      = buf_q[head_r].size;

    // =========================================================================
    // Store-to-load forwarding
    // =========================================================================
    logic        fwd_req_valid_arr [0:1];
    logic [63:0] fwd_req_addr_arr [0:1];
    logic [1:0]  fwd_req_size_arr [0:1];
    logic        fwd_hit_arr [0:1];
    logic [63:0] fwd_data_arr [0:1];

    assign fwd_req_valid_arr[0] = fwd_valid;
    assign fwd_req_valid_arr[1] = fwd1_valid;
    assign fwd_req_addr_arr[0]  = fwd_addr;
    assign fwd_req_addr_arr[1]  = fwd1_addr;
    assign fwd_req_size_arr[0]  = fwd_size;
    assign fwd_req_size_arr[1]  = fwd1_size;
    assign fwd_hit              = fwd_hit_arr[0];
    assign fwd1_hit             = fwd_hit_arr[1];
    assign fwd_data             = fwd_data_arr[0];
    assign fwd1_data            = fwd_data_arr[1];

    genvar fp;
    generate
        for (fp = 0; fp < 2; fp++) begin : gen_forward_lookup
            always_comb begin
                logic [7:0] req_bmask;
                logic [7:0] cover_mask;
                logic [7:0] enq_bmask;
                logic [7:0] enq_overlap;
                logic [7:0] enq_uncovered;

                case (fwd_req_size_arr[fp])
                    2'd0:    req_bmask = 8'h01 << fwd_req_addr_arr[fp][2:0];
                    2'd1:    req_bmask = 8'h03 << fwd_req_addr_arr[fp][2:0];
                    2'd2:    req_bmask = 8'h0F << fwd_req_addr_arr[fp][2:0];
                    default: req_bmask = 8'hFF;
                endcase

                fwd_data_arr[fp] = '0;
                cover_mask       = '0;

                case (enq_data.size)
                    2'd0:    enq_bmask = 8'h01 << enq_data.addr[2:0];
                    2'd1:    enq_bmask = 8'h03 << enq_data.addr[2:0];
                    2'd2:    enq_bmask = 8'h0F << enq_data.addr[2:0];
                    default: enq_bmask = 8'hFF;
                endcase

                enq_overlap = (fwd_req_valid_arr[fp] &&
                               enq_valid &&
                               enq_ready &&
                               (enq_data.addr[63:3] == fwd_req_addr_arr[fp][63:3]))
                            ? (enq_bmask & req_bmask)
                            : 8'h00;
                enq_uncovered = enq_overlap & ~cover_mask;

                // Same-cycle enqueue is the newest committed store.
                for (int b = 0; b < 8; b++) begin
                    if (enq_uncovered[b] &&
                        (b >= int'(enq_data.addr[2:0]))) begin
                        fwd_data_arr[fp][b*8 +: 8] =
                            enq_data.data[
                                (b - int'(enq_data.addr[2:0])) * 8 +: 8
                            ];
                    end
                end
                cover_mask = cover_mask | enq_uncovered;

                // Walk newest to oldest in circular queue order. The first
                // matching store for each byte is architecturally latest.
                for (int step = 0; step < DEPTH; step++) begin
                    if (step < int'(count_r)) begin
                        logic [IDX_BITS-1:0] scan_idx;
                        logic [7:0]          ent_bmask;
                        logic [7:0]          overlap;
                        logic [7:0]          uncovered;
                        int                  idx_int;

                        idx_int = int'(tail_r) - step - 1;
                        if (idx_int < 0)
                            idx_int = idx_int + DEPTH;
                        scan_idx = IDX_BITS'(idx_int);

                        case (buf_q[scan_idx].size)
                            2'd0:    ent_bmask = 8'h01 << buf_q[scan_idx].addr[2:0];
                            2'd1:    ent_bmask = 8'h03 << buf_q[scan_idx].addr[2:0];
                            2'd2:    ent_bmask = 8'h0F << buf_q[scan_idx].addr[2:0];
                            default: ent_bmask = 8'hFF;
                        endcase

                        overlap = (fwd_req_valid_arr[fp] &&
                                   buf_q[scan_idx].valid &&
                                   (buf_q[scan_idx].addr[63:3] == fwd_req_addr_arr[fp][63:3]))
                                ? (ent_bmask & req_bmask)
                                : 8'h00;
                        uncovered = overlap & ~cover_mask;

                        for (int b = 0; b < 8; b++) begin
                            if (uncovered[b] &&
                                (b >= int'(buf_q[scan_idx].addr[2:0]))) begin
                                fwd_data_arr[fp][b*8 +: 8] =
                                    buf_q[scan_idx].data[
                                        (b - int'(buf_q[scan_idx].addr[2:0])) * 8 +: 8
                                    ];
                            end
                        end

                        cover_mask = cover_mask | uncovered;
                    end
                end

                fwd_hit_arr[fp] = fwd_req_valid_arr[fp] && (cover_mask == req_bmask);
            end
        end
    endgenerate

    // =========================================================================
    // Sequential logic
    // =========================================================================
`ifndef SYNTHESIS
    initial sim_perf_profile = $test$plusargs("PERF_PROFILE");
`endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_r  <= '0;
            tail_r  <= '0;
            count_r <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                buf_q[i] <= '0;
            end
`ifndef SYNTHESIS
            sim_deq_valid_cyc <= 0;
            sim_deq_ack_cyc   <= 0;
            sim_deq_wait_cyc  <= 0;
            sim_enq_stall_cyc <= 0;
            sim_full_cyc      <= 0;
            sim_wait_run_cur  <= 0;
            sim_wait_run_max  <= 0;
            sim_wait_addr_r   <= '0;
            sim_wait_data_r   <= '0;
            sim_wait_mask_r   <= '0;
`endif
        end else begin
`ifndef SYNTHESIS
            if (sim_perf_profile) begin
                if (deq_valid)
                    sim_deq_valid_cyc <= sim_deq_valid_cyc + 1;
                if (deq_valid && deq_ack)
                    sim_deq_ack_cyc <= sim_deq_ack_cyc + 1;
                if (enq_valid && !enq_ready)
                    sim_enq_stall_cyc <= sim_enq_stall_cyc + 1;
                if (full)
                    sim_full_cyc <= sim_full_cyc + 1;

                if (deq_valid && !deq_ack) begin
                    sim_deq_wait_cyc <= sim_deq_wait_cyc + 1;
                    if ((buf_q[head_r].addr == sim_wait_addr_r) &&
                        (buf_q[head_r].data == sim_wait_data_r) &&
                        (buf_q[head_r].byte_mask == sim_wait_mask_r)) begin
                        sim_wait_run_cur <= sim_wait_run_cur + 1;
                    end else begin
                        sim_wait_run_cur <= 1;
                        sim_wait_addr_r  <= buf_q[head_r].addr;
                        sim_wait_data_r  <= buf_q[head_r].data;
                        sim_wait_mask_r  <= buf_q[head_r].byte_mask;
                    end
                    if (sim_wait_run_cur >= sim_wait_run_max)
                        sim_wait_run_max <= sim_wait_run_cur + 1;
                end else begin
                    sim_wait_run_cur <= 0;
                end
            end
`endif
            // Dequeue (head consumed by D-cache)
            if (deq_valid && deq_ack) begin
                buf_q[head_r].valid <= 1'b0;
                head_r  <= IDX_BITS'(head_r + 1'b1);
            end

            // Enqueue (committed store from SQ)
            if (enq_valid && enq_ready) begin
                buf_q[tail_r].valid     <= 1'b1;
                buf_q[tail_r].addr      <= enq_data.addr;
                buf_q[tail_r].data      <= enq_data.data;
                buf_q[tail_r].byte_mask <= enq_data.byte_mask;
                buf_q[tail_r].size      <= enq_data.size;
                tail_r  <= IDX_BITS'(tail_r + 1'b1);
            end

            // Count update: handle both-fire case correctly.
            // This must be ONE write to count_r — otherwise a same-cycle
            // enq+deq would only apply the dequeue decrement, underflowing
            // the count when a store queue drain races the D-cache drain.
            if ((enq_valid && enq_ready) && (deq_valid && deq_ack))
                count_r <= count_r;
            else if (enq_valid && enq_ready)
                count_r <= count_r + (IDX_BITS+1)'(1);
            else if (deq_valid && deq_ack)
                count_r <= count_r - (IDX_BITS+1)'(1);
        end
    end

`ifndef SYNTHESIS
    final begin
        if (sim_perf_profile) begin
            $display("CSB summary:");
            $display("  deq_valid / ack cycles     : %0d / %0d",
                     sim_deq_valid_cyc, sim_deq_ack_cyc);
            $display("  deq_wait / enq_stall / full: %0d / %0d / %0d",
                     sim_deq_wait_cyc, sim_enq_stall_cyc, sim_full_cyc);
            $display("  max same-head wait run     : %0d",
                     sim_wait_run_max);
        end
    end
`endif

endmodule
