/* file: fetch_unit.sv
 Description: Fetch unit with branch prediction and I-cache interface.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module fetch_unit
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Output to decode
    output logic [2:0]  fetch_count,
    output logic [31:0] fetch_insn [0:PIPE_WIDTH-1],
    output logic [63:0] fetch_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0] fetch_is_rvc,
    output logic [PIPE_WIDTH-1:0] fetch_bp_taken,
    output logic [63:0] fetch_bp_target [0:PIPE_WIDTH-1],
    output logic        fetch_bp_owner_valid,
    output logic [2:0]  fetch_bp_owner_slot,
    output logic        fetch_bp_owner_from_subgroup,
    output logic [63:0] fetch_bp_lookup_pc,
    output logic [4:0]  fetch_bp_ras_tos,
    output logic [63:0] fetch_bp_ras_top,
    output logic [GHR_BITS-1:0] fetch_bp_ghr,

    // Stall from downstream (decode/rename backpressure)
    input  logic        backend_stall,
    // Frontend quiesce while loop-buffer playback owns rename input.
    input  logic        frontend_hold,

    // Redirect (from commit -- mispredict or exception)
    input  logic        redirect_valid,
    input  logic [63:0] redirect_pc,

    // BPU update (from commit -- actual branch outcome)
    input  logic        bpu_update_valid,
    input  logic [63:0] bpu_update_pc,
    input  logic        bpu_tage_update_valid,
    input  logic [63:0] bpu_tage_update_pc,
    input  logic        bpu_update_taken,
    input  logic        bpu_update_mispredict,
    input  logic [63:0] bpu_update_target,
    input  logic [2:0]  bpu_update_type,     // branch type for BTB
    input  logic [GHR_BITS-1:0] bpu_update_ghr,

    // GHR checkpoint restore
    input  logic        ghr_restore_valid,
    input  logic [GHR_BITS-1:0] ghr_restore_val,
    output logic [GHR_BITS-1:0] ghr_out,

    // RAS restore
    input  logic        ras_restore_valid,
    input  logic [4:0]  ras_restore_tos,
    input  logic        ras_restore_top_valid,
    input  logic [63:0] ras_restore_top_addr,

    // Memory interface (I-cache to L2)
    output logic        icache_fill_req_valid,
    output logic [63:0] icache_fill_req_addr,
    input  logic        icache_fill_resp_valid,
    input  logic [63:0] icache_fill_resp_addr,
    input  logic [511:0] icache_fill_resp_data,

    // Invalidate (FENCE.I)
    input  logic        fence_i,
    // Prefetch L2 interface (from NLPB)
    output logic         pf_l2_req_valid,
    output logic [63:0]  pf_l2_req_addr,
    input  logic         pf_l2_req_ready,
    input  logic         pf_l2_resp_valid,
    input  logic [63:0]  pf_l2_resp_addr,
    input  logic [511:0] pf_l2_resp_data
);

    // =========================================================================
    // Branch type encoding (BTB)
    //   0 = conditional, 1 = JAL, 2 = JALR, 3 = CALL, 4 = RET
    // =========================================================================
    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;

    function automatic logic is_link_reg(input logic [4:0] reg_id);
        begin
            is_link_reg = (reg_id == 5'd1) || (reg_id == 5'd5);
        end
    endfunction

    function automatic logic [63:0] imm_b64(input logic [31:0] insn);
        logic [12:0] imm13;
        begin
            imm13 = {insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
            imm_b64 = {{51{imm13[12]}}, imm13};
        end
    endfunction

    function automatic logic [63:0] imm_j64(input logic [31:0] insn);
        logic [20:0] imm21;
        begin
            imm21 = {insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
            imm_j64 = {{43{imm21[20]}}, imm21};
        end
    endfunction

    // =========================================================================
    // F1 stage signals
    // =========================================================================
    logic [63:0] f1_pc;
    logic        f1_valid;

    // BPU redirect from F2 (predicted-taken branch)
    logic        f2_bpu_redirect;
    logic [63:0] f2_bpu_target;
    logic        req_redirect_c;

    // Sequential next PC: computed from how many bytes F2 consumed
    logic [63:0] f2_seq_next_pc;
    logic        f2_seq_valid;

    // consumed_remainder_r: latched when the current cycle's extraction
    // consumed a straddle remainder AND emitted at least one instruction.
    // The following cycle must bypass the normal f1->f2 pipeline
    // (which otherwise leaves f2_pc_r pointing at the already-processed
    // cache-line base) and instead advance f2_pc_r directly to the
    // f2_seq_next_pc captured on the consume cycle.
    logic        consumed_remainder_r;
    logic [63:0] post_remainder_pc_r;

    // =========================================================================
    // PC generation (F1)
    // Priority: redirect > BPU redirect > sequential
    // =========================================================================
    logic [63:0] next_pc;
    logic        next_valid;
    logic        fe_stall;

    always_comb begin
        if (redirect_valid) begin
            next_pc    = redirect_pc;
            next_valid = 1'b1;
        end else if (f2_bpu_redirect) begin
            next_pc    = f2_bpu_target;
            next_valid = 1'b1;
        end else if (f2_seq_valid) begin
            next_pc    = f2_seq_next_pc;
            next_valid = 1'b1;
        end else begin
            next_pc    = f1_pc;
            next_valid = f1_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1_pc    <= RESET_VECTOR;
            f1_valid <= 1'b1;
        end else if (redirect_valid) begin
            f1_pc    <= redirect_pc;
            f1_valid <= 1'b1;
        end else if (!fe_stall) begin
            // When the cycle after a remainder-consume is using the saved
            // post-remainder PC, keep f1_pc matching f2_pc_r so the pipeline
            // re-syncs (f1 should lead f2 again starting the cycle after).
            if (consumed_remainder_r)
                f1_pc    <= post_remainder_pc_r;
            else
                f1_pc    <= next_pc;
            f1_valid <= next_valid;
        end
    end

    // =========================================================================
    // I-Cache instance
    // =========================================================================
    logic        ic_req_valid;
    logic [63:0] ic_req_addr;
    logic [63:0] req_pc_c;
    logic [63:0] req_block_pc_c;
    logic        ic_resp_valid;
    logic [511:0] ic_resp_data;
    logic        ic_resp_hit;
    logic        ic_invalidate_busy;
    logic        f2_data_valid;
    logic [511:0] f2_data_line;
    logic        packet_buf_enq;
    logic        packet_buf_deq;
    logic        packet_buf_valid;
    logic        packet_buf_full;
    logic        packet_buf_empty;
    logic        ftq_need_alloc_c;
    logic        ftq_enq_valid;
    logic        ftq_pop_valid;
    logic        ftq_head_valid;
    logic        ftq_full;
    logic        ftq_empty;
    logic [FTQ_IDX_BITS-1:0]   ftq_enq_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_head_idx;
    logic [FTQ_EPOCH_BITS-1:0] ftq_enq_epoch;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_enq_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_head_tag;
    logic [FTQ_EPOCH_BITS-1:0] ftq_current_epoch;
    logic [FTQ_IDX_BITS:0]     ftq_count;
    // Forward declarations used by FTQ allocation gating before the full F2
    // register block later in the file.
    logic        f2_valid_r;
    logic [63:0] f2_pc_r;
    // Forward-declared for FTQ completion wiring before the F2 pipeline block.
    logic [FTQ_IDX_BITS-1:0]   f2_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] f2_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] f2_ftq_alloc_tag_r;
    logic        ftq_last_alloc_valid_r;
    logic [63:0] ftq_last_alloc_req_pc_r;
    logic        subgroup_seed_valid_r;
    logic [63:0] subgroup_seed_pc_r;
    logic [63:0] subgroup_seed_parent_pc_r;
    logic [63:0] subgroup_seed_owner_pc_r;
    logic        subgroup_seed_pred_valid_r;
    logic        subgroup_seed_pred_taken_r;
    logic [5:0]  subgroup_seed_pred_offset_r;
    logic [2:0]  subgroup_seed_pred_type_r;
    logic [63:0] subgroup_seed_pred_target_r;
    logic        subgroup_seed_hit_c;
    logic        subgroup_seed_load_c;
    logic        subgroup_seed_pred_taken_c;
    ftq_entry_t  req_ftq_entry_c;
    logic        req_pred_ctl_valid_c;
    logic        req_pred_ctl_taken_c;
    logic [5:0]  req_pred_ctl_offset_c;
    logic [2:0]  req_pred_ctl_type_c;
    logic [63:0] req_pred_ctl_target_c;
    ftq_entry_t  ftq_head_entry;
    fetch_packet_t packet_buf_in;
    fetch_packet_t packet_buf_head;
    logic        packet_buf_owner_match_c;
    logic        remainder_valid_r;

    assign req_pc_c = (req_redirect_c && !redirect_valid)
                      ? f2_bpu_target : f1_pc;
    assign req_block_pc_c = {req_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign ftq_need_alloc_c =
        !redirect_valid &&
        f1_valid &&
        !remainder_valid_r &&
        // The live F2 group already owns this exact request PC. Re-allocating
        // a fresh FTQ entry for it creates a tag with no distinct packet to
        // pair against. Dhrystone hit this at tag 390 on 0x800023d0.
        !(f2_valid_r && (req_pc_c == f2_pc_r)) &&
        (!ftq_last_alloc_valid_r ||
         (req_pc_c != ftq_last_alloc_req_pc_r));

    // Request to I-cache: issue when F1 is valid and not stalled
    assign fe_stall    = frontend_hold ||
                         packet_buf_full || (ftq_full && ftq_need_alloc_c);
    assign ic_req_valid = f1_valid && !fe_stall;
    // On BPU redirect, bypass f1_pc and send the redirect target directly
    // to the icache.  This reduces the taken-branch fetch bubble from 2
    // cycles to 1: the icache starts the new lookup in the SAME cycle as
    // the redirect instead of waiting for f1_pc to update next cycle.
    assign ic_req_addr  = req_pc_c;
    assign ftq_enq_valid = ic_req_valid && ftq_need_alloc_c;

    // I-cache raw combinational outputs (same-cycle as request)
    logic        ic_resp_valid_comb;
    logic [511:0] ic_resp_data_comb;
    logic        ic_resp_hit_comb;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid      (ic_req_valid),
        .req_addr       (ic_req_addr),
        .resp_valid     (ic_resp_valid_comb),
        .resp_data      (ic_resp_data_comb),
        .resp_hit       (ic_resp_hit_comb),
        .fill_req_valid (icache_fill_req_valid),
        .fill_req_addr  (icache_fill_req_addr),
        .fill_resp_valid(icache_fill_resp_valid),
        .fill_resp_addr (icache_fill_resp_addr),
        .fill_resp_data (icache_fill_resp_data),
        .invalidate_all (fence_i),
        .invalidate_busy(ic_invalidate_busy)
    );

    // =========================================================================
    // Next-line prefetch buffer (NLPB)
    // =========================================================================
    logic        nlpb_hit_comb;
    logic [511:0] nlpb_data_comb;
    logic        nlpb_resp_valid_r;
    logic [63:0] nlpb_resp_addr_r;
    logic [511:0] nlpb_resp_data_r;
    logic        nlpb_resp_match_c;
    // Trigger on icache HIT only (not fill-forwards from MSHRs)
    logic        nlpb_trigger;
    logic [63:0] nlpb_trigger_addr;
    assign nlpb_trigger      = ic_resp_valid_comb && ic_resp_hit_comb;
    assign nlpb_trigger_addr = {ic_req_addr[63:6], 6'b0};

    next_line_prefetch_buffer u_nlpb (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_valid   (f1_valid && !fe_stall),
        .lookup_addr    (ic_req_addr),
        .hit            (nlpb_hit_comb),
        .hit_data       (nlpb_data_comb),
        .trigger_valid  (nlpb_trigger),
        .trigger_addr   (nlpb_trigger_addr),
        .flush          (redirect_valid),
        .fence_i        (fence_i),
        .pf_req_valid   (pf_l2_req_valid),
        .pf_req_addr    (pf_l2_req_addr),
        .pf_req_ready   (pf_l2_req_ready),
        .pf_resp_valid  (pf_l2_resp_valid),
        .pf_resp_addr   (pf_l2_resp_addr),
        .pf_resp_data   (pf_l2_resp_data)
    );

    // Merged response: the icache's aligned s1 output remains the primary
    // source.  The NLPB is re-timed by one cycle so its lookup result is only
    // consumed when it matches the current F2 line, avoiding the stale-PC
    // hazard of the old same-cycle bypass path.
    logic        merged_resp_valid_comb;
    logic [511:0] merged_resp_data_comb;
    assign nlpb_resp_match_c =
        nlpb_resp_valid_r &&
        (nlpb_resp_addr_r[63:LINE_BITS] == f2_pc_r[63:LINE_BITS]);
    assign merged_resp_valid_comb = ic_resp_valid_comb || nlpb_resp_match_c;
    assign merged_resp_data_comb  =
        ic_resp_valid_comb ? ic_resp_data_comb : nlpb_resp_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
        end else if (redirect_valid) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
        end else begin
            nlpb_resp_valid_r <= f1_valid && !fe_stall && nlpb_hit_comb;
            nlpb_resp_addr_r  <= {ic_req_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};
            nlpb_resp_data_r  <= nlpb_data_comb;
        end
    end

    // Pipeline alignment with sync-read icache:
    // The icache's internal s1 stage already provides 1-cycle SRAM latency,
    // so at cycle T the *_comb outputs correspond to the request presented
    // at T-1 (= f1_pc at T-1 = f2_pc_r at T).  Adding a second register
    // here would cause f2_pc_r to lead icache response by one cycle and F2
    // would consume stale-PC data.
    assign ic_resp_valid = merged_resp_valid_comb;
    assign ic_resp_data  = merged_resp_data_comb;
    assign ic_resp_hit   = ic_resp_hit_comb || nlpb_resp_match_c;
    assign f2_data_valid = ic_resp_valid;
    assign f2_data_line  = ic_resp_data;
    assign packet_buf_owner_match_c =
        packet_buf_valid &&
        packet_buf_head.valid &&
        ftq_head_valid &&
        (packet_buf_head.ftq_idx == ftq_head_idx) &&
        (packet_buf_head.ftq_epoch == ftq_current_epoch) &&
        (packet_buf_head.ftq_alloc_tag == ftq_head_tag);
    assign packet_buf_deq = packet_buf_valid && !backend_stall &&
                            !frontend_hold;

    ftq u_ftq (
        .clk          (clk),
        .rst_n        (rst_n),
        .flush        (redirect_valid),
        .enq_valid    (ftq_enq_valid),
        .enq_entry    (req_ftq_entry_c),
        .enq_ready    (),
        .enq_idx      (ftq_enq_idx),
        .enq_epoch    (ftq_enq_epoch),
        .enq_tag      (ftq_enq_tag),
        .pop_valid    (ftq_pop_valid),
        .head_valid   (ftq_head_valid),
        .head_entry   (ftq_head_entry),
        .head_idx     (ftq_head_idx),
        .head_tag     (ftq_head_tag),
        .current_epoch(ftq_current_epoch),
        .count        (ftq_count),
        .full         (ftq_full),
        .empty        (ftq_empty)
    );

    fetch_packet_buffer u_fetch_packet_buffer (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (redirect_valid),
        .enq_valid  (packet_buf_enq),
        .enq_packet (packet_buf_in),
        .enq_ready  (),
        .deq_ready  (packet_buf_deq),
        .deq_valid  (packet_buf_valid),
        .deq_packet (packet_buf_head),
        .full       (packet_buf_full),
        .empty      (packet_buf_empty)
    );

    // =========================================================================
    // BTB instance (combinational lookup in F1)
    // =========================================================================
    logic        btb_hit;
    logic [63:0] btb_target;
    logic [2:0]  btb_branch_type;
    logic [5:0]  btb_branch_offset;
    logic        btb_alt_hit;
    logic [63:0] btb_alt_target;
    logic [2:0]  btb_alt_branch_type;
    logic [5:0]  btb_alt_branch_offset;
    logic        btb_update_valid;
    logic        tage_update_valid;

    btb u_btb (
        .clk           (clk),
        .rst_n         (rst_n),
        .lookup_pc     (ic_req_addr),
        .hit           (btb_hit),
        .target        (btb_target),
        .branch_type   (btb_branch_type),
        .branch_offset (btb_branch_offset),
        .alt_hit       (btb_alt_hit),
        .alt_target    (btb_alt_target),
        .alt_branch_type  (btb_alt_branch_type),
        .alt_branch_offset(btb_alt_branch_offset),
        .update_valid  (btb_update_valid),
        .update_pc     (bpu_update_pc),
        .update_target (bpu_update_target),
        .update_type   (bpu_update_type),
        .flush         (1'b0)
    );

    // =========================================================================
    // TAGE-SC-L instance (combinational lookup in F1 plus an auxiliary
    // branch-PC lookup used after IFU predecode identifies the owner
    // conditional on BTB-miss subgroups).
    // =========================================================================
    logic [63:0] predecode_ctl_pc;
    logic [GHR_BITS-1:0] f2_ghr_snapshot_r;
    logic tage_pred_taken;
    logic tage_pred_confident;
    logic owner_tage_pred_taken;
    logic owner_tage_pred_confident;

    // Speculative GHR update: when we predict a branch as taken in F2
    logic tage_spec_update_valid;
    logic tage_spec_taken;

    assign btb_update_valid  = bpu_update_valid;
    assign tage_update_valid = bpu_update_valid && (bpu_update_type == BT_COND);

    tage_sc_l u_tage_sc_l (
        .clk              (clk),
        .rst_n            (rst_n),
        .pc               (ic_req_addr),
        .pred_taken       (tage_pred_taken),
        .pred_confident   (tage_pred_confident),
        .aux_pc           (predecode_ctl_pc),
        .aux_ghr          (f2_ghr_snapshot_r),
        .aux_pred_taken   (owner_tage_pred_taken),
        .aux_pred_confident(owner_tage_pred_confident),
        .update_valid     (tage_update_valid),
        .update_pc        (bpu_update_pc),
        .update_taken     (bpu_update_taken),
        .update_mispredict(bpu_update_mispredict),
        .update_ghr       (bpu_update_ghr),
        .spec_update_valid(tage_spec_update_valid),
        .spec_taken       (tage_spec_taken),
        .ghr_restore_valid(ghr_restore_valid),
        .ghr_restore_val  (ghr_restore_val),
        .ghr_out          (ghr_out),
        .flush            (redirect_valid)
    );

    // =========================================================================
    // RAS instance
    // =========================================================================
    logic        ras_push_valid;
    logic [63:0] ras_push_addr;
    logic        ras_pop_valid;
    logic [63:0] ras_pop_addr;
    logic [4:0]  ras_tos;

    ras u_ras (
        .clk          (clk),
        .rst_n        (rst_n),
        .push_valid   (ras_push_valid),
        .push_addr    (ras_push_addr),
        .pop_valid    (ras_pop_valid),
        .pop_addr     (ras_pop_addr),
        .tos          (ras_tos),
        .restore_valid(ras_restore_valid),
        .restore_tos  (ras_restore_tos),
        .restore_top_valid(ras_restore_top_valid),
        .restore_top_addr (ras_restore_top_addr)
    );

    always_comb begin
        req_pred_ctl_valid_c  = 1'b0;
        req_pred_ctl_taken_c  = 1'b0;
        req_pred_ctl_offset_c = 6'd0;
        req_pred_ctl_type_c   = BT_COND;
        req_pred_ctl_target_c = 64'd0;

        if (btb_hit) begin
            automatic logic [63:0] pred_branch_pc;
            pred_branch_pc      = {req_block_pc_c[63:6], btb_branch_offset};
            req_pred_ctl_valid_c  = 1'b1;
            req_pred_ctl_offset_c = btb_branch_offset;
            req_pred_ctl_type_c   = btb_branch_type;

            case (btb_branch_type)
                BT_COND: begin
                    req_pred_ctl_target_c = btb_target;
                    req_pred_ctl_taken_c =
                        tage_pred_taken ||
                        (!tage_pred_confident && (btb_target < pred_branch_pc));
                end
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    req_pred_ctl_target_c = btb_target;
                    req_pred_ctl_taken_c  = 1'b1;
                end
                BT_RET: begin
                    if ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0)) begin
                        req_pred_ctl_target_c = ras_pop_addr;
                        req_pred_ctl_taken_c  = 1'b1;
                    end
                end
                default: begin
                    req_pred_ctl_valid_c = 1'b0;
                end
            endcase
        end
    end

    always_comb begin
        req_ftq_entry_c = '0;
        req_ftq_entry_c.block_pc         = req_block_pc_c;
        req_ftq_entry_c.start_offset     = req_pc_c[5:0];
        req_ftq_entry_c.fallthrough_pc   = req_block_pc_c + 64'(LINE_SIZE);
        if (subgroup_seed_hit_c) begin
            req_ftq_entry_c.pred_ctl_valid   = subgroup_seed_pred_valid_r;
            req_ftq_entry_c.pred_ctl_taken   = subgroup_seed_pred_taken_r;
            req_ftq_entry_c.pred_ctl_offset  = subgroup_seed_pred_offset_r;
            req_ftq_entry_c.pred_ctl_type    = subgroup_seed_pred_type_r;
            req_ftq_entry_c.pred_ctl_target  = subgroup_seed_pred_target_r;
            req_ftq_entry_c.pred_from_subgroup = 1'b1;
        end else begin
            req_ftq_entry_c.pred_ctl_valid   = req_pred_ctl_valid_c;
            req_ftq_entry_c.pred_ctl_taken   = req_pred_ctl_taken_c;
            req_ftq_entry_c.pred_ctl_offset  = req_pred_ctl_offset_c;
            req_ftq_entry_c.pred_ctl_type    = req_pred_ctl_type_c;
            req_ftq_entry_c.pred_ctl_target  = req_pred_ctl_target_c;
            req_ftq_entry_c.pred_from_subgroup = 1'b0;
        end
        req_ftq_entry_c.btb_hit          = btb_hit;
        req_ftq_entry_c.btb_offset       = btb_branch_offset;
        req_ftq_entry_c.btb_type         = btb_branch_type;
        req_ftq_entry_c.btb_target       = btb_target;
        req_ftq_entry_c.btb_alt_hit      = btb_alt_hit;
        req_ftq_entry_c.btb_alt_offset   = btb_alt_branch_offset;
        req_ftq_entry_c.btb_alt_type     = btb_alt_branch_type;
        req_ftq_entry_c.btb_alt_target   = btb_alt_target;
        req_ftq_entry_c.tage_taken       = tage_pred_taken;
        req_ftq_entry_c.tage_confident   = tage_pred_confident;
        req_ftq_entry_c.ras_tos_snapshot = ras_tos;
        req_ftq_entry_c.ras_top_snapshot = ras_pop_addr;
        req_ftq_entry_c.ghr_snapshot     = ghr_out;
    end

    // =========================================================================
    // F1 -> F2 pipeline registers
    // =========================================================================
    logic        f2_btb_hit_r;
    logic [63:0] f2_btb_target_r;
    logic [2:0]  f2_btb_type_r;
    logic [5:0]  f2_btb_offset_r;
    logic        f2_btb_alt_hit_r;
    logic [63:0] f2_btb_alt_target_r;
    logic [2:0]  f2_btb_alt_type_r;
    logic [5:0]  f2_btb_alt_offset_r;
    logic        f2_tage_taken_r;
    logic        f2_tage_confident_r;
    logic        f2_ftq_valid_r;
    ftq_entry_t  f2_ftq_entry_r;
    // Forward declarations (used by consume_remainder_c before full definition)
    logic [2:0]  extract_count;
    logic [5:0]  start_offset;
    logic        same_line_handoff_c;
    logic        same_line_next_has_ctl_c;

    // On the cycle where f2 consumes a straddle remainder (start_offset=0,
    // remainder_valid_r=1 and one or more instructions were emitted), the
    // usual f1->f2 pipeline would leave f2_pc_r at the same cache-line base
    // next cycle (because f1_pc lagged behind by one cycle across the
    // straddle). Detect the consume event combinationally and advance
    // f2_pc_r directly to f2_seq_next_pc so the following cycle processes
    // the next real instruction stream.
    assign consume_remainder_c = remainder_valid_r && f2_valid_r &&
                                 f2_data_valid && (start_offset == 6'd0) &&
                                 (extract_count > 3'd0);
    // Track the most recent F2 PC emitted to decode. The current f1->f2
    // pipeline can hold f2_pc_r on the same fetch group for back-to-back
    // cycles while the frontend catches up; without a duplicate filter,
    // decode/rename can consume the same group twice.
    logic        f2_last_emit_valid_r;
    logic [63:0] f2_last_emit_pc_r;
    assign f2_will_emit_c = f2_valid_r && f2_data_valid &&
                             (extract_count > 3'd0) &&
                             !(f2_last_emit_valid_r &&
                               (f2_last_emit_pc_r == f2_pc_r));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end else if (redirect_valid) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end else if (ftq_enq_valid) begin
            ftq_last_alloc_valid_r    <= 1'b1;
            ftq_last_alloc_req_pc_r   <= req_pc_c;
        end else if (ftq_pop_valid &&
                     (ftq_count == {{FTQ_IDX_BITS{1'b0}}, 1'b1})) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_valid_r          <= 1'b0;
            f2_pc_r             <= '0;
            f2_btb_hit_r        <= 1'b0;
            f2_btb_target_r     <= '0;
            f2_btb_type_r       <= '0;
            f2_btb_offset_r     <= '0;
            f2_btb_alt_hit_r    <= 1'b0;
            f2_btb_alt_target_r <= '0;
            f2_btb_alt_type_r   <= '0;
            f2_btb_alt_offset_r <= '0;
            f2_tage_taken_r     <= 1'b0;
            f2_tage_confident_r <= 1'b0;
            f2_ghr_snapshot_r   <= '0;
            f2_ftq_valid_r      <= 1'b0;
            f2_ftq_idx_r        <= '0;
            f2_ftq_epoch_r      <= '0;
            f2_ftq_alloc_tag_r  <= '0;
            f2_ftq_entry_r      <= '0;
            consumed_remainder_r <= 1'b0;
            post_remainder_pc_r  <= '0;
            f2_last_emit_valid_r <= 1'b0;
            f2_last_emit_pc_r    <= '0;
        end else if (redirect_valid) begin
            // Flush F2 on redirect and clear the duplicate-suppress flag
            f2_valid_r           <= 1'b0;
            consumed_remainder_r <= 1'b0;
            f2_ftq_valid_r       <= 1'b0;
            f2_ftq_alloc_tag_r   <= '0;
            f2_last_emit_valid_r <= 1'b0;
        end else if (f2_bpu_redirect && !fe_stall) begin
            // BPU redirect: set f2_pc to target so the icache bypass
            // response (arriving next cycle) matches the expected PC.
            f2_valid_r          <= 1'b1;
            f2_pc_r             <= f2_bpu_target;
            // Latch predictor metadata for the redirected-to fetch group.
            // BTB/TAGE lookup follows ic_req_addr, which already points at
            // f2_bpu_target in this cycle.
            f2_btb_hit_r        <= btb_hit;
            f2_btb_target_r     <= btb_target;
            f2_btb_type_r       <= btb_branch_type;
            f2_btb_offset_r     <= btb_branch_offset;
            f2_btb_alt_hit_r    <= btb_alt_hit;
            f2_btb_alt_target_r <= btb_alt_target;
            f2_btb_alt_type_r   <= btb_alt_branch_type;
            f2_btb_alt_offset_r <= btb_alt_branch_offset;
            f2_tage_taken_r     <= tage_pred_taken;
            f2_tage_confident_r <= tage_pred_confident;
            f2_ghr_snapshot_r   <= ghr_out;
            if (ftq_enq_valid) begin
                f2_ftq_valid_r  <= 1'b1;
                f2_ftq_idx_r    <= ftq_enq_idx;
                f2_ftq_epoch_r  <= ftq_enq_epoch;
                f2_ftq_alloc_tag_r <= ftq_enq_tag;
                f2_ftq_entry_r  <= req_ftq_entry_c;
            end
            consumed_remainder_r <= 1'b0;
            f2_last_emit_valid_r <= 1'b0;
        end else begin
            // Duplicate suppression must track any packet that was actually
            // emitted, even if F1/F2 state is frozen by fe_stall. Otherwise a
            // held F2 group can be enqueued multiple times with identical PC
            // and stale ownership metadata, which is exactly the bad
            // Dhrystone tail-pair signature seen at 0x80002178/0x8000217a.
            if (f2_will_emit_c) begin
                f2_last_emit_valid_r <= 1'b1;
                f2_last_emit_pc_r    <= f2_pc_r;
            end

            if (!fe_stall) begin
            f2_valid_r          <= f1_valid;
            if (consume_remainder_c)
                f2_pc_r         <= f2_seq_next_pc;
            else if (consumed_remainder_r)
                f2_pc_r         <= post_remainder_pc_r;
            else
                f2_pc_r         <= f1_pc;
            f2_btb_hit_r        <= btb_hit;
            f2_btb_target_r     <= btb_target;
            f2_btb_type_r       <= btb_branch_type;
            f2_btb_offset_r     <= btb_branch_offset;
            f2_btb_alt_hit_r    <= btb_alt_hit;
            f2_btb_alt_target_r <= btb_alt_target;
            f2_btb_alt_type_r   <= btb_alt_branch_type;
            f2_btb_alt_offset_r <= btb_alt_branch_offset;
            f2_tage_taken_r     <= tage_pred_taken;
            f2_tage_confident_r <= tage_pred_confident;
            if (consume_remainder_c || consumed_remainder_r)
                f2_ghr_snapshot_r <= f2_ghr_snapshot_r;
            else
                f2_ghr_snapshot_r <= ghr_out;

            if (consume_remainder_c || consumed_remainder_r) begin
                if (consumed_remainder_r && ftq_enq_valid) begin
                    f2_ftq_valid_r <= 1'b1;
                    f2_ftq_idx_r   <= ftq_enq_idx;
                    f2_ftq_epoch_r <= ftq_enq_epoch;
                    f2_ftq_alloc_tag_r <= ftq_enq_tag;
                    f2_ftq_entry_r <= req_ftq_entry_c;
                end else begin
                    f2_ftq_valid_r <= f2_ftq_valid_r;
                    f2_ftq_idx_r   <= f2_ftq_idx_r;
                    f2_ftq_epoch_r <= f2_ftq_epoch_r;
                    f2_ftq_alloc_tag_r <= f2_ftq_alloc_tag_r;
                    f2_ftq_entry_r <= f2_ftq_entry_r;
                end
            end else if (ftq_enq_valid) begin
                f2_ftq_valid_r <= 1'b1;
                f2_ftq_idx_r   <= ftq_enq_idx;
                f2_ftq_epoch_r <= ftq_enq_epoch;
                f2_ftq_alloc_tag_r <= ftq_enq_tag;
                f2_ftq_entry_r <= req_ftq_entry_c;
            end else if (!f1_valid) begin
                f2_ftq_valid_r <= 1'b0;
                f2_ftq_idx_r   <= '0;
                f2_ftq_epoch_r <= '0;
                f2_ftq_alloc_tag_r <= '0;
                f2_ftq_entry_r <= '0;
            end

            // Latch the consume event and the post-remainder PC so the
            // next cycle can also advance f1_pc in lock-step.
            if (consume_remainder_c) begin
                consumed_remainder_r <= 1'b1;
                post_remainder_pc_r  <= f2_seq_next_pc;
            end else begin
                consumed_remainder_r <= 1'b0;
            end

            end
        end
    end

    // =========================================================================
    // F2: Instruction extraction from cache line
    //
    // The I-cache returns a full 512-bit (64-byte) line. We extract up to
    // PIPE_WIDTH=6 instructions starting at the byte offset indicated by
    // f2_pc_r[5:0]. Each instruction is either 16-bit compressed (bits[1:0]
    // != 2'b11) or 32-bit.
    // =========================================================================
    localparam int MAX_EXTRACT_BYTES = 62; // max bytes we can look at

    // Raw extracted halfwords and full instruction words before decompression
    logic [15:0] raw_hw [0:PIPE_WIDTH-1];        // raw 16-bit parcel
    logic [31:0] raw_insn [0:PIPE_WIDTH-1];      // 32-bit (either native or zero-extended)
    logic        slot_is_rvc [0:PIPE_WIDTH-1];
    logic        slot_valid [0:PIPE_WIDTH-1];
    logic [63:0] slot_pc [0:PIPE_WIDTH-1];
    logic        predecode_ctl_found;
    logic [2:0]  predecode_ctl_slot;
    logic [2:0]  predecode_ctl_type;
    logic [63:0] predecode_ctl_target;
    logic        ftq_pred_ctl_valid;
    logic        ftq_pred_ctl_slot_match;
    logic        ftq_pred_ctl_taken;
    logic [2:0]  ftq_pred_ctl_slot;
    logic [2:0]  ftq_pred_ctl_type;
    logic [63:0] ftq_pred_ctl_target;
    logic        pd_pred_mismatch;
    logic        owner_cond_pred_found;
    logic [2:0]  owner_cond_pred_slot;
    logic [63:0] owner_cond_pred_target;
    logic        subgroup_split_before_ctl_c;
    // extract_count, start_offset, remainder_valid_r declared earlier

    assign start_offset = f2_pc_r[5:0];

    // ---- Cross-line remainder buffer ----
    logic [15:0] remainder_hw_r;       // first 2 bytes (lower half)
    logic [63:0] remainder_pc_r;       // PC of the straddling instruction

    // Combinational: detect straddling 32-bit instruction at line end
    logic        straddle_detected;
    logic [15:0] straddle_hw;
    logic [63:0] straddle_pc;

    // Extract instructions from the cache line combinationally
    always_comb begin
        // Default all slots
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            raw_hw[i]      = 16'h0;
            raw_insn[i]    = 32'h0000_0013; // NOP
            slot_is_rvc[i] = 1'b0;
            slot_valid[i]  = 1'b0;
            slot_pc[i]     = '0;
        end
        extract_count      = 3'd0;
        straddle_detected  = 1'b0;
        straddle_hw        = 16'h0;
        straddle_pc        = '0;

        if (f2_valid_r && f2_data_valid) begin
            automatic logic [6:0] byte_pos;
            automatic int slot_idx;
            byte_pos = {1'b0, start_offset};
            slot_idx = 0;

            // If the remainder buffer holds the first half of a straddling
            // instruction, combine it with the start of this cache line.
            if (remainder_valid_r && byte_pos == 7'd0) begin
                // The remainder holds the low 16 bits; read bytes 0-1 of
                // this line for the high 16 bits.
                automatic logic [31:0] word32;
                word32[15:0]  = remainder_hw_r;
                word32[23:16] = f2_data_line[0 +: 8];
                word32[31:24] = f2_data_line[8 +: 8];

                slot_is_rvc[0] = 1'b0;
                raw_insn[0]    = word32;
                slot_valid[0]  = 1'b1;
                slot_pc[0]     = remainder_pc_r;
                extract_count  = 3'd1;
                byte_pos       = 7'd2;   // consumed 2 bytes from this line
                slot_idx       = 1;
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (i >= slot_idx) begin
                // Check if we have at least 2 bytes remaining in the line
                if (byte_pos <= 7'd62) begin
                    // Read 16-bit parcel at current position
                    // Each byte is at bit position byte_pos*8
                    automatic logic [15:0] hw;
                    automatic logic [6:0]  bp;
                    bp = byte_pos;
                    hw = {f2_data_line[bp*8 +: 8], f2_data_line[bp*8 +: 8]};
                    // Correct: read two bytes in little-endian order
                    hw[7:0]  = f2_data_line[bp*8 +: 8];
                    hw[15:8] = f2_data_line[(bp+7'd1)*8 +: 8];

                    raw_hw[i]  = hw;
                    slot_pc[i] = {f2_pc_r[63:6], bp[5:0]};

                    if (hw[1:0] != 2'b11) begin
                        // 16-bit compressed instruction
                        slot_is_rvc[i] = 1'b1;
                        raw_insn[i]    = {16'h0, hw};
                        slot_valid[i]  = 1'b1;
                        extract_count  = 3'(i + 1);
                        byte_pos       = byte_pos + 7'd2;
                    end else if (byte_pos <= 7'd60) begin
                        // 32-bit instruction: need 4 bytes
                        automatic logic [31:0] word32;
                        automatic logic [6:0]  bp2;
                        bp2 = byte_pos;
                        word32[7:0]   = f2_data_line[bp2*8 +: 8];
                        word32[15:8]  = f2_data_line[(bp2+7'd1)*8 +: 8];
                        word32[23:16] = f2_data_line[(bp2+7'd2)*8 +: 8];
                        word32[31:24] = f2_data_line[(bp2+7'd3)*8 +: 8];

                        slot_is_rvc[i] = 1'b0;
                        raw_insn[i]    = word32;
                        slot_valid[i]  = 1'b1;
                        extract_count  = 3'(i + 1);
                        byte_pos       = byte_pos + 7'd4;
                    end else begin
                        // 32-bit instruction crosses line boundary.
                        // Save the first 2 bytes for the next cache line.
                        straddle_detected = 1'b1;
                        straddle_hw       = hw;
                        straddle_pc       = {f2_pc_r[63:6], bp[5:0]};
                    end
                end
                // else: past end of line, stop
                end
            end
        end
    end

    // =========================================================================
    // RVC decompression: 6 instances (one per slot)
    // =========================================================================
    logic [15:0] decomp_in  [0:PIPE_WIDTH-1];
    logic [31:0] decomp_out [0:PIPE_WIDTH-1];
    logic        decomp_is_rvc [0:PIPE_WIDTH-1];
    logic        decomp_illegal [0:PIPE_WIDTH-1];

    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_rvc_decomp
            rvc_decompress u_rvc_decomp (
                .insn_in (raw_hw[gi]),
                .insn_out(decomp_out[gi]),
                .is_rvc  (decomp_is_rvc[gi]),
                .illegal (decomp_illegal[gi])
            );
        end
    endgenerate

    // =========================================================================
    // IFU predecode: derive the earliest control-flow instruction from the
    // extracted packet, compare it against the FTQ's predicted earliest CFI,
    // and compute an auxiliary branch-PC direction hint for owner conditionals.
    // The hint may be used to split the packet before the control so the next
    // request starts at the branch PC, but it must not create a live redirect
    // unless the full owner-redirect path is explicitly enabled.
    // =========================================================================
    always_comb begin
        predecode_ctl_found  = 1'b0;
        predecode_ctl_slot   = 3'd0;
        predecode_ctl_type   = BT_COND;
        predecode_ctl_pc     = '0;
        predecode_ctl_target = '0;

        if (f2_valid_r && f2_data_valid) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (!predecode_ctl_found &&
                    slot_valid[i] &&
                    (3'(i) < extract_count)) begin
                    automatic logic [31:0] insn32;
                    automatic logic [6:0]  opcode;
                    automatic logic [2:0]  funct3;
                    automatic logic [4:0]  rd;
                    automatic logic [4:0]  rs1;
                    automatic logic [11:0] imm12;

                    insn32 = slot_is_rvc[i] ? decomp_out[i] : raw_insn[i];
                    opcode = insn32[6:0];
                    funct3 = insn32[14:12];
                    rd     = insn32[11:7];
                    rs1    = insn32[19:15];
                    imm12  = insn32[31:20];

                    case (opcode)
                        7'b1100011: begin
                            predecode_ctl_found  = 1'b1;
                            predecode_ctl_slot   = 3'(i);
                            predecode_ctl_type   = BT_COND;
                            predecode_ctl_pc     = slot_pc[i];
                            predecode_ctl_target = slot_pc[i] + imm_b64(insn32);
                        end
                        7'b1101111: begin
                            predecode_ctl_found  = 1'b1;
                            predecode_ctl_slot   = 3'(i);
                            predecode_ctl_type   = is_link_reg(rd) ? BT_CALL : BT_JAL;
                            predecode_ctl_pc     = slot_pc[i];
                            predecode_ctl_target = slot_pc[i] + imm_j64(insn32);
                        end
                        7'b1100111: begin
                            if (funct3 == 3'b000) begin
                                predecode_ctl_found = 1'b1;
                                predecode_ctl_slot  = 3'(i);
                                predecode_ctl_pc    = slot_pc[i];
                                if ((rd == 5'd0) && is_link_reg(rs1) &&
                                    (imm12 == 12'd0)) begin
                                    predecode_ctl_type = BT_RET;
                                    predecode_ctl_target =
                                        ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0))
                                            ? ras_pop_addr
                                            : 64'd0;
                                end else if (is_link_reg(rd)) begin
                                    predecode_ctl_type   = BT_CALL;
                                    predecode_ctl_target = 64'd0;
                                end else begin
                                    predecode_ctl_type   = BT_JALR;
                                    predecode_ctl_target = 64'd0;
                                end
                            end
                        end
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    always_comb begin
        owner_cond_pred_found  = 1'b0;
        owner_cond_pred_slot   = predecode_ctl_slot;
        owner_cond_pred_target = predecode_ctl_target;

        if (f2_valid_r &&
            f2_data_valid &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND)) begin
            if (owner_tage_pred_taken ||
                (!owner_tage_pred_confident &&
                 (predecode_ctl_target < predecode_ctl_pc))) begin
                owner_cond_pred_found = 1'b1;
            end
        end
    end

    always_comb begin
        ftq_pred_ctl_valid      = 1'b0;
        ftq_pred_ctl_slot_match = 1'b0;
        ftq_pred_ctl_taken      = 1'b0;
        ftq_pred_ctl_slot       = 3'd0;
        ftq_pred_ctl_type       = BT_COND;
        ftq_pred_ctl_target     = '0;

        if (f2_ftq_valid_r && f2_ftq_entry_r.pred_ctl_valid) begin
            ftq_pred_ctl_valid  = 1'b1;
            ftq_pred_ctl_taken  = f2_ftq_entry_r.pred_ctl_taken;
            ftq_pred_ctl_type   = f2_ftq_entry_r.pred_ctl_type;
            ftq_pred_ctl_target = f2_ftq_entry_r.pred_ctl_target;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_valid[i] &&
                    (slot_pc[i][5:0] == f2_ftq_entry_r.pred_ctl_offset)) begin
                    ftq_pred_ctl_slot_match = 1'b1;
                    ftq_pred_ctl_slot       = 3'(i);
                end
            end

            if (!ftq_pred_ctl_slot_match) begin
                ftq_pred_ctl_valid  = 1'b0;
                ftq_pred_ctl_taken  = 1'b0;
                ftq_pred_ctl_target = '0;
            end
        end
    end

    assign subgroup_seed_hit_c =
        subgroup_seed_valid_r && (req_pc_c == subgroup_seed_pc_r);
    assign subgroup_seed_load_c =
        f2_valid_r &&
        f2_data_valid &&
        !redirect_valid &&
        subgroup_split_before_ctl_c &&
        predecode_ctl_found &&
        (predecode_ctl_type == BT_COND) &&
        f2_seq_valid;
    assign subgroup_seed_pred_taken_c =
        (ftq_pred_ctl_valid &&
         (ftq_pred_ctl_slot == predecode_ctl_slot) &&
         (ftq_pred_ctl_type == predecode_ctl_type))
            ? ftq_pred_ctl_taken
            : owner_cond_pred_found;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            subgroup_seed_valid_r       <= 1'b0;
            subgroup_seed_pc_r          <= '0;
            subgroup_seed_parent_pc_r   <= '0;
            subgroup_seed_owner_pc_r    <= '0;
            subgroup_seed_pred_valid_r  <= 1'b0;
            subgroup_seed_pred_taken_r  <= 1'b0;
            subgroup_seed_pred_offset_r <= '0;
            subgroup_seed_pred_type_r   <= '0;
            subgroup_seed_pred_target_r <= '0;
        end else if (redirect_valid) begin
            subgroup_seed_valid_r       <= 1'b0;
            subgroup_seed_pc_r          <= '0;
            subgroup_seed_parent_pc_r   <= '0;
            subgroup_seed_owner_pc_r    <= '0;
            subgroup_seed_pred_valid_r  <= 1'b0;
            subgroup_seed_pred_taken_r  <= 1'b0;
            subgroup_seed_pred_offset_r <= '0;
            subgroup_seed_pred_type_r   <= '0;
            subgroup_seed_pred_target_r <= '0;
        end else if (subgroup_seed_load_c) begin
            subgroup_seed_valid_r       <= 1'b1;
            subgroup_seed_pc_r          <= f2_seq_next_pc;
            subgroup_seed_parent_pc_r   <= f2_pc_r;
            subgroup_seed_owner_pc_r    <= predecode_ctl_pc;
            subgroup_seed_pred_valid_r  <= predecode_ctl_found;
            subgroup_seed_pred_taken_r  <= subgroup_seed_pred_taken_c;
            subgroup_seed_pred_offset_r <= predecode_ctl_pc[5:0];
            subgroup_seed_pred_type_r   <= predecode_ctl_type;
            subgroup_seed_pred_target_r <= predecode_ctl_target;
        end else if (!fe_stall && ic_req_valid && subgroup_seed_hit_c) begin
            subgroup_seed_valid_r       <= 1'b0;
            subgroup_seed_parent_pc_r   <= '0;
            subgroup_seed_owner_pc_r    <= '0;
        end
    end

    always_comb begin
        pd_pred_mismatch = 1'b0;

        if (predecode_ctl_found != ftq_pred_ctl_valid) begin
            pd_pred_mismatch = 1'b1;
        end else if (predecode_ctl_found && ftq_pred_ctl_valid) begin
            if ((predecode_ctl_slot != ftq_pred_ctl_slot) ||
                (predecode_ctl_type != ftq_pred_ctl_type)) begin
                pd_pred_mismatch = 1'b1;
            end else begin
                case (predecode_ctl_type)
                    BT_COND,
                    BT_JAL,
                    BT_RET: begin
                        if (predecode_ctl_target != ftq_pred_ctl_target)
                            pd_pred_mismatch = 1'b1;
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // F2: Branch prediction resolution
    //
    // Scan extracted instructions for the branch predicted by BTB. If BTB hit
    // in F1 and TAGE predicts taken, truncate fetch at the branch and redirect
    // to the predicted target. For RET, use RAS pop address as target.
    // For CALL, push return address onto RAS.
    // =========================================================================
    logic        btb_pred_found;
    logic        btb_slot_matched;
    logic [2:0]  btb_branch_slot;
    logic [63:0] f2_btb_branch_pc;
    logic [63:0] btb_target_addr;
    logic        btb_taken;
    logic [2:0]  btb_truncated_count;
    logic [2:0]  btb_pred_type;
    logic        btb_alt_pred_found;
    logic        btb_alt_slot_matched;
    logic [2:0]  btb_alt_branch_slot;
    logic [63:0] btb_alt_target_addr;
    logic [2:0]  btb_alt_truncated_count;
    logic        static_jal_found;
    logic [2:0]  static_jal_slot;
    logic [63:0] static_jal_target;
    logic [2:0]  static_jal_type;
    logic        static_ret_found;
    logic [2:0]  static_ret_slot;
    logic [63:0] static_ret_target;
    logic        static_ctl_found;
    logic [2:0]  static_ctl_slot;
    logic [63:0] static_ctl_target;
    logic [2:0]  static_ctl_type;
    logic        bp_branch_found;
    logic [2:0]  bp_branch_slot;
    logic [63:0] bp_target_addr;
    logic        bp_taken;
    logic [2:0]  bp_truncated_count;
    logic [2:0]  bp_type;

    always_comb begin
        btb_pred_found     = 1'b0;
        btb_slot_matched   = 1'b0;
        btb_branch_slot    = 3'd0;
        f2_btb_branch_pc   = {f2_pc_r[63:6], f2_btb_offset_r};
        btb_target_addr    = '0;
        btb_taken          = 1'b0;
        btb_truncated_count = extract_count;
        btb_pred_type      = BT_COND;
        btb_alt_pred_found   = 1'b0;
        btb_alt_slot_matched = 1'b0;
        btb_alt_branch_slot  = 3'd0;
        btb_alt_target_addr  = '0;
        btb_alt_truncated_count = extract_count;

        if (f2_valid_r && f2_data_valid && f2_btb_hit_r) begin
            case (f2_btb_type_r)
                BT_COND: begin
                    if (f2_tage_taken_r ||
                        (!f2_tage_confident_r &&
                         (f2_btb_target_r < f2_btb_branch_pc))) begin
                        btb_pred_found  = 1'b1;
                        btb_taken       = 1'b1;
                        btb_target_addr = f2_btb_target_r;
                        btb_pred_type   = BT_COND;
                    end
                end
                BT_JAL: begin
                    btb_pred_found  = 1'b1;
                    btb_taken       = 1'b1;
                    btb_target_addr = f2_btb_target_r;
                    btb_pred_type   = BT_JAL;
                end
                BT_JALR: begin
                    btb_pred_found  = 1'b1;
                    btb_taken       = 1'b1;
                    btb_target_addr = f2_btb_target_r;
                    btb_pred_type   = BT_JALR;
                end
                BT_CALL: begin
                    btb_pred_found  = 1'b1;
                    btb_taken       = 1'b1;
                    btb_target_addr = f2_btb_target_r;
                    btb_pred_type   = BT_CALL;
                end
                BT_RET: begin
                    if ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0)) begin
                        btb_pred_found  = 1'b1;
                        btb_taken       = 1'b1;
                        btb_target_addr = ras_pop_addr;
                        btb_pred_type   = BT_RET;
                    end
                end
                default: begin
                    btb_pred_found = 1'b0;
                end
            endcase

            if (btb_pred_found && btb_taken) begin
                btb_truncated_count = extract_count;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (slot_valid[i] &&
                        (slot_pc[i][5:0] == f2_btb_offset_r)) begin
                        btb_branch_slot     = 3'(i);
                        btb_truncated_count = 3'(i + 1);
                        btb_slot_matched    = 1'b1;
                    end
                end

                if (!btb_slot_matched) begin
                    btb_pred_found = 1'b0;
                    btb_taken      = 1'b0;
                end
            end
        end

        if (f2_valid_r && f2_data_valid && f2_btb_alt_hit_r) begin
            case (f2_btb_alt_type_r)
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    btb_alt_pred_found = 1'b1;
                    btb_alt_target_addr = f2_btb_alt_target_r;
                end
                BT_RET: begin
                    if ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0)) begin
                        btb_alt_pred_found = 1'b1;
                        btb_alt_target_addr = ras_pop_addr;
                    end
                end
                default: begin
                    btb_alt_pred_found = 1'b0;
                end
            endcase

            if (btb_alt_pred_found) begin
                btb_alt_truncated_count = extract_count;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (slot_valid[i] &&
                        (slot_pc[i][5:0] == f2_btb_alt_offset_r)) begin
                        btb_alt_branch_slot     = 3'(i);
                        btb_alt_truncated_count = 3'(i + 1);
                        btb_alt_slot_matched    = 1'b1;
                    end
                end

                if (!btb_alt_slot_matched) begin
                    btb_alt_pred_found = 1'b0;
                end
            end
        end

        if ((!btb_pred_found || !btb_taken) && btb_alt_pred_found) begin
            btb_pred_found      = 1'b1;
            btb_taken           = 1'b1;
            btb_branch_slot     = btb_alt_branch_slot;
            btb_target_addr     = btb_alt_target_addr;
            btb_truncated_count = btb_alt_truncated_count;
            btb_pred_type       = f2_btb_alt_type_r;
        end
    end

    always_comb begin
        static_jal_found  = 1'b0;
        static_jal_slot   = 3'd0;
        static_jal_target = '0;
        static_jal_type   = BT_JAL;

        if (f2_valid_r &&
            f2_data_valid &&
            predecode_ctl_found &&
            ((predecode_ctl_type == BT_JAL) ||
             (predecode_ctl_type == BT_CALL)) &&
            (predecode_ctl_target != 64'd0)) begin
            static_jal_found  = 1'b1;
            static_jal_slot   = predecode_ctl_slot;
            static_jal_target = predecode_ctl_target;
            static_jal_type   = predecode_ctl_type;
        end
    end

    always_comb begin
        static_ret_found  = 1'b0;
        static_ret_slot   = 3'd0;
        static_ret_target = '0;

        if (f2_valid_r &&
            f2_data_valid &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_RET) &&
            (predecode_ctl_target != 64'd0)) begin
            static_ret_found  = 1'b1;
            static_ret_slot   = predecode_ctl_slot;
            static_ret_target = predecode_ctl_target;
        end
    end

    always_comb begin
        static_ctl_found  = 1'b0;
        static_ctl_slot   = 3'd0;
        static_ctl_target = '0;
        static_ctl_type   = BT_JAL;
 
        if (static_jal_found) begin
            static_ctl_found  = 1'b1;
            static_ctl_slot   = static_jal_slot;
            static_ctl_target = static_jal_target;
            static_ctl_type   = static_jal_type;
        end

        if (static_ret_found &&
            (!static_ctl_found || (static_ret_slot < static_ctl_slot))) begin
            static_ctl_found  = 1'b1;
            static_ctl_slot   = static_ret_slot;
            static_ctl_target = static_ret_target;
            static_ctl_type   = BT_RET;
        end
    end

    always_comb begin
        bp_branch_found    = 1'b0;
        bp_branch_slot     = 3'd0;
        bp_target_addr     = '0;
        bp_taken           = 1'b0;
        bp_truncated_count = extract_count;
        bp_type            = BT_COND;

        if (btb_pred_found && btb_taken) begin
            bp_branch_found    = 1'b1;
            bp_branch_slot     = btb_branch_slot;
            bp_target_addr     = btb_target_addr;
            bp_taken           = 1'b1;
            bp_truncated_count = btb_truncated_count;
            bp_type            = btb_pred_type;
        end

        if (static_ctl_found &&
            (!bp_branch_found || (static_ctl_slot < bp_branch_slot))) begin
            bp_branch_found    = 1'b1;
            bp_branch_slot     = static_ctl_slot;
            bp_target_addr     = static_ctl_target;
            bp_taken           = 1'b1;
            bp_truncated_count = 3'(static_ctl_slot + 1);
            bp_type            = static_ctl_type;
        end
    end

    always_comb begin
        subgroup_split_before_ctl_c = 1'b0;

        // Split before a later owner conditional so the next request can be
        // branch-owned. Slot-1 conditionals get the handoff unconditionally
        // unless the current request is already predicting that exact branch as
        // taken in place. Later conditionals still require the auxiliary
        // branch-PC taken hint to avoid over-fragmenting Dhrystone.
        if (f2_valid_r &&
            f2_data_valid &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND) &&
            (predecode_ctl_slot != 3'd0)) begin
            if (predecode_ctl_slot == 3'd1) begin
                if (!(bp_branch_found &&
                      bp_taken &&
                      (bp_type == BT_COND) &&
                      (bp_branch_slot == predecode_ctl_slot))) begin
                    subgroup_split_before_ctl_c = 1'b1;
                end
            end else if ((predecode_ctl_slot == 3'd3) &&
                         ftq_pred_ctl_valid &&
                         (ftq_pred_ctl_type == BT_COND) &&
                         (ftq_pred_ctl_slot == predecode_ctl_slot)) begin
                if (!(bp_branch_found &&
                      bp_taken &&
                      (bp_type == BT_COND) &&
                      (bp_branch_slot == predecode_ctl_slot))) begin
                    subgroup_split_before_ctl_c = 1'b1;
                end
            end else if (owner_cond_pred_found) begin
                if (!ftq_pred_ctl_valid ||
                    (predecode_ctl_slot < ftq_pred_ctl_slot) ||
                    pd_pred_mismatch) begin
                    subgroup_split_before_ctl_c = 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Compute sequential next PC from bytes consumed
    // =========================================================================
    logic [63:0] last_slot_pc;
    logic        last_slot_rvc;
    logic [2:0]  final_count;

    always_comb begin
        // Use branch-truncated count if a taken branch was found
        if (subgroup_split_before_ctl_c) begin
            final_count = predecode_ctl_slot;
        end else if (bp_branch_found && bp_taken) begin
            final_count = bp_truncated_count;
        end else begin
            final_count = extract_count;
        end

        // Compute sequential next PC based on the last instruction delivered
        if (final_count > 3'd0) begin
            automatic int last_idx;
            last_idx = int'(final_count) - 1;
            last_slot_pc  = slot_pc[last_idx];
            last_slot_rvc = slot_is_rvc[last_idx];
            f2_seq_next_pc = last_slot_pc + (last_slot_rvc ? 64'd2 : 64'd4);
            f2_seq_valid   = 1'b1;
        end else if (straddle_detected) begin
            // No complete instructions extracted, but a straddling 32-bit
            // instruction was found. Advance to the next cache line so
            // the remainder buffer can be combined with the new data.
            last_slot_pc   = straddle_pc;
            last_slot_rvc  = 1'b0;
            f2_seq_next_pc = {f2_pc_r[63:6] + 58'd1, 6'd0};  // next line
            f2_seq_valid   = 1'b1;
        end else begin
            last_slot_pc   = f2_pc_r;
            last_slot_rvc  = 1'b0;
            f2_seq_next_pc = f2_pc_r;
            f2_seq_valid   = 1'b0;
        end
    end

    // Phase-6 cleanup: the same-line subgroup handoff path is retired.
    // Continued delivery now relies only on the FTQ-owned request contract and
    // the cross-line remainder path. Keep trace plumbing explicit at zero so
    // debug logs still show that the legacy path is inactive.
    assign same_line_next_has_ctl_c = 1'b0;
    assign same_line_handoff_c = 1'b0;

    assign ftq_pop_valid =
        packet_buf_deq &&
        packet_buf_owner_match_c &&
        packet_buf_head.ftq_owner_complete;

    // =========================================================================
    // BPU redirect to F1
    // =========================================================================
    assign req_redirect_c  = bp_branch_found && bp_taken &&
                             !subgroup_split_before_ctl_c &&
                             !redirect_valid;
    assign f2_bpu_redirect = req_redirect_c && !fe_stall;
    assign f2_bpu_target   = bp_target_addr;

    // =========================================================================
    // RAS push/pop control
    //
    // Push on CALL (return address = branch PC + 4 or +2 for RVC).
    // Pop on RET.
    // Only active when F2 is delivering valid instructions and not stalled.
    // =========================================================================
    always_comb begin
        ras_push_valid = 1'b0;
        ras_push_addr  = '0;
        ras_pop_valid  = 1'b0;

        if (bp_branch_found && bp_taken &&
            !subgroup_split_before_ctl_c &&
            !fe_stall && !redirect_valid) begin
            if (bp_type == BT_CALL) begin
                ras_push_valid = 1'b1;
                // Push return address: PC of the call + instruction size
                ras_push_addr  = slot_pc[bp_branch_slot]
                                 + (slot_is_rvc[bp_branch_slot] ? 64'd2 : 64'd4);
            end else if (bp_type == BT_RET) begin
                ras_pop_valid = 1'b1;
            end
        end
    end

    // =========================================================================
    // Speculative GHR update
    //
    // When a conditional branch is predicted, speculatively shift the GHR.
    // =========================================================================
    always_comb begin
        tage_spec_update_valid = 1'b0;
        tage_spec_taken        = 1'b0;

        if (bp_branch_found &&
            !subgroup_split_before_ctl_c &&
            !fe_stall && !redirect_valid) begin
            if (bp_type == BT_COND) begin
                tage_spec_update_valid = 1'b1;
                tage_spec_taken        = bp_taken;
            end
        end
    end

    // =========================================================================
    // Remainder buffer: save the first 2 bytes of a straddling instruction
    //
    // The remainder must persist until the next cache line is actually
    // available and the extraction logic consumes it (consume_remainder_c).
    // If the next line misses in the I-cache, we may idle for several
    // cycles with a valid remainder waiting for data.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            remainder_valid_r <= 1'b0;
            remainder_hw_r    <= 16'h0;
            remainder_pc_r    <= '0;
        end else if (redirect_valid || (f2_bpu_redirect && !fe_stall)) begin
            remainder_valid_r <= 1'b0;
            remainder_hw_r    <= 16'h0;
            remainder_pc_r    <= '0;
        end else if (!fe_stall) begin
            if (straddle_detected && f2_valid_r && f2_data_valid) begin
                // New straddle detected on the current cache line: latch the
                // first 2 bytes so the next cache line can complete it.
                remainder_valid_r <= 1'b1;
                remainder_hw_r    <= straddle_hw;
                remainder_pc_r    <= straddle_pc;
            end else if (consume_remainder_c) begin
                // Successfully combined remainder with the new cache line;
                // clear the buffer.
                remainder_valid_r <= 1'b0;
            end
            // Otherwise: hold the remainder while we wait for the next
            // cache line to arrive (I-cache miss, backend stall, etc.).
        end
    end

    // =========================================================================
    // Fetch packet construction and fetch-buffered output to decode
    // =========================================================================
    logic        packet_owner_from_subgroup_c;

    always_comb begin
        packet_owner_from_subgroup_c = f2_ftq_entry_r.pred_from_subgroup;

        // The subgroup seed is cleared as soon as the split request issues, so
        // the eventual packet can no longer rely on the FTQ bit alone. Recover
        // subgroup ownership from the live seed relation at packet build time.
        if (subgroup_seed_valid_r &&
            (f2_pc_r == subgroup_seed_parent_pc_r) &&
            predecode_ctl_found &&
            (predecode_ctl_pc == subgroup_seed_owner_pc_r)) begin
            packet_owner_from_subgroup_c = 1'b1;
        end
    end

    always_comb begin
        packet_buf_enq = f2_will_emit_c && !redirect_valid && !frontend_hold;
        packet_buf_in  = '0;

        if (f2_will_emit_c) begin
            packet_buf_in.valid            = 1'b1;
            packet_buf_in.ftq_idx          = f2_ftq_idx_r;
            packet_buf_in.ftq_epoch        = f2_ftq_epoch_r;
            packet_buf_in.ftq_alloc_tag    = f2_ftq_alloc_tag_r;
            // A line-end straddle only keeps FTQ ownership open when the
            // frontend still needs the sequential continuation. If this packet
            // already ends in a taken redirect, the post-branch straddling
            // bytes are dead path and must not block FTQ pop. The Dhrystone
            // livelock at tag 387 was exactly this case: CALL at 0x8000213a
            // redirected to 0x8000239c, but the trailing dead-path straddle
            // left ftq_owner_complete low forever.
            packet_buf_in.ftq_owner_complete =
                !straddle_detected ||
                (bp_branch_found && bp_taken && !subgroup_split_before_ctl_c);
            packet_buf_in.ftq_block_pc     = f2_ftq_entry_r.block_pc;
            packet_buf_in.ftq_start_offset = f2_ftq_entry_r.start_offset;
            packet_buf_in.ftq_bp_lookup_pc =
                f2_ftq_entry_r.block_pc + 64'(f2_ftq_entry_r.start_offset);
            packet_buf_in.ftq_pred_valid   = f2_ftq_entry_r.pred_ctl_valid;
            packet_buf_in.ftq_pred_taken   = f2_ftq_entry_r.pred_ctl_taken;
            packet_buf_in.ftq_pred_offset  = f2_ftq_entry_r.pred_ctl_offset;
            packet_buf_in.ftq_pred_type    = f2_ftq_entry_r.pred_ctl_type;
            packet_buf_in.ftq_pred_target  = f2_ftq_entry_r.pred_ctl_target;
            packet_buf_in.ftq_pred_from_subgroup =
                packet_owner_from_subgroup_c;
            packet_buf_in.pd_ctl_valid     =
                predecode_ctl_found && !subgroup_split_before_ctl_c;
            packet_buf_in.pd_ctl_slot      = predecode_ctl_slot;
            packet_buf_in.pd_ctl_type      = predecode_ctl_type;
            packet_buf_in.pd_ctl_target    = predecode_ctl_target;
            packet_buf_in.fetch_count      = final_count;
            // The fetch packet now carries the request-time repair snapshot
            // owned by its FTQ entry instead of the live frontend state.
            if (f2_ftq_valid_r) begin
                packet_buf_in.fetch_bp_ras_tos =
                    f2_ftq_entry_r.ras_tos_snapshot;
                packet_buf_in.fetch_bp_ras_top =
                    f2_ftq_entry_r.ras_top_snapshot;
                packet_buf_in.fetch_bp_ghr =
                    f2_ftq_entry_r.ghr_snapshot;
            end else begin
                packet_buf_in.fetch_bp_ras_tos = ras_tos;
                packet_buf_in.fetch_bp_ras_top = ras_pop_addr;
                packet_buf_in.fetch_bp_ghr     = f2_ghr_snapshot_r;
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < final_count && slot_valid[i]) begin
                    packet_buf_in.fetch_insn[i] =
                        slot_is_rvc[i] ? decomp_out[i] : raw_insn[i];
                    packet_buf_in.fetch_pc[i]     = slot_pc[i];
                    packet_buf_in.fetch_is_rvc[i] = slot_is_rvc[i];

                    if (bp_branch_found && bp_taken &&
                        !subgroup_split_before_ctl_c &&
                        (3'(i) == bp_branch_slot)) begin
                        packet_buf_in.fetch_bp_taken[i]  = 1'b1;
                        packet_buf_in.fetch_bp_target[i] = bp_target_addr;
                    end else begin
                        packet_buf_in.fetch_bp_taken[i]  = 1'b0;
                        packet_buf_in.fetch_bp_target[i] = '0;
                    end
                end
            end
        end
    end

    always_comb begin
        fetch_count      = 3'd0;
        fetch_bp_owner_valid = 1'b0;
        fetch_bp_owner_slot  = 3'd0;
        fetch_bp_owner_from_subgroup = 1'b0;
        fetch_bp_lookup_pc   = 64'd0;
        fetch_bp_ras_tos = 5'd0;
        fetch_bp_ras_top = 64'd0;
        fetch_bp_ghr     = '0;
        fetch_is_rvc     = '0;
        fetch_bp_taken   = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            fetch_insn[i]      = 32'h0000_0013;
            fetch_pc[i]        = '0;
            fetch_bp_target[i] = '0;
        end

        if (packet_buf_valid) begin
            fetch_count      = packet_buf_head.fetch_count;
            fetch_bp_owner_valid = packet_buf_head.pd_ctl_valid;
            fetch_bp_owner_slot  = packet_buf_head.pd_ctl_slot;
            fetch_bp_owner_from_subgroup =
                packet_buf_head.pd_ctl_valid &&
                packet_buf_head.ftq_pred_from_subgroup;
            fetch_bp_lookup_pc   = packet_buf_head.ftq_bp_lookup_pc;
            fetch_bp_ras_tos = packet_buf_head.fetch_bp_ras_tos;
            fetch_bp_ras_top = packet_buf_head.fetch_bp_ras_top;
            fetch_bp_ghr     = packet_buf_head.fetch_bp_ghr;
            fetch_is_rvc     = packet_buf_head.fetch_is_rvc;
            fetch_bp_taken   = packet_buf_head.fetch_bp_taken;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                fetch_insn[i]      = packet_buf_head.fetch_insn[i];
                fetch_pc[i]        = packet_buf_head.fetch_pc[i];
                fetch_bp_target[i] = packet_buf_head.fetch_bp_target[i];
            end
        end
    end

    // =========================================================================
    // Optional fetch-path trace (debug only)
    // =========================================================================
    logic trace_fetch_en;
    integer trace_fetch_cycle;
    initial begin
        trace_fetch_en = 1'b0;
        if ($test$plusargs("TRACE_FETCH")) trace_fetch_en = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_fetch_cycle <= 0;
        end else begin
            trace_fetch_cycle <= trace_fetch_cycle + 1;
            if (trace_fetch_en &&
                ((trace_fetch_cycle < 600) ||
                 ((f1_pc >= 64'h0000_0000_8000_2000) &&
                  (f1_pc <  64'h0000_0000_8000_2440)) ||
                 ((f2_pc_r >= 64'h0000_0000_8000_2000) &&
                  (f2_pc_r <  64'h0000_0000_8000_2440)))) begin
                $display("[FETCH] cyc=%0d f1_pc=%016h ic_req_v=%b ic_req=%016h ic_resp_v=%b ic_hit=%b nlpb_hit=%b f2_v=%b f2_pc=%016h f2_hit=%b f2_type=%0d f2_off=%0d f2_alt_hit=%b f2_alt_type=%0d f2_alt_off=%0d ext=%0d final=%0d emit=%b dup=%b seq_v=%b seq_pc=%016h slh=%b sl_ctl=%b bp=%b bp_taken=%b bp_type=%0d bp_slot=%0d bp_tgt=%016h pd_v=%b pd_slot=%0d pd_type=%0d pd_tgt=%016h ftq_pred_v=%b ftq_pred_t=%b ftq_pred_slot=%0d ftq_pred_type=%0d ftq_sub=%b pd_mm=%b sg_v=%b sg_pc=%016h sg_t=%b sg_parent=%016h sg_owner=%016h ras_tos=%0d ras_push=%b ras_push_addr=%016h ras_pop=%b ras_pop_addr=%016h redir=%b redir_pc=%016h cmt_redir=%b cmt_pc=%016h rem_v=%b cons_rem=%b consd_rem=%b ftq_need=%b ftq_enq=%b ftq_enq_tag=%0d ftq_pop=%b ftq_cnt=%0d ftq_head_v=%b ftq_head=%0d ftq_head_tag=%0d f2_ftq_v=%b f2_ftq=%0d f2_ftq_tag=%0d f2_ftq_blk=%016h pkt_live=%b pkt_ftq_tag=%0d fe_hold=%b fe_stall=%b fetch_out=%0d",
                    trace_fetch_cycle,
                    f1_pc,
                    ic_req_valid,
                    ic_req_addr,
                    ic_resp_valid,
                    ic_resp_hit,
                    nlpb_hit_comb,
                    f2_valid_r,
                    f2_pc_r,
                    f2_btb_hit_r,
                    f2_btb_type_r,
                    f2_btb_offset_r,
                    f2_btb_alt_hit_r,
                    f2_btb_alt_type_r,
                    f2_btb_alt_offset_r,
                    extract_count,
                    final_count,
                    f2_will_emit_c,
                    (f2_last_emit_valid_r && (f2_last_emit_pc_r == f2_pc_r)),
                    f2_seq_valid,
                    f2_seq_next_pc,
                    same_line_handoff_c,
                    same_line_next_has_ctl_c,
                    bp_branch_found,
                    bp_taken,
                    bp_type,
                    bp_branch_slot,
                    bp_target_addr,
                    predecode_ctl_found,
                    predecode_ctl_slot,
                    predecode_ctl_type,
                    predecode_ctl_target,
                    ftq_pred_ctl_valid,
                    ftq_pred_ctl_taken,
                    ftq_pred_ctl_slot,
                    ftq_pred_ctl_type,
                    f2_ftq_entry_r.pred_from_subgroup,
                    pd_pred_mismatch,
                    subgroup_seed_valid_r,
                    subgroup_seed_pc_r,
                    subgroup_seed_pred_taken_r,
                    subgroup_seed_parent_pc_r,
                    subgroup_seed_owner_pc_r,
                    ras_tos,
                    ras_push_valid,
                    ras_push_addr,
                    ras_pop_valid,
                    ras_pop_addr,
                    f2_bpu_redirect,
                    f2_bpu_target,
                    redirect_valid,
                    redirect_pc,
                    remainder_valid_r,
                    consume_remainder_c,
                    consumed_remainder_r,
                    ftq_need_alloc_c,
                    ftq_enq_valid,
                    ftq_enq_tag,
                    ftq_pop_valid,
                    ftq_count,
                    ftq_head_valid,
                    ftq_head_idx,
                    ftq_head_tag,
                    f2_ftq_valid_r,
                    f2_ftq_idx_r,
                    f2_ftq_alloc_tag_r,
                    f2_ftq_entry_r.block_pc,
                    packet_buf_owner_match_c,
                    packet_buf_valid ? packet_buf_head.ftq_alloc_tag : '0,
                    frontend_hold,
                    fe_stall,
                    fetch_count);
            end
        end
    end

endmodule
