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
    // Compute the byte mask for the load request
    logic [7:0] fwd_req_bmask;
    logic [2:0] fwd_req_off;
    assign fwd_req_off = fwd_addr[2:0];

    always_comb begin
        case (fwd_size)
            2'd0:    fwd_req_bmask = 8'h01 << fwd_req_off;
            2'd1:    fwd_req_bmask = 8'h03 << fwd_req_off;
            2'd2:    fwd_req_bmask = 8'h0F << fwd_req_off;
            default: fwd_req_bmask = 8'hFF;
        endcase
    end

    // Per-entry match/overlap signals
    logic [DEPTH-1:0] ent_full_cover;
    logic [7:0]       ent_overlap [0:DEPTH-1];
    logic [63:0]      ent_fwd_data [0:DEPTH-1];

    genvar fi;
    generate
        for (fi = 0; fi < DEPTH; fi++) begin : gen_fwd_cam
            logic [7:0] ent_bmask;
            logic [2:0] ent_off;
            assign ent_off = buf_q[fi].addr[2:0];

            always_comb begin
                case (buf_q[fi].size)
                    2'd0:    ent_bmask = 8'h01 << ent_off;
                    2'd1:    ent_bmask = 8'h03 << ent_off;
                    2'd2:    ent_bmask = 8'h0F << ent_off;
                    default: ent_bmask = 8'hFF;
                endcase
            end

            logic addr_match;
            assign addr_match = fwd_valid
                              & buf_q[fi].valid
                              & (buf_q[fi].addr[63:3] == fwd_addr[63:3]);

            assign ent_overlap[fi]    = addr_match ? (ent_bmask & fwd_req_bmask) : 8'h00;
            assign ent_full_cover[fi] = addr_match & ((ent_bmask & fwd_req_bmask) == fwd_req_bmask);

            // Per-entry forwarding data.  buf_q[fi].data is LSB-aligned to
            // the store's effective address; byte 0 corresponds to memory
            // byte buf_q[fi].addr[2:0].  Select buf_q[fi].data[b - addr[2:0]]
            // for each output dword byte `b` that the store covers.
            always_comb begin
                ent_fwd_data[fi] = '0;
                for (int b = 0; b < 8; b++) begin
                    if (ent_overlap[fi][b] && (b >= int'(buf_q[fi].addr[2:0]))) begin
                        ent_fwd_data[fi][b*8 +: 8] =
                            buf_q[fi].data[(b - int'(buf_q[fi].addr[2:0])) * 8 +: 8];
                    end
                end
            end
        end
    endgenerate

    // Merge: later-written (younger) entries overwrite older byte slots.
    // Scan in reverse age order so youngest wins — scan from tail-1 downward
    // using modular arithmetic would be complex; instead we do a simple linear
    // scan letting each matching entry override previous bytes.
    always_comb begin
        fwd_data = '0;
        for (int e = 0; e < DEPTH; e++) begin
            for (int b = 0; b < 8; b++) begin
                if (ent_overlap[e][b]) begin
                    fwd_data[b*8 +: 8] = ent_fwd_data[e][b*8 +: 8];
                end
            end
        end
    end

    assign fwd_hit = |ent_full_cover;

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_r  <= '0;
            tail_r  <= '0;
            count_r <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                buf_q[i] <= '0;
            end
        end else begin
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

endmodule
