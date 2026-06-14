/* file: uop_cache.sv
 Description: UOP-cache decoded-op cache (UOC-REPACK revision).

   ============================================================================
   UOC-REPACK (2026-06-13).  Gated by UOP_CACHE_ENABLE (default 0 = not
   instantiated = bit-exact shipping config).  When ENABLE=1 this is the
   *repack* UOC whose fill path packs DENSE decoded traces across packet /
   line / direct-taken-edge boundaries, so the truncation slots the line path
   leaves empty (10-46% of cycles on supply rows) are recovered from a
   resident dense entry.  This realizes UB x hit-rate (the FUND thesis,
   doc/uoc_repack_gate_2026-06-13.md).

   The as-built UOC (pre-repack) cached one truncated post-fusion fetch group
   at a time, keyed by fused_insn[0].pc, byte-for-byte equal to the 4-wide
   line packet -- the ~0%-gain root.  This revision inverts that fill path.

   --------------------------------------------------------------------------
   FILL (this module, COMPLETE here):  inversions #1/#5/#6 + the seal
   predicates of #2/#3.  A fill-build register accumulates decoded ops across
   consecutive fused groups into a head-keyed dense entry, sealing+installing
   on:
       * entry full at UOC_PER_ENTRY (4)
       * indirect target (any is_jalr -- JALR/RET/C.JR/C.JALR: the successor
         PC is register-dynamic, not statically known at fill time)
       * serializing op (CSR / FENCE / FENCE.I / AMO / ECALL / EBREAK /
         MRET / SRET / SFENCE.VMA / WFI)
       * exception
       * redirect / invalidate (flush -> drop the partial build)
   Direct control (JAL / Bcc) is packed THROUGH (does NOT seal) -- recovering
   the taken-edge truncation is the entire point.  Install keys on the
   build-HEAD pc; dup-detect + pLRU victim are head-keyed (inversion #5).
   The dense entry stores no successor PC: next_group_pc(ops,count)
   reconstructs it (a sealed entry's tail is either a direct branch with a
   known target or a sequential op; indirect/serializing tails seal and cede
   next-PC to the live frontend, inversion #1).

   REPLAY/FTQ-BYPASS (inversions #2 live-TAGE / #3 control+partial serve /
   #4 FTQ-single-enq-port, no frontend-hold, no per-exit flush):  These
   require the UOC to drive FTQ enqueues and consult live BPU/TAGE -- a
   frontend (fetch_top/ifu/bpu) rewire that is OUT of this module's current
   post-fusion / pre-rename position.  Until that frontend bypass lands, the
   replay emit path here is held at the SAFE straight-line policy (refuse
   control/partial, frontend-hold handoff) so ENABLE=1 cannot static-replay
   stale predictions (the 2026-05-05 misp-inflation failure mode).  See the
   deliverable report for the precise remaining frontend work-list.
   --------------------------------------------------------------------------

   Pipeline:
     F0  (lookup)   - drive SRAM addr = predicted next-group PC
     F1  (hit)      - SRAM data + tag compare ready
     F2  (mux/fill) - emit cached group OR accumulate+install dense entry

 Author: Jeremy Cai
 Date: Apr. 25, 2026 (UOC-REPACK 2026-06-13)
 Version: 3.0
*/
`ifndef UOP_CACHE_SV
`define UOP_CACHE_SV

module uop_cache
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,

    // Capture-side input (from fusion stage, post-decode)
    input  decoded_insn_t       fused_insn [0:PIPE_WIDTH-1],
    input  wire [2:0]          fused_count,

    // Replay-side output (to rename input mux)
    output decoded_insn_t       uoc_insn   [0:PIPE_WIDTH-1],
    output reg [2:0]          uoc_count,
    output reg                active,              // 1 = playback owns rename input
    output reg                handoff_valid,       // 1-cycle pulse on PLAYING→IDLE
    output reg [63:0]         handoff_pc,

    // Frontend redirect (commit flush, BRU early redirect, FENCE.I)
    input  wire                redirect_valid,
    input  wire [63:0]         redirect_pc,
    input  wire                invalidate,          // FENCE.I / satp / SFENCE.VMA / full-flush

    // Backpressure from rename
    input  wire                stall,

    // Telemetry counters (driven combinational; tb samples them)
    output reg                ev_lookup,
    output reg                ev_hit,
    output reg                ev_miss,
    output reg                ev_fill,
    output reg                ev_fill_evict_valid,
    output reg                ev_enter_playing,
    output reg                ev_exit_playing_miss,
    output reg                ev_exit_playing_nohit,
    output reg                ev_exit_playing_unsafe,
    output reg                ev_emit,
    output reg                ev_emit_control,
    output reg                ev_emit_cond,
    output reg                ev_emit_jal,
    output reg                ev_emit_jalr,
    output reg                ev_emit_pred_taken,
    output reg                ev_invalidate
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
    // Seal predicates (inversion #2/#3 fill-time segmentation).
    //
    // A dense build must SEAL-AND-INSTALL after an op when the successor PC is
    // not statically packable, or architectural side effects forbid replay:
    //   * indirect: any is_jalr (JALR / RET / C.JR / C.JALR -> register target)
    //   * serializing: CSR / FENCE / FENCE.I / AMO / ECALL / EBREAK / MRET /
    //                  SRET / SFENCE.VMA / WFI
    //   * exception on the op
    // Direct control (is_jal / is_branch) does NOT seal -- it packs through
    // (the whole point: recover the taken-edge truncation slots).
    // =========================================================================
    function automatic logic op_seals(input decoded_insn_t op);
        return op.is_jalr ||
               op.is_csr     || op.is_fence   || op.is_fence_i ||
               op.is_ecall   || op.is_ebreak  || op.is_mret    ||
               op.is_sret    || op.is_sfence_vma || op.is_wfi   ||
               op.is_amo     || op.has_exception;
    endfunction

    // An op cannot be densely packed AT ALL if it is fused (the fused payload
    // carries cross-op state the dense builder must not split mid-fusion) --
    // keep fused groups intact: a fused op forces the entry to seal AFTER it,
    // and a build may not START on a fused continuation.  Conservative: treat
    // fused like a seal-after.
    function automatic logic op_seals_after(input decoded_insn_t op);
        return op_seals(op) || op.is_fused;
    endfunction

    // =========================================================================
    // Predicted-next-group PC tracker.
    //
    // Drives the SRAM lookup address; one cycle later we know whether the
    // cache holds that group.  (Replay path; the FILL path keys independently
    // off the dense build head.)
    // =========================================================================
    logic [63:0] predicted_next_pc_r;
    logic [63:0] predicted_next_pc_c;          // combinational this-cycle update

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
    // =========================================================================
    logic [UOC_PLRU_BITS-1:0] plru_r [UOC_SETS];

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

    function automatic logic [6:0] plru_update(input logic [6:0] p,
                                                input logic [2:0] w);
        logic [6:0] np;
        begin
            np = p;
            np[0] = ~w[2];
            if (!w[2]) begin
                np[1] = ~w[1];
                if (!w[1]) np[3] = ~w[0];
                else       np[4] = ~w[0];
            end else begin
                np[2] = ~w[1];
                if (!w[1]) np[5] = ~w[0];
                else       np[6] = ~w[0];
            end
            return np;
        end
    endfunction

    // =========================================================================
    // F1: tag compare on SRAM read output.
    // =========================================================================
    logic [63:0] lookup_pc_r;
    logic        lookup_valid_r;

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
    // =========================================================================
    typedef enum logic {
        UOC_IDLE    = 1'b0,
        UOC_PLAYING = 1'b1
    } uoc_state_e;

    uoc_state_e state_r, state_next_c;

    // Replay-emit safety policy.
    //
    // Until the FTQ-single-enq-port + live-TAGE frontend bypass (inversions
    // #2/#3/#4) lands, REPLAY refuses control/partial groups and uses the
    // frontend-hold handoff -- so ENABLE=1 can NEVER static-replay a stored
    // prediction (the 2026-05-05 misp-inflation failure mode).  The plusargs
    // remain available to A/B the unsafe path under the unit TB only.
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

    // Output mux: when active, drive uoc_insn/uoc_count from hit_data
    always_comb begin
        for (int u = 0; u < PIPE_WIDTH; u++) begin
            uoc_insn[u] = active ? hit_data_c[u] : '0;
        end
        uoc_count = active ? hit_count_c : 3'd0;
    end

    assign handoff_valid = stream_exit_c;
    assign handoff_pc    = lookup_pc_r;

    // =========================================================================
    // Predicted-next-PC update (combinational, drives F0 lookup)
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

    assign tag_raddr_c  = pc_index(predicted_next_pc_c);
    assign data_raddr_c = pc_index(predicted_next_pc_c);

    // =========================================================================
    // FILL — DENSE TRACE BUILDER (inversion #1/#5; segmentation #2/#3).
    //
    // A fill-build register accumulates decoded ops across consecutive fused
    // groups.  Each fused group this cycle is appended op-by-op into the
    // build buffer.  The buffer SEALS-AND-INSTALLS (head-keyed) when it
    // reaches UOC_PER_ENTRY ops, or right after an op that op_seals_after().
    // Direct control (is_jal/is_branch, non-fused) packs through.
    //
    // Contiguity: the builder only appends a group whose head PC equals the
    // sequential/taken successor of the current build tail (next_group_pc of
    // the partial build).  A discontiguous head (mispredict redirect target,
    // wrong-path) restarts the build at that head.  This keeps every dense
    // entry a real architectural straight-or-direct-taken trace.
    //
    // The builder is fed only on cycles where fused delivers a non-empty
    // group and the UOC is not replaying (active=0) and not flushing.  This
    // is the donor-residency mechanism: a hot loop's dense entry becomes
    // resident after one pass and is then a HIT on the next pass.
    // =========================================================================
    decoded_insn_t build_ops_r [0:UOC_PER_ENTRY-1];
    logic [2:0]    build_count_r;              // 0..UOC_PER_ENTRY
    logic [63:0]   build_head_pc_r;
    logic          build_valid_r;              // a build is in progress
    logic [63:0]   build_next_pc_r;            // expected next head (contiguity)

    // Combinational next-state of the builder + the install decision.
    decoded_insn_t build_ops_n [0:UOC_PER_ENTRY-1];
    logic [2:0]    build_count_n;
    logic [63:0]   build_head_pc_n;
    logic          build_valid_n;
    logic [63:0]   build_next_pc_n;

    logic          install_c;                  // seal+install this cycle
    logic [UOC_PER_ENTRY-1:0] install_op_valid_c;
    decoded_insn_t install_ops_c [0:UOC_PER_ENTRY-1];
    logic [2:0]    install_count_c;
    logic [63:0]   install_head_pc_c;

    // Feed condition: fused delivering, UOC not replaying, no flush.
    logic fill_feed_c;
    assign fill_feed_c = en && (state_r == UOC_IDLE) && !active &&
                         (fused_count != 3'd0) &&
                         !redirect_valid && !invalidate;

    always_comb begin
        // Default: hold the build.
        for (int u = 0; u < UOC_PER_ENTRY; u++) build_ops_n[u] = build_ops_r[u];
        build_count_n   = build_count_r;
        build_head_pc_n = build_head_pc_r;
        build_valid_n   = build_valid_r;
        build_next_pc_n = build_next_pc_r;

        install_c         = 1'b0;
        install_count_c   = 3'd0;
        install_head_pc_c = build_head_pc_r;
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            install_ops_c[u]      = build_ops_r[u];
            install_op_valid_c[u] = 1'b0;
        end

        if (redirect_valid || invalidate) begin
            // Drop the partial build on any flush (cede next-PC, inversion #1).
            build_count_n = 3'd0;
            build_valid_n = 1'b0;
        end else if (fill_feed_c) begin : do_accumulate
            // Working copy we mutate op-by-op across this fused group.
            decoded_insn_t w_ops [0:UOC_PER_ENTRY-1];
            logic [2:0]    w_count;
            logic [63:0]   w_head;
            logic          w_valid;
            logic [63:0]   w_next;
            logic          group_contig;

            for (int u = 0; u < UOC_PER_ENTRY; u++) w_ops[u] = build_ops_r[u];
            w_count = build_count_r;
            w_head  = build_head_pc_r;
            w_valid = build_valid_r;
            w_next  = build_next_pc_r;

            // Contiguity test for the head of this fused group.
            group_contig = w_valid && (fused_insn[0].pc == w_next);
            if (!w_valid || !group_contig) begin
                // (Re)start the build at this group's head.  If a partial
                // build was open and discontiguous, install it first iff it
                // holds >=1 op (a real trace), else just drop it.
                if (w_valid && (w_count != 3'd0)) begin
                    install_c       = 1'b1;
                    install_count_c = w_count;
                    install_head_pc_c = w_head;
                    for (int u = 0; u < UOC_PER_ENTRY; u++) begin
                        install_ops_c[u]      = w_ops[u];
                        install_op_valid_c[u] = (3'(u) < w_count);
                    end
                end
                w_count = 3'd0;
                w_head  = fused_insn[0].pc;
                w_valid = 1'b1;
            end

            // Append each op of the fused group.  On a fill-only-one-install
            // restriction (single data-RAM write port per cycle), we permit
            // at most ONE seal+install per cycle: if a second seal would be
            // needed, stop appending and carry the rest as the new build.
            // In practice a fused group is <=4 ops and seals are sparse, so
            // one install/cycle covers the overwhelmingly common case; the
            // residual (two seals in one 4-wide group) simply defers the
            // second trace's install to the next contiguous pass.
            for (int g = 0; g < PIPE_WIDTH; g++) begin
                if ((3'(g) < fused_count) && !install_c) begin
                    // append op g
                    w_ops[w_count] = fused_insn[g];
                    w_count        = w_count + 3'd1;
                    w_next         = fused_insn[g].bp_taken ?
                                        fused_insn[g].bp_target :
                                        (fused_insn[g].pc +
                                         (fused_insn[g].is_rvc ? 64'd2 : 64'd4));
                    // Seal?
                    if ((w_count == 3'(UOC_PER_ENTRY)) ||
                        op_seals_after(fused_insn[g])) begin
                        install_c       = 1'b1;
                        install_count_c = w_count;
                        install_head_pc_c = w_head;
                        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
                            install_ops_c[u]      = w_ops[u];
                            install_op_valid_c[u] = (3'(u) < w_count);
                        end
                        // Reset build for whatever follows the seal.
                        w_count = 3'd0;
                        w_head  = w_next;
                        // If the sealing op ceded next-PC (indirect/serializing/
                        // exception), the successor is dynamic -> close the
                        // build (live frontend owns next-PC).
                        if (op_seals(fused_insn[g])) begin
                            w_valid = 1'b0;
                        end else begin
                            w_valid = 1'b1;
                        end
                    end
                end
            end

            for (int u = 0; u < UOC_PER_ENTRY; u++) build_ops_n[u] = w_ops[u];
            build_count_n   = w_count;
            build_head_pc_n = w_head;
            build_valid_n   = w_valid;
            build_next_pc_n = w_next;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            build_count_r   <= 3'd0;
            build_valid_r   <= 1'b0;
            build_head_pc_r <= '0;
            build_next_pc_r <= '0;
        end else begin
            for (int u = 0; u < UOC_PER_ENTRY; u++) build_ops_r[u] <= build_ops_n[u];
            build_count_r   <= build_count_n;
            build_head_pc_r <= build_head_pc_n;
            build_valid_r   <= build_valid_n;
            build_next_pc_r <= build_next_pc_n;
        end
    end

    // =========================================================================
    // INSTALL: write the sealed dense entry, head-keyed (inversion #5).
    // =========================================================================
    logic [UOC_INDEX_BITS-1:0]  fill_idx_c;
    logic [UOC_TAG_BITS-1:0]    fill_tag_c;
    assign fill_idx_c = pc_index(install_head_pc_c);
    assign fill_tag_c = pc_tag(install_head_pc_c);

    // Dup-detect, head-keyed: skip the install iff the build head is already
    // the resident lookup hit (common post-replay resume).  Re-keyed to the
    // build head, not the per-group pc.
    logic dup_skip_c;
    assign dup_skip_c = (fill_idx_c == lookup_idx_c) && hit_c &&
                        (lookup_pc_r == install_head_pc_c);

    logic [UOC_WAY_BITS-1:0] victim_way_c;
    assign victim_way_c = plru_victim(plru_r[fill_idx_c]);

    logic do_fill_c;
    assign do_fill_c = install_c && !dup_skip_c;

    assign tag_we_c     = do_fill_c;
    assign tag_waddr_c  = fill_idx_c;
    assign tag_wway_c   = victim_way_c;
    assign tag_wvalid_c = 1'b1;
    assign tag_wtag_c   = fill_tag_c;

    always_comb begin
        for (int w = 0; w < UOC_WAYS; w++) begin
            data_we_c[w] = do_fill_c && (UOC_WAY_BITS'(w) == victim_way_c);
        end
    end
    assign data_waddr_c  = fill_idx_c;
    assign data_wcount_c = install_count_c;
    always_comb begin
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            data_wdata_c[u] = install_op_valid_c[u] ? install_ops_c[u]
                                                    : '0;
        end
    end

    logic victim_valid_at_fill_c;
    always_comb begin
        victim_valid_at_fill_c = do_fill_c && (fill_idx_c == lookup_idx_c) &&
                                 tag_valid_out[victim_way_c];
    end

    // pLRU update.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < UOC_SETS; s++) plru_r[s] <= '0;
        end else begin
            if (do_fill_c) begin
                plru_r[fill_idx_c] <= plru_update(plru_r[fill_idx_c], victim_way_c);
            end
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
