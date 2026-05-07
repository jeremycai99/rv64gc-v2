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
    // Frontend quiesce while decoded-op replay owns rename input.
    input  logic        frontend_hold,
    // Avoid packet fast-pathing while a replay structure is forming a
    // candidate, including the cycle that starts a replay window.
    input  logic        frontend_replay_blocking,
    input  logic        frontend_replay_start,

    // Redirect (from commit -- mispredict or exception)
    input  logic        redirect_valid,
    input  logic [63:0] redirect_pc,

    // BPU update (from commit -- actual branch outcome)
    input  logic        bpu_update_valid,
    input  logic [63:0] bpu_update_pc,
    input  logic        bpu_tage_update_valid,
    input  logic [63:0] bpu_tage_update_pc,
    input  logic        bpu_tage_update_taken,
    input  logic        bpu_tage_update_mispredict,
    input  logic [63:0] bpu_tage_update_target,
    input  logic [GHR_BITS-1:0] bpu_tage_update_ghr,
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
    localparam int ICQ_DEPTH = 4;
    localparam int ICQ_COUNT_BITS = $clog2(ICQ_DEPTH + 1);

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
    logic        line_straddle_advance_c;

    // Sequential next PC: computed from how many bytes F2 consumed
    logic [63:0] f2_seq_next_pc;
    logic        f2_seq_valid;
    logic        f2_will_emit_c;
    logic        f2_pc_consumed_c;
    logic        consume_remainder_c;
    logic        f2_duplicate_suppressed_c;
    logic [63:0] f2_duplicate_next_pc_c;
    logic        f2_ftq_owner_live_c;
    logic        f2_owner_completion_candidate_c;
    logic        f2_same_owner_continue_c;
    logic        bp_branch_found;
    logic        bp_taken;
    logic [63:0] bp_target_addr;
    logic        subgroup_split_before_ctl_c;

    // consumed_remainder_r: latched when the current cycle's extraction
    // consumed a straddle remainder AND emitted at least one instruction.
    // The following cycle must bypass the normal f1->f2 pipeline
    // (which otherwise leaves the IFU work cursor pointing at the
    // already-processed cache-line base) and instead advance it directly to the
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
        end else if (f2_duplicate_suppressed_c) begin
            next_pc    = f2_duplicate_next_pc_c;
            next_valid = 1'b1;
        end else if (f2_seq_valid && f2_pc_consumed_c) begin
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
            // post-remainder PC, keep f1_pc matching the work cursor so the pipeline
            // re-syncs (f1 should lead f2 again starting the cycle after).
            //
            // A same-cycle BPU redirect must still win over that resync.  A
            // CALL/JAL immediately after a consumed cross-line remainder can
            // redirect to its target while consumed_remainder_r is still set
            // from the prior cycle; letting the stale post-remainder PC win
            // replays the call packet and then emits its fall-through path.
            if (f2_bpu_redirect)
                f1_pc    <= f2_bpu_target;
            else if (consumed_remainder_r)
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
    logic [63:0]                          ic_req_addr_pipe_r;
    logic                                 ic_req_ftq_pipe_valid_r;
    logic [FTQ_IDX_BITS-1:0]              ic_req_ftq_pipe_idx_r;
    logic [FTQ_EPOCH_BITS-1:0]            ic_req_ftq_pipe_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0]        ic_req_ftq_pipe_alloc_tag_r;
    logic        icq_full;
    logic        icq_empty;
    logic [ICQ_COUNT_BITS-1:0] icq_count;
    logic        ic_invalidate_busy;
    logic        f2_data_valid;
    logic [511:0] f2_data_line;
    logic        packet_buf_enq;
    logic        packet_buf_enq_ready;
    logic        packet_buf_enq_fire;
    logic        packet_buf_deq;
    logic        packet_buf_deq_fire;
    logic        packet_buf_flowthrough_c;
    logic        packet_buf_valid;
    logic        packet_buf_full;
    logic        packet_buf_empty;
    logic [3:0]  packet_buf_count;
    logic        packet_buf_stale_owner_c;
    logic        packet_flowthrough_candidate;
    logic        packet_flowthrough_valid;
    logic        packet_flowthrough_owner_match_c;
    logic        fetch_packet_out_valid;
    fetch_packet_t fetch_packet_out;
    logic        ftq_need_alloc_c;
    logic        ftq_normal_enq_valid;
    logic        ftq_enq_valid;
    logic        ftq_enq_ready;
    logic        ifu_req_valid_c;
    logic        ifu_req_ready_c;
    logic        ifu_req_fire_c;
    logic        ftq_pop_valid;
    logic        ftq_ifu_req_pop_valid;
    logic        ftq_delivery_push_valid;
    logic        ftq_ifu_pop_valid;
    logic        ftq_commit_pop_valid;
    logic        ftq_head_valid;
    logic        ftq_ifu_owner_valid;
    logic        ftq_ifu_wb_owner_valid;
    logic        ftq_next_ifu_owner_valid;
    logic        ftq_commit_head_valid;
    logic        ftq_commit_owner_valid;
    logic        ftq_full;
    logic        ftq_empty;
    logic [FTQ_IDX_BITS-1:0]   ftq_enq_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_head_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_ifu_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_ifu_wb_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_next_ifu_owner_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_commit_head_idx;
    logic [FTQ_IDX_BITS-1:0]   ftq_commit_owner_idx;
    logic [FTQ_EPOCH_BITS-1:0] ftq_enq_epoch;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_enq_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_head_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_ifu_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_ifu_wb_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_next_ifu_owner_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_commit_head_tag;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_commit_owner_tag;
    logic [FTQ_EPOCH_BITS-1:0] ftq_current_epoch;
    logic [FTQ_IDX_BITS:0]     ftq_count;
    logic [FTQ_IDX_BITS:0]     ftq_count_alloc_to_ifu;
    logic [FTQ_IDX_BITS:0]     ftq_count_ifu_to_wb;
    logic [FTQ_IDX_BITS:0]     ftq_count_ifu_to_commit;
    // Forward declarations used by FTQ allocation and completion wiring before
    // the IFU work cursor is declared later in the file.
    logic        f2_work_valid_c;
    logic [63:0] f2_work_pc_c;
    logic        f2_work_line_valid_c;
    logic [63:LINE_BITS] f2_work_line_addr_c;
    logic        f2_work_owner_complete_c;
    logic        f2_work_owner_delivered_c;
    logic        f2_owner_delivery_push_c;
    logic        f2_redirect_without_owner_successor_c;
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
    ftq_entry_t  ftq_ifu_owner_entry;
    ftq_entry_t  ftq_ifu_wb_owner_entry;
    ftq_entry_t  ftq_next_ifu_owner_entry;
    ftq_entry_t  ftq_commit_head_entry;
    ftq_entry_t  ftq_commit_owner_entry;
    ftq_entry_t  ftq_enq_entry_c;
    fetch_packet_t packet_buf_in;
    fetch_packet_t packet_buf_head;
    logic        packet_buf_owner_match_c;
    logic        packet_buf_head_owner_complete_c;
    logic        remainder_valid_r;
    logic        subgroup_split_second_ctl_en;
    logic        subgroup_split_any_second_ctl_en;
    logic        subgroup_split_owner_cond_en;
    logic        subgroup_split_slot3_ftq_taken_only_en;

`ifdef SIMULATION
    logic sim_subgroup_split_second_ctl_en;
    logic sim_subgroup_split_any_second_ctl_en;
    logic sim_subgroup_split_owner_cond_en;
    logic sim_subgroup_split_slot3_ftq_taken_only_en;
    initial begin
        sim_subgroup_split_second_ctl_en =
            !$test$plusargs("DISABLE_SUBGROUP_SPLIT_SECOND_CTL");
        sim_subgroup_split_any_second_ctl_en =
            !$test$plusargs("DISABLE_SPLIT_ANY_SECOND_CTL");
        sim_subgroup_split_owner_cond_en =
            !$test$plusargs("DISABLE_SUBGROUP_SPLIT_OWNER_COND");
        sim_subgroup_split_slot3_ftq_taken_only_en =
            $test$plusargs("SPLIT_SLOT3_FTQ_TAKEN_ONLY");
    end
    assign subgroup_split_second_ctl_en =
        sim_subgroup_split_second_ctl_en;
    assign subgroup_split_any_second_ctl_en =
        sim_subgroup_split_any_second_ctl_en;
    assign subgroup_split_owner_cond_en =
        sim_subgroup_split_owner_cond_en;
    assign subgroup_split_slot3_ftq_taken_only_en =
        sim_subgroup_split_slot3_ftq_taken_only_en;
`else
    assign subgroup_split_second_ctl_en = 1'b1;
    assign subgroup_split_any_second_ctl_en = 1'b1;
    assign subgroup_split_owner_cond_en = 1'b1;
    assign subgroup_split_slot3_ftq_taken_only_en = 1'b0;
`endif

    // Monolithic IFU request boundary.  The IFU may accept a new owner only
    // when the response queue can absorb the coming line and the IBuffer has
    // room for eventual packet delivery. This is the structural backpressure
    // point for bounded runahead.
    assign ifu_req_valid_c = ftq_enq_valid;
    assign ifu_req_ready_c = ftq_enq_ready && !icq_full && !packet_buf_full;
    assign ifu_req_fire_c  = ifu_req_valid_c && ifu_req_ready_c;

    // The FTQ handles same-cycle alloc-to-IFU transfer when the allocated owner
    // is not yet visible in the registered allocation-to-request region.
    assign ftq_ifu_req_pop_valid = ifu_req_fire_c;

    assign req_pc_c = (req_redirect_c && !redirect_valid)
                      ? f2_bpu_target
                      : (line_straddle_advance_c
                            ? f2_seq_next_pc
                            : f1_pc);
    assign req_block_pc_c = {req_pc_c[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign ftq_need_alloc_c =
        !redirect_valid &&
        f1_valid &&
        !remainder_valid_r &&
        !line_straddle_advance_c &&
        !f2_same_owner_continue_c &&
        // The live F2 group already owns this exact request PC. Re-allocating
        // a fresh FTQ entry for it creates a tag with no distinct packet to
        // pair against. A predicted redirect is different: it starts a new
        // dynamic fetch block even when the target PC matches a recently
        // allocated loop-body PC, so it must get a fresh owner tag.
        (req_redirect_c || !(f2_work_valid_c && (req_pc_c == f2_work_pc_c))) &&
        (req_redirect_c || !ftq_last_alloc_valid_r ||
         (req_pc_c != ftq_last_alloc_req_pc_r));

    // Request to I-cache: issue when F1 is valid and not stalled
    assign fe_stall    = frontend_hold ||
                         packet_buf_full ||
                         icq_full ||
                         (ftq_need_alloc_c && !ftq_enq_ready);
    assign ic_req_valid = f1_valid && !fe_stall;
    // On BPU redirect, bypass f1_pc and send the redirect target directly
    // to the icache.  This reduces the taken-branch fetch bubble from 2
    // cycles to 1: the icache starts the new lookup in the SAME cycle as
    // the redirect instead of waiting for f1_pc to update next cycle.
    assign ic_req_addr  = req_pc_c;
    assign ftq_normal_enq_valid = ic_req_valid && ftq_need_alloc_c;
    assign ftq_enq_valid = ftq_normal_enq_valid;
    assign ftq_enq_entry_c = req_ftq_entry_c;

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
    logic        nlpb_aux_hit_comb;
    logic [511:0] nlpb_aux_data_comb;
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
        .aux_lookup_valid(f1_valid && !fe_stall),
        .aux_lookup_addr (f1_pc),
        .aux_hit         (nlpb_aux_hit_comb),
        .aux_hit_data    (nlpb_aux_data_comb),
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
        f2_work_line_valid_c &&
        (nlpb_resp_addr_r[63:LINE_BITS] == f2_work_line_addr_c);
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
    // at T-1 (= f1_pc at T-1 = IFU work/F2 cursor at T).
    //
    // Iteration gamma' phase 0 (2026-05-05): Route the icache response
    // through icache_resp_queue, with bypass-when-empty so the steady-state
    // F1/F2-lockstep case is functionally identical to the prior direct read.
    // The queue carries the source PC + FTQ identity per entry, enabling
    // future F1-stage runahead (where F1 fires ahead of F2 consumption and
    // the queue absorbs the rate mismatch) without the F2-tracks-f1_pc
    // architectural mismatch documented in fetch_unit.sv:1267.
    //
    // Pipeline register: capture (ic_req_addr, ftq identity at request) for
    // 1 cycle so the queue's enq carries the source identity matched to
    // the icache response that arrives at this cycle.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ic_req_addr_pipe_r           <= '0;
            ic_req_ftq_pipe_valid_r      <= 1'b0;
            ic_req_ftq_pipe_idx_r        <= '0;
            ic_req_ftq_pipe_epoch_r      <= '0;
            ic_req_ftq_pipe_alloc_tag_r  <= '0;
        end else if (redirect_valid) begin
            ic_req_ftq_pipe_valid_r      <= 1'b0;
        end else begin
            ic_req_addr_pipe_r           <= ic_req_addr;
            // FTQ identity at the cycle ic_req fires: when ftq_enq fires,
            // capture the new entry's identity; otherwise carry whatever
            // F1 had (for held cycles, the request still goes out for the
            // already-allocated head).
            if (ftq_enq_valid) begin
                ic_req_ftq_pipe_valid_r      <= 1'b1;
                ic_req_ftq_pipe_idx_r        <= ftq_enq_idx;
                ic_req_ftq_pipe_epoch_r      <= ftq_enq_epoch;
                ic_req_ftq_pipe_alloc_tag_r  <= ftq_enq_tag;
            end
        end
    end

    // Queue: depth 4. Bypass mode means functionally a wire when empty +
    // enq_valid + deq_ready. Storage only fires for genuine buffering.
    logic                                  icq_deq_valid;
    logic [511:0]                          icq_deq_data;
    logic                                  icq_deq_hit;
    logic [63:0]                           icq_deq_pc;
    logic [63:LINE_BITS]                   icq_deq_line_addr;
    logic                                  icq_deq_ftq_valid;
    logic [FTQ_IDX_BITS-1:0]               icq_deq_ftq_idx;
    logic [FTQ_EPOCH_BITS-1:0]             icq_deq_ftq_epoch;
    logic [FTQ_ALLOC_TAG_BITS-1:0]         icq_deq_ftq_alloc_tag;
    logic                                  icq_deq_ready;
    logic                                  icq_line_matches_f2_c;
    logic                                  icq_deq_owner_match_c;
    logic                                  icq_deq_stale_c;
    logic                                  f2_line_state_valid_r;
    logic [63:LINE_BITS]                   f2_line_state_addr_r;
    logic [511:0]                          f2_line_state_data_r;
    logic                                  f2_line_state_hit_r;
    logic [FTQ_EPOCH_BITS-1:0]             f2_line_state_epoch_r;
    logic                                  f2_line_state_match_c;
    logic                                  f2_line_state_use_c;
    logic [63:LINE_BITS]                   f2_ifu_line_addr_c;
    typedef struct packed {
        logic                                  valid;
        logic [63:0]                           pc;
        logic                                  ftq_valid;
        logic [FTQ_IDX_BITS-1:0]               ftq_idx;
        logic [FTQ_EPOCH_BITS-1:0]             ftq_epoch;
        logic [FTQ_ALLOC_TAG_BITS-1:0]         ftq_alloc_tag;
        ftq_entry_t                            ftq_entry;
        logic                                  line_valid;
        logic [63:LINE_BITS]                   line_addr;
        logic                                  owner_complete;
        logic                                  owner_delivered;
    } ifu_work_item_t;
    function automatic ifu_work_item_t make_ifu_work_item(
        input logic                                  valid,
        input logic [63:0]                           pc,
        input logic                                  ftq_valid,
        input logic [FTQ_IDX_BITS-1:0]               ftq_idx,
        input logic [FTQ_EPOCH_BITS-1:0]             ftq_epoch,
        input logic [FTQ_ALLOC_TAG_BITS-1:0]         ftq_alloc_tag,
        input ftq_entry_t                            ftq_entry
    );
        begin
            make_ifu_work_item = '0;
            make_ifu_work_item.valid         = valid;
            make_ifu_work_item.pc            = pc;
            make_ifu_work_item.ftq_valid     = ftq_valid;
            make_ifu_work_item.ftq_idx       = ftq_idx;
            make_ifu_work_item.ftq_epoch     = ftq_epoch;
            make_ifu_work_item.ftq_alloc_tag = ftq_alloc_tag;
            make_ifu_work_item.ftq_entry     = ftq_entry;
            make_ifu_work_item.line_valid    = valid;
            make_ifu_work_item.line_addr     = pc[63:LINE_BITS];
            make_ifu_work_item.owner_complete = 1'b0;
            make_ifu_work_item.owner_delivered = 1'b0;
        end
    endfunction
    ifu_work_item_t                         ifu_work_r;
    ifu_work_item_t                         ifu_work_next_c;
    logic                                  f2_work_ftq_valid_c;
    logic [FTQ_IDX_BITS-1:0]               f2_work_ftq_idx_c;
    logic [FTQ_EPOCH_BITS-1:0]             f2_work_ftq_epoch_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0]         f2_work_ftq_alloc_tag_c;
    ftq_entry_t                            f2_work_ftq_entry_c;
    logic                                  ifu_work_redirect_c;
    logic                                  ifu_work_redirect_next_owner_match_c;
    logic                                  ifu_work_redirect_enq_owner_c;
    logic                                  ifu_work_redirect_keep_owner_c;
    logic                                  ifu_work_take_ftq_next_owner_c;
    logic                                  ifu_work_take_request_owner_c;
    logic                                  ifu_work_take_remainder_request_owner_c;
    icache_resp_queue #(.DEPTH(ICQ_DEPTH)) u_icache_resp_queue (
        .clk(clk),
        .rst_n(rst_n),
        .flush(redirect_valid),
        .resp_valid_i(merged_resp_valid_comb),
        .resp_data_i(merged_resp_data_comb),
        .resp_hit_i(ic_resp_hit_comb || nlpb_resp_match_c),
        .resp_pc_i(ic_req_addr_pipe_r),
        .resp_ftq_valid_i(ic_req_ftq_pipe_valid_r),
        .resp_ftq_idx_i(ic_req_ftq_pipe_idx_r),
        .resp_ftq_epoch_i(ic_req_ftq_pipe_epoch_r),
        .resp_ftq_alloc_tag_i(ic_req_ftq_pipe_alloc_tag_r),
        .deq_ready_i(icq_deq_ready),
        .deq_valid_o(icq_deq_valid),
        .deq_data_o(icq_deq_data),
        .deq_hit_o(icq_deq_hit),
        .deq_pc_o(icq_deq_pc),
        .deq_line_addr_o(icq_deq_line_addr),
        .deq_ftq_valid_o(icq_deq_ftq_valid),
        .deq_ftq_idx_o(icq_deq_ftq_idx),
        .deq_ftq_epoch_o(icq_deq_ftq_epoch),
        .deq_ftq_alloc_tag_o(icq_deq_ftq_alloc_tag),
        .full(icq_full),
        .empty(icq_empty),
        .count(icq_count)
    );

    assign icq_line_matches_f2_c =
        icq_deq_valid &&
        f2_work_line_valid_c &&
        (icq_deq_line_addr == f2_work_line_addr_c);
    assign icq_deq_owner_match_c =
        icq_deq_valid &&
        icq_deq_ftq_valid &&
        ftq_ifu_wb_owner_valid &&
        (icq_deq_ftq_idx == ftq_ifu_wb_owner_idx) &&
        (icq_deq_ftq_epoch == ftq_current_epoch) &&
        (icq_deq_ftq_alloc_tag == ftq_ifu_wb_owner_tag);
    assign icq_deq_stale_c =
        icq_deq_valid &&
        (!icq_deq_ftq_valid ||
         (icq_deq_ftq_epoch != ftq_current_epoch));
    assign f2_line_state_match_c =
        f2_line_state_valid_r &&
        f2_work_line_valid_c &&
        (f2_line_state_addr_r == f2_work_line_addr_c) &&
        (f2_line_state_epoch_r == ftq_current_epoch);

    // IFU only accepts a queue head when the line belongs to the work cursor.
    // A same-line owner may reuse the line-state record without popping a
    // future-line ICQ head. Owner equality is observed separately because the
    // current FTQ IFU-writeback pointer can lag the ICQ head during legal
    // frontend handoff timing.
    // Responses from flushed or unowned requests are drained as stale entries,
    // but never exposed as F2 data.
    assign icq_deq_ready =
        icq_line_matches_f2_c ||
        icq_deq_stale_c;
    assign ic_resp_valid =
        icq_deq_valid && icq_deq_ready && !icq_deq_stale_c;
    assign ic_resp_data  = icq_deq_data;
    assign ic_resp_hit   = icq_deq_hit;
    assign f2_line_state_use_c = f2_line_state_match_c && !ic_resp_valid;
    assign f2_data_valid =
        f2_line_state_use_c || ic_resp_valid;
    assign f2_data_line  =
        f2_line_state_use_c ? f2_line_state_data_r : ic_resp_data;
    assign f2_ifu_line_addr_c =
        f2_line_state_use_c
            ? f2_line_state_addr_r
            : icq_deq_line_addr;
    assign f2_work_valid_c         = ifu_work_r.valid;
    assign f2_work_pc_c            = ifu_work_r.pc;
    assign f2_work_ftq_valid_c     = ifu_work_r.ftq_valid;
    assign f2_work_ftq_idx_c       = ifu_work_r.ftq_idx;
    assign f2_work_ftq_epoch_c     = ifu_work_r.ftq_epoch;
    assign f2_work_ftq_alloc_tag_c = ifu_work_r.ftq_alloc_tag;
    assign f2_work_ftq_entry_c     = ifu_work_r.ftq_entry;
    assign f2_work_line_valid_c    = ifu_work_r.line_valid;
    assign f2_work_line_addr_c     = ifu_work_r.line_addr;
    assign f2_work_owner_delivered_c = ifu_work_r.owner_delivered;
    assign f2_ftq_owner_live_c =
        f2_work_ftq_valid_c &&
        ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c == ftq_ifu_wb_owner_tag);
    assign ifu_work_redirect_c =
        f2_bpu_redirect && !fe_stall;
    assign ifu_work_redirect_next_owner_match_c =
        ifu_work_redirect_c &&
        ftq_next_ifu_owner_valid &&
        (ftq_next_ifu_owner_entry.block_pc ==
         {f2_bpu_target[63:LINE_BITS], {LINE_BITS{1'b0}}}) &&
        (ftq_next_ifu_owner_entry.start_offset == f2_bpu_target[5:0]);
    assign ifu_work_redirect_enq_owner_c =
        ifu_work_redirect_c &&
        !ifu_work_redirect_next_owner_match_c &&
        ftq_enq_valid;
    assign ifu_work_redirect_keep_owner_c =
        ifu_work_redirect_c &&
        !ifu_work_redirect_next_owner_match_c &&
        !ftq_enq_valid;
    assign ifu_work_take_ftq_next_owner_c =
        !ifu_work_redirect_c &&
        !fe_stall &&
        ftq_ifu_pop_valid &&
        ftq_next_ifu_owner_valid &&
        f2_seq_valid;
    assign ifu_work_take_remainder_request_owner_c =
        !ifu_work_redirect_c &&
        !fe_stall &&
        consumed_remainder_r &&
        ftq_enq_valid;
    assign ifu_work_take_request_owner_c =
        !ifu_work_redirect_c &&
        !fe_stall &&
        !(line_straddle_advance_c ||
          consume_remainder_c ||
          consumed_remainder_r) &&
        ftq_enq_valid;
    assign packet_buf_deq = !backend_stall && !frontend_hold;

    // IFU line-data lifetime is tracked separately from the FTQ owner cursor.
    // Same-line owners may share this physical line record, but every emitted
    // packet still carries the current FTQ idx/epoch/tag from the work cursor.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_line_state_valid_r <= 1'b0;
            f2_line_state_addr_r  <= '0;
            f2_line_state_data_r  <= '0;
            f2_line_state_hit_r   <= 1'b0;
            f2_line_state_epoch_r <= '0;
        end else if (redirect_valid || fence_i) begin
            f2_line_state_valid_r <= 1'b0;
            f2_line_state_addr_r  <= '0;
            f2_line_state_data_r  <= '0;
            f2_line_state_hit_r   <= 1'b0;
            f2_line_state_epoch_r <= '0;
        end else if (f2_work_valid_c && ic_resp_valid) begin
            f2_line_state_valid_r <= 1'b1;
            f2_line_state_addr_r  <= icq_deq_line_addr;
            f2_line_state_data_r  <= ic_resp_data;
            f2_line_state_hit_r   <= ic_resp_hit;
            f2_line_state_epoch_r <= ftq_current_epoch;
        end
    end

    ftq u_ftq (
        .clk          (clk),
        .rst_n        (rst_n),
        .flush        (redirect_valid),
        .enq_valid    (ftq_enq_valid),
        .enq_entry    (ftq_enq_entry_c),
        .enq_ready    (ftq_enq_ready),
        .enq_idx      (ftq_enq_idx),
        .enq_epoch    (ftq_enq_epoch),
        .enq_tag      (ftq_enq_tag),
        .ifu_req_pop_valid(ftq_ifu_req_pop_valid),
        .delivery_push_valid(ftq_delivery_push_valid),
        .pop_valid    (ftq_ifu_pop_valid),
        .head_valid   (ftq_head_valid),
        .head_entry   (ftq_head_entry),
        .head_idx     (ftq_head_idx),
        .head_tag     (ftq_head_tag),
        .ifu_owner_valid(ftq_ifu_owner_valid),
        .ifu_owner_entry(ftq_ifu_owner_entry),
        .ifu_owner_idx(ftq_ifu_owner_idx),
        .ifu_owner_tag(ftq_ifu_owner_tag),
        .ifu_wb_owner_valid(ftq_ifu_wb_owner_valid),
        .ifu_wb_owner_entry(ftq_ifu_wb_owner_entry),
        .ifu_wb_owner_idx(ftq_ifu_wb_owner_idx),
        .ifu_wb_owner_tag(ftq_ifu_wb_owner_tag),
        .next_ifu_owner_valid(ftq_next_ifu_owner_valid),
        .next_ifu_owner_entry(ftq_next_ifu_owner_entry),
        .next_ifu_owner_idx(ftq_next_ifu_owner_idx),
        .next_ifu_owner_tag(ftq_next_ifu_owner_tag),
        .commit_pop_valid(ftq_commit_pop_valid),
        .commit_head_valid(ftq_commit_head_valid),
        .commit_head_entry(ftq_commit_head_entry),
        .commit_head_idx(ftq_commit_head_idx),
        .commit_head_tag(ftq_commit_head_tag),
        .commit_owner_valid(ftq_commit_owner_valid),
        .commit_owner_entry(ftq_commit_owner_entry),
        .commit_owner_idx(ftq_commit_owner_idx),
        .commit_owner_tag(ftq_commit_owner_tag),
        .current_epoch(ftq_current_epoch),
        .count        (ftq_count),
        .count_alloc_to_ifu(ftq_count_alloc_to_ifu),
        .count_ifu_to_wb(ftq_count_ifu_to_wb),
        .count_ifu_to_commit(ftq_count_ifu_to_commit),
        .full         (ftq_full),
        .empty        (ftq_empty)
    );

    fetch_packet_buffer u_fetch_packet_buffer (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (redirect_valid),
        .enq_valid  (packet_buf_enq),
        .enq_packet (packet_buf_in),
        .enq_ready  (packet_buf_enq_ready),
        .enq_fire   (packet_buf_enq_fire),
        .deq_ready  (packet_buf_deq),
        .deq_valid  (packet_buf_valid),
        .deq_packet (packet_buf_head),
        .deq_fire   (packet_buf_deq_fire),
        .deq_flowthrough(packet_buf_flowthrough_c),
        .owner_valid(ftq_commit_owner_valid),
        .owner_idx  (ftq_commit_owner_idx),
        .owner_epoch(ftq_current_epoch),
        .owner_tag  (ftq_commit_owner_tag),
        .deq_owner_match(packet_buf_owner_match_c),
        .deq_stale_owner(packet_buf_stale_owner_c),
        .deq_owner_complete(packet_buf_head_owner_complete_c),
        .full       (packet_buf_full),
        .empty      (packet_buf_empty),
        .count      (packet_buf_count)
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
    logic        f1_aux_btb_hit;
    logic [63:0] f1_aux_btb_target;
    logic [2:0]  f1_aux_btb_type;
    logic [5:0]  f1_aux_btb_offset;
    logic        f1_aux_btb_alt_hit;
    logic [63:0] f1_aux_btb_alt_target;
    logic [2:0]  f1_aux_btb_alt_type;
    logic [5:0]  f1_aux_btb_alt_offset;
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
        .aux_lookup_pc (f1_pc),
        .aux_hit       (f1_aux_btb_hit),
        .aux_target    (f1_aux_btb_target),
        .aux_branch_type  (f1_aux_btb_type),
        .aux_branch_offset(f1_aux_btb_offset),
        .aux_alt_hit       (f1_aux_btb_alt_hit),
        .aux_alt_target    (f1_aux_btb_alt_target),
        .aux_alt_branch_type  (f1_aux_btb_alt_type),
        .aux_alt_branch_offset(f1_aux_btb_alt_offset),
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
    logic [63:0] predecode_ctl_target;
    logic [GHR_BITS-1:0] f2_ghr_snapshot_r;
    logic [63:0] tage_lookup_pc;
    logic [63:0] tage_lookup_target;
    logic tage_pred_taken;
    logic tage_pred_confident;
    logic owner_tage_pred_taken;
    logic owner_tage_pred_confident;

    // Speculative GHR update: when we predict a branch as taken in F2
    logic tage_spec_update_valid;
    logic tage_spec_taken;

    assign btb_update_valid  = bpu_update_valid;
    assign tage_update_valid = bpu_tage_update_valid;
    assign tage_lookup_pc =
        (btb_hit && (btb_branch_type == BT_COND))
            ? {req_block_pc_c[63:LINE_BITS], btb_branch_offset}
            : ic_req_addr;
    assign tage_lookup_target =
        (btb_hit && (btb_branch_type == BT_COND)) ? btb_target : 64'd0;

    tage_sc_l u_tage_sc_l (
        .clk              (clk),
        .rst_n            (rst_n),
        .pc               (tage_lookup_pc),
        .target           (tage_lookup_target),
        .pred_taken       (tage_pred_taken),
        .pred_confident   (tage_pred_confident),
        .aux_pc           (predecode_ctl_pc),
        .aux_target       (predecode_ctl_target),
        .aux_ghr          (f2_ghr_snapshot_r),
        .aux_pred_taken   (owner_tage_pred_taken),
        .aux_pred_confident(owner_tage_pred_confident),
        .update_valid     (tage_update_valid),
        .update_pc        (bpu_tage_update_pc),
        .update_target    (bpu_tage_update_target),
        .update_taken     (bpu_tage_update_taken),
        .update_mispredict(bpu_tage_update_mispredict),
        .update_ghr       (bpu_tage_update_ghr),
        .spec_update_valid(tage_spec_update_valid),
        .spec_taken       (tage_spec_taken),
        .spec_pc          (predecode_ctl_pc),
        .spec_target      (predecode_ctl_target),
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
            req_pred_ctl_valid_c  = 1'b1;
            req_pred_ctl_offset_c = btb_branch_offset;
            req_pred_ctl_type_c   = btb_branch_type;

            case (btb_branch_type)
                BT_COND: begin
                    req_pred_ctl_target_c = btb_target;
                    req_pred_ctl_taken_c  = tage_pred_taken;
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

    logic        f1_aux_pred_ctl_valid_c;
    logic        f1_aux_pred_ctl_taken_c;
    logic [5:0]  f1_aux_pred_ctl_offset_c;
    logic [2:0]  f1_aux_pred_ctl_type_c;
    logic [63:0] f1_aux_pred_ctl_target_c;

    always_comb begin
        f1_aux_pred_ctl_valid_c  = 1'b0;
        f1_aux_pred_ctl_taken_c  = 1'b0;
        f1_aux_pred_ctl_offset_c = 6'd0;
        f1_aux_pred_ctl_type_c   = BT_COND;
        f1_aux_pred_ctl_target_c = 64'd0;

        if (f1_aux_btb_hit) begin
            automatic logic [63:0] pred_branch_pc;
            pred_branch_pc = {f1_pc[63:LINE_BITS], f1_aux_btb_offset};
            f1_aux_pred_ctl_valid_c  = 1'b1;
            f1_aux_pred_ctl_offset_c = f1_aux_btb_offset;
            f1_aux_pred_ctl_type_c   = f1_aux_btb_type;

            case (f1_aux_btb_type)
                BT_COND: begin
                    f1_aux_pred_ctl_target_c = f1_aux_btb_target;
                    f1_aux_pred_ctl_taken_c =
                        (f1_aux_btb_target < pred_branch_pc);
                end
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    f1_aux_pred_ctl_target_c = f1_aux_btb_target;
                    f1_aux_pred_ctl_taken_c  = 1'b1;
                end
                BT_RET: begin
                    if ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0)) begin
                        f1_aux_pred_ctl_target_c = ras_pop_addr;
                        f1_aux_pred_ctl_taken_c  = 1'b1;
                    end
                end
                default: begin
                    f1_aux_pred_ctl_valid_c = 1'b0;
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
    // Forward declarations (used by consume_remainder_c before full definition)
    logic [2:0]  extract_count;
    logic [5:0]  start_offset;

    // On the cycle where f2 consumes a straddle remainder (start_offset=0,
    // remainder_valid_r=1 and one or more instructions were emitted), the
    // usual f1->f2 pipeline would leave the work cursor at the same cache-line base
    // next cycle (because f1_pc lagged behind by one cycle across the
    // straddle). Detect the consume event combinationally and advance
    // the work cursor directly to f2_seq_next_pc so the following cycle processes
    // the next real instruction stream.
    assign consume_remainder_c = remainder_valid_r && f2_work_valid_c &&
                                 f2_data_valid && (start_offset == 6'd0) &&
                                 (extract_count > 3'd0);

    always_comb begin
        logic [63:0]                           work_pc_next;
        logic                                  work_ftq_valid_next;
        logic [FTQ_IDX_BITS-1:0]               work_ftq_idx_next;
        logic [FTQ_EPOCH_BITS-1:0]             work_ftq_epoch_next;
        logic [FTQ_ALLOC_TAG_BITS-1:0]         work_ftq_alloc_tag_next;
        ftq_entry_t                            work_ftq_entry_next;
        logic                                  work_owner_delivered_next;

        ifu_work_next_c = ifu_work_r;

        work_pc_next            = f1_pc;
        work_ftq_valid_next     = f2_work_ftq_valid_c;
        work_ftq_idx_next       = f2_work_ftq_idx_c;
        work_ftq_epoch_next     = f2_work_ftq_epoch_c;
        work_ftq_alloc_tag_next = f2_work_ftq_alloc_tag_c;
        work_ftq_entry_next     = f2_work_ftq_entry_c;
        work_owner_delivered_next =
            f2_work_owner_delivered_c || f2_owner_delivery_push_c;

        if (redirect_valid) begin
            ifu_work_next_c = '0;
        end else if (ifu_work_redirect_c) begin
            if (ifu_work_redirect_next_owner_match_c) begin
                ifu_work_next_c = make_ifu_work_item(
                    1'b1,
                    f2_bpu_target,
                    1'b1,
                    ftq_next_ifu_owner_idx,
                    ftq_current_epoch,
                    ftq_next_ifu_owner_tag,
                    ftq_next_ifu_owner_entry);
            end else if (ifu_work_redirect_enq_owner_c) begin
                ifu_work_next_c = make_ifu_work_item(
                    1'b1,
                    f2_bpu_target,
                    1'b1,
                    ftq_enq_idx,
                    ftq_enq_epoch,
                    ftq_enq_tag,
                    ftq_enq_entry_c);
            end else begin
                ifu_work_next_c = make_ifu_work_item(
                    1'b1,
                    f2_bpu_target,
                    f2_work_ftq_valid_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_epoch_c,
                    f2_work_ftq_alloc_tag_c,
                    f2_work_ftq_entry_c);
                ifu_work_next_c.owner_delivered = work_owner_delivered_next;
            end
        end else if (!fe_stall) begin
            if (ifu_work_take_ftq_next_owner_c) begin
                ifu_work_next_c = make_ifu_work_item(
                    1'b1,
                    f2_seq_next_pc,
                    1'b1,
                    ftq_next_ifu_owner_idx,
                    ftq_current_epoch,
                    ftq_next_ifu_owner_tag,
                    ftq_next_ifu_owner_entry);
            end else begin
                if (line_straddle_advance_c)
                    work_pc_next = f2_seq_next_pc;
                else if (consume_remainder_c)
                    work_pc_next = f2_seq_next_pc;
                else if (consumed_remainder_r)
                    work_pc_next = post_remainder_pc_r;
                else
                    work_pc_next = f1_pc;

                if (line_straddle_advance_c ||
                    consume_remainder_c ||
                    consumed_remainder_r) begin
                    if (ifu_work_take_remainder_request_owner_c) begin
                        work_ftq_valid_next     = 1'b1;
                        work_ftq_idx_next       = ftq_enq_idx;
                        work_ftq_epoch_next     = ftq_enq_epoch;
                        work_ftq_alloc_tag_next = ftq_enq_tag;
                        work_ftq_entry_next     = ftq_enq_entry_c;
                        work_owner_delivered_next = 1'b0;
                    end
                end else if (ifu_work_take_request_owner_c) begin
                    work_ftq_valid_next     = 1'b1;
                    work_ftq_idx_next       = ftq_enq_idx;
                    work_ftq_epoch_next     = ftq_enq_epoch;
                    work_ftq_alloc_tag_next = ftq_enq_tag;
                    work_ftq_entry_next     = ftq_enq_entry_c;
                    work_owner_delivered_next = 1'b0;
                end else if (!f1_valid) begin
                    work_ftq_valid_next     = 1'b0;
                    work_ftq_idx_next       = '0;
                    work_ftq_epoch_next     = '0;
                    work_ftq_alloc_tag_next = '0;
                    work_ftq_entry_next     = '0;
                    work_owner_delivered_next = 1'b0;
                end

                ifu_work_next_c = make_ifu_work_item(
                    f1_valid,
                    work_pc_next,
                    work_ftq_valid_next,
                    work_ftq_idx_next,
                    work_ftq_epoch_next,
                    work_ftq_alloc_tag_next,
                    work_ftq_entry_next);
                ifu_work_next_c.owner_delivered = work_owner_delivered_next;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ifu_work_r <= '0;
        else
            ifu_work_r <= ifu_work_next_c;
    end

    // Track the most recent F2 PC emitted to decode. The current f1->f2
    // pipeline can hold the work cursor on the same fetch group for back-to-back
    // cycles while the frontend catches up; without a duplicate filter,
    // decode/rename can consume the same group twice.
    logic        f2_has_emit_payload_c;
    logic        f2_last_emit_valid_r;
    logic [63:0] f2_last_emit_pc_r;
    logic [63:0] f2_last_emit_next_pc_r;
    logic        f2_last_emit_ftq_valid_r;
    logic [FTQ_IDX_BITS-1:0] f2_last_emit_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] f2_last_emit_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] f2_last_emit_ftq_alloc_tag_r;
    logic        f2_replay_block_valid_r;
    logic [63:0] f2_replay_block_pc_r;
    logic        f2_replay_block_ftq_valid_r;
    logic [FTQ_IDX_BITS-1:0] f2_replay_block_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] f2_replay_block_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] f2_replay_block_ftq_alloc_tag_r;
    logic [1:0]  f2_replay_block_age_r;
    logic        f2_last_emit_owner_match_c;
    logic        f2_last_emit_hit_c;
    logic        f2_replay_block_owner_match_c;
    logic        f2_replay_block_hit_c;
    assign f2_has_emit_payload_c = f2_work_valid_c && f2_data_valid &&
                                   (extract_count > 3'd0);
    assign f2_last_emit_owner_match_c =
        (f2_last_emit_ftq_valid_r && f2_work_ftq_valid_c &&
         (f2_last_emit_ftq_idx_r == f2_work_ftq_idx_c) &&
         (f2_last_emit_ftq_epoch_r == f2_work_ftq_epoch_c) &&
         (f2_last_emit_ftq_alloc_tag_r == f2_work_ftq_alloc_tag_c)) ||
        (!f2_last_emit_ftq_valid_r && !f2_work_ftq_valid_c);
    assign f2_last_emit_hit_c =
        f2_last_emit_valid_r &&
        (f2_last_emit_pc_r == f2_work_pc_c) &&
        f2_last_emit_owner_match_c;
    assign f2_replay_block_owner_match_c =
        (f2_replay_block_ftq_valid_r && f2_work_ftq_valid_c &&
         (f2_replay_block_ftq_idx_r == f2_work_ftq_idx_c) &&
         (f2_replay_block_ftq_epoch_r == f2_work_ftq_epoch_c) &&
         (f2_replay_block_ftq_alloc_tag_r == f2_work_ftq_alloc_tag_c)) ||
        (!f2_replay_block_ftq_valid_r && !f2_work_ftq_valid_c);
    assign f2_replay_block_hit_c =
        f2_replay_block_valid_r &&
        (f2_replay_block_pc_r == f2_work_pc_c) &&
        f2_replay_block_owner_match_c;
    assign f2_duplicate_suppressed_c =
        f2_has_emit_payload_c &&
        (f2_last_emit_hit_c || f2_replay_block_hit_c);
    assign f2_duplicate_next_pc_c =
        f2_last_emit_hit_c
            ? f2_last_emit_next_pc_r
            : (f2_seq_valid ? f2_seq_next_pc : f1_pc);
    // Iteration alpha' (2026-05-05): explicit packet-buffer backpressure.
    // F2 must not emit unless the IBuffer can accept the packet. The buffer can
    // now accept on a full+dequeue cycle and can flow through when empty, so use
    // its ready rather than the raw full flag.
    assign f2_will_emit_c = f2_has_emit_payload_c &&
                             !f2_duplicate_suppressed_c &&
                             packet_buf_enq_ready;
    // A duplicate-suppressed F2 group must not advance F1 using the current
    // group's sequential PC. The bytes were already consumed by the original
    // emission; advancing again starts the next request inside that packet.
    assign f2_pc_consumed_c = f2_will_emit_c || line_straddle_advance_c;

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
        end else if (ftq_ifu_pop_valid && !ftq_next_ifu_owner_valid) begin
            ftq_last_alloc_valid_r    <= 1'b0;
            ftq_last_alloc_req_pc_r   <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_btb_hit_r        <= 1'b0;
            f2_btb_target_r     <= '0;
            f2_btb_type_r       <= '0;
            f2_btb_offset_r     <= '0;
            f2_btb_alt_hit_r    <= 1'b0;
            f2_btb_alt_target_r <= '0;
            f2_btb_alt_type_r   <= '0;
            f2_btb_alt_offset_r <= '0;
            f2_tage_taken_r     <= 1'b0;
            f2_ghr_snapshot_r   <= '0;
            consumed_remainder_r <= 1'b0;
            post_remainder_pc_r  <= '0;
            f2_last_emit_valid_r <= 1'b0;
            f2_last_emit_pc_r    <= '0;
            f2_last_emit_next_pc_r <= '0;
            f2_last_emit_ftq_valid_r <= 1'b0;
            f2_last_emit_ftq_idx_r <= '0;
            f2_last_emit_ftq_epoch_r <= '0;
            f2_last_emit_ftq_alloc_tag_r <= '0;
            f2_replay_block_valid_r <= 1'b0;
            f2_replay_block_pc_r    <= '0;
            f2_replay_block_ftq_valid_r <= 1'b0;
            f2_replay_block_ftq_idx_r <= '0;
            f2_replay_block_ftq_epoch_r <= '0;
            f2_replay_block_ftq_alloc_tag_r <= '0;
            f2_replay_block_age_r   <= '0;
        end else if (redirect_valid) begin
            // Flush cursor-adjacent state on redirect and clear the
            // duplicate-suppress flag.
            consumed_remainder_r <= 1'b0;
            f2_last_emit_valid_r <= 1'b0;
            f2_last_emit_ftq_valid_r <= 1'b0;
            f2_replay_block_valid_r <= 1'b0;
            f2_replay_block_ftq_valid_r <= 1'b0;
            f2_last_emit_next_pc_r <= '0;
            f2_replay_block_pc_r    <= '0;
            f2_replay_block_age_r   <= '0;
        end else if (f2_bpu_redirect && !fe_stall) begin
            // BPU redirect: the IFU work cursor is redirected to the target.
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
            f2_ghr_snapshot_r   <= ghr_out;
            consumed_remainder_r <= 1'b0;
            // The redirecting packet was emitted this cycle.  Remember its
            // PC across the redirect so a lagging f1->f2 handoff cannot
            // replay the same packet after the target packet has started.
            // For a self-targeting branch, allow the PC to emit repeatedly.
            f2_last_emit_valid_r <= (f2_bpu_target != f2_work_pc_c);
            f2_last_emit_pc_r    <= f2_work_pc_c;
            f2_last_emit_next_pc_r <= f2_bpu_target;
            f2_last_emit_ftq_valid_r <= f2_work_ftq_valid_c;
            f2_last_emit_ftq_idx_r <= f2_work_ftq_idx_c;
            f2_last_emit_ftq_epoch_r <= f2_work_ftq_epoch_c;
            f2_last_emit_ftq_alloc_tag_r <= f2_work_ftq_alloc_tag_c;
            f2_replay_block_valid_r <= (f2_bpu_target != f2_work_pc_c);
            f2_replay_block_pc_r    <= f2_work_pc_c;
            f2_replay_block_ftq_valid_r <= f2_work_ftq_valid_c;
            f2_replay_block_ftq_idx_r <= f2_work_ftq_idx_c;
            f2_replay_block_ftq_epoch_r <= f2_work_ftq_epoch_c;
            f2_replay_block_ftq_alloc_tag_r <= f2_work_ftq_alloc_tag_c;
            f2_replay_block_age_r   <= 2'd2;
        end else begin
            // Duplicate suppression must track any packet that was actually
            // emitted, even if F1/F2 state is frozen by fe_stall. Otherwise a
            // held F2 group can be enqueued multiple times with identical PC
            // and stale ownership metadata, which is exactly the bad
            // Dhrystone tail-pair signature seen at 0x80002178/0x8000217a.
            if (f2_will_emit_c) begin
                f2_last_emit_valid_r <= 1'b1;
                f2_last_emit_pc_r    <= f2_work_pc_c;
                f2_last_emit_ftq_valid_r <= f2_work_ftq_valid_c;
                f2_last_emit_ftq_idx_r <= f2_work_ftq_idx_c;
                f2_last_emit_ftq_epoch_r <= f2_work_ftq_epoch_c;
                f2_last_emit_ftq_alloc_tag_r <= f2_work_ftq_alloc_tag_c;
                if (bp_branch_found && bp_taken &&
                    !subgroup_split_before_ctl_c && !redirect_valid) begin
                    f2_last_emit_next_pc_r <= bp_target_addr;
                end else if (f2_seq_valid) begin
                    f2_last_emit_next_pc_r <= f2_seq_next_pc;
                end else begin
                    f2_last_emit_next_pc_r <= f1_pc;
                end
            end
            if (f2_replay_block_valid_r && !fe_stall) begin
                if (f2_will_emit_c &&
                    ((f2_work_pc_c != f2_replay_block_pc_r) ||
                     !f2_replay_block_owner_match_c)) begin
                    // Once the redirected-to packet has emitted, the blocked
                    // PC may be reached again by a real tight-loop iteration.
                    // Keeping the guard alive for a fixed age turns that real
                    // return into a frontend bubble.
                    f2_replay_block_valid_r <= 1'b0;
                    f2_replay_block_ftq_valid_r <= 1'b0;
                    f2_replay_block_age_r   <= '0;
                end else if (f2_replay_block_hit_c && f2_has_emit_payload_c) begin
                    f2_replay_block_valid_r <= 1'b0;
                    f2_replay_block_ftq_valid_r <= 1'b0;
                    f2_replay_block_age_r   <= '0;
                end else if (f2_replay_block_age_r == 2'd0) begin
                    f2_replay_block_valid_r <= 1'b0;
                    f2_replay_block_ftq_valid_r <= 1'b0;
                end else begin
                    f2_replay_block_age_r <= f2_replay_block_age_r - 2'd1;
                end
            end

            if (!fe_stall) begin
                f2_btb_hit_r        <= btb_hit;
                f2_btb_target_r     <= btb_target;
                f2_btb_type_r       <= btb_branch_type;
                f2_btb_offset_r     <= btb_branch_offset;
                f2_btb_alt_hit_r    <= btb_alt_hit;
                f2_btb_alt_target_r <= btb_alt_target;
                f2_btb_alt_type_r   <= btb_alt_branch_type;
                f2_btb_alt_offset_r <= btb_alt_branch_offset;
                f2_tage_taken_r     <= tage_pred_taken;
                if (line_straddle_advance_c || consume_remainder_c ||
                    consumed_remainder_r) begin
                    f2_ghr_snapshot_r <= f2_ghr_snapshot_r;
                end else begin
                    f2_ghr_snapshot_r <= ghr_out;
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
    // PIPE_WIDTH=4 instructions starting at the byte offset indicated by
    // f2_work_pc_c[5:0]. Each instruction is either 16-bit compressed (bits[1:0]
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
    logic        second_ctl_found;
    logic [2:0]  second_ctl_slot;
    logic [2:0]  second_ctl_type;
    logic [63:0] second_ctl_pc;
    logic [63:0] second_ctl_target;
    logic        second_ctl_backward_cond;
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
    logic        subgroup_split_seed_c;
    logic [2:0]  subgroup_split_slot_c;
    logic [2:0]  subgroup_split_type_c;
    logic [63:0] subgroup_split_pc_c;
    logic [63:0] subgroup_split_target_c;
    // extract_count, start_offset, remainder_valid_r declared earlier

    assign start_offset = f2_work_pc_c[5:0];

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

        if (f2_work_valid_c && f2_data_valid) begin
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
                    hw = {f2_data_line[bp*8 +: 8],
                          f2_data_line[bp*8 +: 8]};
                    // Correct: read two bytes in little-endian order
                    hw[7:0]  = f2_data_line[bp*8 +: 8];
                    hw[15:8] = f2_data_line[(bp+7'd1)*8 +: 8];

                    raw_hw[i]  = hw;
                    slot_pc[i] = {f2_work_pc_c[63:6], bp[5:0]};

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
                        straddle_pc       = {f2_work_pc_c[63:6], bp[5:0]};
                    end
                end
                // else: past end of line, stop
                end
            end
        end
    end

    assign line_straddle_advance_c =
        f2_work_valid_c &&
        f2_data_valid &&
        straddle_detected &&
        (extract_count == 3'd0) &&
        f2_seq_valid &&
        !redirect_valid &&
        !fe_stall;

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
        second_ctl_found     = 1'b0;
        second_ctl_slot      = 3'd0;
        second_ctl_type      = BT_COND;
        second_ctl_pc        = '0;
        second_ctl_target    = '0;

        if (f2_work_valid_c && f2_data_valid) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_valid[i] &&
                    (3'(i) < extract_count)) begin
                    automatic logic        ctl_found_i;
                    automatic logic [2:0]  ctl_type_i;
                    automatic logic [63:0] ctl_pc_i;
                    automatic logic [63:0] ctl_target_i;
                    automatic logic [31:0] insn32;
                    automatic logic [6:0]  opcode;
                    automatic logic [2:0]  funct3;
                    automatic logic [4:0]  rd;
                    automatic logic [4:0]  rs1;
                    automatic logic [11:0] imm12;

                    ctl_found_i  = 1'b0;
                    ctl_type_i   = BT_COND;
                    ctl_pc_i     = slot_pc[i];
                    ctl_target_i = '0;
                    insn32 = slot_is_rvc[i] ? decomp_out[i] : raw_insn[i];
                    opcode = insn32[6:0];
                    funct3 = insn32[14:12];
                    rd     = insn32[11:7];
                    rs1    = insn32[19:15];
                    imm12  = insn32[31:20];

                    case (opcode)
                        7'b1100011: begin
                            ctl_found_i  = 1'b1;
                            ctl_type_i   = BT_COND;
                            ctl_target_i = slot_pc[i] + imm_b64(insn32);
                        end
                        7'b1101111: begin
                            ctl_found_i  = 1'b1;
                            ctl_type_i   = is_link_reg(rd) ? BT_CALL : BT_JAL;
                            ctl_target_i = slot_pc[i] + imm_j64(insn32);
                        end
                        7'b1100111: begin
                            if (funct3 == 3'b000) begin
                                ctl_found_i = 1'b1;
                                if ((rd == 5'd0) && is_link_reg(rs1) &&
                                    (imm12 == 12'd0)) begin
                                    ctl_type_i = BT_RET;
                                    ctl_target_i =
                                        ((ras_tos != 5'd0) && (ras_pop_addr != 64'd0))
                                            ? ras_pop_addr
                                            : 64'd0;
                                end else if (is_link_reg(rd)) begin
                                    ctl_type_i   = BT_CALL;
                                    ctl_target_i = 64'd0;
                                end else begin
                                    ctl_type_i   = BT_JALR;
                                    ctl_target_i = 64'd0;
                                end
                            end
                        end
                        default: begin
                        end
                    endcase

                    if (ctl_found_i) begin
                        if (!predecode_ctl_found) begin
                            predecode_ctl_found  = 1'b1;
                            predecode_ctl_slot   = 3'(i);
                            predecode_ctl_type   = ctl_type_i;
                            predecode_ctl_pc     = ctl_pc_i;
                            predecode_ctl_target = ctl_target_i;
                        end else if (!second_ctl_found) begin
                            second_ctl_found  = 1'b1;
                            second_ctl_slot   = 3'(i);
                            second_ctl_type   = ctl_type_i;
                            second_ctl_pc     = ctl_pc_i;
                            second_ctl_target = ctl_target_i;
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        owner_cond_pred_found  = 1'b0;
        owner_cond_pred_slot   = predecode_ctl_slot;
        owner_cond_pred_target = predecode_ctl_target;

        if (f2_work_valid_c &&
            f2_data_valid &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND)) begin
            if (owner_tage_pred_taken) begin
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

        if (f2_work_ftq_valid_c && f2_work_ftq_entry_c.pred_ctl_valid) begin
            ftq_pred_ctl_valid  = 1'b1;
            ftq_pred_ctl_taken  = f2_work_ftq_entry_c.pred_ctl_taken;
            ftq_pred_ctl_type   = f2_work_ftq_entry_c.pred_ctl_type;
            ftq_pred_ctl_target = f2_work_ftq_entry_c.pred_ctl_target;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_valid[i] &&
                    (slot_pc[i][5:0] ==
                     f2_work_ftq_entry_c.pred_ctl_offset)) begin
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
        f2_work_valid_c &&
        f2_data_valid &&
        f2_will_emit_c &&
        !redirect_valid &&
        subgroup_split_before_ctl_c &&
        subgroup_split_seed_c &&
        (subgroup_split_type_c == BT_COND) &&
        f2_seq_valid;
    assign subgroup_seed_pred_taken_c =
        (ftq_pred_ctl_valid &&
         (ftq_pred_ctl_slot == subgroup_split_slot_c) &&
         (ftq_pred_ctl_type == subgroup_split_type_c))
           ? ftq_pred_ctl_taken
            : (((subgroup_split_slot_c == predecode_ctl_slot) &&
                (subgroup_split_pc_c == predecode_ctl_pc) &&
                (subgroup_split_target_c == predecode_ctl_target))
                   ? owner_cond_pred_found
                   : 1'b0);

    assign second_ctl_backward_cond =
        second_ctl_found &&
        (second_ctl_type == BT_COND) &&
        (second_ctl_target != 64'd0) &&
        (second_ctl_target < second_ctl_pc);

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
            subgroup_seed_parent_pc_r   <= f2_work_pc_c;
            subgroup_seed_owner_pc_r    <= subgroup_split_pc_c;
            subgroup_seed_pred_valid_r  <= 1'b1;
            subgroup_seed_pred_taken_r  <= subgroup_seed_pred_taken_c;
            subgroup_seed_pred_offset_r <= subgroup_split_pc_c[5:0];
            subgroup_seed_pred_type_r   <= subgroup_split_type_c;
            subgroup_seed_pred_target_r <= subgroup_split_target_c;
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
    logic [2:0]  bp_branch_slot;
    logic [2:0]  bp_truncated_count;
    logic [2:0]  bp_type;

    always_comb begin
        btb_pred_found     = 1'b0;
        btb_slot_matched   = 1'b0;
        btb_branch_slot    = 3'd0;
        btb_target_addr    = '0;
        btb_taken          = 1'b0;
        btb_truncated_count = extract_count;
        btb_pred_type      = BT_COND;
        btb_alt_pred_found   = 1'b0;
        btb_alt_slot_matched = 1'b0;
        btb_alt_branch_slot  = 3'd0;
        btb_alt_target_addr  = '0;
        btb_alt_truncated_count = extract_count;

        if (f2_work_valid_c && f2_data_valid &&
            f2_btb_hit_r) begin
            case (f2_btb_type_r)
                BT_COND: begin
                    if (f2_tage_taken_r) begin
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

        if (f2_work_valid_c && f2_data_valid &&
            f2_btb_alt_hit_r) begin
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

        if (f2_work_valid_c &&
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

        if (f2_work_valid_c &&
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

        // A subgroup FTQ entry can carry the owning conditional's prediction
        // even before the BTB has a matching entry.  Use it only when the
        // current predecode confirms the same live branch.
        if (ftq_pred_ctl_valid &&
            ftq_pred_ctl_taken &&
            (ftq_pred_ctl_type == BT_COND) &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND) &&
            (predecode_ctl_slot == ftq_pred_ctl_slot) &&
            (predecode_ctl_target == ftq_pred_ctl_target) &&
            (!bp_branch_found || (ftq_pred_ctl_slot < bp_branch_slot))) begin
            bp_branch_found    = 1'b1;
            bp_branch_slot     = ftq_pred_ctl_slot;
            bp_target_addr     = ftq_pred_ctl_target;
            bp_taken           = 1'b1;
            bp_truncated_count = 3'(ftq_pred_ctl_slot + 1);
            bp_type            = BT_COND;
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
        subgroup_split_seed_c       = 1'b1;
        subgroup_split_slot_c       = predecode_ctl_slot;
        subgroup_split_type_c       = predecode_ctl_type;
        subgroup_split_pc_c         = predecode_ctl_pc;
        subgroup_split_target_c     = predecode_ctl_target;

        // If the earliest conditional is not predicted taken, do not carry a
        // later control-flow instruction as an unpredicted passenger. Split
        // before the second CFI so the next request gets its own BTB/TAGE
        // lookup and can redirect independently.
        if (subgroup_split_second_ctl_en &&
            f2_work_valid_c &&
            f2_data_valid &&
            predecode_ctl_found &&
            second_ctl_found &&
            (predecode_ctl_type == BT_COND) &&
            !(bp_branch_found && bp_taken &&
              (bp_branch_slot <= second_ctl_slot)) &&
            (subgroup_split_any_second_ctl_en ||
             (predecode_ctl_slot == 3'd0) ||
             second_ctl_backward_cond)) begin
            subgroup_split_before_ctl_c = 1'b1;
            subgroup_split_seed_c       = 1'b0;
            subgroup_split_slot_c       = second_ctl_slot;
            subgroup_split_type_c       = second_ctl_type;
            subgroup_split_pc_c         = second_ctl_pc;
            subgroup_split_target_c     = second_ctl_target;

        // Split before a later owner conditional so the next request can be
        // branch-owned. Slot-1 conditionals only get the handoff when they are
        // likely taken; an untaken forward branch can remain in the parent
        // packet without creating a one-instruction subgroup.
        end else if (subgroup_split_owner_cond_en &&
            f2_work_valid_c &&
            f2_data_valid &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND) &&
            (predecode_ctl_slot != 3'd0)) begin
            if (predecode_ctl_slot == 3'd1) begin
                if (!(bp_branch_found &&
                      bp_taken &&
                      (bp_type == BT_COND) &&
                      (bp_branch_slot == predecode_ctl_slot)) &&
                    (owner_cond_pred_found ||
                     ((predecode_ctl_target != 64'd0) &&
                      (predecode_ctl_target < predecode_ctl_pc)))) begin
                    subgroup_split_before_ctl_c = 1'b1;
                end
            end else if ((predecode_ctl_slot == 3'd3) &&
                         ftq_pred_ctl_valid &&
                         (ftq_pred_ctl_type == BT_COND) &&
                         (!subgroup_split_slot3_ftq_taken_only_en ||
                          ftq_pred_ctl_taken) &&
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
            final_count = subgroup_split_slot_c;
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
            f2_seq_next_pc = {f2_work_pc_c[63:6] + 58'd1, 6'd0};
            f2_seq_valid   = 1'b1;
        end else begin
            last_slot_pc   = f2_work_pc_c;
            last_slot_rvc  = 1'b0;
            f2_seq_next_pc = f2_work_pc_c;
            f2_seq_valid   = 1'b0;
        end
    end

    // A straight-line continuation within the current cache line remains part
    // of the same fetch-block owner. Allocate a new FTQ owner only at a real
    // ownership boundary: control transfer, explicit subgroup split, line end,
    // or straddle handling.
    assign f2_same_owner_continue_c =
        f2_work_valid_c &&
        f2_data_valid &&
        f2_seq_valid &&
        (final_count > 3'd0) &&
        !straddle_detected &&
        !predecode_ctl_found &&
        !subgroup_split_before_ctl_c &&
        !(bp_branch_found && bp_taken) &&
        (f2_seq_next_pc[63:LINE_BITS] == f2_work_pc_c[63:LINE_BITS]);

    // Completion is a property of the current IFU work item after extraction and
    // predecode. A straddle-remainder consume or redirect without a successor
    // owner may emit instructions, but the owner can still have a same-owner
    // continuation packet on the following cycle. Keep completion gated until
    // that continuation point so FTQ writeback/pop and packet metadata agree on
    // the owner lifetime.
    assign f2_redirect_without_owner_successor_c =
        req_redirect_c &&
        !ftq_enq_valid &&
        (ftq_count_ifu_to_wb <= {{FTQ_IDX_BITS{1'b0}}, 1'b1});
    assign f2_work_owner_complete_c =
        !consume_remainder_c &&
        !f2_redirect_without_owner_successor_c &&
        !f2_same_owner_continue_c &&
        (!straddle_detected ||
         (bp_branch_found && bp_taken && !subgroup_split_before_ctl_c));

    // Decode no longer consumes a separate packet_buf_in bypass. Flow-through
    // is an IBuffer-owned empty-buffer delivery observation.
    assign packet_flowthrough_candidate = packet_buf_flowthrough_c;
    assign packet_flowthrough_owner_match_c =
        packet_flowthrough_candidate &&
        packet_buf_owner_match_c;
    assign packet_flowthrough_valid = packet_buf_flowthrough_c;

    assign f2_owner_completion_candidate_c =
        f2_will_emit_c &&
        packet_buf_in.valid &&
        f2_work_owner_complete_c &&
        f2_work_ftq_valid_c &&
        !redirect_valid &&
        !frontend_hold;
    assign f2_owner_delivery_push_c =
        packet_buf_enq &&
        f2_work_ftq_valid_c &&
        f2_ftq_owner_live_c &&
        !f2_work_owner_delivered_c &&
        !redirect_valid &&
        !frontend_hold;
    assign ftq_delivery_push_valid = f2_owner_delivery_push_c;
    assign ftq_ifu_pop_valid =
        f2_owner_completion_candidate_c &&
        f2_ftq_owner_live_c;
    assign ftq_commit_pop_valid =
        (packet_buf_deq_fire &&
         packet_buf_owner_match_c &&
         packet_buf_head_owner_complete_c);
    assign ftq_pop_valid = ftq_ifu_pop_valid;

    // =========================================================================
    // BPU redirect to F1
    // =========================================================================
    assign req_redirect_c  = f2_will_emit_c &&
                             bp_branch_found && bp_taken &&
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

        if (f2_will_emit_c &&
            bp_branch_found && bp_taken &&
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

        if (f2_work_valid_c &&
            f2_data_valid &&
            f2_will_emit_c &&
            predecode_ctl_found &&
            (predecode_ctl_type == BT_COND) &&
            (predecode_ctl_slot < final_count) &&
            !fe_stall && !redirect_valid) begin
            tage_spec_update_valid = 1'b1;
            tage_spec_taken =
                bp_branch_found && bp_taken &&
                (bp_type == BT_COND) &&
                (bp_branch_slot == predecode_ctl_slot);
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
            if (straddle_detected &&
                f2_work_valid_c &&
                f2_data_valid) begin
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
        packet_owner_from_subgroup_c = f2_work_ftq_entry_c.pred_from_subgroup;

        // The subgroup seed is cleared as soon as the split request issues, so
        // the eventual packet can no longer rely on the FTQ bit alone. Recover
        // subgroup ownership from the live seed relation at packet build time.
        if (subgroup_seed_valid_r &&
            (f2_work_pc_c == subgroup_seed_parent_pc_r) &&
            predecode_ctl_found &&
            (predecode_ctl_pc == subgroup_seed_owner_pc_r)) begin
            packet_owner_from_subgroup_c = 1'b1;
        end
    end

    always_comb begin
        packet_buf_enq =
            f2_will_emit_c &&
            !redirect_valid &&
            !frontend_hold;
        packet_buf_in  = '0;

        if (f2_will_emit_c) begin
            packet_buf_in.valid            = 1'b1;
            packet_buf_in.ftq_idx          = f2_work_ftq_idx_c;
            packet_buf_in.ftq_epoch        = f2_work_ftq_epoch_c;
            packet_buf_in.ftq_alloc_tag    = f2_work_ftq_alloc_tag_c;
            // A line-end straddle only keeps FTQ ownership open when the
            // frontend still needs the sequential continuation. If this packet
            // already ends in a taken redirect, the post-branch straddling
            // bytes are dead path and must not block FTQ pop. The Dhrystone
            // livelock at tag 387 was exactly this case: CALL at 0x8000213a
            // redirected to 0x8000239c, but the trailing dead-path straddle
            // left ftq_owner_complete low forever.
            packet_buf_in.ftq_owner_complete = f2_work_owner_complete_c;
            packet_buf_in.ftq_block_pc     = f2_work_ftq_entry_c.block_pc;
            packet_buf_in.ftq_start_offset = f2_work_ftq_entry_c.start_offset;
            packet_buf_in.ifu_line_addr    = f2_ifu_line_addr_c;
            packet_buf_in.ifu_line_reused  = f2_line_state_use_c;
            packet_buf_in.ftq_bp_lookup_pc =
                f2_work_ftq_entry_c.block_pc +
                64'(f2_work_ftq_entry_c.start_offset);
            packet_buf_in.ftq_pred_valid   =
                f2_work_ftq_entry_c.pred_ctl_valid;
            packet_buf_in.ftq_pred_taken   =
                f2_work_ftq_entry_c.pred_ctl_taken;
            packet_buf_in.ftq_pred_offset  =
                f2_work_ftq_entry_c.pred_ctl_offset;
            packet_buf_in.ftq_pred_type    =
                f2_work_ftq_entry_c.pred_ctl_type;
            packet_buf_in.ftq_pred_target  =
                f2_work_ftq_entry_c.pred_ctl_target;
            packet_buf_in.ftq_pred_from_subgroup =
                packet_owner_from_subgroup_c;
            packet_buf_in.pd_ctl_valid     =
                predecode_ctl_found && (predecode_ctl_slot < final_count);
            packet_buf_in.pd_ctl_slot      = predecode_ctl_slot;
            packet_buf_in.pd_ctl_type      = predecode_ctl_type;
            packet_buf_in.pd_ctl_target    = predecode_ctl_target;
            packet_buf_in.fetch_count      = final_count;
            // The fetch packet now carries the request-time repair snapshot
            // owned by its FTQ entry instead of the live frontend state.
            if (f2_work_ftq_valid_c) begin
                packet_buf_in.fetch_bp_ras_tos =
                    f2_work_ftq_entry_c.ras_tos_snapshot;
                packet_buf_in.fetch_bp_ras_top =
                    f2_work_ftq_entry_c.ras_top_snapshot;
                packet_buf_in.fetch_bp_ghr =
                    f2_work_ftq_entry_c.ghr_snapshot;
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

        fetch_packet_out_valid = packet_buf_valid;
        fetch_packet_out       = packet_buf_head;

        if (fetch_packet_out_valid) begin
            fetch_count      = fetch_packet_out.fetch_count;
            fetch_bp_owner_valid = fetch_packet_out.pd_ctl_valid;
            fetch_bp_owner_slot  = fetch_packet_out.pd_ctl_slot;
            fetch_bp_owner_from_subgroup =
                fetch_packet_out.pd_ctl_valid &&
                fetch_packet_out.ftq_pred_from_subgroup;
            fetch_bp_lookup_pc   = fetch_packet_out.ftq_bp_lookup_pc;
            fetch_bp_ras_tos = fetch_packet_out.fetch_bp_ras_tos;
            fetch_bp_ras_top = fetch_packet_out.fetch_bp_ras_top;
            fetch_bp_ghr     = fetch_packet_out.fetch_bp_ghr;
            fetch_is_rvc     = fetch_packet_out.fetch_is_rvc;
            fetch_bp_taken   = fetch_packet_out.fetch_bp_taken;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                fetch_insn[i]      = fetch_packet_out.fetch_insn[i];
                fetch_pc[i]        = fetch_packet_out.fetch_pc[i];
                fetch_bp_target[i] = fetch_packet_out.fetch_bp_target[i];
            end
        end
    end

`ifdef SIMULATION
    logic delivery_check_en;
    logic delivery_strict_en;
    logic delivery_score_valid_r;
    logic [FTQ_IDX_BITS-1:0] delivery_score_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] delivery_score_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] delivery_score_tag_r;
    logic [63:0] delivery_score_next_pc_r;
    logic delivery_score_complete_r;
    logic delivery_fire_c;
    logic delivery_score_owner_match_c;
    integer delivery_check_owner_switch_count;
    integer delivery_check_noncontig_count;
    localparam int DELIVERY_CHECK_PRINT_LIMIT = 16;

    initial begin
        delivery_check_en = $test$plusargs("FETCH_DELIVERY_CHECK");
        delivery_strict_en = $test$plusargs("FETCH_DELIVERY_STRICT");
    end

    assign delivery_fire_c =
        fetch_packet_out_valid &&
        fetch_packet_out.valid &&
        (fetch_packet_out.fetch_count != 3'd0) &&
        !backend_stall &&
        !frontend_hold;
    assign delivery_score_owner_match_c =
        delivery_score_valid_r &&
        (fetch_packet_out.ftq_idx == delivery_score_idx_r) &&
        (fetch_packet_out.ftq_epoch == delivery_score_epoch_r) &&
        (fetch_packet_out.ftq_alloc_tag == delivery_score_tag_r);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delivery_score_valid_r   <= 1'b0;
            delivery_score_idx_r     <= '0;
            delivery_score_epoch_r   <= '0;
            delivery_score_tag_r     <= '0;
            delivery_score_next_pc_r <= '0;
            delivery_score_complete_r <= 1'b0;
            delivery_check_owner_switch_count <= 0;
            delivery_check_noncontig_count <= 0;
        end else if (redirect_valid) begin
            delivery_score_valid_r   <= 1'b0;
            delivery_score_idx_r     <= '0;
            delivery_score_epoch_r   <= '0;
            delivery_score_tag_r     <= '0;
            delivery_score_next_pc_r <= '0;
            delivery_score_complete_r <= 1'b0;
        end else if (delivery_check_en && delivery_fire_c) begin
            automatic logic [63:0] expected_pc;
            automatic logic packet_redirect_taken;
            automatic logic [63:0] packet_redirect_target;

            if (delivery_score_valid_r &&
                !delivery_score_owner_match_c &&
                !delivery_score_complete_r) begin
                if (delivery_check_owner_switch_count <
                    DELIVERY_CHECK_PRINT_LIMIT) begin
                    $display("[FETCH_DELIVERY_CHECK] owner switched before complete old_idx=%0d old_tag=%0d old_next=%016h new_idx=%0d new_tag=%0d new_pc0=%016h",
                             delivery_score_idx_r,
                             delivery_score_tag_r,
                             delivery_score_next_pc_r,
                             fetch_packet_out.ftq_idx,
                             fetch_packet_out.ftq_alloc_tag,
                             fetch_packet_out.fetch_pc[0]);
                end
                delivery_check_owner_switch_count <=
                    delivery_check_owner_switch_count + 1;
            end

            expected_pc = delivery_score_owner_match_c
                ? delivery_score_next_pc_r
                : (fetch_packet_out.ftq_block_pc +
                   64'(fetch_packet_out.ftq_start_offset));
            packet_redirect_taken = 1'b0;
            packet_redirect_target = '0;

            if (fetch_packet_out.pd_ctl_valid &&
                (fetch_packet_out.pd_ctl_slot <
                 fetch_packet_out.fetch_count)) begin
                case (fetch_packet_out.pd_ctl_type)
                    BT_COND: begin
                        if (fetch_packet_out.ftq_pred_valid &&
                            fetch_packet_out.ftq_pred_taken &&
                            (fetch_packet_out.ftq_pred_target ==
                             fetch_packet_out.pd_ctl_target)) begin
                            packet_redirect_taken = 1'b1;
                            packet_redirect_target =
                                fetch_packet_out.pd_ctl_target;
                        end
                    end
                    BT_JAL,
                    BT_CALL: begin
                        packet_redirect_taken = 1'b1;
                        packet_redirect_target =
                            fetch_packet_out.pd_ctl_target;
                    end
                    BT_JALR,
                    BT_RET: begin
                        if (fetch_packet_out.pd_ctl_target != 64'd0) begin
                            packet_redirect_taken = 1'b1;
                            packet_redirect_target =
                                fetch_packet_out.pd_ctl_target;
                        end
                    end
                    default: begin
                    end
                endcase
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (i < int'(fetch_packet_out.fetch_count)) begin
                    if (fetch_packet_out.fetch_pc[i] != expected_pc) begin
                        if (delivery_check_noncontig_count <
                            DELIVERY_CHECK_PRINT_LIMIT) begin
                            $display("[FETCH_DELIVERY_CHECK] non-contiguous owner stream idx=%0d tag=%0d slot=%0d expected=%016h got=%016h count=%0d complete=%b flowthrough=%b deq=%b",
                                     fetch_packet_out.ftq_idx,
                                     fetch_packet_out.ftq_alloc_tag,
                                     i,
                                     expected_pc,
                                     fetch_packet_out.fetch_pc[i],
                                     fetch_packet_out.fetch_count,
                                     fetch_packet_out.ftq_owner_complete,
                                     packet_flowthrough_valid,
                                     packet_buf_deq);
                            $display("[FETCH_DELIVERY_CHECK_DETAIL] pkt_block=%016h pkt_start=%0d pkt_lookup=%016h ifu_line=%014h reused=%b pred_valid=%b pred_taken=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_valid=%b pd_slot=%0d pd_type=%0d pd_target=%016h",
                                     fetch_packet_out.ftq_block_pc,
                                     fetch_packet_out.ftq_start_offset,
                                     fetch_packet_out.ftq_bp_lookup_pc,
                                     fetch_packet_out.ifu_line_addr,
                                     fetch_packet_out.ifu_line_reused,
                                     fetch_packet_out.ftq_pred_valid,
                                     fetch_packet_out.ftq_pred_taken,
                                     fetch_packet_out.ftq_pred_offset,
                                     fetch_packet_out.ftq_pred_type,
                                     fetch_packet_out.ftq_pred_target,
                                     fetch_packet_out.pd_ctl_valid,
                                     fetch_packet_out.pd_ctl_slot,
                                     fetch_packet_out.pd_ctl_type,
                                     fetch_packet_out.pd_ctl_target);
                            $display("[FETCH_DELIVERY_CHECK_F2] work_pc=%016h work_valid=%b work_idx=%0d work_tag=%0d work_block=%016h work_start=%0d owner_live=%b ftq_enq=%b enq_idx=%0d enq_tag=%0d enq_block=%016h enq_start=%0d ftq_pop=%b count_ifu_wb=%0d next_owner=%b next_idx=%0d next_tag=%0d next_block=%016h next_start=%0d",
                                     f2_work_pc_c,
                                     f2_work_ftq_valid_c,
                                     f2_work_ftq_idx_c,
                                     f2_work_ftq_alloc_tag_c,
                                     f2_work_ftq_entry_c.block_pc,
                                     f2_work_ftq_entry_c.start_offset,
                                     f2_ftq_owner_live_c,
                                     ftq_enq_valid,
                                     ftq_enq_idx,
                                     ftq_enq_tag,
                                     ftq_enq_entry_c.block_pc,
                                     ftq_enq_entry_c.start_offset,
                                     ftq_ifu_pop_valid,
                                     ftq_count_ifu_to_wb,
                                     ftq_next_ifu_owner_valid,
                                     ftq_next_ifu_owner_idx,
                                     ftq_next_ifu_owner_tag,
                                     ftq_next_ifu_owner_entry.block_pc,
                                     ftq_next_ifu_owner_entry.start_offset);
                        end
                        delivery_check_noncontig_count <=
                            delivery_check_noncontig_count + 1;
                        if (delivery_strict_en)
                            $fatal(1, "fetch delivery PC stream is non-contiguous");
                    end
                    if (fetch_packet_out.fetch_bp_taken[i]) begin
                        expected_pc = fetch_packet_out.fetch_bp_target[i];
                    end else begin
                        expected_pc = fetch_packet_out.fetch_pc[i] +
                            (fetch_packet_out.fetch_is_rvc[i] ? 64'd2 : 64'd4);
                    end
                end
            end
            if (packet_redirect_taken) begin
                expected_pc = packet_redirect_target;
            end

            delivery_score_valid_r   <= 1'b1;
            delivery_score_idx_r     <= fetch_packet_out.ftq_idx;
            delivery_score_epoch_r   <= fetch_packet_out.ftq_epoch;
            delivery_score_tag_r     <= fetch_packet_out.ftq_alloc_tag;
            delivery_score_next_pc_r <= expected_pc;
            delivery_score_complete_r <= fetch_packet_out.ftq_owner_complete;
        end
    end

    final begin
        if (delivery_check_en) begin
            $display("");
            $display("=== FETCH DELIVERY CHECK ===");
            $display("strict mode                  : %0d", delivery_strict_en);
            $display("owner switch before complete : %0d",
                     delivery_check_owner_switch_count);
            $display("non-contiguous packet PCs    : %0d",
                     delivery_check_noncontig_count);
        end
    end

    // Same-line owner contract monitor. This is intentionally simulation-only:
    // it verifies the refactor contract that I-cache line data may be shared,
    // but packet delivery remains owned by FTQ idx/epoch/tag.
    logic owner_check_en;
    logic owner_strict_en;
    logic owner_alloc_valid_r;
    logic [63:LINE_BITS] owner_alloc_line_r;
    logic [FTQ_IDX_BITS-1:0] owner_alloc_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_alloc_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_alloc_tag_r;
    logic owner_packet_valid_r;
    logic [63:LINE_BITS] owner_packet_line_r;
    logic [FTQ_IDX_BITS-1:0] owner_packet_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_packet_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_packet_tag_r;
    logic owner_stream_valid_r;
    logic [FTQ_IDX_BITS-1:0] owner_stream_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] owner_stream_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] owner_stream_tag_r;
    logic [63:0] owner_stream_next_pc_r;
    integer owner_same_line_diff_owner_alloc_count;
    integer owner_same_line_same_owner_packet_count;
    integer owner_same_line_diff_owner_packet_count;
    integer owner_line_share_same_owner_count;
    integer owner_line_share_diff_owner_count;
    integer owner_packet_line_mismatch_count;
    integer owner_packet_duplicate_pc_count;
    integer owner_packet_skipped_pc_count;
    localparam int OWNER_CHECK_PRINT_LIMIT = 16;

    initial begin
        owner_check_en = $test$plusargs("FETCH_OWNER_CHECK");
        owner_strict_en = $test$plusargs("FETCH_OWNER_STRICT");
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner_alloc_valid_r <= 1'b0;
            owner_alloc_line_r  <= '0;
            owner_alloc_idx_r   <= '0;
            owner_alloc_epoch_r <= '0;
            owner_alloc_tag_r   <= '0;
            owner_packet_valid_r <= 1'b0;
            owner_packet_line_r  <= '0;
            owner_packet_idx_r   <= '0;
            owner_packet_epoch_r <= '0;
            owner_packet_tag_r   <= '0;
            owner_stream_valid_r <= 1'b0;
            owner_stream_idx_r   <= '0;
            owner_stream_epoch_r <= '0;
            owner_stream_tag_r   <= '0;
            owner_stream_next_pc_r <= '0;
            owner_same_line_diff_owner_alloc_count <= 0;
            owner_same_line_same_owner_packet_count <= 0;
            owner_same_line_diff_owner_packet_count <= 0;
            owner_line_share_same_owner_count <= 0;
            owner_line_share_diff_owner_count <= 0;
            owner_packet_line_mismatch_count <= 0;
            owner_packet_duplicate_pc_count <= 0;
            owner_packet_skipped_pc_count <= 0;
        end else if (redirect_valid) begin
            owner_alloc_valid_r <= 1'b0;
            owner_packet_valid_r <= 1'b0;
            owner_stream_valid_r <= 1'b0;
        end else if (owner_check_en) begin
            if (ftq_enq_valid) begin
                automatic logic same_alloc_owner;
                same_alloc_owner =
                    owner_alloc_valid_r &&
                    (ftq_enq_idx == owner_alloc_idx_r) &&
                    (ftq_enq_epoch == owner_alloc_epoch_r) &&
                    (ftq_enq_tag == owner_alloc_tag_r);

                if (owner_alloc_valid_r &&
                    (ftq_enq_entry_c.block_pc[63:LINE_BITS] ==
                     owner_alloc_line_r) &&
                    !same_alloc_owner) begin
                    if (owner_same_line_diff_owner_alloc_count <
                        OWNER_CHECK_PRINT_LIMIT) begin
                        $display("[FETCH_OWNER_CHECK] same-line alloc to new owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_start=%0d",
                                 owner_alloc_line_r,
                                 owner_alloc_idx_r,
                                 owner_alloc_tag_r,
                                 ftq_enq_idx,
                                 ftq_enq_tag,
                                 ftq_enq_entry_c.start_offset);
                    end
                    owner_same_line_diff_owner_alloc_count <=
                        owner_same_line_diff_owner_alloc_count + 1;
                end

                owner_alloc_valid_r <= 1'b1;
                owner_alloc_line_r  <= ftq_enq_entry_c.block_pc[63:LINE_BITS];
                owner_alloc_idx_r   <= ftq_enq_idx;
                owner_alloc_epoch_r <= ftq_enq_epoch;
                owner_alloc_tag_r   <= ftq_enq_tag;
            end

            if (delivery_fire_c) begin
                automatic logic packet_same_owner;
                automatic logic stream_same_owner;
                automatic logic [63:LINE_BITS] packet_line;
                automatic logic [63:LINE_BITS] packet_pc0_line;
                automatic logic packet_line_metadata_ok;
                automatic logic [63:0] expected_pc;
                automatic logic packet_redirect_taken;
                automatic logic [63:0] packet_redirect_target;

                packet_pc0_line =
                    fetch_packet_out.fetch_pc[0][63:LINE_BITS];
                packet_line_metadata_ok =
                    (fetch_packet_out.ifu_line_addr == packet_pc0_line) ||
                    ((fetch_packet_out.fetch_pc[0][5:0] == 6'd62) &&
                     (fetch_packet_out.ifu_line_addr ==
                      (packet_pc0_line + (64-LINE_BITS)'(1))));
                if (!packet_line_metadata_ok) begin
                    if (owner_packet_line_mismatch_count <
                        OWNER_CHECK_PRINT_LIMIT) begin
                        $display("[FETCH_OWNER_CHECK] packet line metadata mismatch owner idx=%0d tag=%0d meta=%014h pc0=%016h",
                                 fetch_packet_out.ftq_idx,
                                 fetch_packet_out.ftq_alloc_tag,
                                 fetch_packet_out.ifu_line_addr,
                                 fetch_packet_out.fetch_pc[0]);
                    end
                    owner_packet_line_mismatch_count <=
                        owner_packet_line_mismatch_count + 1;
                    if (owner_strict_en)
                        $fatal(1, "fetch packet IFU line metadata mismatch");
                end
                packet_line = packet_pc0_line;
                packet_same_owner =
                    owner_packet_valid_r &&
                    (fetch_packet_out.ftq_idx == owner_packet_idx_r) &&
                    (fetch_packet_out.ftq_epoch == owner_packet_epoch_r) &&
                    (fetch_packet_out.ftq_alloc_tag == owner_packet_tag_r);
                stream_same_owner =
                    owner_stream_valid_r &&
                    (fetch_packet_out.ftq_idx == owner_stream_idx_r) &&
                    (fetch_packet_out.ftq_epoch == owner_stream_epoch_r) &&
                    (fetch_packet_out.ftq_alloc_tag == owner_stream_tag_r);

                if (owner_packet_valid_r &&
                    (packet_line == owner_packet_line_r)) begin
                    if (packet_same_owner) begin
                        owner_same_line_same_owner_packet_count <=
                            owner_same_line_same_owner_packet_count + 1;
                    end else begin
                        if (owner_same_line_diff_owner_packet_count <
                            OWNER_CHECK_PRINT_LIMIT) begin
                            $display("[FETCH_OWNER_CHECK] same-line packet switched owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_pc0=%016h",
                                     packet_line,
                                     owner_packet_idx_r,
                                     owner_packet_tag_r,
                                     fetch_packet_out.ftq_idx,
                                     fetch_packet_out.ftq_alloc_tag,
                                     fetch_packet_out.fetch_pc[0]);
                        end
                        owner_same_line_diff_owner_packet_count <=
                            owner_same_line_diff_owner_packet_count + 1;
                    end
                end

                if (fetch_packet_out.ifu_line_reused) begin
                    if (packet_same_owner) begin
                        owner_line_share_same_owner_count <=
                            owner_line_share_same_owner_count + 1;
                    end else begin
                        owner_line_share_diff_owner_count <=
                            owner_line_share_diff_owner_count + 1;
                        if (owner_line_share_diff_owner_count <
                            OWNER_CHECK_PRINT_LIMIT) begin
                            $display("[FETCH_OWNER_CHECK] line data reused across owner line=%014h old_idx=%0d old_tag=%0d new_idx=%0d new_tag=%0d new_pc0=%016h",
                                     packet_line,
                                     owner_packet_idx_r,
                                     owner_packet_tag_r,
                                     fetch_packet_out.ftq_idx,
                                     fetch_packet_out.ftq_alloc_tag,
                                     fetch_packet_out.fetch_pc[0]);
                        end
                    end
                end

                expected_pc = stream_same_owner
                    ? owner_stream_next_pc_r
                    : (fetch_packet_out.ftq_block_pc +
                       64'(fetch_packet_out.ftq_start_offset));
                packet_redirect_taken = 1'b0;
                packet_redirect_target = '0;

                if (fetch_packet_out.pd_ctl_valid &&
                    (fetch_packet_out.pd_ctl_slot <
                     fetch_packet_out.fetch_count)) begin
                    case (fetch_packet_out.pd_ctl_type)
                        BT_COND: begin
                            if (fetch_packet_out.ftq_pred_valid &&
                                fetch_packet_out.ftq_pred_taken &&
                                (fetch_packet_out.ftq_pred_target ==
                                 fetch_packet_out.pd_ctl_target)) begin
                                packet_redirect_taken = 1'b1;
                                packet_redirect_target =
                                    fetch_packet_out.pd_ctl_target;
                            end
                        end
                        BT_JAL,
                        BT_CALL: begin
                            packet_redirect_taken = 1'b1;
                            packet_redirect_target =
                                fetch_packet_out.pd_ctl_target;
                        end
                        BT_JALR,
                        BT_RET: begin
                            if (fetch_packet_out.pd_ctl_target != 64'd0) begin
                                packet_redirect_taken = 1'b1;
                                packet_redirect_target =
                                    fetch_packet_out.pd_ctl_target;
                            end
                        end
                        default: begin
                        end
                    endcase
                end

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (i < int'(fetch_packet_out.fetch_count)) begin
                        if (fetch_packet_out.fetch_pc[i] != expected_pc) begin
                            if (fetch_packet_out.fetch_pc[i] < expected_pc) begin
                                if (owner_packet_duplicate_pc_count <
                                    OWNER_CHECK_PRINT_LIMIT) begin
                                    $display("[FETCH_OWNER_CHECK] duplicate/replayed PC owner idx=%0d tag=%0d slot=%0d expected=%016h got=%016h",
                                             fetch_packet_out.ftq_idx,
                                             fetch_packet_out.ftq_alloc_tag,
                                             i,
                                             expected_pc,
                                             fetch_packet_out.fetch_pc[i]);
                                end
                                owner_packet_duplicate_pc_count <=
                                    owner_packet_duplicate_pc_count + 1;
                            end else begin
                                if (owner_packet_skipped_pc_count <
                                    OWNER_CHECK_PRINT_LIMIT) begin
                                    $display("[FETCH_OWNER_CHECK] skipped PC owner idx=%0d tag=%0d slot=%0d expected=%016h got=%016h",
                                             fetch_packet_out.ftq_idx,
                                             fetch_packet_out.ftq_alloc_tag,
                                             i,
                                             expected_pc,
                                             fetch_packet_out.fetch_pc[i]);
                                    $display("[FETCH_OWNER_CHECK_DETAIL] pkt_block=%016h pkt_start=%0d pkt_lookup=%016h ifu_line=%014h reused=%b pred_valid=%b pred_taken=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_valid=%b pd_slot=%0d pd_type=%0d pd_target=%016h stream_same=%b packet_same=%b",
                                             fetch_packet_out.ftq_block_pc,
                                             fetch_packet_out.ftq_start_offset,
                                             fetch_packet_out.ftq_bp_lookup_pc,
                                             fetch_packet_out.ifu_line_addr,
                                             fetch_packet_out.ifu_line_reused,
                                             fetch_packet_out.ftq_pred_valid,
                                             fetch_packet_out.ftq_pred_taken,
                                             fetch_packet_out.ftq_pred_offset,
                                             fetch_packet_out.ftq_pred_type,
                                             fetch_packet_out.ftq_pred_target,
                                             fetch_packet_out.pd_ctl_valid,
                                             fetch_packet_out.pd_ctl_slot,
                                             fetch_packet_out.pd_ctl_type,
                                             fetch_packet_out.pd_ctl_target,
                                             stream_same_owner,
                                             packet_same_owner);
                                    $display("[FETCH_OWNER_CHECK_F2] work_pc=%016h work_valid=%b work_idx=%0d work_tag=%0d work_block=%016h work_start=%0d owner_live=%b ftq_enq=%b enq_idx=%0d enq_tag=%0d enq_block=%016h enq_start=%0d ftq_pop=%b count_ifu_wb=%0d next_owner=%b next_idx=%0d next_tag=%0d next_block=%016h next_start=%0d",
                                             f2_work_pc_c,
                                             f2_work_ftq_valid_c,
                                             f2_work_ftq_idx_c,
                                             f2_work_ftq_alloc_tag_c,
                                             f2_work_ftq_entry_c.block_pc,
                                             f2_work_ftq_entry_c.start_offset,
                                             f2_ftq_owner_live_c,
                                             ftq_enq_valid,
                                             ftq_enq_idx,
                                             ftq_enq_tag,
                                             ftq_enq_entry_c.block_pc,
                                             ftq_enq_entry_c.start_offset,
                                             ftq_ifu_pop_valid,
                                             ftq_count_ifu_to_wb,
                                             ftq_next_ifu_owner_valid,
                                             ftq_next_ifu_owner_idx,
                                             ftq_next_ifu_owner_tag,
                                             ftq_next_ifu_owner_entry.block_pc,
                                             ftq_next_ifu_owner_entry.start_offset);
                                end
                                owner_packet_skipped_pc_count <=
                                    owner_packet_skipped_pc_count + 1;
                            end
                            if (owner_strict_en)
                                $fatal(1, "fetch owner stream duplicate or skip");
                        end
                        if (fetch_packet_out.fetch_bp_taken[i]) begin
                            expected_pc = fetch_packet_out.fetch_bp_target[i];
                        end else begin
                            expected_pc = fetch_packet_out.fetch_pc[i] +
                                (fetch_packet_out.fetch_is_rvc[i]
                                     ? 64'd2
                                     : 64'd4);
                        end
                    end
                end
                if (packet_redirect_taken)
                    expected_pc = packet_redirect_target;

                owner_packet_valid_r <= 1'b1;
                owner_packet_line_r  <= packet_line;
                owner_packet_idx_r   <= fetch_packet_out.ftq_idx;
                owner_packet_epoch_r <= fetch_packet_out.ftq_epoch;
                owner_packet_tag_r   <= fetch_packet_out.ftq_alloc_tag;
                owner_stream_valid_r <= 1'b1;
                owner_stream_idx_r   <= fetch_packet_out.ftq_idx;
                owner_stream_epoch_r <= fetch_packet_out.ftq_epoch;
                owner_stream_tag_r   <= fetch_packet_out.ftq_alloc_tag;
                owner_stream_next_pc_r <= expected_pc;
            end
        end
    end

    final begin
        if (owner_check_en) begin
            $display("");
            $display("=== FETCH OWNER CHECK ===");
            $display("strict mode                    : %0d", owner_strict_en);
            $display("same-line alloc new owner      : %0d",
                     owner_same_line_diff_owner_alloc_count);
            $display("same-line packet same owner    : %0d",
                     owner_same_line_same_owner_packet_count);
            $display("same-line packet diff owner    : %0d",
                     owner_same_line_diff_owner_packet_count);
            $display("line share same owner          : %0d",
                     owner_line_share_same_owner_count);
            $display("line share diff owner          : %0d",
                     owner_line_share_diff_owner_count);
            $display("packet line metadata mismatch  : %0d",
                     owner_packet_line_mismatch_count);
            $display("owner duplicate/replayed PCs   : %0d",
                     owner_packet_duplicate_pc_count);
            $display("owner skipped PCs              : %0d",
                     owner_packet_skipped_pc_count);
        end
    end

    // XiangShan-style catch-up opportunity probe.  This is observation-only:
    // it counts cycles where F2 is suppressing an already emitted packet while
    // F1 already names the next packet, the next line is present in the NLPB,
    // and an independent F1 BTB lookup can name the predicted redirect target.
    logic xs_catchup_probe_en;
    logic xs_catchup_trace_en;
    logic xs_catchup_base_c;
    logic xs_catchup_fetch0_c;
    logic xs_catchup_crossline_c;
    logic xs_catchup_nlpb_c;
    logic xs_catchup_aux_taken_c;
    logic xs_catchup_recoverable_c;
    logic xs_catchup_target_last_c;

    integer xs_catchup_base_cycles;
    integer xs_catchup_fetch0_cycles;
    integer xs_catchup_crossline_cycles;
    integer xs_catchup_nlpb_cycles;
    integer xs_catchup_aux_taken_cycles;
    integer xs_catchup_recoverable_cycles;
    integer xs_catchup_target_last_cycles;
    integer xs_catchup_ret_cycles;
    integer xs_packet_buf_stale_owner_cycles;
    integer xs_ftq_empty_cycles;
    integer xs_ftq_full_cycles;
    integer xs_ftq_occ_sum;
    integer xs_ftq_occ_max;
    integer xs_ftq_occ_hist [0:5];
    integer xs_packet_buf_empty_cycles;
    integer xs_packet_buf_full_cycles;
    integer xs_packet_buf_occ_sum;
    integer xs_packet_buf_occ_max;
    integer xs_packet_buf_occ_hist [0:4];
    integer xs_ftq_alloc_cycles;
    integer xs_ftq_pop_cycles;
    integer xs_ftq_alloc_pop_cycles;
    integer xs_ic_req_valid_cycles;
    integer xs_ic_req_stall_frontend_hold_cycles;
    integer xs_ic_req_stall_packet_full_cycles;
    integer xs_ic_req_stall_ftq_full_cycles;
    integer xs_backend_stall_cycles;
    integer xs_backend_stall_packet_ready_cycles;
    integer xs_frontend_hold_cycles;
    integer xs_dup_last_emit_cycles;
    integer xs_dup_replay_guard_cycles;
    integer xs_dup_both_reasons_cycles;
    integer xs_f2_owner_no_head_cycles;
    integer xs_f2_owner_idx_mismatch_cycles;
    integer xs_f2_owner_epoch_mismatch_cycles;
    integer xs_f2_owner_tag_mismatch_cycles;
    integer xs_f2_owner_live_cycles;
    integer xs_f2_cursor_wb_no_head_cycles;
    integer xs_f2_cursor_wb_idx_skew_cycles;
    integer xs_f2_cursor_wb_epoch_skew_cycles;
    integer xs_f2_cursor_wb_tag_skew_cycles;
    integer xs_packet_stale_no_head_cycles;
    integer xs_packet_stale_idx_mismatch_cycles;
    integer xs_packet_stale_epoch_mismatch_cycles;
    integer xs_packet_stale_tag_mismatch_cycles;
    integer xs_flowthrough_candidate_cycles;
    integer xs_flowthrough_owner_miss_cycles;
    integer xs_flowthrough_incomplete_owner_cycles;
    integer xs_flowthrough_valid_cycles;

    localparam int XS_CATCHUP_TOPN = 8;
    logic [63:0] xs_catchup_top_pc [0:XS_CATCHUP_TOPN-1];
    integer xs_catchup_top_count [0:XS_CATCHUP_TOPN-1];
    logic [63:0] xs_dup_top_pc [0:XS_CATCHUP_TOPN-1];
    integer xs_dup_top_count [0:XS_CATCHUP_TOPN-1];

    logic xs_dup_last_emit_c;
    logic xs_dup_replay_guard_c;
    logic xs_f2_owner_no_head_c;
    logic xs_f2_owner_idx_mismatch_c;
    logic xs_f2_owner_epoch_mismatch_c;
    logic xs_f2_owner_tag_mismatch_c;
    logic xs_f2_cursor_wb_no_head_c;
    logic xs_f2_cursor_wb_idx_skew_c;
    logic xs_f2_cursor_wb_epoch_skew_c;
    logic xs_f2_cursor_wb_tag_skew_c;
    logic xs_packet_stale_no_head_c;
    logic xs_packet_stale_idx_mismatch_c;
    logic xs_packet_stale_epoch_mismatch_c;
    logic xs_packet_stale_tag_mismatch_c;
    logic xs_flowthrough_incomplete_owner_c;

    initial begin
        xs_catchup_probe_en = 1'b0;
        xs_catchup_trace_en = 1'b0;
        if ($test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP") ||
            $test$plusargs("TRACE_XS_CATCHUP")) begin
            xs_catchup_probe_en = 1'b1;
        end
        if ($test$plusargs("TRACE_XS_CATCHUP"))
            xs_catchup_trace_en = 1'b1;
    end

    assign xs_catchup_base_c =
        f2_duplicate_suppressed_c &&
        f2_last_emit_hit_c &&
        f1_valid &&
        (f1_pc == f2_last_emit_next_pc_r) &&
        packet_buf_empty &&
        !redirect_valid &&
        !backend_stall &&
        !frontend_hold &&
        !fe_stall;
    assign xs_catchup_fetch0_c =
        xs_catchup_base_c && (fetch_count == 3'd0);
    assign xs_catchup_crossline_c =
        xs_catchup_base_c &&
        (f1_pc[63:LINE_BITS] != f2_work_pc_c[63:LINE_BITS]);
    assign xs_catchup_nlpb_c =
        xs_catchup_base_c && nlpb_aux_hit_comb;
    assign xs_catchup_aux_taken_c =
        xs_catchup_base_c &&
        f1_aux_pred_ctl_valid_c &&
        f1_aux_pred_ctl_taken_c;
    assign xs_catchup_recoverable_c =
        xs_catchup_fetch0_c &&
        xs_catchup_crossline_c &&
        nlpb_aux_hit_comb &&
        f1_aux_pred_ctl_valid_c &&
        f1_aux_pred_ctl_taken_c;
    assign xs_catchup_target_last_c =
        xs_catchup_recoverable_c &&
        (f1_aux_pred_ctl_target_c == f2_last_emit_pc_r);
    assign xs_dup_last_emit_c =
        f2_duplicate_suppressed_c &&
        f2_last_emit_valid_r &&
        (f2_last_emit_pc_r == f2_work_pc_c);
    assign xs_dup_replay_guard_c =
        f2_duplicate_suppressed_c &&
        f2_replay_block_hit_c;
    assign xs_f2_cursor_wb_no_head_c =
        f2_work_ftq_valid_c && !ftq_ifu_wb_owner_valid;
    assign xs_f2_cursor_wb_idx_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c != ftq_ifu_wb_owner_idx);
    assign xs_f2_cursor_wb_epoch_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c != ftq_current_epoch);
    assign xs_f2_cursor_wb_tag_skew_c =
        f2_work_ftq_valid_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c != ftq_ifu_wb_owner_tag);
    assign xs_f2_owner_no_head_c =
        f2_owner_completion_candidate_c && !ftq_ifu_wb_owner_valid;
    assign xs_f2_owner_idx_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c != ftq_ifu_wb_owner_idx);
    assign xs_f2_owner_epoch_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c != ftq_current_epoch);
    assign xs_f2_owner_tag_mismatch_c =
        f2_owner_completion_candidate_c && ftq_ifu_wb_owner_valid &&
        (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
        (f2_work_ftq_epoch_c == ftq_current_epoch) &&
        (f2_work_ftq_alloc_tag_c != ftq_ifu_wb_owner_tag);
    assign xs_packet_stale_no_head_c =
        packet_buf_valid && packet_buf_head.valid && !ftq_commit_owner_valid;
    assign xs_packet_stale_idx_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx != ftq_commit_owner_idx);
    assign xs_packet_stale_epoch_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx == ftq_commit_owner_idx) &&
        (packet_buf_head.ftq_epoch != ftq_current_epoch);
    assign xs_packet_stale_tag_mismatch_c =
        packet_buf_valid && packet_buf_head.valid && ftq_commit_owner_valid &&
        (packet_buf_head.ftq_idx == ftq_commit_owner_idx) &&
        (packet_buf_head.ftq_epoch == ftq_current_epoch) &&
        (packet_buf_head.ftq_alloc_tag != ftq_commit_owner_tag);
    assign xs_flowthrough_incomplete_owner_c =
        packet_flowthrough_owner_match_c &&
        !f2_work_owner_complete_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xs_catchup_base_cycles        <= 0;
            xs_catchup_fetch0_cycles      <= 0;
            xs_catchup_crossline_cycles   <= 0;
            xs_catchup_nlpb_cycles        <= 0;
            xs_catchup_aux_taken_cycles   <= 0;
            xs_catchup_recoverable_cycles <= 0;
            xs_catchup_target_last_cycles <= 0;
            xs_catchup_ret_cycles         <= 0;
            xs_packet_buf_stale_owner_cycles <= 0;
            xs_ftq_empty_cycles           <= 0;
            xs_ftq_full_cycles            <= 0;
            xs_ftq_occ_sum                <= 0;
            xs_ftq_occ_max                <= 0;
            xs_packet_buf_empty_cycles    <= 0;
            xs_packet_buf_full_cycles     <= 0;
            xs_packet_buf_occ_sum         <= 0;
            xs_packet_buf_occ_max         <= 0;
            xs_ftq_alloc_cycles           <= 0;
            xs_ftq_pop_cycles             <= 0;
            xs_ftq_alloc_pop_cycles       <= 0;
            xs_ic_req_valid_cycles        <= 0;
            xs_ic_req_stall_frontend_hold_cycles <= 0;
            xs_ic_req_stall_packet_full_cycles   <= 0;
            xs_ic_req_stall_ftq_full_cycles      <= 0;
            xs_backend_stall_cycles       <= 0;
            xs_backend_stall_packet_ready_cycles <= 0;
            xs_frontend_hold_cycles       <= 0;
            xs_dup_last_emit_cycles       <= 0;
            xs_dup_replay_guard_cycles    <= 0;
            xs_dup_both_reasons_cycles    <= 0;
            xs_f2_owner_no_head_cycles    <= 0;
            xs_f2_owner_idx_mismatch_cycles <= 0;
            xs_f2_owner_epoch_mismatch_cycles <= 0;
            xs_f2_owner_tag_mismatch_cycles <= 0;
            xs_f2_owner_live_cycles       <= 0;
            xs_f2_cursor_wb_no_head_cycles <= 0;
            xs_f2_cursor_wb_idx_skew_cycles <= 0;
            xs_f2_cursor_wb_epoch_skew_cycles <= 0;
            xs_f2_cursor_wb_tag_skew_cycles <= 0;
            xs_packet_stale_no_head_cycles <= 0;
            xs_packet_stale_idx_mismatch_cycles <= 0;
            xs_packet_stale_epoch_mismatch_cycles <= 0;
            xs_packet_stale_tag_mismatch_cycles <= 0;
            xs_flowthrough_candidate_cycles    <= 0;
            xs_flowthrough_owner_miss_cycles   <= 0;
            xs_flowthrough_incomplete_owner_cycles <= 0;
            xs_flowthrough_valid_cycles        <= 0;
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                xs_catchup_top_pc[i]    <= 64'd0;
                xs_catchup_top_count[i] <= 0;
                xs_dup_top_pc[i]        <= 64'd0;
                xs_dup_top_count[i]     <= 0;
            end
            for (int i = 0; i < 6; i++) begin
                xs_ftq_occ_hist[i] <= 0;
            end
            for (int i = 0; i < 5; i++) begin
                xs_packet_buf_occ_hist[i] <= 0;
            end
        end else if (xs_catchup_probe_en) begin
            if (ftq_empty)
                xs_ftq_empty_cycles <= xs_ftq_empty_cycles + 1;
            if (ftq_full)
                xs_ftq_full_cycles <= xs_ftq_full_cycles + 1;
            xs_ftq_occ_sum <= xs_ftq_occ_sum + int'(ftq_count);
            if (int'(ftq_count) > xs_ftq_occ_max)
                xs_ftq_occ_max <= int'(ftq_count);
            if (ftq_count == '0)
                xs_ftq_occ_hist[0] <= xs_ftq_occ_hist[0] + 1;
            else if (ftq_count == (FTQ_IDX_BITS+1)'(1))
                xs_ftq_occ_hist[1] <= xs_ftq_occ_hist[1] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(3))
                xs_ftq_occ_hist[2] <= xs_ftq_occ_hist[2] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(7))
                xs_ftq_occ_hist[3] <= xs_ftq_occ_hist[3] + 1;
            else if (ftq_count <= (FTQ_IDX_BITS+1)'(15))
                xs_ftq_occ_hist[4] <= xs_ftq_occ_hist[4] + 1;
            else
                xs_ftq_occ_hist[5] <= xs_ftq_occ_hist[5] + 1;

            if (packet_buf_empty)
                xs_packet_buf_empty_cycles <= xs_packet_buf_empty_cycles + 1;
            if (packet_buf_full)
                xs_packet_buf_full_cycles <= xs_packet_buf_full_cycles + 1;
            xs_packet_buf_occ_sum <=
                xs_packet_buf_occ_sum + int'(packet_buf_count);
            if (int'(packet_buf_count) > xs_packet_buf_occ_max)
                xs_packet_buf_occ_max <= int'(packet_buf_count);
            if (packet_buf_count == 4'd0)
                xs_packet_buf_occ_hist[0] <= xs_packet_buf_occ_hist[0] + 1;
            else if (packet_buf_count == 4'd1)
                xs_packet_buf_occ_hist[1] <= xs_packet_buf_occ_hist[1] + 1;
            else if (packet_buf_count <= 4'd3)
                xs_packet_buf_occ_hist[2] <= xs_packet_buf_occ_hist[2] + 1;
            else if (packet_buf_count <= 4'd7)
                xs_packet_buf_occ_hist[3] <= xs_packet_buf_occ_hist[3] + 1;
            else
                xs_packet_buf_occ_hist[4] <= xs_packet_buf_occ_hist[4] + 1;

            if (ftq_enq_valid)
                xs_ftq_alloc_cycles <= xs_ftq_alloc_cycles + 1;
            if (ftq_pop_valid)
                xs_ftq_pop_cycles <= xs_ftq_pop_cycles + 1;
            if (ftq_enq_valid && ftq_pop_valid)
                xs_ftq_alloc_pop_cycles <= xs_ftq_alloc_pop_cycles + 1;
            if (ic_req_valid)
                xs_ic_req_valid_cycles <= xs_ic_req_valid_cycles + 1;
            if (f1_valid && frontend_hold)
                xs_ic_req_stall_frontend_hold_cycles <=
                    xs_ic_req_stall_frontend_hold_cycles + 1;
            if (f1_valid && packet_buf_full)
                xs_ic_req_stall_packet_full_cycles <=
                    xs_ic_req_stall_packet_full_cycles + 1;
            if (f1_valid && ftq_full && ftq_need_alloc_c)
                xs_ic_req_stall_ftq_full_cycles <=
                    xs_ic_req_stall_ftq_full_cycles + 1;
            if (backend_stall)
                xs_backend_stall_cycles <= xs_backend_stall_cycles + 1;
            if (backend_stall && (packet_buf_valid || packet_flowthrough_valid))
                xs_backend_stall_packet_ready_cycles <=
                    xs_backend_stall_packet_ready_cycles + 1;
            if (frontend_hold)
                xs_frontend_hold_cycles <= xs_frontend_hold_cycles + 1;

            if (xs_dup_last_emit_c)
                xs_dup_last_emit_cycles <= xs_dup_last_emit_cycles + 1;
            if (f2_duplicate_suppressed_c) begin : xs_dup_top_update
                int hit_idx;
                int empty_idx;
                int min_idx;
                int use_idx;
                int min_count;

                hit_idx = -1;
                empty_idx = -1;
                min_idx = 0;
                use_idx = -1;
                min_count = xs_dup_top_count[0];
                for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                    if ((xs_dup_top_count[i] != 0) &&
                        (xs_dup_top_pc[i] == f2_work_pc_c) &&
                        (hit_idx < 0)) begin
                        hit_idx = i;
                    end
                    if ((xs_dup_top_count[i] == 0) &&
                        (empty_idx < 0)) begin
                        empty_idx = i;
                    end
                    if (xs_dup_top_count[i] < min_count) begin
                        min_count = xs_dup_top_count[i];
                        min_idx = i;
                    end
                end
                if (hit_idx >= 0)
                    use_idx = hit_idx;
                else if (empty_idx >= 0)
                    use_idx = empty_idx;
                else
                    use_idx = min_idx;

                xs_dup_top_pc[use_idx] <= f2_work_pc_c;
                if (hit_idx >= 0)
                    xs_dup_top_count[use_idx] <=
                        xs_dup_top_count[use_idx] + 1;
                else
                    xs_dup_top_count[use_idx] <= 1;
            end
            if (xs_dup_replay_guard_c)
                xs_dup_replay_guard_cycles <= xs_dup_replay_guard_cycles + 1;
            if (xs_dup_last_emit_c && xs_dup_replay_guard_c)
                xs_dup_both_reasons_cycles <= xs_dup_both_reasons_cycles + 1;
            if (xs_f2_owner_no_head_c)
                xs_f2_owner_no_head_cycles <= xs_f2_owner_no_head_cycles + 1;
            if (xs_f2_owner_idx_mismatch_c)
                xs_f2_owner_idx_mismatch_cycles <=
                    xs_f2_owner_idx_mismatch_cycles + 1;
            if (xs_f2_owner_epoch_mismatch_c)
                xs_f2_owner_epoch_mismatch_cycles <=
                    xs_f2_owner_epoch_mismatch_cycles + 1;
            if (xs_f2_owner_tag_mismatch_c)
                xs_f2_owner_tag_mismatch_cycles <=
                    xs_f2_owner_tag_mismatch_cycles + 1;
            if (f2_ftq_owner_live_c)
                xs_f2_owner_live_cycles <= xs_f2_owner_live_cycles + 1;
            if (xs_f2_cursor_wb_no_head_c)
                xs_f2_cursor_wb_no_head_cycles <=
                    xs_f2_cursor_wb_no_head_cycles + 1;
            if (xs_f2_cursor_wb_idx_skew_c)
                xs_f2_cursor_wb_idx_skew_cycles <=
                    xs_f2_cursor_wb_idx_skew_cycles + 1;
            if (xs_f2_cursor_wb_epoch_skew_c)
                xs_f2_cursor_wb_epoch_skew_cycles <=
                    xs_f2_cursor_wb_epoch_skew_cycles + 1;
            if (xs_f2_cursor_wb_tag_skew_c)
                xs_f2_cursor_wb_tag_skew_cycles <=
                    xs_f2_cursor_wb_tag_skew_cycles + 1;
            if (xs_packet_stale_no_head_c)
                xs_packet_stale_no_head_cycles <=
                    xs_packet_stale_no_head_cycles + 1;
            if (xs_packet_stale_idx_mismatch_c)
                xs_packet_stale_idx_mismatch_cycles <=
                    xs_packet_stale_idx_mismatch_cycles + 1;
            if (xs_packet_stale_epoch_mismatch_c)
                xs_packet_stale_epoch_mismatch_cycles <=
                    xs_packet_stale_epoch_mismatch_cycles + 1;
            if (xs_packet_stale_tag_mismatch_c)
                xs_packet_stale_tag_mismatch_cycles <=
                    xs_packet_stale_tag_mismatch_cycles + 1;
            if (packet_flowthrough_candidate)
                xs_flowthrough_candidate_cycles <=
                    xs_flowthrough_candidate_cycles + 1;
            if (packet_flowthrough_candidate && !packet_flowthrough_owner_match_c)
                xs_flowthrough_owner_miss_cycles <=
                    xs_flowthrough_owner_miss_cycles + 1;
            if (xs_flowthrough_incomplete_owner_c)
                xs_flowthrough_incomplete_owner_cycles <=
                    xs_flowthrough_incomplete_owner_cycles + 1;
            if (packet_flowthrough_valid)
                xs_flowthrough_valid_cycles <=
                    xs_flowthrough_valid_cycles + 1;

            if (xs_catchup_base_c)
                xs_catchup_base_cycles <= xs_catchup_base_cycles + 1;
            if (xs_catchup_fetch0_c)
                xs_catchup_fetch0_cycles <= xs_catchup_fetch0_cycles + 1;
            if (xs_catchup_crossline_c)
                xs_catchup_crossline_cycles <=
                    xs_catchup_crossline_cycles + 1;
            if (xs_catchup_nlpb_c)
                xs_catchup_nlpb_cycles <= xs_catchup_nlpb_cycles + 1;
            if (xs_catchup_aux_taken_c)
                xs_catchup_aux_taken_cycles <=
                    xs_catchup_aux_taken_cycles + 1;
            if (xs_catchup_recoverable_c) begin
                xs_catchup_recoverable_cycles <=
                    xs_catchup_recoverable_cycles + 1;
                if (f1_aux_pred_ctl_type_c == BT_RET)
                    xs_catchup_ret_cycles <= xs_catchup_ret_cycles + 1;
                begin : xs_catchup_top_update
                    int hit_idx;
                    int empty_idx;
                    int min_idx;
                    int use_idx;
                    int min_count;

                    hit_idx = -1;
                    empty_idx = -1;
                    min_idx = 0;
                    use_idx = -1;
                    min_count = xs_catchup_top_count[0];
                    for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                        if ((xs_catchup_top_count[i] != 0) &&
                            (xs_catchup_top_pc[i] == f1_pc) &&
                            (hit_idx < 0)) begin
                            hit_idx = i;
                        end
                        if ((xs_catchup_top_count[i] == 0) &&
                            (empty_idx < 0)) begin
                            empty_idx = i;
                        end
                        if (xs_catchup_top_count[i] < min_count) begin
                            min_count = xs_catchup_top_count[i];
                            min_idx = i;
                        end
                    end
                    if (hit_idx >= 0)
                        use_idx = hit_idx;
                    else if (empty_idx >= 0)
                        use_idx = empty_idx;
                    else
                        use_idx = min_idx;

                    xs_catchup_top_pc[use_idx] <= f1_pc;
                    if (hit_idx >= 0)
                        xs_catchup_top_count[use_idx] <=
                            xs_catchup_top_count[use_idx] + 1;
                    else
                        xs_catchup_top_count[use_idx] <= 1;
                end
            end
            if (xs_catchup_target_last_c) begin
                xs_catchup_target_last_cycles <=
                    xs_catchup_target_last_cycles + 1;
            end
            if (packet_buf_stale_owner_c)
                xs_packet_buf_stale_owner_cycles <=
                    xs_packet_buf_stale_owner_cycles + 1;

            if (xs_catchup_trace_en && xs_catchup_base_c) begin
                $display("[XS_CATCHUP] pc=%016h f2_pc=%016h last_next=%016h fetch0=%b cross=%b nlpb=%b aux_v=%b aux_t=%b aux_type=%0d aux_tgt=%016h target_last=%b",
                         f1_pc,
                         f2_work_pc_c,
                         f2_last_emit_next_pc_r,
                         xs_catchup_fetch0_c,
                         xs_catchup_crossline_c,
                         nlpb_aux_hit_comb,
                         f1_aux_pred_ctl_valid_c,
                         f1_aux_pred_ctl_taken_c,
                         f1_aux_pred_ctl_type_c,
                         f1_aux_pred_ctl_target_c,
                         xs_catchup_target_last_c);
            end
        end
    end

    final begin
        if (xs_catchup_probe_en) begin
            $display("");
            $display("=== XS NLPB CATCH-UP PROBE ===");
            $display("base duplicate cycles       : %0d",
                     xs_catchup_base_cycles);
            $display("base with fetch_out=0       : %0d",
                     xs_catchup_fetch0_cycles);
            $display("base cross-line             : %0d",
                     xs_catchup_crossline_cycles);
            $display("base with NLPB aux hit      : %0d",
                     xs_catchup_nlpb_cycles);
            $display("base with aux taken predict : %0d",
                     xs_catchup_aux_taken_cycles);
            $display("recoverable cross-line      : %0d",
                     xs_catchup_recoverable_cycles);
            $display("recoverable target=last pc  : %0d",
                     xs_catchup_target_last_cycles);
            $display("recoverable RET cycles      : %0d",
                     xs_catchup_ret_cycles);
            $display("xs packet-buffer stale owner: %0d",
                     xs_packet_buf_stale_owner_cycles);
            $display("xs ftq empty cycles         : %0d",
                     xs_ftq_empty_cycles);
            $display("xs ftq full cycles          : %0d",
                     xs_ftq_full_cycles);
            $display("xs ftq occ sum              : %0d",
                     xs_ftq_occ_sum);
            $display("xs ftq occ max              : %0d",
                     xs_ftq_occ_max);
            $display("xs ftq occ hist 0           : %0d",
                     xs_ftq_occ_hist[0]);
            $display("xs ftq occ hist 1           : %0d",
                     xs_ftq_occ_hist[1]);
            $display("xs ftq occ hist 2to3        : %0d",
                     xs_ftq_occ_hist[2]);
            $display("xs ftq occ hist 4to7        : %0d",
                     xs_ftq_occ_hist[3]);
            $display("xs ftq occ hist 8to15       : %0d",
                     xs_ftq_occ_hist[4]);
            $display("xs ftq occ hist 16plus      : %0d",
                     xs_ftq_occ_hist[5]);
            $display("xs packet buf empty cycles  : %0d",
                     xs_packet_buf_empty_cycles);
            $display("xs packet buf full cycles   : %0d",
                     xs_packet_buf_full_cycles);
            $display("xs packet buf occ sum       : %0d",
                     xs_packet_buf_occ_sum);
            $display("xs packet buf occ max       : %0d",
                     xs_packet_buf_occ_max);
            $display("xs packet buf occ hist 0    : %0d",
                     xs_packet_buf_occ_hist[0]);
            $display("xs packet buf occ hist 1    : %0d",
                     xs_packet_buf_occ_hist[1]);
            $display("xs packet buf occ hist 2to3 : %0d",
                     xs_packet_buf_occ_hist[2]);
            $display("xs packet buf occ hist 4to7 : %0d",
                     xs_packet_buf_occ_hist[3]);
            $display("xs packet buf occ hist 8    : %0d",
                     xs_packet_buf_occ_hist[4]);
            $display("xs ftq alloc cycles         : %0d",
                     xs_ftq_alloc_cycles);
            $display("xs ftq pop cycles           : %0d",
                     xs_ftq_pop_cycles);
            $display("xs ftq alloc pop cycles     : %0d",
                     xs_ftq_alloc_pop_cycles);
            $display("xs ic req valid cycles      : %0d",
                     xs_ic_req_valid_cycles);
            $display("xs ic stall frontend hold   : %0d",
                     xs_ic_req_stall_frontend_hold_cycles);
            $display("xs ic stall packet full     : %0d",
                     xs_ic_req_stall_packet_full_cycles);
            $display("xs ic stall ftq full        : %0d",
                     xs_ic_req_stall_ftq_full_cycles);
            $display("xs backend stall cycles     : %0d",
                     xs_backend_stall_cycles);
            $display("xs backend stall pkt ready  : %0d",
                     xs_backend_stall_packet_ready_cycles);
            $display("xs frontend hold cycles     : %0d",
                     xs_frontend_hold_cycles);
            $display("xs dup last emit            : %0d",
                     xs_dup_last_emit_cycles);
            $display("xs dup replay guard         : %0d",
                     xs_dup_replay_guard_cycles);
            $display("xs dup both reasons         : %0d",
                     xs_dup_both_reasons_cycles);
            $display("xs f2 owner live            : %0d",
                     xs_f2_owner_live_cycles);
            $display("xs f2 owner no head         : %0d",
                     xs_f2_owner_no_head_cycles);
            $display("xs f2 owner idx mismatch    : %0d",
                     xs_f2_owner_idx_mismatch_cycles);
            $display("xs f2 owner epoch mismatch  : %0d",
                     xs_f2_owner_epoch_mismatch_cycles);
            $display("xs f2 owner tag mismatch    : %0d",
                     xs_f2_owner_tag_mismatch_cycles);
            $display("xs f2 cursor wb no head     : %0d",
                     xs_f2_cursor_wb_no_head_cycles);
            $display("xs f2 cursor wb idx skew    : %0d",
                     xs_f2_cursor_wb_idx_skew_cycles);
            $display("xs f2 cursor wb epoch skew  : %0d",
                     xs_f2_cursor_wb_epoch_skew_cycles);
            $display("xs f2 cursor wb tag skew    : %0d",
                     xs_f2_cursor_wb_tag_skew_cycles);
            $display("xs packet stale no head     : %0d",
                     xs_packet_stale_no_head_cycles);
            $display("xs packet stale idx mismatch: %0d",
                     xs_packet_stale_idx_mismatch_cycles);
            $display("xs packet stale epoch mismatch: %0d",
                     xs_packet_stale_epoch_mismatch_cycles);
            $display("xs packet stale tag mismatch: %0d",
                     xs_packet_stale_tag_mismatch_cycles);
            $display("xs flowthrough candidate    : %0d",
                     xs_flowthrough_candidate_cycles);
            $display("xs flowthrough owner miss   : %0d",
                     xs_flowthrough_owner_miss_cycles);
            $display("xs flowthrough incomplete owner: %0d",
                     xs_flowthrough_incomplete_owner_cycles);
            $display("xs flowthrough valid        : %0d",
                     xs_flowthrough_valid_cycles);
            $display("recoverable top F1 PCs:");
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                if (xs_catchup_top_count[i] != 0) begin
                    $display("  %016h %0d",
                             xs_catchup_top_pc[i],
                             xs_catchup_top_count[i]);
                end
            end
            $display("duplicate-suppressed top F2 PCs:");
            for (int i = 0; i < XS_CATCHUP_TOPN; i++) begin
                if (xs_dup_top_count[i] != 0) begin
                    $display("  %016h %0d",
                             xs_dup_top_pc[i],
                             xs_dup_top_count[i]);
                end
            end
        end
    end
`endif

    // =========================================================================
    // Optional fetch-path trace (debug only)
    // =========================================================================
    logic trace_fetch_en;
    logic trace_fetch_split_en;
    logic trace_fetch_dup_en;
    logic trace_fetch_owner_en;
    integer trace_fetch_cycle;
    initial begin
        trace_fetch_en = 1'b0;
        trace_fetch_split_en = 1'b0;
        trace_fetch_dup_en = 1'b0;
        trace_fetch_owner_en = 1'b0;
        if ($test$plusargs("TRACE_FETCH")) trace_fetch_en = 1'b1;
        if ($test$plusargs("TRACE_FETCH_SPLIT")) trace_fetch_split_en = 1'b1;
        if ($test$plusargs("FETCH_DUP_TRACE")) trace_fetch_dup_en = 1'b1;
        if ($test$plusargs("TRACE_FETCH_OWNER")) trace_fetch_owner_en = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_fetch_cycle <= 0;
        end else begin
            trace_fetch_cycle <= trace_fetch_cycle + 1;
            if (trace_fetch_en &&
                ((trace_fetch_cycle < 600) ||
                 ((f1_pc >= 64'h0000_0000_8000_2000) &&
                  (f1_pc <  64'h0000_0000_8000_2470)) ||
                 ((f1_pc >= 64'h0000_0000_8000_2500) &&
                  (f1_pc <  64'h0000_0000_8000_2560)) ||
                 ((f1_pc >= 64'h0000_0000_8000_3100) &&
                  (f1_pc <  64'h0000_0000_8000_3400)) ||
                 ((f1_pc >= 64'h0000_0000_8000_39f0) &&
                  (f1_pc <  64'h0000_0000_8000_3a80)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_2000) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_2470)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_2500) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_2560)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_3100) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_3400)) ||
                 ((f2_work_pc_c >= 64'h0000_0000_8000_39f0) &&
                  (f2_work_pc_c <  64'h0000_0000_8000_3a80)))) begin
                $display("[FETCH] cyc=%0d f1_pc=%016h ic_req_v=%b ic_req=%016h ic_resp_v=%b ic_hit=%b nlpb_hit=%b f2_v=%b f2_pc=%016h f2_hit=%b f2_type=%0d f2_off=%0d f2_alt_hit=%b f2_alt_type=%0d f2_alt_off=%0d ext=%0d final=%0d emit=%b dup=%b seq_v=%b seq_pc=%016h line_reuse=%b bp=%b bp_taken=%b bp_type=%0d bp_slot=%0d bp_tgt=%016h pd_v=%b pd_slot=%0d pd_type=%0d pd_tgt=%016h ftq_pred_v=%b ftq_pred_t=%b ftq_pred_slot=%0d ftq_pred_type=%0d ftq_sub=%b pd_mm=%b sg_v=%b sg_pc=%016h sg_t=%b sg_parent=%016h sg_owner=%016h ras_tos=%0d ras_push=%b ras_push_addr=%016h ras_pop=%b ras_pop_addr=%016h redir=%b redir_pc=%016h cmt_redir=%b cmt_pc=%016h rem_v=%b cons_rem=%b consd_rem=%b ftq_need=%b ftq_enq=%b ftq_enq_tag=%0d ftq_pop=%b ftq_cnt=%0d ftq_head_v=%b ftq_head=%0d ftq_head_tag=%0d f2_ftq_v=%b f2_ftq=%0d f2_ftq_tag=%0d f2_ftq_blk=%016h pkt_live=%b pkt_ftq_tag=%0d fe_hold=%b fe_stall=%b fetch_out=%0d",
                    trace_fetch_cycle,
                    f1_pc,
                    ic_req_valid,
                    ic_req_addr,
                    ic_resp_valid,
                    ic_resp_hit,
                    nlpb_hit_comb,
                    f2_work_valid_c,
                    f2_work_pc_c,
                    f2_btb_hit_r,
                    f2_btb_type_r,
                    f2_btb_offset_r,
                    f2_btb_alt_hit_r,
                    f2_btb_alt_type_r,
                    f2_btb_alt_offset_r,
                    extract_count,
                    final_count,
                    f2_will_emit_c,
                    f2_duplicate_suppressed_c,
                    f2_seq_valid,
                    f2_seq_next_pc,
                    f2_line_state_use_c,
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
                    f2_work_ftq_entry_c.pred_from_subgroup,
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
                    f2_work_ftq_valid_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    f2_work_ftq_entry_c.block_pc,
                    packet_buf_owner_match_c,
                    packet_buf_valid ? packet_buf_head.ftq_alloc_tag : '0,
                    frontend_hold,
                    fe_stall,
                    fetch_count);
            end
            if (trace_fetch_dup_en &&
                f2_has_emit_payload_c &&
                !f2_will_emit_c) begin
                $display("[FETCH_DUP] cyc=%0d pc=%016h last_v=%b last_pc=%016h last_next=%016h replay_hit=%b replay_pc=%016h replay_age=%0d seq_v=%b seq=%016h ext=%0d final=%0d f2_ftq_v=%b f2_ftq=%0d f2_tag=%0d block=%016h pred_v=%b pred_t=%b pred_off=%0d pred_type=%0d pred_target=%016h pd_v=%b pd_slot=%0d pd_type=%0d pd_target=%016h bp=%b bp_taken=%b bp_slot=%0d bp_type=%0d bp_target=%016h rem_v=%b straddle=%b fe_stall=%b fe_hold=%b pkt_v=%b pkt_tag=%0d ftq_head_v=%b ftq_head=%0d ftq_head_tag=%0d ftq_cnt=%0d fetch_out=%0d out_pc0=%016h out_pc1=%016h out_pc2=%016h out_pc3=%016h",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    f2_last_emit_valid_r,
                    f2_last_emit_pc_r,
                    f2_last_emit_next_pc_r,
                    f2_replay_block_hit_c,
                    f2_replay_block_pc_r,
                    f2_replay_block_age_r,
                    f2_seq_valid,
                    f2_seq_next_pc,
                    extract_count,
                    final_count,
                    f2_work_ftq_valid_c,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    f2_work_ftq_entry_c.block_pc,
                    f2_work_ftq_entry_c.pred_ctl_valid,
                    f2_work_ftq_entry_c.pred_ctl_taken,
                    f2_work_ftq_entry_c.pred_ctl_offset,
                    f2_work_ftq_entry_c.pred_ctl_type,
                    f2_work_ftq_entry_c.pred_ctl_target,
                    predecode_ctl_found,
                    predecode_ctl_slot,
                    predecode_ctl_type,
                    predecode_ctl_target,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    bp_type,
                    bp_target_addr,
                    remainder_valid_r,
                    straddle_detected,
                    fe_stall,
                    frontend_hold,
                    packet_buf_valid,
                    packet_buf_valid ? packet_buf_head.ftq_alloc_tag : '0,
                    ftq_head_valid,
                    ftq_head_idx,
                    ftq_head_tag,
                    ftq_count,
                    fetch_count,
                    fetch_pc[0],
                    fetch_pc[1],
                    fetch_pc[2],
                    fetch_pc[3]);
            end
            if (trace_fetch_owner_en &&
                f2_owner_completion_candidate_c &&
                !f2_ftq_owner_live_c) begin
                $display("[FETCH_OWNER_TRACE] cyc=%0d pc=%016h seq=%016h final=%0d straddle=%b bp=%b bp_taken=%b bp_slot=%0d bp_type=%0d target=%016h work_idx=%0d work_tag=%0d wb_valid=%b wb_idx=%0d wb_tag=%0d ftq_cnt=%0d ftq_alloc_to_ifu=%0d ftq_ifu_to_wb=%0d ftq_ifu_to_commit=%0d icq_valid=%b icq_line=%014h line_reuse=%b pkt_valid=%b pkt_match=%b pkt_complete=%b fetch_out=%0d out_pc0=%016h",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    f2_seq_next_pc,
                    final_count,
                    straddle_detected,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    bp_type,
                    bp_target_addr,
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_valid,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag,
                    ftq_count,
                    ftq_count_alloc_to_ifu,
                    ftq_count_ifu_to_wb,
                    ftq_count_ifu_to_commit,
                    icq_deq_valid,
                    icq_deq_line_addr,
                    f2_line_state_use_c,
                    packet_buf_valid,
                    packet_buf_owner_match_c,
                    packet_buf_head_owner_complete_c,
                    fetch_count,
                    fetch_pc[0]);
            end
            if (trace_fetch_split_en && subgroup_seed_load_c) begin
                $display("[FETCH_SPLIT] cyc=%0d parent_pc=%016h split_pc=%016h split_tgt=%016h split_slot=%0d split_type=%0d reason=%s pre_pc=%016h pre_tgt=%016h second_pc=%016h second_tgt=%016h ftq_pred_v=%b ftq_pred_t=%b ftq_pred_slot=%0d ftq_pred_type=%0d owner_pred=%b bp_found=%b bp_taken=%b bp_slot=%0d final=%0d ext=%0d",
                    trace_fetch_cycle,
                    f2_work_pc_c,
                    subgroup_split_pc_c,
                    subgroup_split_target_c,
                    subgroup_split_slot_c,
                    subgroup_split_type_c,
                    subgroup_split_seed_c ? "owner" : "second",
                    predecode_ctl_pc,
                    predecode_ctl_target,
                    second_ctl_pc,
                    second_ctl_target,
                    ftq_pred_ctl_valid,
                    ftq_pred_ctl_taken,
                    ftq_pred_ctl_slot,
                    ftq_pred_ctl_type,
                    owner_cond_pred_found,
                    bp_branch_found,
                    bp_taken,
                    bp_branch_slot,
                    final_count,
                    extract_count);
            end
        end
    end

    // ====================================================================
    // Pipeline timing invariants (SVA assertions)
    // ====================================================================
    // Codifies the timing relationships that the current design depends
    // on. Any RTL change that violates one fires immediately during
    // simulation, telling us which invariant the change broke before
    // benchmarks run. This is the "design validation" layer the harness
    // was missing -- counters tell WHAT is wrong; assertions tell WHICH
    // architectural property the change violated.
    //
    // Per AGENTS.md SVA discipline: gated on `ifndef SYNTHESIS` so they
    // only fire in simulation; cleared during reset and 1 cycle after
    // redirect_valid (when state is in transition).

`ifndef SYNTHESIS

    // Invariant A: any queue response accepted by the IFU work cursor must name
    // the same physical cache line as the current work PC. A queued response may
    // be older than the current request pipe once response elasticity exists, so
    // the response-line metadata is the authoritative timing source here.
    property p_f2_pc_matches_resp_source;
        @(posedge clk) disable iff (!rst_n || redirect_valid ||
                                     consumed_remainder_r)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (f2_work_line_addr_c == icq_deq_line_addr);
    endproperty
    a_f2_pc_matches_resp_source: assert property (p_f2_pc_matches_resp_source)
        else $error("[INVARIANT_A] IFU work/data line mismatch: work_line=%014h work_pc=%016h icq_line=%014h",
                    f2_work_line_addr_c, f2_work_pc_c, icq_deq_line_addr);

    // Invariant B: the IFU work owner's epoch must equal current FTQ epoch when
    // the work cursor has a valid owner. A stale epoch means the frontend is
    // processing data from a flushed FTQ entry. The owner epoch mismatch counter
    // tracks this; this assertion makes the counter movement a hard correctness
    // property.
    property p_f2_owner_epoch_current;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_work_ftq_valid_c |->
        (f2_work_ftq_epoch_c == ftq_current_epoch);
    endproperty
    a_f2_owner_epoch_current: assert property (p_f2_owner_epoch_current)
        else $error("[INVARIANT_B] IFU work owner epoch stale: work_epoch=%h ftq_epoch=%h",
                    f2_work_ftq_epoch_c, ftq_current_epoch);

    // Invariant C: when F2 emits, f2_pc_consumed_c must be 1 (semantic
    // tautology that catches any future change accidentally clearing
    // f2_pc_consumed_c on emit, which would break F1's case 4 advance).
    property p_emit_implies_consumed;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_will_emit_c |-> f2_pc_consumed_c;
    endproperty
    a_emit_implies_consumed: assert property (p_emit_implies_consumed)
        else $error("[INVARIANT_C] F2 emitted but pc_consumed_c=0");

    // Invariant D: an accepted queue head must match the line of the IFU work
    // cursor. A future-line queue head may be visible while the frontend is
    // consuming the local line-state record, but it must not be popped or used
    // as data.
    property p_queue_pc_matches_f2;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ic_resp_valid && f2_work_line_valid_c) |->
        (icq_deq_line_addr == f2_work_line_addr_c);
    endproperty
    a_queue_pc_matches_f2: assert property (p_queue_pc_matches_f2)
        else $error("[INVARIANT_D] queue line/IFU work line mismatch: deq_line=%014h work_line=%014h work_pc=%016h",
                    icq_deq_line_addr, f2_work_line_addr_c, f2_work_pc_c);

    // Invariant D2: if the frontend is reusing a same-line response, the
    // line-state record must still name the same line as the work cursor's PC.
    property p_same_line_reuse_has_line_state;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        f2_line_state_use_c |->
        (f2_line_state_valid_r &&
         f2_work_line_valid_c &&
         (f2_line_state_addr_r == f2_work_line_addr_c) &&
         (f2_line_state_epoch_r == ftq_current_epoch));
    endproperty
    a_same_line_reuse_has_line_state:
        assert property (p_same_line_reuse_has_line_state)
        else $error("[INVARIANT_D2] same-line reuse missing line state: state_v=%b state_line=%014h work_line=%014h work_pc=%016h state_epoch=%h ftq_epoch=%h",
                    f2_line_state_valid_r,
                    f2_line_state_addr_r,
                    f2_work_line_addr_c,
                    f2_work_pc_c,
                    f2_line_state_epoch_r,
                    ftq_current_epoch);

    // Invariant D3: the IFU work cursor's cached line identity must describe
    // the cursor PC while the cursor is valid. This replaces the retired raw
    // F2 mirror-register check and keeps the cursor as the single F2 work
    // state until later runahead slices intentionally advance it independently.
    property p_ifu_work_cursor_line_self_consistent;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (ifu_work_r.line_valid == ifu_work_r.valid) &&
        (!ifu_work_r.valid ||
         (ifu_work_r.line_addr == ifu_work_r.pc[63:LINE_BITS]));
    endproperty
    a_ifu_work_cursor_line_self_consistent:
        assert property (p_ifu_work_cursor_line_self_consistent)
        else $error("[INVARIANT_D3] IFU work cursor line identity mismatch: valid=%b line_valid=%b pc=%016h line=%014h",
                    ifu_work_r.valid,
                    ifu_work_r.line_valid,
                    ifu_work_r.pc,
                    ifu_work_r.line_addr);

    // Invariant E: the FTQ IFU-writeback pointer may advance only when the IFU
    // work owner being completed is the current IFU-writeback owner. Plain F2
    // packet emission can be ahead of or behind the writeback pointer while
    // same-line data sharing and IBuffer delivery are still monolithic.
    property p_f2_pop_matches_ftq_wb_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ftq_ifu_pop_valid |->
        (f2_work_ftq_valid_c &&
         ftq_ifu_wb_owner_valid &&
         (f2_work_ftq_idx_c == ftq_ifu_wb_owner_idx) &&
         (f2_work_ftq_epoch_c == ftq_current_epoch) &&
         (f2_work_ftq_alloc_tag_c == ftq_ifu_wb_owner_tag));
    endproperty
    a_f2_pop_matches_ftq_wb_owner:
        assert property (p_f2_pop_matches_ftq_wb_owner)
        else $error("[INVARIANT_E] IFU work FTQ pop owner mismatch: work_idx=%h work_tag=%h wb_idx=%h wb_tag=%h",
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag);

    // Invariant E2: a completed IFU work item that is not the current FTQ
    // IFU-writeback owner must remain blocked from popping the FTQ. The
    // candidate counters expose this residual skew; the invariant protects the
    // structural guard while later slices remove the skew itself.
    property p_f2_wrong_owner_completion_candidate_does_not_pop;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        (f2_owner_completion_candidate_c && !f2_ftq_owner_live_c) |->
        !ftq_ifu_pop_valid;
    endproperty
    a_f2_wrong_owner_completion_candidate_does_not_pop:
        assert property (p_f2_wrong_owner_completion_candidate_does_not_pop)
        else $error("[INVARIANT_E2] wrong-owner IFU completion candidate popped FTQ: work_idx=%h work_tag=%h wb_valid=%b wb_idx=%h wb_tag=%h",
                    f2_work_ftq_idx_c,
                    f2_work_ftq_alloc_tag_c,
                    ftq_ifu_wb_owner_valid,
                    ftq_ifu_wb_owner_idx,
                    ftq_ifu_wb_owner_tag);

    // Invariant F: the IFU request-pop into the FTQ must be a real
    // allocation/request handshake. This keeps request-owner progress tied to
    // FTQ enqueue readiness and downstream response/IBuffer capacity.
    property p_ifu_req_pop_is_ready_enq;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ftq_ifu_req_pop_valid |->
        (ftq_enq_valid && ftq_enq_ready && !icq_full && !packet_buf_full);
    endproperty
    a_ifu_req_pop_is_ready_enq:
        assert property (p_ifu_req_pop_is_ready_enq)
        else $error("[INVARIANT_F] IFU request-pop without ready enqueue: enq_v=%b enq_r=%b icq_full=%b pkt_full=%b",
                    ftq_enq_valid,
                    ftq_enq_ready,
                    icq_full,
                    packet_buf_full);

    // Invariant G: when the cursor policy selects the FTQ next IFU-writeback
    // owner, the registered cursor must load that owner identity and the
    // cursor-computed next PC on the following cycle.
    property p_ifu_cursor_loads_ftq_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_take_ftq_next_owner_c |=>
        (ifu_work_r.valid &&
         ifu_work_r.ftq_valid &&
         (ifu_work_r.pc == $past(f2_seq_next_pc)) &&
         (ifu_work_r.ftq_idx == $past(ftq_next_ifu_owner_idx)) &&
         (ifu_work_r.ftq_epoch == $past(ftq_current_epoch)) &&
         (ifu_work_r.ftq_alloc_tag == $past(ftq_next_ifu_owner_tag)));
    endproperty
    a_ifu_cursor_loads_ftq_next_owner:
        assert property (p_ifu_cursor_loads_ftq_next_owner)
        else $error("[INVARIANT_G] IFU cursor failed FTQ next-owner load: pc=%016h idx=%h tag=%h",
                    ifu_work_r.pc,
                    ifu_work_r.ftq_idx,
                    ifu_work_r.ftq_alloc_tag);

    // Invariant H: if a redirect target is already the FTQ next owner, the
    // redirect handoff must load that next-owner identity rather than relying
    // on direct request-allocation metadata.
    property p_ifu_redirect_loads_matching_next_owner;
        @(posedge clk) disable iff (!rst_n || redirect_valid)
        ifu_work_redirect_next_owner_match_c |=>
        (ifu_work_r.valid &&
         ifu_work_r.ftq_valid &&
         (ifu_work_r.pc == $past(f2_bpu_target)) &&
         (ifu_work_r.ftq_idx == $past(ftq_next_ifu_owner_idx)) &&
         (ifu_work_r.ftq_epoch == $past(ftq_current_epoch)) &&
         (ifu_work_r.ftq_alloc_tag == $past(ftq_next_ifu_owner_tag)));
    endproperty
    a_ifu_redirect_loads_matching_next_owner:
        assert property (p_ifu_redirect_loads_matching_next_owner)
        else $error("[INVARIANT_H] IFU redirect failed matching next-owner load: pc=%016h idx=%h tag=%h",
                    ifu_work_r.pc,
                    ifu_work_r.ftq_idx,
                    ifu_work_r.ftq_alloc_tag);

`endif

endmodule
