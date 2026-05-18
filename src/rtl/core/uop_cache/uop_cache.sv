/* file: uop_cache.sv
 Description: UOP-cache decoded-op cache. Caches post-fusion fetch
              groups indexed by their start PC and streams cached groups to
              rename once the predicted next PC hits. This is an explicit
              research path and is disabled for Stage 1 signoff until it is
              tied to live BPU/FTQ validation.

              Pipeline:
                F0  (lookup)   - drive SRAM addr = predicted next-group PC
                F1  (hit)      - SRAM data + tag compare ready
                F2  (mux/fill) - emit cached group OR fill from fused output

              `active` means the cache owns the rename input this cycle.
              `handoff_valid` pulses only when a stream exits and fetch must
              resume from `handoff_pc`.

              See doc/uop_cache_design_2026-04-25.md for the full spec.
 Author: Jeremy Cai
 Date: Apr. 25, 2026
 Version: 2.0
*/
`ifndef UOP_CACHE_SV
`define UOP_CACHE_SV

module uop_cache
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                clk,
    input  logic                rst_n,
    input  logic                en,

    // Capture-side input (from fusion stage, post-decode)
    input  decoded_insn_t       fused_insn [0:PIPE_WIDTH-1],
    input  logic [2:0]          fused_count,

    // Replay-side output (to rename input mux)
    output decoded_insn_t       uoc_insn   [0:PIPE_WIDTH-1],
    output logic [2:0]          uoc_count,
    output logic                active,              // 1 = playback owns rename input
    output logic                handoff_valid,       // 1-cycle pulse on PLAYING→IDLE
    output logic [63:0]         handoff_pc,

    // Frontend redirect (commit flush, BRU early redirect, FENCE.I)
    input  logic                redirect_valid,
    input  logic [63:0]         redirect_pc,
    input  logic                invalidate,          // FENCE.I or full-flush invalidate

    // Backpressure from rename
    input  logic                stall,

    // Telemetry counters (driven combinational; tb samples them)
    output logic                ev_lookup,
    output logic                ev_hit,
    output logic                ev_miss,
    output logic                ev_fill,
    output logic                ev_fill_evict_valid,
    output logic                ev_enter_playing,
    output logic                ev_exit_playing_miss,
    output logic                ev_exit_playing_nohit,
    output logic                ev_exit_playing_unsafe,
    output logic                ev_emit,
    output logic                ev_emit_control,
    output logic                ev_emit_cond,
    output logic                ev_emit_jal,
    output logic                ev_emit_jalr,
    output logic                ev_emit_pred_taken,
    output logic                ev_invalidate
);

    // =========================================================================
    // Helpers: PC → {tag, index} split
    // =========================================================================
    function automatic logic [UOC_INDEX_BITS-1:0] pc_index(input logic [63:0] pc);
        return pc[UOC_OFFSET_BITS +: UOC_INDEX_BITS];
    endfunction

    function automatic logic [UOC_TAG_BITS-1:0] pc_tag(input logic [63:0] pc);
        return pc[63 -: UOC_TAG_BITS];
    endfunction

    // Reconstruct stored entry's PC from {tag,index} (offset bits are 0).
    function automatic logic [63:0] reconstruct_pc(input logic [UOC_TAG_BITS-1:0] tag,
                                                   input logic [UOC_INDEX_BITS-1:0] idx);
        logic [63:0] pc;
        begin
            pc                                                       = '0;
            pc[63 -: UOC_TAG_BITS]                                   = tag;
            pc[UOC_OFFSET_BITS +: UOC_INDEX_BITS]                    = idx;
            return pc;
        end
    endfunction

    // =========================================================================
    // Predicted-next-group PC tracker.
    //
    // Each cycle we maintain a prediction of the start PC of the *next* fetch
    // group after whatever is currently being emitted (either by fused or
    // by an in-progress playback).  This prediction drives the SRAM lookup
    // address; one cycle later we know whether the cache holds that group.
    // =========================================================================
    logic [63:0] predicted_next_pc_r;
    logic [63:0] predicted_next_pc_c;          // combinational this-cycle update

    // Compute the start-of-next-group PC from a 4-wide group of decoded µops
    // and a count.  If the last µop is a taken branch, use its target; else
    // PC + (4 if non-RVC, 2 if RVC).  Fused control µops carry the control
    // instruction PC in pc for branch recovery and the first architectural PC
    // in trap_pc for precise trap restart.
    function automatic logic [63:0] next_group_pc(
        input decoded_insn_t group [0:PIPE_WIDTH-1],
        input logic [2:0]    count
    );
        logic [63:0] pc;
        decoded_insn_t last;
        int           idx;
        begin
            if (count == 3'd0) begin
                return predicted_next_pc_r;     // unchanged
            end
            idx  = int'(count) - 1;
            last = group[idx];
            if (last.bp_taken) begin
                return last.bp_target;
            end
            pc = last.pc + (last.is_rvc ? 64'd2 : 64'd4);
            return pc;
        end
    endfunction

    // =========================================================================
    // Tag RAM
    // =========================================================================
    logic [UOC_INDEX_BITS-1:0]   tag_raddr_c;
    logic [UOC_WAYS-1:0]         tag_valid_out;
    logic [UOC_TAG_BITS-1:0]     tag_out [0:UOC_WAYS-1];

    logic                        tag_we_c;
    logic [UOC_INDEX_BITS-1:0]   tag_waddr_c;
    logic [UOC_WAY_BITS-1:0]     tag_wway_c;
    logic                        tag_wvalid_c;
    logic [UOC_TAG_BITS-1:0]     tag_wtag_c;

    uop_cache_tag_ram u_tag (
        .clk            (clk),
        .rst_n          (rst_n),
        .raddr          (tag_raddr_c),
        .valid_out      (tag_valid_out),
        .tag_out        (tag_out),
        .we             (tag_we_c),
        .waddr          (tag_waddr_c),
        .wway           (tag_wway_c),
        .wvalid         (tag_wvalid_c),
        .wtag           (tag_wtag_c),
        .invalidate_all (invalidate)
    );

    // =========================================================================
    // Data RAMs (one bank per way)
    // =========================================================================
    logic [UOC_INDEX_BITS-1:0] data_raddr_c;
    decoded_insn_t             data_rdata [0:UOC_WAYS-1][0:UOC_PER_ENTRY-1];
    logic [2:0]                data_rcount [0:UOC_WAYS-1];

    logic                      data_we_c [0:UOC_WAYS-1];
    logic [UOC_INDEX_BITS-1:0] data_waddr_c;
    decoded_insn_t             data_wdata_c [0:UOC_PER_ENTRY-1];
    logic [2:0]                data_wcount_c;

    genvar gw;
    generate
        for (gw = 0; gw < UOC_WAYS; gw++) begin : g_way
            uop_cache_data_ram u_data (
                .clk    (clk),
                .raddr  (data_raddr_c),
                .rdata  (data_rdata[gw]),
                .rcount (data_rcount[gw]),
                .we     (data_we_c[gw]),
                .waddr  (data_waddr_c),
                .wdata  (data_wdata_c),
                .wcount (data_wcount_c)
            );
        end
    endgenerate

    // =========================================================================
    // pLRU (tree-pLRU, 7 bits per set, 8 ways)
    // bit[0] root:    0→ways 0-3, 1→ways 4-7
    // bit[1] L0/L1:   0→ways 0-1, 1→ways 2-3
    // bit[2] L0/L1:   0→ways 4-5, 1→ways 6-7
    // bit[3..6] leaf: each picks within a 2-way pair
    // =========================================================================
    logic [UOC_PLRU_BITS-1:0] plru_r [UOC_SETS];

    // Compute victim way from pLRU bits.
    function automatic logic [UOC_WAY_BITS-1:0] plru_victim(input logic [6:0] p);
        logic        b0, b1, b2, b3;
        logic [2:0]  way;
        begin
            b0 = p[0];
            if (!b0) begin
                b1 = p[1];
                if (!b1) begin
                    b3 = p[3];
                    way = b3 ? 3'd1 : 3'd0;
                end else begin
                    b3 = p[4];
                    way = b3 ? 3'd3 : 3'd2;
                end
            end else begin
                b2 = p[2];
                if (!b2) begin
                    b3 = p[5];
                    way = b3 ? 3'd5 : 3'd4;
                end else begin
                    b3 = p[6];
                    way = b3 ? 3'd7 : 3'd6;
                end
            end
            return way;
        end
    endfunction

    // Update pLRU on access (way W just used) — point bits AWAY from W.
    function automatic logic [6:0] plru_update(input logic [6:0] p,
                                                input logic [2:0] w);
        logic [6:0] np;
        begin
            np = p;
            np[0] = ~w[2];                   // root: away from way's high half
            if (!w[2]) begin
                np[1] = ~w[1];               // ways 0-3 sub
                if (!w[1]) np[3] = ~w[0];    // way 0 vs 1
                else       np[4] = ~w[0];    // way 2 vs 3
            end else begin
                np[2] = ~w[1];               // ways 4-7 sub
                if (!w[1]) np[5] = ~w[0];    // way 4 vs 5
                else       np[6] = ~w[0];    // way 6 vs 7
            end
            return np;
        end
    endfunction

    // =========================================================================
    // F1: tag compare on SRAM read output.
    //
    // SRAM was addressed at posedge T-1 with predicted_next_pc_r (computed
    // at T-1).  At cycle T, SRAM has data for that lookup PC.  We need to
    // remember which PC we looked up so the F1 comparator uses the right
    // tag and index → we register lookup_pc_r alongside the SRAM addr.
    // =========================================================================
    logic [63:0] lookup_pc_r;
    logic        lookup_valid_r;             // 0 if previous cycle suppressed lookup

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_pc_r    <= '0;
            lookup_valid_r <= 1'b0;
        end else begin
            lookup_pc_r    <= predicted_next_pc_c;
            lookup_valid_r <= en && !redirect_valid && !invalidate;
        end
    end

    logic [UOC_TAG_BITS-1:0]   lookup_tag_c;
    logic [UOC_INDEX_BITS-1:0] lookup_idx_c;
    assign lookup_tag_c = pc_tag(lookup_pc_r);
    assign lookup_idx_c = pc_index(lookup_pc_r);

    logic [UOC_WAYS-1:0]      hit_way_oh_c;
    logic                     hit_c;
    logic [UOC_WAY_BITS-1:0]  hit_way_c;

    always_comb begin
        hit_way_oh_c = '0;
        for (int w = 0; w < UOC_WAYS; w++) begin
            if (tag_valid_out[w] && (tag_out[w] == lookup_tag_c)) begin
                hit_way_oh_c[w] = 1'b1;
            end
        end
    end
    assign hit_c = lookup_valid_r && |hit_way_oh_c;

    always_comb begin
        hit_way_c = '0;
        for (int w = 0; w < UOC_WAYS; w++) begin
            if (hit_way_oh_c[w]) hit_way_c = w[UOC_WAY_BITS-1:0];
        end
    end

    decoded_insn_t hit_data_c [0:UOC_PER_ENTRY-1];
    logic [2:0]    hit_count_c;
    always_comb begin
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            hit_data_c[u] = data_rdata[hit_way_c][u];
        end
        hit_count_c = data_rcount[hit_way_c];
    end

    // =========================================================================
    // State machine: IDLE / PLAYING.
    //
    // IDLE -> PLAYING: the predicted next fetch group hits in the cache.
    // PLAYING: keep streaming cached groups while the next predicted PC hits.
    // PLAYING -> IDLE: miss/unsafe group; redirect fetch to the first group
    // that the UOP cache cannot serve.
    // =========================================================================
    typedef enum logic {
        UOC_IDLE    = 1'b0,
        UOC_PLAYING = 1'b1
    } uoc_state_e;

    uoc_state_e state_r, state_next_c;

    // Stage-1 safety policy: the UOP cache may bypass decode, but it
    // must not become the branch predictor. Control-flow groups need live
    // BPU/FTQ validation before this path can safely replay them by default.
`ifndef SYNTHESIS
    bit sim_uoc_allow_partial_groups;
    bit sim_uoc_allow_control_groups;
    initial begin
        sim_uoc_allow_partial_groups =
            $test$plusargs("UOC_ALLOW_PARTIAL_GROUPS") ||
            $test$plusargs("UOC_UNSAFE_STREAM");
        sim_uoc_allow_control_groups =
            $test$plusargs("UOC_ALLOW_CONTROL") ||
            $test$plusargs("UOC_UNSAFE_STREAM");
    end
    logic uoc_allow_partial_groups;
    logic uoc_allow_control_groups;
    assign uoc_allow_partial_groups = sim_uoc_allow_partial_groups;
    assign uoc_allow_control_groups = sim_uoc_allow_control_groups;
`else
    localparam logic uoc_allow_partial_groups = 1'b0;
    localparam logic uoc_allow_control_groups = 1'b0;
`endif

    // Replay guard: default to full straight-line groups only. Refuse groups
    // whose next-PC accounting or architectural side effects need live
    // BPU/FTQ validation.
    logic hit_data_unplayable_c;
    always_comb begin
        hit_data_unplayable_c =
            (hit_count_c == 3'd0) ||
            (!uoc_allow_partial_groups && (hit_count_c != 3'(PIPE_WIDTH)));
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            if (3'(u) < hit_count_c) begin
                if (hit_data_c[u].is_fused  ||
                    (!uoc_allow_control_groups &&
                     (hit_data_c[u].is_branch ||
                      hit_data_c[u].is_jal ||
                      hit_data_c[u].is_jalr)) ||
                    hit_data_c[u].is_csr    || hit_data_c[u].is_fence ||
                    hit_data_c[u].is_fence_i|| hit_data_c[u].is_ecall ||
                    hit_data_c[u].is_ebreak || hit_data_c[u].is_mret  ||
                    hit_data_c[u].is_sret   || hit_data_c[u].is_sfence_vma ||
                    hit_data_c[u].is_wfi    || hit_data_c[u].is_amo   ||
                    hit_data_c[u].has_exception || !hit_data_c[u].valid) begin
                    hit_data_unplayable_c = 1'b1;
                end
            end
        end
    end

    logic emit_valid_c;
    logic emit_c;
    logic stream_exit_c;
    logic emit_has_cond_c;
    logic emit_has_jal_c;
    logic emit_has_jalr_c;
    logic emit_has_pred_taken_c;

    assign emit_valid_c =
        en && hit_c && !hit_data_unplayable_c &&
        !redirect_valid && !invalidate;
    assign emit_c = emit_valid_c && !stall;

    assign stream_exit_c =
        (state_r == UOC_PLAYING) &&
        !stall && !redirect_valid && !invalidate && !emit_c;

    always_comb begin
        emit_has_cond_c       = 1'b0;
        emit_has_jal_c        = 1'b0;
        emit_has_jalr_c       = 1'b0;
        emit_has_pred_taken_c = 1'b0;
        if (emit_c) begin
            for (int u = 0; u < UOC_PER_ENTRY; u++) begin
                if (3'(u) < hit_count_c) begin
                    emit_has_cond_c       |= hit_data_c[u].is_branch;
                    emit_has_jal_c        |= hit_data_c[u].is_jal;
                    emit_has_jalr_c       |= hit_data_c[u].is_jalr;
                    emit_has_pred_taken_c |= hit_data_c[u].bp_taken;
                end
            end
        end
    end

    always_comb begin
        state_next_c = state_r;
        if (redirect_valid || invalidate || !en) begin
            state_next_c = UOC_IDLE;
        end else if (state_r == UOC_IDLE) begin
            if (emit_c) state_next_c = UOC_PLAYING;
        end else begin
            if (stall) begin
                state_next_c = UOC_PLAYING;
            end else if (emit_c) begin
                state_next_c = UOC_PLAYING;
            end else begin
                state_next_c = UOC_IDLE;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) state_r <= UOC_IDLE;
        else        state_r <= state_next_c;
    end

    assign active = emit_valid_c;

    // =========================================================================
    // Output mux: when active, drive uoc_insn/uoc_count from hit_data
    // =========================================================================
    always_comb begin
        for (int u = 0; u < PIPE_WIDTH; u++) begin
            uoc_insn[u] = active ? hit_data_c[u] : '0;
        end
        uoc_count = active ? hit_count_c : 3'd0;
    end

    // Handoff: when a stream exits, fetch restarts at the first PC not served
    // by the UOP cache. For a miss this is lookup_pc_r; for an unsafe hit it is
    // also lookup_pc_r because the live frontend must decode that exact group.
    assign handoff_valid = stream_exit_c;
    assign handoff_pc    = lookup_pc_r;

    // =========================================================================
    // Predicted-next-PC update (combinational, drives F0 lookup)
    //
    // - When emitting hit_data: next group = end-of-hit_data
    // - Otherwise, when fused_count > 0: next group = end-of-fused
    // - On redirect: next group = redirect_pc
    // - Otherwise: hold previous prediction
    // =========================================================================
    always_comb begin
        if (redirect_valid) begin
            predicted_next_pc_c = redirect_pc;
        end else if (emit_c) begin
            predicted_next_pc_c = next_group_pc(hit_data_c, hit_count_c);
        end else if ((state_r == UOC_IDLE) && (fused_count != 3'd0)) begin
            predicted_next_pc_c = next_group_pc(fused_insn, fused_count);
        end else begin
            predicted_next_pc_c = predicted_next_pc_r;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) predicted_next_pc_r <= RESET_VECTOR;
        else        predicted_next_pc_r <= predicted_next_pc_c;
    end

    // SRAM read addresses (driven from the *next-cycle* prediction)
    assign tag_raddr_c  = pc_index(predicted_next_pc_c);
    assign data_raddr_c = pc_index(predicted_next_pc_c);

    // =========================================================================
    // Fill: on every cycle where fused produces a group, install or refresh
    // its entry in the cache (capture-when-decoded model).  This is the
    // simplest fill policy; it auto-warms the cache at no extra latency.
    //
    // Skip fill if the entry for this PC is already cached in any way at
    // the same index — to avoid duplicate installs and pLRU disruption.
    // (Detected via secondary tag compare against fused_insn[0].pc; this
    // is a separate compare from the F1 lookup compare since fused PC
    // and lookup PC are independent.)
    //
    // Implementation note: fill index/tag come from current cycle's fused
    // output, NOT from the lookup pipeline; the SRAM ports are
    // single-port-capable (one R + one W per cycle to different addrs is
    // OK for separate-port SRAM, which this is modelled as).
    // =========================================================================
    logic                       fill_pending_c;
    logic [UOC_INDEX_BITS-1:0]  fill_idx_c;
    logic [UOC_TAG_BITS-1:0]    fill_tag_c;

    assign fill_pending_c = en && (state_r == UOC_IDLE) && !active &&
                            (fused_count != 3'd0) &&
                            !redirect_valid && !invalidate;
    assign fill_idx_c     = pc_index(fused_insn[0].pc);
    assign fill_tag_c     = pc_tag(fused_insn[0].pc);

    // Probe whether this fill PC is already cached.
    // We can only probe the way ports we already have read for THIS cycle's
    // lookup_pc_r (= predicted_next_pc).  When fused_insn[0].pc matches
    // predicted_next_pc (common case: post-PLAYING resume), we get a
    // duplicate-detect for free; otherwise we conservatively do the fill,
    // which may cause occasional duplicate entries (functionally correct,
    // mildly wasteful capacity).
    logic dup_skip_c;
    assign dup_skip_c = (fill_idx_c == lookup_idx_c) && hit_c &&
                        (lookup_pc_r == fused_insn[0].pc);

    // Victim-way selection from pLRU
    logic [UOC_WAY_BITS-1:0] victim_way_c;
    assign victim_way_c = plru_victim(plru_r[fill_idx_c]);

    logic do_fill_c;
    assign do_fill_c = fill_pending_c && !dup_skip_c;

    // Tag-write port driven from fill
    assign tag_we_c     = do_fill_c;
    assign tag_waddr_c  = fill_idx_c;
    assign tag_wway_c   = victim_way_c;
    assign tag_wvalid_c = 1'b1;
    assign tag_wtag_c   = fill_tag_c;

    // Data-write ports: only the victim way is enabled for write
    always_comb begin
        for (int w = 0; w < UOC_WAYS; w++) begin
            data_we_c[w] = do_fill_c && (UOC_WAY_BITS'(w) == victim_way_c);
        end
    end
    assign data_waddr_c  = fill_idx_c;
    assign data_wcount_c = fused_count;
    always_comb begin
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            data_wdata_c[u] = fused_insn[u];
        end
    end

    // Track if the chosen victim was valid (telemetry: capacity pressure)
    logic victim_valid_at_fill_c;
    always_comb begin
        // tag_valid_out reflects lookup_idx_c (last-cycle lookup), not fill_idx_c.
        // For accurate eviction telemetry we'd need a second tag-RAM read port;
        // approximate with: signal valid only when fill index matches lookup
        // index (so tag_valid_out is accurate for this set).
        victim_valid_at_fill_c = do_fill_c && (fill_idx_c == lookup_idx_c) &&
                                 tag_valid_out[victim_way_c];
    end

    // Update pLRU: on hit, mark hit_way as MRU.  On fill, mark victim as MRU.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < UOC_SETS; s++) plru_r[s] <= '0;
        end else begin
            // Fill-path update (write happens at this set/victim)
            if (do_fill_c) begin
                plru_r[fill_idx_c] <= plru_update(plru_r[fill_idx_c], victim_way_c);
            end
            // Hit-path update (read happened at this set/hit_way last cycle)
            // Only update if not also a fill at the same set this cycle (fill wins).
            if (hit_c && !(do_fill_c && (fill_idx_c == lookup_idx_c))) begin
                plru_r[lookup_idx_c] <= plru_update(plru_r[lookup_idx_c], hit_way_c);
            end
        end
    end

    // =========================================================================
    // Telemetry counters (1-cycle pulses)
    // =========================================================================
    assign ev_lookup            = lookup_valid_r && en;
    assign ev_hit               = hit_c;
    assign ev_miss              = lookup_valid_r && en && !hit_c;
    assign ev_fill              = do_fill_c;
    assign ev_fill_evict_valid  = victim_valid_at_fill_c;
    assign ev_enter_playing     = (state_r == UOC_IDLE) && emit_c;
    assign ev_exit_playing_miss = stream_exit_c;
    assign ev_exit_playing_nohit  = stream_exit_c && !hit_c;
    assign ev_exit_playing_unsafe = stream_exit_c && hit_c && hit_data_unplayable_c;
    assign ev_emit              = emit_c;
    assign ev_emit_control      = emit_c && (emit_has_cond_c || emit_has_jal_c || emit_has_jalr_c);
    assign ev_emit_cond         = emit_c && emit_has_cond_c;
    assign ev_emit_jal          = emit_c && emit_has_jal_c;
    assign ev_emit_jalr         = emit_c && emit_has_jalr_c;
    assign ev_emit_pred_taken   = emit_c && emit_has_pred_taken_c;
    assign ev_invalidate        = invalidate;

endmodule
`endif
