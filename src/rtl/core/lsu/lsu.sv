/* file: lsu.sv
 Description: 2-load 1-store LSU top integrating load AGUs, store AGU,
              store data path, load queue, store queue, committed store
              buffer, and D-cache interface with store-to-load forwarding.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/

`ifndef LSU_SV
`define LSU_SV

module lsu
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Issue inputs (from issue queues)
    input logic [1:0] load_issue_valid,
    input iq_entry_t load_issue_data [0:1],
    input logic sta_issue_valid,
    input iq_entry_t sta_issue_data,
    input logic std_issue_valid,
    input iq_entry_t std_issue_data,

    // PRF read data (from regfile)
    input logic [63:0] load_rs1 [0:1],
    input logic [63:0] sta_rs1,
    input logic [63:0] std_rs2,

    // Writeback to CDB (load results)
    output logic [1:0] load_wb_valid,
    output logic [ROB_IDX_BITS-1:0] load_wb_rob_idx [0:1],
    output logic [PHYS_REG_BITS-1:0] load_wb_pdst [0:1],
    output logic [63:0] load_wb_data [0:1],
    output logic [1:0] load_wb_has_exception,
    output logic [3:0] load_wb_exc_code [0:1],

    // STA writeback (mark store ROB entry as address-computed)
    output logic sta_wb_valid,
    output logic [ROB_IDX_BITS-1:0] sta_wb_rob_idx,

    // Store commit (from commit unit)
    input logic [2:0] store_commit_count,

    // Speculative wakeup (load issues -> wake dependents)
    output logic [1:0] spec_wakeup_valid,
    output logic [PHYS_REG_BITS-1:0] spec_wakeup_tag [0:1],
    // Cancel (cache miss -> cancel speculative wakeup)
    output logic [1:0] spec_cancel_valid,
    output logic [PHYS_REG_BITS-1:0] spec_cancel_tag [0:1],

    // LQ/SQ allocation (from rename)
    input logic [2:0] lq_alloc_count,
    input logic [2:0] sq_alloc_count,
    output logic [LQ_IDX_BITS-1:0] lq_alloc_idx [0:PIPE_WIDTH-1],
    output logic [SQ_IDX_BITS-1:0] sq_alloc_idx [0:PIPE_WIDTH-1],
    output logic lq_full,
    output logic sq_full,

    // Ordering violation (to commit for flush)
    output logic ordering_violation,
    output logic [ROB_IDX_BITS-1:0] violation_rob_idx,

    // D-cache interface
    output logic [1:0] dcache_load_req_valid,
    output logic [63:0] dcache_load_req_addr [0:1],
    output logic [1:0] dcache_load_req_size [0:1],
    output logic [1:0] dcache_load_req_is_unsigned,
    input logic [1:0] dcache_load_resp_valid,
    input logic [63:0] dcache_load_resp_data [0:1],
    input logic [1:0] dcache_load_resp_hit,

    // D-cache store port (from CSB)
    output logic dcache_store_req_valid,
    output logic [63:0] dcache_store_req_addr,
    output logic [63:0] dcache_store_req_data,
    output logic [7:0] dcache_store_req_byte_mask,
    input logic dcache_store_ack,

    // Flush
    input flush_t flush_in
);

    // =========================================================================
    // Load AGU: effective address computation (x2)
    // =========================================================================
    logic [63:0] load_eff_addr [0:1];
    logic [1:0]  load_addr_misaligned;

    genvar li;
    generate
        for (li = 0; li < 2; li++) begin : gen_load_agu
            assign load_eff_addr[li] = load_rs1[li] + load_issue_data[li].imm;

            // Misalignment check based on access size
            logic [2:0] ld_off;
            assign ld_off = load_eff_addr[li][2:0];

            always_comb begin
                case (load_issue_data[li].mem_size)
                    MEM_HALF:  load_addr_misaligned[li] = ld_off[0];
                    MEM_WORD:  load_addr_misaligned[li] = |ld_off[1:0];
                    MEM_DWORD: load_addr_misaligned[li] = |ld_off[2:0];
                    default:   load_addr_misaligned[li] = 1'b0;
                endcase
            end
        end
    endgenerate

    // =========================================================================
    // Store AGU: effective address computation (x1)
    // =========================================================================
    logic [63:0] sta_eff_addr;
    logic        sta_addr_misaligned;
    logic [2:0]  sta_off;

    assign sta_eff_addr = sta_rs1 + sta_issue_data.imm;
    assign sta_off = sta_eff_addr[2:0];

    always_comb begin
        case (sta_issue_data.mem_size)
            MEM_HALF:  sta_addr_misaligned = sta_off[0];
            MEM_WORD:  sta_addr_misaligned = |sta_off[1:0];
            MEM_DWORD: sta_addr_misaligned = |sta_off[2:0];
            default:   sta_addr_misaligned = 1'b0;
        endcase
    end

    // =========================================================================
    // Store data: byte mask generation
    // =========================================================================
    logic [7:0] std_byte_mask;

    always_comb begin
        case (std_issue_data.mem_size)
            MEM_BYTE:  std_byte_mask = 8'h01;
            MEM_HALF:  std_byte_mask = 8'h03;
            MEM_WORD:  std_byte_mask = 8'h0F;
            MEM_DWORD: std_byte_mask = 8'hFF;
            default:   std_byte_mask = 8'h01;
        endcase
    end

    // =========================================================================
    // STA writeback to ROB (mark address computed)
    // =========================================================================
    assign sta_wb_valid   = sta_issue_valid & ~flush_in.valid;
    assign sta_wb_rob_idx = sta_issue_data.rob_idx;

    // =========================================================================
    // Speculative wakeup: issue load -> wake dependents immediately
    // =========================================================================
    generate
        for (li = 0; li < 2; li++) begin : gen_spec_wakeup
            assign spec_wakeup_valid[li] = load_issue_valid[li] & ~flush_in.valid;
            assign spec_wakeup_tag[li]   = load_issue_data[li].pdst;
        end
    endgenerate

    // =========================================================================
    // Store-to-load forwarding wires (SQ and CSB)
    // =========================================================================
    // Only port 0 is wired for forwarding (SQ has a single fwd port).
    // Port 1 goes directly to D-cache without SQ forwarding check.
    logic        sq_fwd_hit;
    logic        sq_fwd_partial;
    logic [63:0] sq_fwd_data;

    logic        csb_fwd_hit;
    logic [63:0] csb_fwd_data;

    // =========================================================================
    // Store Queue
    // =========================================================================
    logic        sq_drain_valid;
    sq_entry_t   sq_drain_entry;
    logic        sq_drain_ready;

    store_queue u_store_queue (
        .clk             (clk),
        .rst_n           (rst_n),
        // Allocate
        .alloc_count     (sq_alloc_count),
        .alloc_idx       (sq_alloc_idx),
        .full            (sq_full),
        // STA fill
        .sta_valid       (sta_issue_valid & ~flush_in.valid),
        .sta_idx         (sta_issue_data.sq_idx),
        .sta_addr        (sta_eff_addr),
        .sta_size        (sta_issue_data.mem_size),
        // STD fill
        .std_valid       (std_issue_valid & ~flush_in.valid),
        .std_idx         (std_issue_data.sq_idx),
        .std_data        (std_rs2),
        .std_byte_mask   (std_byte_mask),
        // Store-to-load forwarding (from load port 0)
        .fwd_req_valid   (load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid),
        .fwd_req_addr    (load_eff_addr[0]),
        .fwd_req_size    (load_issue_data[0].mem_size),
        .fwd_hit         (sq_fwd_hit),
        .fwd_partial     (sq_fwd_partial),
        .fwd_data        (sq_fwd_data),
        // Commit
        .commit_count    (store_commit_count),
        // Drain to CSB
        .drain_valid     (sq_drain_valid),
        .drain_entry     (sq_drain_entry),
        .drain_ready     (sq_drain_ready),
        // Flush
        .flush_valid     (flush_in.valid),
        .flush_full      (flush_in.full_flush)
    );

    // =========================================================================
    // Load Queue
    // =========================================================================
    // Load queue exec fill: only port 0 for now (port 1 follows same pattern)
    // We record both ports but ordering violation check uses the STA port.
    // The load queue has a single exec port; we mux between the two load ports
    // using a registered round-robin or priority. For simplicity, port 0 has
    // priority; port 1 fills on the next cycle via a hold register.

    // Port 0 exec fill signals
    logic        lq_exec_valid;
    logic [LQ_IDX_BITS-1:0] lq_exec_idx;
    logic [63:0] lq_exec_addr;
    logic [1:0]  lq_exec_size;
    logic        lq_exec_is_unsigned;

    // Port 1 hold register for deferred LQ exec fill
    logic        lq_p1_hold_valid_r;
    logic [LQ_IDX_BITS-1:0] lq_p1_hold_idx_r;
    logic [63:0] lq_p1_hold_addr_r;
    logic [1:0]  lq_p1_hold_size_r;
    logic        lq_p1_hold_unsigned_r;

    // Port 0 has priority; port 1 deferred to hold register
    logic p0_exec_fire;
    logic p1_exec_fire;
    assign p0_exec_fire = load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid;
    assign p1_exec_fire = load_issue_valid[1] & ~load_addr_misaligned[1] & ~flush_in.valid;

    // Mux: port 0 new > port 1 hold > port 1 new
    always_comb begin
        if (p0_exec_fire) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = load_issue_data[0].lq_idx;
            lq_exec_addr        = load_eff_addr[0];
            lq_exec_size        = load_issue_data[0].mem_size;
            lq_exec_is_unsigned = load_issue_data[0].is_unsigned;
        end else if (lq_p1_hold_valid_r) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = lq_p1_hold_idx_r;
            lq_exec_addr        = lq_p1_hold_addr_r;
            lq_exec_size        = lq_p1_hold_size_r;
            lq_exec_is_unsigned = lq_p1_hold_unsigned_r;
        end else if (p1_exec_fire) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = load_issue_data[1].lq_idx;
            lq_exec_addr        = load_eff_addr[1];
            lq_exec_size        = load_issue_data[1].mem_size;
            lq_exec_is_unsigned = load_issue_data[1].is_unsigned;
        end else begin
            lq_exec_valid       = 1'b0;
            lq_exec_idx         = '0;
            lq_exec_addr        = '0;
            lq_exec_size        = '0;
            lq_exec_is_unsigned = 1'b0;
        end
    end

    // Hold register: capture port 1 when port 0 also fires same cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_p1_hold_valid_r    <= 1'b0;
        end else if (flush_in.valid) begin
            lq_p1_hold_valid_r    <= 1'b0;
        end else begin
            if (p0_exec_fire && p1_exec_fire) begin
                // Port 1 deferred
                lq_p1_hold_valid_r    <= 1'b1;
                lq_p1_hold_idx_r      <= load_issue_data[1].lq_idx;
                lq_p1_hold_addr_r     <= load_eff_addr[1];
                lq_p1_hold_size_r     <= load_issue_data[1].mem_size;
                lq_p1_hold_unsigned_r <= load_issue_data[1].is_unsigned;
            end else if (lq_p1_hold_valid_r && !p0_exec_fire) begin
                // Held entry consumed this cycle
                lq_p1_hold_valid_r <= 1'b0;
            end
        end
    end

    // LQ result fill: port 0 result (either from forwarding or D-cache)
    logic        lq_result_valid;
    logic [LQ_IDX_BITS-1:0] lq_result_idx;
    logic [63:0] lq_result_data;

    // Load result registered from previous cycle for LQ recording
    logic        lq_result_valid_r;
    logic [LQ_IDX_BITS-1:0] lq_result_idx_r;
    logic [63:0] lq_result_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_result_valid_r <= 1'b0;
        end else if (flush_in.valid) begin
            lq_result_valid_r <= 1'b0;
        end else begin
            lq_result_valid_r <= load_wb_valid[0];
            lq_result_idx_r   <= load_issue_data_r[0].lq_idx;
            lq_result_data_r  <= load_wb_data[0];
        end
    end

    assign lq_result_valid = lq_result_valid_r;
    assign lq_result_idx   = lq_result_idx_r;
    assign lq_result_data  = lq_result_data_r;

    // Registered load issue data for result recording
    iq_entry_t load_issue_data_r [0:1];
    logic [1:0] load_issue_valid_r;
    logic [63:0] load_eff_addr_r [0:1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_issue_valid_r <= '0;
        end else if (flush_in.valid) begin
            load_issue_valid_r <= '0;
        end else begin
            load_issue_valid_r    <= load_issue_valid;
            load_issue_data_r[0]  <= load_issue_data[0];
            load_issue_data_r[1]  <= load_issue_data[1];
            load_eff_addr_r[0]    <= load_eff_addr[0];
            load_eff_addr_r[1]    <= load_eff_addr[1];
        end
    end

    load_queue u_load_queue (
        .clk               (clk),
        .rst_n             (rst_n),
        // Allocate
        .alloc_count       (lq_alloc_count),
        .alloc_idx         (lq_alloc_idx),
        .full              (lq_full),
        // Load execution (address fill)
        .exec_valid        (lq_exec_valid),
        .exec_idx          (lq_exec_idx),
        .exec_addr         (lq_exec_addr),
        .exec_size         (lq_exec_size),
        .exec_is_unsigned  (lq_exec_is_unsigned),
        // Load result
        .result_valid      (lq_result_valid),
        .result_idx        (lq_result_idx),
        .result_data       (lq_result_data),
        // Store-to-load ordering violation check (from STA)
        .st_addr_valid     (sta_issue_valid & ~flush_in.valid),
        .st_addr           (sta_eff_addr),
        .st_size           (sta_issue_data.mem_size),
        .st_rob_idx        (sta_issue_data.rob_idx),
        .ordering_violation(ordering_violation),
        .violation_rob_idx (violation_rob_idx),
        // Commit
        .commit_count      (store_commit_count),
        // Flush
        .flush_valid       (flush_in.valid),
        .flush_full        (flush_in.full_flush)
    );

    // =========================================================================
    // Committed Store Buffer
    // =========================================================================
    logic csb_enq_ready;

    committed_store_buffer u_csb (
        .clk            (clk),
        .rst_n          (rst_n),
        // Enqueue from SQ drain
        .enq_valid      (sq_drain_valid),
        .enq_data       (sq_drain_entry),
        .enq_ready      (csb_enq_ready),
        // Dequeue to D-cache
        .deq_valid      (dcache_store_req_valid),
        .deq_addr       (dcache_store_req_addr),
        .deq_data       (dcache_store_req_data),
        .deq_byte_mask  (dcache_store_req_byte_mask),
        .deq_size       (),
        .deq_ack        (dcache_store_ack),
        // Store-to-load forwarding (from load port 0)
        .fwd_addr       (load_eff_addr[0]),
        .fwd_size       (load_issue_data[0].mem_size),
        .fwd_hit        (csb_fwd_hit),
        .fwd_data       (csb_fwd_data),
        // Full
        .full           ()
    );

    assign sq_drain_ready = csb_enq_ready;

    // =========================================================================
    // D-cache load request generation
    // =========================================================================
    // Port 0: send to D-cache only if no SQ/CSB forwarding hit and no misalign
    // Port 1: always send to D-cache (no forwarding check on port 1)
    logic p0_fwd_hit;
    assign p0_fwd_hit = sq_fwd_hit | csb_fwd_hit;

    assign dcache_load_req_valid[0] = load_issue_valid[0]
                                    & ~load_addr_misaligned[0]
                                    & ~p0_fwd_hit
                                    & ~sq_fwd_partial
                                    & ~flush_in.valid;
    assign dcache_load_req_addr[0]  = load_eff_addr[0];
    assign dcache_load_req_size[0]  = load_issue_data[0].mem_size;
    assign dcache_load_req_is_unsigned[0] = load_issue_data[0].is_unsigned;

    assign dcache_load_req_valid[1] = load_issue_valid[1]
                                    & ~load_addr_misaligned[1]
                                    & ~flush_in.valid;
    assign dcache_load_req_addr[1]  = load_eff_addr[1];
    assign dcache_load_req_size[1]  = load_issue_data[1].mem_size;
    assign dcache_load_req_is_unsigned[1] = load_issue_data[1].is_unsigned;

    // =========================================================================
    // Load data extraction and sign/zero extension
    // =========================================================================
    // D-cache returns 64-bit aligned data. Extract correct bytes based on
    // addr[2:0] and size, then sign/zero extend.
    logic [63:0] load_extracted [0:1];

    generate
        for (li = 0; li < 2; li++) begin : gen_load_extract
            logic [63:0] raw_data;
            logic [2:0]  byte_offset;
            logic [1:0]  ld_size;
            logic        ld_unsigned;

            // Port 0 may use forwarded data; port 1 always uses cache data
            always_comb begin
                if (li == 0 && p0_fwd_hit) begin
                    raw_data = sq_fwd_hit ? sq_fwd_data : csb_fwd_data;
                end else begin
                    raw_data = dcache_load_resp_data[li];
                end
            end

            assign byte_offset = load_eff_addr[li][2:0];
            assign ld_size     = load_issue_data[li].mem_size;
            assign ld_unsigned = load_issue_data[li].is_unsigned;

            // Shift right to align the target bytes to bit 0
            logic [63:0] shifted;
            assign shifted = raw_data >> ({3'b0, byte_offset} * 4'd8);

            // Extract and extend
            always_comb begin
                case (ld_size)
                    MEM_BYTE: begin
                        if (ld_unsigned)
                            load_extracted[li] = {56'b0, shifted[7:0]};
                        else
                            load_extracted[li] = {{56{shifted[7]}}, shifted[7:0]};
                    end
                    MEM_HALF: begin
                        if (ld_unsigned)
                            load_extracted[li] = {48'b0, shifted[15:0]};
                        else
                            load_extracted[li] = {{48{shifted[15]}}, shifted[15:0]};
                    end
                    MEM_WORD: begin
                        if (ld_unsigned)
                            load_extracted[li] = {32'b0, shifted[31:0]};
                        else
                            load_extracted[li] = {{32{shifted[31]}}, shifted[31:0]};
                    end
                    default: begin
                        load_extracted[li] = shifted;
                    end
                endcase
            end
        end
    endgenerate

    // =========================================================================
    // Load writeback to CDB
    // =========================================================================
    // Port 0: valid on forwarding hit (same cycle) or D-cache hit (same cycle)
    // Port 1: valid on D-cache hit
    always_comb begin
        // Port 0
        if (load_issue_valid[0] && load_addr_misaligned[0] && !flush_in.valid) begin
            // Misalignment exception
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = load_issue_data[0].rob_idx;
            load_wb_pdst[0]          = load_issue_data[0].pdst;
            load_wb_data[0]          = '0;
            load_wb_has_exception[0] = 1'b1;
            load_wb_exc_code[0]      = 4'd4; // EXC_LOAD_MISALIGN
        end else if (load_issue_valid[0] && p0_fwd_hit && !flush_in.valid) begin
            // Store-to-load forwarding hit
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = load_issue_data[0].rob_idx;
            load_wb_pdst[0]          = load_issue_data[0].pdst;
            load_wb_data[0]          = load_extracted[0];
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
        end else if (dcache_load_resp_valid[0] && !flush_in.valid) begin
            // D-cache response
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = load_issue_data_r[0].rob_idx;
            load_wb_pdst[0]          = load_issue_data_r[0].pdst;
            load_wb_data[0]          = load_extracted[0];
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
        end else begin
            load_wb_valid[0]         = 1'b0;
            load_wb_rob_idx[0]       = '0;
            load_wb_pdst[0]          = '0;
            load_wb_data[0]          = '0;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
        end

        // Port 1
        if (load_issue_valid[1] && load_addr_misaligned[1] && !flush_in.valid) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = load_issue_data[1].rob_idx;
            load_wb_pdst[1]          = load_issue_data[1].pdst;
            load_wb_data[1]          = '0;
            load_wb_has_exception[1] = 1'b1;
            load_wb_exc_code[1]      = 4'd4;
        end else if (dcache_load_resp_valid[1] && !flush_in.valid) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = load_issue_data_r[1].rob_idx;
            load_wb_pdst[1]          = load_issue_data_r[1].pdst;
            load_wb_data[1]          = load_extracted[1];
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else begin
            load_wb_valid[1]         = 1'b0;
            load_wb_rob_idx[1]       = '0;
            load_wb_pdst[1]          = '0;
            load_wb_data[1]          = '0;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end
    end

    // =========================================================================
    // Speculative wakeup cancel on cache miss
    // =========================================================================
    // If a load was issued (speculative wakeup sent) but the D-cache missed,
    // cancel the wakeup so dependents re-wait. This fires the cycle after issue
    // when the D-cache response is known.
    generate
        for (li = 0; li < 2; li++) begin : gen_spec_cancel
            always_comb begin
                if (load_issue_valid_r[li] && !flush_in.valid) begin
                    if (li == 0) begin
                        // Port 0: cancel if no forwarding hit and D-cache missed
                        spec_cancel_valid[0] = dcache_load_resp_valid[0]
                                             & ~dcache_load_resp_hit[0];
                        spec_cancel_tag[0]   = load_issue_data_r[0].pdst;
                    end else begin
                        spec_cancel_valid[1] = dcache_load_resp_valid[1]
                                             & ~dcache_load_resp_hit[1];
                        spec_cancel_tag[1]   = load_issue_data_r[1].pdst;
                    end
                end else begin
                    spec_cancel_valid[li] = 1'b0;
                    spec_cancel_tag[li]   = '0;
                end
            end
        end
    endgenerate

endmodule

`endif
