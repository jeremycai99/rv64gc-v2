/* file: lsu.sv
 Description: Load-store unit with 2-load 1-store ports and forwarding.
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
    input logic [1:0] load_issue_candidate_valid,
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
    output logic std_wb_valid,
    output logic [ROB_IDX_BITS-1:0] std_wb_rob_idx,

    // Commit counts (from commit unit)
    input logic [2:0] store_commit_count,
    input logic [2:0] load_commit_count,

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
    input logic [ROB_IDX_BITS-1:0] rob_head,

    // Ordering violation (to commit for flush)
    output logic ordering_violation,
    output logic [ROB_IDX_BITS-1:0] violation_rob_idx,
    output logic [1:0] load_issue_suppress,

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

    // L2 fill snoop (for load miss handling)
    // The LSU watches L2 → D-cache fill responses and matches them against
    // in-flight missed loads tracked in the Load Miss Buffer.  When a fill
    // arrives for a line that has a pending load, the LSU extracts the
    // requested bytes from the fill line and writes back the load result
    // via the CDB.  This is the "late response" path for missed loads.
    input logic        dcache_fill_valid,
    input logic [63:0] dcache_fill_addr,
    input logic [LINE_SIZE*8-1:0] dcache_fill_data,

    // Flush
    input flush_t flush_in
);

    // Forward declarations (used by spec_wakeup before full definition)
    logic [1:0] load_issue_valid_r;
    logic [1:0] load_issue_valid_rr;
    logic [1:0] load_nocache_r;
    logic [1:0] load_nocache_rr;
    logic            p1_eff_valid;
    logic            p1_eff_misalign;
    logic [63:0]     p1_eff_addr;
    iq_entry_t       p1_eff_data;
    logic            p1_eff_nocache;
    logic            p0_fwd_hit;
    logic            p1_fwd_hold_valid_r;

    // =========================================================================
    // Load AGU: effective address computation (x2)
    // =========================================================================
    // For fused AUIPC+LD: base address comes from the PC of the AUIPC half,
    // not from rs1 (which is x0/zero for the fused uop because the auipc has
    // no source register).  Detect this case via is_fused on a load and use
    // pc + imm.  Other fusions never produce loads.
    logic [63:0] load_eff_addr [0:1];
    logic [1:0]  load_addr_misaligned;

    genvar li;
    generate
        for (li = 0; li < 2; li++) begin : gen_load_agu
            wire is_pc_rel_ld = load_issue_data[li].is_fused;
            assign load_eff_addr[li] =
                (is_pc_rel_ld ? load_issue_data[li].pc : load_rs1[li])
                + load_issue_data[li].imm;

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
    // For fused AUIPC+ST: same logic as fused loads — use pc instead of rs1
    // because the store's base register comes from the auipc half.
    logic [63:0] sta_eff_addr;
    logic        sta_addr_misaligned;
    logic [2:0]  sta_off;

    wire sta_is_pc_rel = sta_issue_data.is_fused;
    assign sta_eff_addr = (sta_is_pc_rel ? sta_issue_data.pc : sta_rs1)
                        + sta_issue_data.imm;
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
    //
    // Bug fix: do NOT gate with ~flush_in.valid.
    //
    // On a branch mispredict, the flush fires the same cycle as the STA may
    // issue.  If the store is OLDER than the mispredicting branch, it must
    // survive the flush — the SQ's own flush logic will distinguish which
    // entries to discard by ROB age.  Silently dropping the STA causes the
    // older store to be lost: its SQ entry never gets addr_valid, its ROB
    // entry never gets ready (because sta_wb_valid never fires), and
    // commit permanently stalls.
    assign sta_wb_valid   = sta_issue_valid;
    assign sta_wb_rob_idx = sta_issue_data.rob_idx;
    assign std_wb_valid   = std_issue_valid;
    assign std_wb_rob_idx = std_issue_data.rob_idx;

    // =========================================================================
    // Speculative wakeup: load issue -> wake dependents
    //
    // Timing: pulse spec_wakeup the cycle BEFORE the load result is on the
    // (combinational) CDB.  For a 2-cycle D-cache hit:
    //   - T+0: load AGU (issue)
    //   - T+1: load at _r stage  -> spec_wakeup pulses
    //   - T+2: load result on combinational CDB (load_wb)
    //   - T+2: dependent IQ entry observes spec_wakeup_r match -> latched
    //          src1_ready -> consumer issues at T+3 with bypass from
    //          cdb_r[4] (which captures the T+2 broadcast).
    //
    // The spec_wakeup is treated by the IQ as a registered hint that lets a
    // consumer issue 1 cycle EARLIER than it would by waiting for the
    // (already-registered) cdb_r broadcast.  Without the 1-cycle delay
    // here, the consumer would issue the same cycle as the AGU and read
    // stale operand data from PRF/bypass.
    //
    // We pulse spec_wakeup based on the *_r stage (1 cycle after AGU),
    // then the IQ further latches it via src1_ready, giving a total of
    // 2 cycles between load AGU and consumer issue — exactly matching the
    // dcache-hit producer→bypass latency.
    // =========================================================================
    generate
        for (li = 0; li < 2; li++) begin : gen_spec_wakeup
            assign spec_wakeup_valid[li] = load_issue_valid_r[li]
                                         & ~load_nocache_r[li]
                                         & ~flush_in.valid;
            assign spec_wakeup_tag[li]   = load_issue_data_r[li].pdst;
        end
    endgenerate

    // =========================================================================
    // Store-to-load forwarding wires (SQ and CSB)
    // =========================================================================
    // Port 0 forwards from same-cycle STA/STD, SQ, and CSB.
    // Port 1 now probes a second SQ forwarding port as well; CSB remains
    // port-0 only.
    logic        sq_fwd_hit;
    logic        sq_fwd_partial;
    logic        sq_fwd_wait;
    logic [63:0] sq_fwd_data;
    logic        sq_wait_p1;
    logic        sq_fwd_hit_p1;
    logic        sq_fwd_partial_p1;
    logic [63:0] sq_fwd_data_p1;
    logic        p1_wait_req_valid;
    logic [63:0] p1_wait_req_addr;
    logic [1:0]  p1_wait_req_size;
    logic [ROB_IDX_BITS-1:0] p1_wait_req_rob_idx;

    logic        csb_fwd_hit;
    logic [63:0] csb_fwd_data;

    // =========================================================================
    // Same-cycle STA/STD → load forwarding bypass
    // =========================================================================
    // When a store and a load issue on the SAME cycle and the load's address
    // matches the store's address (and the store fully covers the load's
    // byte mask), we must forward directly from the store's in-flight
    // STA/STD data — the SQ entry hasn't yet been written this cycle, so the
    // SQ CAM won't see it.  This path has HIGHER priority than the SQ CAM
    // (younger store wins over older SQ entries).
    logic        same_cycle_fwd_hit;
    logic        same_cycle_fwd_partial;
    logic [63:0] same_cycle_fwd_data;
    logic        same_cycle_sta_wait0;
    logic        same_cycle_sta_wait1;
    logic        sta_std_same_store;
    logic [7:0]  sta_byte_mask_dyn;
    logic [7:0]  load0_byte_mask_dyn;
    logic [7:0]  load1_byte_mask_dyn;
    logic [2:0]  sta_byte_off;
    logic [2:0]  load0_byte_off;
    logic [2:0]  load1_byte_off;
    logic [ROB_IDX_BITS:0] sta_issue_age;
    logic [ROB_IDX_BITS:0] load0_issue_age;
    logic [ROB_IDX_BITS:0] load1_issue_age;
    logic                  sta_older_than_load0;
    logic                  sta_older_than_load1;

    assign sta_byte_off   = sta_eff_addr[2:0];
    assign load0_byte_off = load_eff_addr[0][2:0];
    assign load1_byte_off = load_eff_addr[1][2:0];

    always_comb begin
        case (sta_issue_data.mem_size)
            MEM_BYTE:  sta_byte_mask_dyn = 8'h01 << sta_byte_off;
            MEM_HALF:  sta_byte_mask_dyn = 8'h03 << sta_byte_off;
            MEM_WORD:  sta_byte_mask_dyn = 8'h0F << sta_byte_off;
            MEM_DWORD: sta_byte_mask_dyn = 8'hFF;
            default:   sta_byte_mask_dyn = 8'h00;
        endcase
        case (load_issue_data[0].mem_size)
            MEM_BYTE:  load0_byte_mask_dyn = 8'h01 << load0_byte_off;
            MEM_HALF:  load0_byte_mask_dyn = 8'h03 << load0_byte_off;
            MEM_WORD:  load0_byte_mask_dyn = 8'h0F << load0_byte_off;
            MEM_DWORD: load0_byte_mask_dyn = 8'hFF;
            default:   load0_byte_mask_dyn = 8'h00;
        endcase
        case (load_issue_data[1].mem_size)
            MEM_BYTE:  load1_byte_mask_dyn = 8'h01 << load1_byte_off;
            MEM_HALF:  load1_byte_mask_dyn = 8'h03 << load1_byte_off;
            MEM_WORD:  load1_byte_mask_dyn = 8'h0F << load1_byte_off;
            MEM_DWORD: load1_byte_mask_dyn = 8'hFF;
            default:   load1_byte_mask_dyn = 8'h00;
        endcase
    end

    function automatic logic [ROB_IDX_BITS:0] lsu_rob_age_from_head(
        input logic [ROB_IDX_BITS-1:0] idx
    );
        if (idx >= rob_head)
            lsu_rob_age_from_head = {1'b0, idx} - {1'b0, rob_head};
        else
            lsu_rob_age_from_head = ROB_DEPTH[ROB_IDX_BITS:0] - {1'b0, rob_head} + {1'b0, idx};
    endfunction

    assign sta_issue_age       = lsu_rob_age_from_head(sta_issue_data.rob_idx);
    assign load0_issue_age     = lsu_rob_age_from_head(load_issue_data[0].rob_idx);
    assign load1_issue_age     = lsu_rob_age_from_head(load_issue_data[1].rob_idx);
    assign sta_older_than_load0 = sta_issue_valid &&
                                  load_issue_candidate_valid[0] &&
                                  (sta_issue_age < load0_issue_age);
    assign sta_older_than_load1 = sta_issue_valid &&
                                  load_issue_candidate_valid[1] &&
                                  (sta_issue_age < load1_issue_age);
    assign sta_std_same_store   = sta_issue_valid && std_issue_valid &&
                                  (sta_issue_data.sq_idx == std_issue_data.sq_idx);

    // Same-cycle coverage check: store must be fully covering the load's
    // bytes AND address[63:3] must match (same 8-byte aligned word).
    // STA/STD issue independently, so only treat them as a forwarding pair
    // when they belong to the same SQ entry.
    logic same_cycle_addr_match0;
    logic same_cycle_addr_match1;
    logic [7:0] same_cycle_overlap0;
    logic [7:0] same_cycle_overlap1;
    // Gate on load_issue_valid to prevent stale load_eff_addr from
    // oscillating through the same-cycle forwarding comparison.
    assign same_cycle_addr_match0 =
        load_issue_valid[0] & sta_std_same_store &
        (sta_eff_addr[63:3] == load_eff_addr[0][63:3]);
    assign same_cycle_addr_match1 =
        load_issue_candidate_valid[1] & sta_issue_valid &
        (sta_eff_addr[63:3] == load_eff_addr[1][63:3]);
    assign same_cycle_overlap0 = (sta_older_than_load0 && same_cycle_addr_match0)
                               ? (sta_byte_mask_dyn & load0_byte_mask_dyn)
                               : 8'h00;
    assign same_cycle_overlap1 = (sta_older_than_load1 && same_cycle_addr_match1)
                               ? (sta_byte_mask_dyn & load1_byte_mask_dyn)
                               : 8'h00;
    assign same_cycle_fwd_hit = load_issue_valid[0] & ~load_addr_misaligned[0] &
                                ~flush_in.valid &
                                sta_older_than_load0 &
                                same_cycle_addr_match0 &
                                ((sta_byte_mask_dyn & load0_byte_mask_dyn)
                                 == load0_byte_mask_dyn);
    assign same_cycle_fwd_partial =
        load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid &
        sta_older_than_load0 &
        same_cycle_addr_match0 &
        (same_cycle_overlap0 != 8'h00) & ~same_cycle_fwd_hit;
    assign same_cycle_sta_wait0 =
        load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid &
        sta_older_than_load0 &
        (same_cycle_overlap0 != 8'h00) &
        ~same_cycle_fwd_hit;
    assign same_cycle_sta_wait1 =
        load_issue_candidate_valid[1] & ~load_addr_misaligned[1] & ~flush_in.valid &
        sta_older_than_load1 &
        (same_cycle_overlap1 != 8'h00);

    // Build same-cycle fwd data: for each byte position `b` in the memory
    // dword that is covered by the store, take the store's byte at position
    // `b - sta_byte_off` of std_rs2 (std_rs2 is LSB-aligned to the store's
    // own address, so its byte 0 corresponds to memory byte sta_byte_off).
    always_comb begin
        same_cycle_fwd_data = '0;
        for (int b = 0; b < 8; b++) begin
            if (same_cycle_overlap0[b] && (b >= int'(sta_byte_off))) begin
                same_cycle_fwd_data[b*8 +: 8] =
                    std_rs2[(b - int'(sta_byte_off)) * 8 +: 8];
            end
        end
    end

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
        .rob_head        (rob_head),
        // STA fill (do NOT gate with flush: older stores must survive
        // mispredict flushes; the SQ flush handler filters by ROB age).
        .sta_valid       (sta_issue_valid),
        .sta_idx         (sta_issue_data.sq_idx),
        .sta_rob_idx     (sta_issue_data.rob_idx),
        .sta_addr        (sta_eff_addr),
        .sta_size        (sta_issue_data.mem_size),
        // STD fill (same rationale: let older stores through; SQ filters)
        .std_valid       (std_issue_valid),
        .std_idx         (std_issue_data.sq_idx),
        .std_data        (std_rs2),
        .std_byte_mask   (std_byte_mask),
        // Store-to-load forwarding (from load port 0).
        // Gate fwd_req_addr to 0 when invalid to prevent stale
        // load_eff_addr from oscillating through Verilator's eval loop.
        .fwd_req_valid   (load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid),
        .fwd_req_addr    ((load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid)
                          ? load_eff_addr[0] : 64'd0),
        .fwd_req_size    (load_issue_data[0].mem_size),
        .fwd_req_rob_idx (load_issue_data[0].rob_idx),
        .fwd_hit         (sq_fwd_hit),
        .fwd_partial     (sq_fwd_partial),
        .fwd_wait        (sq_fwd_wait),
        .fwd_data        (sq_fwd_data),
        .wait_req_valid  (p1_wait_req_valid),
        .wait_req_addr   (p1_wait_req_addr),
        .wait_req_size   (p1_wait_req_size),
        .wait_req_rob_idx(p1_wait_req_rob_idx),
        .wait_fwd_hit    (sq_fwd_hit_p1),
        .wait_partial    (sq_fwd_partial_p1),
        .wait_wait       (sq_wait_p1),
        .wait_data       (sq_fwd_data_p1),
        .wait_hit        (),
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
    logic [ROB_IDX_BITS-1:0] lq_exec_rob_idx;
    logic [63:0] lq_exec_addr;
    logic [1:0]  lq_exec_size;
    logic        lq_exec_is_unsigned;

    // Port 1 hold register for deferred LQ exec fill
    logic        lq_p1_hold_valid_r;
    logic [LQ_IDX_BITS-1:0] lq_p1_hold_idx_r;
    logic [ROB_IDX_BITS-1:0] lq_p1_hold_rob_idx_r;
    logic [63:0] lq_p1_hold_addr_r;
    logic [1:0]  lq_p1_hold_size_r;
    logic        lq_p1_hold_unsigned_r;

    // Port 0 has priority; port 1 deferred to hold register.
    // Port 1 uses the EFFECTIVE issue (which includes the dcache-conflict
    // retry register) so the LQ exec_idx tracks the deferred load.
    logic p0_exec_fire;
    logic p1_exec_fire;
    assign p0_exec_fire = load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid;
    assign p1_exec_fire = p1_eff_valid       & ~p1_eff_misalign        & ~flush_in.valid;

    // Mux: port 0 new > port 1 hold > port 1 effective (new or retry)
    always_comb begin
        if (p0_exec_fire) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = load_issue_data[0].lq_idx;
            lq_exec_rob_idx     = load_issue_data[0].rob_idx;
            lq_exec_addr        = load_eff_addr[0];
            lq_exec_size        = load_issue_data[0].mem_size;
            lq_exec_is_unsigned = load_issue_data[0].is_unsigned;
        end else if (lq_p1_hold_valid_r) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = lq_p1_hold_idx_r;
            lq_exec_rob_idx     = lq_p1_hold_rob_idx_r;
            lq_exec_addr        = lq_p1_hold_addr_r;
            lq_exec_size        = lq_p1_hold_size_r;
            lq_exec_is_unsigned = lq_p1_hold_unsigned_r;
        end else if (p1_exec_fire) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = p1_eff_data.lq_idx;
            lq_exec_rob_idx     = p1_eff_data.rob_idx;
            lq_exec_addr        = p1_eff_addr;
            lq_exec_size        = p1_eff_data.mem_size;
            lq_exec_is_unsigned = p1_eff_data.is_unsigned;
        end else begin
            lq_exec_valid       = 1'b0;
            lq_exec_idx         = '0;
            lq_exec_rob_idx     = '0;
            lq_exec_addr        = '0;
            lq_exec_size        = '0;
            lq_exec_is_unsigned = 1'b0;
        end
    end

    // Hold register: capture port 1 (effective) when port 0 also fires
    // same cycle.  Uses p1_eff which already accounts for the dcache
    // conflict retry path.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_p1_hold_valid_r    <= 1'b0;
        end else if (flush_in.valid) begin
            lq_p1_hold_valid_r    <= 1'b0;
        end else begin
            if (p0_exec_fire && p1_exec_fire) begin
                // Port 1 deferred
                lq_p1_hold_valid_r    <= 1'b1;
                lq_p1_hold_idx_r      <= p1_eff_data.lq_idx;
                lq_p1_hold_rob_idx_r  <= p1_eff_data.rob_idx;
                lq_p1_hold_addr_r     <= p1_eff_addr;
                lq_p1_hold_size_r     <= p1_eff_data.mem_size;
                lq_p1_hold_unsigned_r <= p1_eff_data.is_unsigned;
            end else if (lq_p1_hold_valid_r && !p0_exec_fire) begin
                // Held entry consumed this cycle
                lq_p1_hold_valid_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Load pipeline metadata: shift-register chain
    // =========================================================================
    // The D-cache has a 2-cycle load latency (stage-0 RAM read + stage-1 tag
    // compare).  We must track the issued load metadata for 2 cycles so that
    // the writeback on cache hit uses the correct rob_idx / pdst / lq_idx /
    // byte_offset — not the stale values from the CURRENT (post-issue) cycle.
    //
    // Stages:
    //   *_r  = 1 cycle after issue
    //   *_rr = 2 cycles after issue (matches the cycle dcache_load_resp_valid
    //          fires for a hit).
    // =========================================================================
    iq_entry_t load_issue_data_r  [0:1];
    iq_entry_t load_issue_data_rr [0:1];
    // load_issue_valid_r/rr declared earlier (forward decl)
    logic [63:0] load_eff_addr_r  [0:1];
    logic [63:0] load_eff_addr_rr [0:1];
    // load_nocache_r/rr declared earlier (forward decl)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_issue_valid_r  <= '0;
            load_issue_valid_rr <= '0;
            load_nocache_r      <= '0;
            load_nocache_rr     <= '0;
        end else if (flush_in.valid) begin
            // Clear _rr (2-cycle stale) to prevent wrong-path writebacks
            // from hitting reallocated ROB entries after a full flush.
            // Leave _r: a load that issued 1 cycle ago will age into _rr
            // next cycle; if the flush is full, the next cycle's _rr eval
            // will see flush_in cleared and process normally.
            load_issue_valid_rr <= '0;
            load_nocache_rr     <= '0;
            load_nocache_r      <= '0;
            load_nocache_rr     <= '0;
        end else begin
            // Port 0 propagates the original issue.  Port 1 propagates the
            // EFFECTIVE issue (which includes the retry register), so the
            // writeback metadata at _rr matches the cycle the dcache
            // responds for the deferred load.
            load_issue_valid_r[0] <= load_issue_valid[0];
            load_issue_valid_r[1] <= p1_eff_valid;
            load_issue_data_r[0]  <= load_issue_data[0];
            load_issue_data_r[1]  <= p1_eff_data;
            load_eff_addr_r[0]    <= load_eff_addr[0];
            load_eff_addr_r[1]    <= p1_eff_addr;
            load_nocache_r[0]     <= load_issue_valid[0] &
                                     (load_addr_misaligned[0] | p0_fwd_hit |
                                      sq_fwd_partial | flush_in.valid);
            load_nocache_r[1]     <= p1_eff_valid & p1_eff_nocache;

            // Stage 2 (2 cycles after issue): matches cache response cycle.
            load_issue_valid_rr   <= load_issue_valid_r;
            load_issue_data_rr[0] <= load_issue_data_r[0];
            load_issue_data_rr[1] <= load_issue_data_r[1];
            load_eff_addr_rr[0]   <= load_eff_addr_r[0];
            load_eff_addr_rr[1]   <= load_eff_addr_r[1];
            load_nocache_rr[0]    <= load_nocache_r[0];
            load_nocache_rr[1]    <= load_nocache_r[1];
        end
    end

    // =========================================================================
    // LQ result fill: whichever path drove load_wb[0] this cycle also
    // records the result into the load queue.  Because the LMB needs to be
    // declared below before we can reference its fields here, we forward-
    // declare the lq_result source selector and bind it in the same
    // writeback always_comb block below.
    // =========================================================================
    logic                   lq_result_valid;
    logic [LQ_IDX_BITS-1:0] lq_result_idx;
    logic [63:0]            lq_result_data;

    logic                   lq_result_valid_r;
    logic [LQ_IDX_BITS-1:0] lq_result_idx_r;
    logic [63:0]            lq_result_data_r;
    logic [LQ_IDX_BITS-1:0] lq_result_idx_sel;  // combinational selector

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_result_valid_r <= 1'b0;
        end else if (flush_in.valid) begin
            lq_result_valid_r <= 1'b0;
        end else begin
            lq_result_valid_r <= load_wb_valid[0];
            lq_result_idx_r   <= lq_result_idx_sel;
            lq_result_data_r  <= load_wb_data[0];
        end
    end

    assign lq_result_valid = lq_result_valid_r;
    assign lq_result_idx   = lq_result_idx_r;
    assign lq_result_data  = lq_result_data_r;

    load_queue u_load_queue (
        .clk               (clk),
        .rst_n             (rst_n),
        // Allocate
        .alloc_count       (lq_alloc_count),
        .alloc_idx         (lq_alloc_idx),
        .full              (lq_full),
        .rob_head          (rob_head),
        // Load execution (address fill)
        .exec_valid        (lq_exec_valid),
        .exec_idx          (lq_exec_idx),
        .exec_rob_idx      (lq_exec_rob_idx),
        .exec_addr         (lq_exec_addr),
        .exec_size         (lq_exec_size),
        .exec_is_unsigned  (lq_exec_is_unsigned),
        // Load result
        .result_valid      (lq_result_valid),
        .result_idx        (lq_result_idx),
        .result_data       (lq_result_data),
        // Store-to-load ordering violation check (from STA).
        // Use the same unguarded STA valid as above; a flush-cycle STA that
        // is older than the flush point still needs its ordering check.
        .st_addr_valid     (sta_issue_valid),
        .st_addr           (sta_eff_addr),
        .st_size           (sta_issue_data.mem_size),
        .st_rob_idx        (sta_issue_data.rob_idx),
        .ordering_violation(ordering_violation),
        .violation_rob_idx (violation_rob_idx),
        // Commit
        .commit_count      (load_commit_count),
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
        .fwd_valid      (load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid),
        .fwd_addr       ((load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid)
                          ? load_eff_addr[0] : 64'd0),
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
    //
    // p0_fwd_hit covers three sources: the same-cycle STA/STD bypass, the
    // SQ CAM (older stores in the SQ), and the CSB CAM (committed but not
    // yet drained stores).  Any of these hitting means we do NOT send the
    // load to the D-cache (avoids polluting the cache and wasting an MSHR).
    // p0_fwd_hit declared earlier (forward decl)
    assign p0_fwd_hit = same_cycle_fwd_hit | sq_fwd_hit | csb_fwd_hit;

    // -------------------------------------------------------------------------
    // Port-1 retry hold register for d-cache same-set conflicts.
    //
    // The d-cache suppresses port 1 when both loads target the same set
    // (bank conflict).  Without a retry path, port 1's load would be lost
    // and the ROB entry would never become ready, deadlocking commit.
    //
    // We replicate port 1's metadata pipeline (issue → _r → _rr) on a
    // shifted timeline so the writeback path can still match the cache
    // response.  When a conflict is detected, port 1 is captured into the
    // retry register and re-fired through dcache port 1 the *next* cycle
    // (when port 0 is presumably free or, at worst, still conflicting and
    // we re-hold).
    // -------------------------------------------------------------------------
    logic            p1_retry_valid_r;
    iq_entry_t       p1_retry_data_r;
    logic [63:0]     p1_retry_addr_r;
    logic            p1_retry_misalign_r;
    logic            p1_retry_load_nocache_r;
    logic            p1_sq_fwd_blocked;
    assign load_issue_suppress[0] =
        load_issue_candidate_valid[0] &&
        ~load_addr_misaligned[0] &&
        ~flush_in.valid &&
        (sq_fwd_wait || same_cycle_sta_wait0);

    // Combinational: same-set conflict between port 0 and port 1
    logic dcache_conflict;
    assign dcache_conflict = load_issue_valid[0] && load_issue_valid[1]
                            && ~load_addr_misaligned[0]
                            && ~load_addr_misaligned[1]
                            && (load_eff_addr[0][13:6] ==
                                load_eff_addr[1][13:6]);

    // Effective port 1 sources: prefer the retry register if valid;
    // otherwise the new issue (suppressed on conflict).
    // p1_eff_valid/misalign/addr/data/nocache declared earlier (forward decl)

    always_comb begin
        if (p1_retry_valid_r) begin
            p1_wait_req_valid   = 1'b1;
            p1_wait_req_addr    = p1_retry_addr_r;
            p1_wait_req_size    = p1_retry_data_r.mem_size;
            p1_wait_req_rob_idx = p1_retry_data_r.rob_idx;
        end else begin
            p1_wait_req_valid   = load_issue_candidate_valid[1] &&
                                  ~load_addr_misaligned[1] &&
                                  ~flush_in.valid;
            p1_wait_req_addr    = load_eff_addr[1];
            p1_wait_req_size    = load_issue_data[1].mem_size;
            p1_wait_req_rob_idx = load_issue_data[1].rob_idx;
        end
    end

    assign p1_sq_fwd_blocked =
        !p1_retry_valid_r &&
        load_issue_candidate_valid[1] &&
        !load_addr_misaligned[1] &&
        !flush_in.valid &&
        sq_fwd_hit_p1 &&
        !sq_wait_p1 &&
        p1_fwd_hold_valid_r;

    assign load_issue_suppress[1] =
        load_issue_candidate_valid[1] &&
        (p1_retry_valid_r ||
         (!load_addr_misaligned[1] && !flush_in.valid && !p1_retry_valid_r &&
          (sq_wait_p1 || sq_fwd_partial_p1 || p1_sq_fwd_blocked ||
           same_cycle_sta_wait1)));

    always_comb begin
        if (p1_retry_valid_r) begin
            p1_eff_valid    = !sq_wait_p1 &&
                              !sq_fwd_partial_p1 &&
                              (!sq_fwd_hit_p1 || !p1_fwd_hold_valid_r);
            p1_eff_data     = p1_retry_data_r;
            p1_eff_addr     = p1_retry_addr_r;
            p1_eff_misalign = p1_retry_misalign_r;
            p1_eff_nocache  = p1_retry_load_nocache_r |
                              sq_fwd_hit_p1 | sq_fwd_partial_p1;
        end else if (load_issue_valid[1] && !sq_wait_p1 && !sq_fwd_partial_p1 &&
                     (sq_fwd_hit_p1 ? !p1_fwd_hold_valid_r : !dcache_conflict)) begin
            p1_eff_valid    = 1'b1;
            p1_eff_data     = load_issue_data[1];
            p1_eff_addr     = load_eff_addr[1];
            p1_eff_misalign = load_addr_misaligned[1];
            p1_eff_nocache  = load_addr_misaligned[1] | flush_in.valid |
                              sq_fwd_hit_p1 | sq_fwd_partial_p1;
        end else begin
            p1_eff_valid    = 1'b0;
            p1_eff_data     = '0;
            p1_eff_addr     = '0;
            p1_eff_misalign = 1'b0;
            p1_eff_nocache  = 1'b0;
        end
    end

    // Capture port 1 on a d-cache set conflict.  Address-known / data-not-ready
    // hazards use load_issue_suppress to keep the IQ entry live instead.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_retry_valid_r <= 1'b0;
        end else if (flush_in.valid) begin
            p1_retry_valid_r <= 1'b0;
        end else begin
            if (p1_retry_valid_r) begin
                // Drain after one cycle unless the retried load is still
                // blocked by an older store whose address is known but whose
                // data has not reached the SQ yet.
                if (!sq_wait_p1 && !sq_fwd_partial_p1)
                    p1_retry_valid_r <= 1'b0;
            end
            if (dcache_conflict && !sq_wait_p1 && !sq_fwd_partial_p1 && !sq_fwd_hit_p1) begin
                p1_retry_valid_r        <= 1'b1;
                p1_retry_data_r         <= load_issue_data[1];
                p1_retry_addr_r         <= load_eff_addr[1];
                p1_retry_misalign_r     <= load_addr_misaligned[1];
                p1_retry_load_nocache_r <= load_addr_misaligned[1] | flush_in.valid;
            end
        end
    end

    assign dcache_load_req_valid[0] = load_issue_valid[0]
                                    & ~load_addr_misaligned[0]
                                    & ~p0_fwd_hit
                                    & ~sq_fwd_partial
                                    & ~same_cycle_fwd_partial
                                    & ~flush_in.valid;
    assign dcache_load_req_addr[0]  = load_eff_addr[0];
    assign dcache_load_req_size[0]  = load_issue_data[0].mem_size;
    assign dcache_load_req_is_unsigned[0] = load_issue_data[0].is_unsigned;

    assign dcache_load_req_valid[1] = p1_eff_valid
                                    & ~p1_eff_misalign
                                    & ~sq_fwd_hit_p1
                                    & ~sq_fwd_partial_p1
                                    & ~flush_in.valid;
    assign dcache_load_req_addr[1]  = p1_eff_addr;
    assign dcache_load_req_size[1]  = p1_eff_data.mem_size;
    assign dcache_load_req_is_unsigned[1] = p1_eff_data.is_unsigned;

    // =========================================================================
    // Load data extraction and sign/zero extension
    // =========================================================================
    // D-cache returns 64-bit aligned data. Extract correct bytes based on
    // addr[2:0] and size, then sign/zero extend.  Separate extract paths:
    //   - Forwarding / misalign (same cycle as issue): uses _current_ metadata
    //   - D-cache hit (2 cycles after issue): uses _rr_ metadata
    // A mux below in load_wb selects between them.
    logic [63:0] load_extracted_fwd [0:1];  // same-cycle (forwarding/misalign)
    logic [63:0] load_extracted_dc  [0:1];  // 2-cycle delayed (dcache hit)
    logic [63:0] p1_extracted_fwd;

    generate
        for (li = 0; li < 2; li++) begin : gen_load_extract
            // ---- Forwarding / misalign path (current cycle) ----
            // Forwarding data is already byte-positioned in the memory dword
            // (byte b at position b*8 +: 8).  The extraction shifts right
            // by the load's byte offset to LSB-align the requested bytes.
            logic [63:0] fwd_raw;
            logic [63:0] fwd_shifted;
            always_comb begin
                if (li == 0 && p0_fwd_hit) begin
                    // Priority: same_cycle > SQ > CSB (youngest wins)
                    if (same_cycle_fwd_hit)
                        fwd_raw = same_cycle_fwd_data;
                    else if (sq_fwd_hit)
                        fwd_raw = sq_fwd_data;
                    else
                        fwd_raw = csb_fwd_data;
                end else begin
                    fwd_raw = '0;
                end
                fwd_shifted = fwd_raw >> ({3'b0, load_eff_addr[li][2:0]} * 4'd8);
                case (load_issue_data[li].mem_size)
                    MEM_BYTE: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {56'b0, fwd_shifted[7:0]}
                                : {{56{fwd_shifted[7]}}, fwd_shifted[7:0]};
                    MEM_HALF: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {48'b0, fwd_shifted[15:0]}
                                : {{48{fwd_shifted[15]}}, fwd_shifted[15:0]};
                    MEM_WORD: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {32'b0, fwd_shifted[31:0]}
                                : {{32{fwd_shifted[31]}}, fwd_shifted[31:0]};
                    default:  load_extracted_fwd[li] = fwd_shifted;
                endcase
            end

            // ---- D-cache hit path (2 cycles after issue) ----
            // The dcache already extracts, sign/zero extends, and LSB-aligns
            // its response based on the load's size and byte offset.
            // Pass it through unchanged -- a second extraction here
            // would shift it again and corrupt non-dword-aligned loads.
            assign load_extracted_dc[li] = dcache_load_resp_data[li];
        end
    endgenerate

    always_comb begin
        logic [63:0] p1_fwd_shifted;

        p1_fwd_shifted = sq_fwd_data_p1 >> ({3'b0, p1_eff_addr[2:0]} * 4'd8);
        case (p1_eff_data.mem_size)
            MEM_BYTE: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {56'b0, p1_fwd_shifted[7:0]}
                        : {{56{p1_fwd_shifted[7]}}, p1_fwd_shifted[7:0]};
            MEM_HALF: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {48'b0, p1_fwd_shifted[15:0]}
                        : {{48{p1_fwd_shifted[15]}}, p1_fwd_shifted[15:0]};
            MEM_WORD: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {32'b0, p1_fwd_shifted[31:0]}
                        : {{32{p1_fwd_shifted[31]}}, p1_fwd_shifted[31:0]};
            default:  p1_extracted_fwd = p1_fwd_shifted;
        endcase
    end

    // =========================================================================
    // Load Miss Buffer (LMB)
    // =========================================================================
    // When a load misses the D-cache, the cache currently never generates a
    // second (late) response; the fill eventually installs the line but the
    // original load is lost.  We track pending misses here and resolve them
    // by snooping the L2 → D-cache fill response directly.
    //
    // Each entry holds the load metadata and the line-aligned miss address.
    // When a fill arrives whose line matches an entry, we extract the
    // requested bytes from the fill data and generate a CDB writeback for
    // that load.  The LMB is a simple, free-list-allocated array.
    // =========================================================================
    localparam int LMB_DEPTH    = 8;
    localparam int LMB_IDX_BITS = $clog2(LMB_DEPTH);

    typedef struct packed {
        logic                       valid;
        logic [63:0]                line_addr;     // address aligned to LINE_SIZE
        logic [5:0]                 byte_offset;   // byte offset within the line
        logic [1:0]                 size;          // mem_size_e
        logic                       is_unsigned;
        logic [ROB_IDX_BITS-1:0]    rob_idx;
        logic [PHYS_REG_BITS-1:0]   pdst;
        logic [LQ_IDX_BITS-1:0]     lq_idx;
    } lmb_entry_t;

    lmb_entry_t lmb [0:LMB_DEPTH-1];

    // Miss detection: a load issued 2 cycles ago whose cache path did not
    // produce a response this cycle and which wasn't handled via forwarding
    // or the misalign exception path.
    logic p0_miss_detect;
    logic p1_miss_detect;
    assign p0_miss_detect = load_issue_valid_rr[0]
                          & ~load_nocache_rr[0]
                          & ~dcache_load_resp_valid[0];
    assign p1_miss_detect = load_issue_valid_rr[1]
                          & ~load_nocache_rr[1]
                          & ~dcache_load_resp_valid[1];

    // Find a free LMB slot (lowest index).
    logic                     lmb_free_avail;
    logic [LMB_IDX_BITS-1:0]  lmb_free_idx;

    always_comb begin
        lmb_free_avail = 1'b0;
        lmb_free_idx   = '0;
        for (int i = 0; i < LMB_DEPTH; i++) begin
            if (!lmb[i].valid && !lmb_free_avail) begin
                lmb_free_avail = 1'b1;
                lmb_free_idx   = LMB_IDX_BITS'(i);
            end
        end
    end

    // Match an incoming fill to an LMB entry (line-aligned compare).
    logic [LMB_DEPTH-1:0] lmb_fill_match;
    logic                 lmb_any_match;
    logic [LMB_IDX_BITS-1:0] lmb_match_idx;

    always_comb begin
        lmb_any_match = 1'b0;
        lmb_match_idx = '0;
        for (int i = 0; i < LMB_DEPTH; i++) begin
            lmb_fill_match[i] = lmb[i].valid
                              & dcache_fill_valid
                              & (lmb[i].line_addr[63:LINE_BITS]
                                 == dcache_fill_addr[63:LINE_BITS]);
            if (lmb_fill_match[i] && !lmb_any_match) begin
                lmb_any_match = 1'b1;
                lmb_match_idx = LMB_IDX_BITS'(i);
            end
        end
    end

    // Extract bytes from the fill line based on the matched entry's offset.
    // The fill data is LINE_SIZE*8 bits (512 bits).  We extract a 64-bit
    // aligned dword using the entry's [5:3] index, then sign/zero extend
    // using [2:0] byte offset + size.
    logic [63:0] lmb_fill_dword;
    logic [63:0] lmb_fill_shifted;
    logic [63:0] lmb_extracted;
    always_comb begin
        lmb_fill_dword = dcache_fill_data[{lmb[lmb_match_idx].byte_offset[5:3],
                                            3'b000} * 8 +: 64];
        lmb_fill_shifted = lmb_fill_dword >> ({3'b0, lmb[lmb_match_idx].byte_offset[2:0]} * 4'd8);
        case (lmb[lmb_match_idx].size)
            MEM_BYTE: lmb_extracted = lmb[lmb_match_idx].is_unsigned
                        ? {56'b0, lmb_fill_shifted[7:0]}
                        : {{56{lmb_fill_shifted[7]}}, lmb_fill_shifted[7:0]};
            MEM_HALF: lmb_extracted = lmb[lmb_match_idx].is_unsigned
                        ? {48'b0, lmb_fill_shifted[15:0]}
                        : {{48{lmb_fill_shifted[15]}}, lmb_fill_shifted[15:0]};
            MEM_WORD: lmb_extracted = lmb[lmb_match_idx].is_unsigned
                        ? {32'b0, lmb_fill_shifted[31:0]}
                        : {{32{lmb_fill_shifted[31]}}, lmb_fill_shifted[31:0]};
            default:  lmb_extracted = lmb_fill_shifted;
        endcase
    end

    // =========================================================================
    // LMB sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < LMB_DEPTH; i++) begin
                lmb[i].valid <= 1'b0;
            end
        end else if (flush_in.valid && flush_in.full_flush) begin
            // Full flush: drop all speculative pending misses.
            for (int i = 0; i < LMB_DEPTH; i++) begin
                lmb[i].valid <= 1'b0;
            end
        end else begin
            // Allocate on miss detection. If both ports miss in the same
            // cycle, port 0 wins the single allocation slot; port 1 still
            // cancels its speculative wakeup and will at least not commit
            // wrong data.
            if (p0_miss_detect && lmb_free_avail) begin
                lmb[lmb_free_idx].valid        <= 1'b1;
                lmb[lmb_free_idx].line_addr    <=
                    {load_eff_addr_rr[0][63:LINE_BITS], {LINE_BITS{1'b0}}};
                lmb[lmb_free_idx].byte_offset  <= load_eff_addr_rr[0][5:0];
                lmb[lmb_free_idx].size         <= load_issue_data_rr[0].mem_size;
                lmb[lmb_free_idx].is_unsigned  <= load_issue_data_rr[0].is_unsigned;
                lmb[lmb_free_idx].rob_idx      <= load_issue_data_rr[0].rob_idx;
                lmb[lmb_free_idx].pdst         <= load_issue_data_rr[0].pdst;
                lmb[lmb_free_idx].lq_idx       <= load_issue_data_rr[0].lq_idx;
            end else if (p1_miss_detect && lmb_free_avail) begin
                lmb[lmb_free_idx].valid        <= 1'b1;
                lmb[lmb_free_idx].line_addr    <=
                    {load_eff_addr_rr[1][63:LINE_BITS], {LINE_BITS{1'b0}}};
                lmb[lmb_free_idx].byte_offset  <= load_eff_addr_rr[1][5:0];
                lmb[lmb_free_idx].size         <= load_issue_data_rr[1].mem_size;
                lmb[lmb_free_idx].is_unsigned  <= load_issue_data_rr[1].is_unsigned;
                lmb[lmb_free_idx].rob_idx      <= load_issue_data_rr[1].rob_idx;
                lmb[lmb_free_idx].pdst         <= load_issue_data_rr[1].pdst;
                lmb[lmb_free_idx].lq_idx       <= load_issue_data_rr[1].lq_idx;
            end

            // On fill match, free the LMB entry (response is generated
            // combinationally via lmb_any_match in the writeback mux below).
            if (lmb_any_match) begin
                lmb[lmb_match_idx].valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Store-to-load forwarding hold register
    // =========================================================================
    // Delay forwarding writeback by 1 cycle to break the combinational loop:
    //   CDB → bypass → IQ → issue → load_eff_addr → SQ fwd → load_wb → CDB
    // The consumer reads from PRF (written at the next edge from this CDB).
    logic        fwd_hold_valid_r;
    logic [ROB_IDX_BITS-1:0] fwd_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] fwd_hold_pdst_r;
    logic [63:0] fwd_hold_data_r;
    logic [LQ_IDX_BITS-1:0] fwd_hold_lq_idx_r;

    logic fwd_hold_is_exc_r;
    logic [ROB_IDX_BITS-1:0] p1_fwd_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] p1_fwd_hold_pdst_r;
    logic [63:0] p1_fwd_hold_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in.valid) begin
            fwd_hold_valid_r  <= 1'b0;
            fwd_hold_is_exc_r <= 1'b0;
        end else begin
            // Capture ANY same-cycle load writeback (fwd OR misalign)
            // to eliminate all same-cycle CDB loops from load port 0.
            fwd_hold_valid_r   <= load_issue_valid[0] && !flush_in.valid
                                  && (p0_fwd_hit || load_addr_misaligned[0]);
            fwd_hold_is_exc_r  <= load_addr_misaligned[0];
            fwd_hold_rob_idx_r <= load_issue_data[0].rob_idx;
            fwd_hold_pdst_r    <= load_issue_data[0].pdst;
            fwd_hold_data_r    <= load_addr_misaligned[0] ? 64'd0 : load_extracted_fwd[0];
            fwd_hold_lq_idx_r  <= load_issue_data[0].lq_idx;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in.valid) begin
            p1_fwd_hold_valid_r <= 1'b0;
        end else begin
            if (p1_fwd_hold_valid_r &&
                !((load_issue_valid[1] && load_addr_misaligned[1] && !flush_in.valid) ||
                   (dcache_load_resp_valid[1] && load_issue_valid_rr[1] &&
                    !load_nocache_rr[1]) ||
                   (fwd_hold_valid_r && dcache_load_resp_valid[0] &&
                    load_issue_valid_rr[0] && !load_nocache_rr[0]))) begin
                p1_fwd_hold_valid_r <= 1'b0;
            end

            if (!p1_fwd_hold_valid_r &&
                p1_eff_valid &&
                !p1_eff_misalign &&
                sq_fwd_hit_p1 &&
                !sq_wait_p1 &&
                !flush_in.valid) begin
                p1_fwd_hold_valid_r   <= 1'b1;
                p1_fwd_hold_rob_idx_r <= p1_eff_data.rob_idx;
                p1_fwd_hold_pdst_r    <= p1_eff_data.pdst;
                p1_fwd_hold_data_r    <= p1_extracted_fwd;
            end
        end
    end

    // =========================================================================
    // Load writeback to CDB
    // =========================================================================
    // Priority (Port 0):
    //   1. Misalign exception (same-cycle, rare — doesn't oscillate)
    //   2. Forwarding hold (1-cycle delayed SQ/CSB fwd)
    //   3. D-cache hit response (2-cycle delayed metadata)
    //   4. LMB fill match (late miss response)
    // Priority (Port 1):
    //   1. Misalign exception
    //   2. D-cache hit response
    //   3. Port-0 forwarded spill
    //   4. SQ-forward hold
    //
    // Note: only port 0 is wired to the LMB for now (single-port fill match).
    // =========================================================================
    always_comb begin
        logic p0_dcache_hit_valid;
        logic p1_normal_wb_valid;
        logic p0_fwd_spill_to_p1;

        p0_dcache_hit_valid = dcache_load_resp_valid[0] && load_issue_valid_rr[0]
                           && !load_nocache_rr[0];
        p1_normal_wb_valid  = (load_issue_valid[1] && load_addr_misaligned[1] && !flush_in.valid)
                           || (dcache_load_resp_valid[1] && load_issue_valid_rr[1]
                               && !load_nocache_rr[1]);
        // If a same-cycle forwarded/misaligned load is queued in fwd_hold at
        // the exact cycle an older port-0 dcache hit returns, the older hit
        // must not be dropped.  Spill the held forwarded result onto port 1
        // when that slot is otherwise idle.
        p0_fwd_spill_to_p1 = fwd_hold_valid_r && p0_dcache_hit_valid && !p1_normal_wb_valid;

        // Default LQ index selector (drives lq_result_idx_sel)
        lq_result_idx_sel = '0;

        // Port 0 — no same-cycle paths.  Misalign + fwd both go through
        // the hold register (1-cycle delayed) to eliminate CDB loops.
        if (p0_dcache_hit_valid) begin
            // D-cache hit response — 2 cycles after issue.
            // NOT gated by flush: an older load must write back even if a
            // younger instruction triggers a flush in the same cycle.
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = load_issue_data_rr[0].rob_idx;
            load_wb_pdst[0]          = load_issue_data_rr[0].pdst;
            load_wb_data[0]          = load_extracted_dc[0];
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = load_issue_data_rr[0].lq_idx;
        end else if (fwd_hold_valid_r) begin
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = fwd_hold_rob_idx_r;
            load_wb_pdst[0]          = fwd_hold_pdst_r;
            load_wb_data[0]          = fwd_hold_data_r;
            load_wb_has_exception[0] = fwd_hold_is_exc_r;
            load_wb_exc_code[0]      = fwd_hold_is_exc_r ? 4'd4 : 4'd0;
            lq_result_idx_sel        = fwd_hold_lq_idx_r;
        end else if (lmb_any_match) begin
            // Late miss response from LMB (fill arrived).
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = lmb[lmb_match_idx].rob_idx;
            load_wb_pdst[0]          = lmb[lmb_match_idx].pdst;
            load_wb_data[0]          = lmb_extracted;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = lmb[lmb_match_idx].lq_idx;
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
        end else if (dcache_load_resp_valid[1] && load_issue_valid_rr[1]
                     && !load_nocache_rr[1]) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = load_issue_data_rr[1].rob_idx;
            load_wb_pdst[1]          = load_issue_data_rr[1].pdst;
            load_wb_data[1]          = load_extracted_dc[1];
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else if (p0_fwd_spill_to_p1) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = fwd_hold_rob_idx_r;
            load_wb_pdst[1]          = fwd_hold_pdst_r;
            load_wb_data[1]          = fwd_hold_data_r;
            load_wb_has_exception[1] = fwd_hold_is_exc_r;
            load_wb_exc_code[1]      = fwd_hold_is_exc_r ? 4'd4 : 4'd0;
        end else if (p1_fwd_hold_valid_r) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = p1_fwd_hold_rob_idx_r;
            load_wb_pdst[1]          = p1_fwd_hold_pdst_r;
            load_wb_data[1]          = p1_fwd_hold_data_r;
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
    // If a load was issued (speculative wakeup sent) but the D-cache missed
    // (no hit response 2 cycles after issue), cancel the wakeup so dependents
    // re-wait until the LMB generates the late response.
    generate
        for (li = 0; li < 2; li++) begin : gen_spec_cancel
            always_comb begin
                spec_cancel_valid[li] = 1'b0;
                spec_cancel_tag[li]   = '0;
                if (load_issue_valid_rr[li] && !load_nocache_rr[li] &&
                    !dcache_load_resp_valid[li] && !flush_in.valid) begin
                    spec_cancel_valid[li] = 1'b1;
                    spec_cancel_tag[li]   = load_issue_data_rr[li].pdst;
                end
            end
        end
    endgenerate

`ifdef LSU_DEBUG
    // ---- DEBUG traces — only compiled when +define+LSU_DEBUG is passed.
    integer dbg_cycle = 0;
    always_ff @(posedge clk) begin
        dbg_cycle <= dbg_cycle + 1;
        if (load_issue_valid[0]) begin
            $display("[%0d] LSU issue[0]: rob=%0d pdst=%0d addr=%016h size=%0d unsigned=%0d fwd_hit=%b misalign=%b partial=%b flush=%b",
                dbg_cycle, load_issue_data[0].rob_idx, load_issue_data[0].pdst,
                load_eff_addr[0], load_issue_data[0].mem_size, load_issue_data[0].is_unsigned,
                p0_fwd_hit, load_addr_misaligned[0], sq_fwd_partial, flush_in.valid);
        end
        if (load_issue_valid[1]) begin
            $display("[%0d] LSU issue[1]: rob=%0d pdst=%0d addr=%016h size=%0d unsigned=%0d misalign=%b flush=%b",
                dbg_cycle, load_issue_data[1].rob_idx, load_issue_data[1].pdst,
                load_eff_addr[1], load_issue_data[1].mem_size, load_issue_data[1].is_unsigned,
                load_addr_misaligned[1], flush_in.valid);
        end
        if (load_wb_valid[0]) begin
            $display("[%0d] LSU wb[0]:    rob=%0d pdst=%0d data=%016h exc=%b",
                dbg_cycle, load_wb_rob_idx[0], load_wb_pdst[0],
                load_wb_data[0], load_wb_has_exception[0]);
        end
        if (load_wb_valid[1]) begin
            $display("[%0d] LSU wb[1]:    rob=%0d pdst=%0d data=%016h exc=%b",
                dbg_cycle, load_wb_rob_idx[1], load_wb_pdst[1],
                load_wb_data[1], load_wb_has_exception[1]);
        end
        if (sta_issue_valid) begin
            $display("[%0d] LSU STA:      rob=%0d addr=%016h size=%0d flush=%b",
                dbg_cycle, sta_issue_data.rob_idx, sta_eff_addr, sta_issue_data.mem_size, flush_in.valid);
        end
        if (std_issue_valid) begin
            $display("[%0d] LSU STD:      rob=%0d data=%016h mask=%02h",
                dbg_cycle, std_issue_data.rob_idx, std_rs2, std_byte_mask);
        end
        if (p0_miss_detect && lmb_free_avail) begin
            $display("[%0d] LSU LMB alloc: rob=%0d pdst=%0d line=%016h off=%0d",
                dbg_cycle, load_issue_data_rr[0].rob_idx, load_issue_data_rr[0].pdst,
                {load_eff_addr_rr[0][63:LINE_BITS], {LINE_BITS{1'b0}}},
                load_eff_addr_rr[0][5:0]);
        end
        if (dcache_fill_valid) begin
            $display("[%0d] LSU fill snoop: addr=%016h", dbg_cycle, dcache_fill_addr);
        end
        if (lmb_any_match) begin
            $display("[%0d] LSU LMB match[%0d]: rob=%0d data=%016h",
                dbg_cycle, lmb_match_idx, lmb[lmb_match_idx].rob_idx, lmb_extracted);
        end
        if (dcache_store_req_valid) begin
            $display("[%0d] LSU store->dcache: addr=%016h data=%016h mask=%02h",
                dbg_cycle, dcache_store_req_addr, dcache_store_req_data, dcache_store_req_byte_mask);
        end
        if (flush_in.valid) begin
            $display("[%0d] LSU FLUSH:    rob_idx=%0d full=%b redirect=%016h",
                dbg_cycle, flush_in.rob_idx, flush_in.full_flush, flush_in.redirect_pc);
        end
        if (ordering_violation) begin
            $display("[%0d] LSU ORDERING VIOL: load_rob=%0d (sta_rob=%0d sta_addr=%016h)",
                dbg_cycle, violation_rob_idx, sta_issue_data.rob_idx, sta_eff_addr);
        end
    end
`endif

endmodule

`endif
