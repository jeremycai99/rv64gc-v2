/* file: rename.sv
 Description: Six-wide register renaming with RAT and free list.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rename
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Input: decoded instructions from decode (up to 6)
    input  decoded_insn_t dec_insn [0:PIPE_WIDTH-1],
    input  logic [2:0]    dec_count,     // how many valid decoded insns (0..6)

    // Output: renamed instructions to dispatch queue (up to 6)
    output renamed_insn_t ren_insn [0:PIPE_WIDTH-1],
    output logic [2:0]    ren_count,     // how many renamed this cycle (0..6)

    // Move/zero elimination flags for each output slot (set when the
    // instruction was eliminated at rename and must NOT be dispatched)
    output logic [PIPE_WIDTH-1:0] ren_move_eliminated,
    output logic [PIPE_WIDTH-1:0] ren_zero_eliminated,

    // ROB allocation interface
    input  logic [ROB_IDX_BITS-1:0] rob_alloc_idx [0:PIPE_WIDTH-1],
    input  logic                    rob_alloc_ready,  // ROB can accept

    // Stall output (backpressure to decode/fetch)
    output logic stall,

    // Dispatch queue backpressure
    input  logic dq_full,

    // LQ/SQ allocation
    input  logic [LQ_IDX_BITS-1:0]  lq_alloc_idx [0:PIPE_WIDTH-1],
    input  logic [SQ_IDX_BITS-1:0]  sq_alloc_idx [0:PIPE_WIDTH-1],
    input  logic                    lq_full,
    input  logic                    sq_full,

    // PRF ready table (which physical registers have been written)
    input  logic [INT_PRF_DEPTH-1:0] preg_ready_table,

    // Flush (from commit)
    input  flush_t flush_in,

    // Commit: release old_pdst to free list + update committed RAT
    input  logic [2:0]               commit_count,
    input  logic [PHYS_REG_BITS-1:0] commit_old_pdst [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]    commit_rd_valid,
    input  logic [4:0]               commit_rd_arch  [0:PIPE_WIDTH-1],
    input  logic [PHYS_REG_BITS-1:0] commit_pdst     [0:PIPE_WIDTH-1],
    // Checkpoint release from commit
    input  logic [PIPE_WIDTH-1:0]              commit_release_cp,
    input  logic [CHECKPOINT_BITS-1:0]         commit_cp_id [0:PIPE_WIDTH-1]
);

    // =========================================================================
    // Holding register: retains decoded instructions that could not advance
    // Stored as flat bit-vectors to avoid Verilator packed-struct array bugs.
    // =========================================================================
    localparam int HI_W = $bits(decoded_insn_t);
    logic [HI_W-1:0] hold_insn_flat [0:PIPE_WIDTH-1];
    decoded_insn_t hold_insn [0:PIPE_WIDTH-1];
    always_comb begin
        for (int k = 0; k < PIPE_WIDTH; k++)
            hold_insn[k] = decoded_insn_t'(hold_insn_flat[k]);
    end
    logic [PIPE_WIDTH-1:0] hold_valid;
    logic                  hold_active_c;

    assign hold_active_c = |hold_valid;

    // =========================================================================
    // Merged working set: held insns first, then new decode insns fill gaps
    // =========================================================================
    decoded_insn_t work_insn [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0] work_valid;

    // =========================================================================
    // Move elimination detection per slot
    // =========================================================================
    logic [PIPE_WIDTH-1:0] is_move_elim;
    logic [PIPE_WIDTH-1:0] is_zero_elim;  // li rd, 0 or xor rd, rd, rd

    // =========================================================================
    // Per-slot advance signals
    // =========================================================================
    logic [PIPE_WIDTH-1:0] slot_can_advance;
    logic [PIPE_WIDTH-1:0] slot_needs_preg;    // slot needs a free list alloc
    logic [PIPE_WIDTH-1:0] slot_needs_lq;
    logic [PIPE_WIDTH-1:0] slot_needs_sq;
    logic [PIPE_WIDTH-1:0] slot_needs_ckpt;

    // =========================================================================
    // Free list allocation tracking
    // =========================================================================
    logic [2:0] fl_req_count;
    logic [PHYS_REG_BITS-1:0] fl_alloc_preg [0:PIPE_WIDTH-1];
    logic [2:0] fl_avail_count;

    // Map each slot to its position in the free list allocation sequence
    logic [2:0] fl_slot_idx [0:PIPE_WIDTH-1];

    // =========================================================================
    // Checkpoint signals
    // =========================================================================
    logic ckpt_save_valid;
    logic [CHECKPOINT_BITS-1:0] ckpt_save_id;
    logic ckpt_save_avail;

    // Snapshot data for checkpoint
    logic [PHYS_REG_BITS-1:0] rat_snapshot [0:31];
    logic [INT_PRF_DEPTH-1:0] fl_bitmap_snapshot;
    logic [ROB_IDX_BITS-1:0]  rob_tail_snapshot;

    // Restore outputs (driven by flush path to checkpoint module)
    logic [PHYS_REG_BITS-1:0] restored_rat [0:31];
    logic [INT_PRF_DEPTH-1:0] restored_fl_bitmap;
    logic [ROB_IDX_BITS-1:0]  restored_rob_tail;

    // =========================================================================
    // RAT interface signals
    // =========================================================================
    logic [ARCH_REG_BITS-1:0] rat_rs1_arch [0:PIPE_WIDTH-1];
    logic [ARCH_REG_BITS-1:0] rat_rs2_arch [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] rat_rs1_phys [0:PIPE_WIDTH-1];
    logic [PHYS_REG_BITS-1:0] rat_rs2_phys [0:PIPE_WIDTH-1];

    logic [PIPE_WIDTH-1:0]    rat_wr_en;
    logic [ARCH_REG_BITS-1:0] rat_wr_arch [0:PIPE_WIDTH-1];
    // verilator lint_off UNOPTFLAT
    // rat_wr_phys feeds into RAT which outputs rat_rs1_phys, which feeds back
    // into rat_wr_phys for move-eliminated slots.  This is a valid cascading
    // dependency (slot i depends on slot j < i), not a true combinational loop.
    logic [PHYS_REG_BITS-1:0] rat_wr_phys [0:PIPE_WIDTH-1];
    // verilator lint_on UNOPTFLAT
    logic [PHYS_REG_BITS-1:0] rat_old_phys [0:PIPE_WIDTH-1];

    // =========================================================================
    // Free list release: count how many valid old_pdst from commit
    // =========================================================================
    logic [2:0]               fl_release_count;
    logic [PHYS_REG_BITS-1:0] fl_release_preg [0:PIPE_WIDTH-1];

    // =========================================================================
    // Commit write-enable for CRAT and committed free-list bitmap
    // =========================================================================
    logic [PIPE_WIDTH-1:0] crat_wr_en;
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            crat_wr_en[i] = commit_rd_valid[i] && (3'(i) < commit_count);
        end
    end

    // =========================================================================
    // Internal flush signals
    // =========================================================================
    logic do_flush;
    assign do_flush = flush_in.valid && flush_in.full_flush;

    logic do_ckpt_restore;
    assign do_ckpt_restore = flush_in.valid && !flush_in.full_flush;

    // =========================================================================
    // Per-slot advance resource tracking
    // =========================================================================
    logic found_ckpt_branch;
    logic [2:0] ckpt_branch_slot;

    // Cumulative resource counters at each slot boundary (prefix sums)
    logic [2:0] preg_consumed_before [0:PIPE_WIDTH];
    logic [2:0] rob_consumed_before  [0:PIPE_WIDTH];
    logic       ckpt_consumed_before [0:PIPE_WIDTH];

    // Per-slot resource availability flags
    logic [PIPE_WIDTH-1:0] has_preg;
    logic [PIPE_WIDTH-1:0] has_lq;
    logic [PIPE_WIDTH-1:0] has_sq;
    logic [PIPE_WIDTH-1:0] has_ckpt;
    logic [PIPE_WIDTH-1:0] has_rob;
    logic [PIPE_WIDTH-1:0] has_dq;

    // slot_can_advance_sp: "sans preg" — all non-preg resources available.
    // Breaks the preg/has_preg/fl_avail circular dependency so fl_req_count
    // and fl_slot_idx can be gated by an advance decision that's computed
    // BEFORE the free-list returns fl_avail_count.  Prevents alloc-but-
    // no-advance orphans that leak pregs into the free pool and deplete it.
    logic [PIPE_WIDTH-1:0] slot_can_advance_sp;
    logic [2:0] sp_ckpt_consumed_before [0:PIPE_WIDTH];
    logic       in_order_open_sp [0:PIPE_WIDTH];
    logic       in_order_open    [0:PIPE_WIDTH];

    // =========================================================================
    // Work slot compaction indices: map held/decode insns to work positions
    // Held insns compact to bottom, decode fills rest.
    // Implemented with cascading counters.
    // =========================================================================
    // hold_pos[i]: which work slot does held slot i land in? (-1 if invalid)
    // dec_pos[i]:  which work slot does decode slot i land in?
    logic [2:0] hold_dest [0:PIPE_WIDTH-1];
    logic [2:0] dec_dest  [0:PIPE_WIDTH-1];
    logic [2:0] num_held;
    logic [2:0] num_accepted_dec;

    // Output compaction: which output slot does advancing work slot i map to?
    logic [2:0] out_dest [0:PIPE_WIDTH-1];

    // Stall intermediates
    logic       any_work_advance_c;
    logic       capture_nonadvance_c;

    // Holding register next-state compaction
    logic [2:0] next_hold_dest [0:PIPE_WIDTH-1];

    // =========================================================================
    // Submodule instances
    // =========================================================================

    rat u_rat (
        .clk          (clk),
        .rst_n        (rst_n),
        .rs1_arch     (rat_rs1_arch),
        .rs2_arch     (rat_rs2_arch),
        .rs1_phys     (rat_rs1_phys),
        .rs2_phys     (rat_rs2_phys),
        .wr_en        (rat_wr_en),
        .wr_arch      (rat_wr_arch),
        .wr_phys      (rat_wr_phys),
        .old_phys     (rat_old_phys),
        .commit_wr_en (crat_wr_en),
        .commit_arch  (commit_rd_arch),
        .commit_phys  (commit_pdst),
        .ckpt_save    (ckpt_save_valid),
        .ckpt_save_id (ckpt_save_id),
        .ckpt_restore (do_ckpt_restore),
        .ckpt_restore_id (flush_in.checkpoint_id),
        .flush        (do_flush)
    );

    free_list u_free_list (
        .clk              (clk),
        .rst_n            (rst_n),
        .alloc_req_count  (fl_req_count),
        .alloc_preg       (fl_alloc_preg),
        .alloc_avail_count(fl_avail_count),
        .release_count    (fl_release_count),
        .release_preg     (fl_release_preg),
        .commit_wr_valid  (crat_wr_en),
        .commit_pdst      (commit_pdst),
        .ckpt_save        (ckpt_save_valid),
        .ckpt_save_id     (ckpt_save_id),
        .ckpt_restore     (do_ckpt_restore),
        .ckpt_restore_id  (flush_in.checkpoint_id),
        .flush            (do_flush)
    );

    checkpoint u_checkpoint (
        .clk                (clk),
        .rst_n              (rst_n),
        .save_valid         (ckpt_save_valid),
        .save_id            (ckpt_save_id),
        .save_avail         (ckpt_save_avail),
        .rat_snapshot       (rat_snapshot),
        .fl_bitmap_snapshot (fl_bitmap_snapshot),
        .rob_tail_snapshot  (rob_tail_snapshot),
        .restore_valid      (do_ckpt_restore),
        .restore_id         (flush_in.checkpoint_id),
        .restored_rat       (restored_rat),
        .restored_fl_bitmap (restored_fl_bitmap),
        .restored_rob_tail  (restored_rob_tail),
        .release_valid      (commit_release_cp),
        .release_id         (commit_cp_id),
        .flush              (do_flush || do_ckpt_restore)
    );

    // =========================================================================
    // Commit release: per-slot gated release (defense in depth)
    // =========================================================================
    always_comb begin
        fl_release_count = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            fl_release_preg[i] = (commit_rd_valid[i] && (3'(i) < commit_count))
                                 ? commit_old_pdst[i] : '0;
        end
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (commit_rd_valid[i] && (3'(i) < commit_count)) begin
                fl_release_count = 3'(i + 1);
            end
        end
    end

    // =========================================================================
    // Merge holding register with new decode input
    //
    // Held insns compact to the lowest work slots, then new decode insns
    // fill remaining positions.  No 'automatic' variables needed: we use
    // a running counter accumulated across the loop.
    // =========================================================================
    always_comb begin
        num_held = '0;
        num_accepted_dec = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            work_insn[i]  = '0;
            work_valid[i] = 1'b0;
            hold_dest[i]  = '0;
            dec_dest[i]   = '0;
        end

        // Pass 1: compact held insns into lowest work slots
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (hold_valid[i]) begin
                hold_dest[i] = num_held;
                work_insn[num_held]  = hold_insn[i];
                work_valid[num_held] = 1'b1;
                num_held = num_held + 3'd1;
            end
        end

        // Pass 2: fill remaining work slots with new decode input.
        // If the hold register is occupied, it owns rename for this cycle and
        // decode is stalled. Mixing held slots with a fresh decode packet can
        // accept only a prefix of that packet and drop its tail.
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (!hold_active_c &&
                (3'(i) < dec_count) && dec_insn[i].valid &&
                (num_held + num_accepted_dec) < 3'(PIPE_WIDTH)) begin
                dec_dest[i] = num_held + num_accepted_dec;
                work_insn[num_held + num_accepted_dec]  = dec_insn[i];
                work_valid[num_held + num_accepted_dec] = 1'b1;
                num_accepted_dec = num_accepted_dec + 3'd1;
            end
        end
    end

    // =========================================================================
    // Move elimination detection
    //
    // Patterns:
    //   mv rd, rs    = ALU_ADD, use_imm=1, imm==0, rs1!=x0
    //   li rd, 0     = ALU_ADD, use_imm=1, imm==0, rs1==x0
    //   xor rd,rd,rd = ALU_XOR, !use_imm, rs1==rs2
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            is_move_elim[i] = 1'b0;
            is_zero_elim[i] = 1'b0;

            if (work_valid[i] && work_insn[i].rd_valid &&
                work_insn[i].rd_arch != 5'd0 &&
                work_insn[i].fu_type == FU_ALU) begin

                // Keep move elimination disabled: aliasing a destination to
                // an arbitrary source physical register needs lifetime/refcount
                // support that this pipeline does not yet have.  Zero-only
                // elimination is safe because it maps the destination to p0,
                // the hardwired-zero register, and consumes no new preg.
                if (work_insn[i].alu_op == ALU_ADD &&
                    work_insn[i].use_imm &&
                    work_insn[i].imm == 64'd0 &&
                    work_insn[i].rs1_arch == 5'd0) begin
                    is_zero_elim[i] = 1'b1; // li rd, 0
                end else if (work_insn[i].alu_op == ALU_XOR &&
                             !work_insn[i].use_imm &&
                             work_insn[i].rs1_valid &&
                             work_insn[i].rs2_valid &&
                             (work_insn[i].rs1_arch == work_insn[i].rs2_arch)) begin
                    is_zero_elim[i] = 1'b1; // xor rd, rs, rs
                end
            end
        end
    end

    // =========================================================================
    // Determine which slots need resources
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            slot_needs_preg[i] = work_valid[i] && work_insn[i].rd_valid &&
                                 (work_insn[i].rd_arch != 5'd0) &&
                                 !is_move_elim[i] && !is_zero_elim[i];

            slot_needs_lq[i]   = work_valid[i] && work_insn[i].is_load;
            slot_needs_sq[i]   = work_valid[i] && work_insn[i].is_store;
            slot_needs_ckpt[i] = work_valid[i] && work_insn[i].is_branch;
        end
    end

    // =========================================================================
    // Pass 1: slot_can_advance_sp (sans preg).
    //
    // We need a pre-fl-avail decision on whether each slot CAN advance
    // based on non-preg resources, so that fl_req_count only requests
    // pregs for slots that will actually use them.  This eliminates the
    // "alloc-but-no-advance orphan" leak where free_list clears a bit for
    // a slot that ultimately can't advance due to LQ/SQ/CKPT/ROB/DQ
    // limits.  preg shortage is handled afterwards by has_preg below.
    // =========================================================================
    always_comb begin
        sp_ckpt_consumed_before[0] = 1'b0;
        in_order_open_sp[0]        = 1'b1;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            slot_can_advance_sp[i] = 1'b0;
            has_lq[i]   = 1'b1;
            has_sq[i]   = 1'b1;
            has_ckpt[i] = 1'b1;
            has_rob[i]  = 1'b1;
            has_dq[i]   = 1'b1;

            if (work_valid[i]) begin
                if (slot_needs_lq[i])   has_lq[i]   = !lq_full;
                if (slot_needs_sq[i])   has_sq[i]   = !sq_full;
                if (slot_needs_ckpt[i]) begin
                    has_ckpt[i] = !sp_ckpt_consumed_before[i] && ckpt_save_avail;
                end
                has_rob[i] = rob_alloc_ready;
                has_dq[i]  = !dq_full;
                slot_can_advance_sp[i] = in_order_open_sp[i] &&
                                         has_lq[i] && has_sq[i] &&
                                         has_ckpt[i] && has_rob[i] && has_dq[i];
            end

            sp_ckpt_consumed_before[i+1] = sp_ckpt_consumed_before[i];
            in_order_open_sp[i+1]        = in_order_open_sp[i];
            if (work_valid[i] && !slot_can_advance_sp[i]) begin
                in_order_open_sp[i+1] = 1'b0;
            end
            if (slot_can_advance_sp[i] && slot_needs_ckpt[i]) begin
                sp_ckpt_consumed_before[i+1] = 1'b1;
            end
        end
    end

    // =========================================================================
    // Free list allocation request count (gated by slot_can_advance_sp).
    // Only slots that will actually advance (modulo preg availability) are
    // counted — avoids orphan allocations.
    // =========================================================================
    always_comb begin
        fl_req_count = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (slot_needs_preg[i] && slot_can_advance_sp[i]) begin
                fl_req_count = fl_req_count + 3'd1;
            end
        end
    end

    // =========================================================================
    // Map each advancing preg-needing slot to its index in fl_alloc_preg[].
    // Same sp gating as fl_req_count so the mapping is contiguous from 0.
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            fl_slot_idx[i] = '0;
        end
        fl_slot_idx[0] = '0;
        for (int i = 1; i < PIPE_WIDTH; i++) begin
            fl_slot_idx[i] = fl_slot_idx[i-1];
            if (slot_needs_preg[i-1] && slot_can_advance_sp[i-1]) begin
                fl_slot_idx[i] = fl_slot_idx[i-1] + 3'd1;
            end
        end
    end

    // =========================================================================
    // Pass 2: final slot_can_advance with preg availability.
    //
    // has_lq/has_sq/has_ckpt/has_rob/has_dq were set by Pass 1 along with
    // slot_can_advance_sp.  Here we add the preg gate: fl_slot_idx[i] (the
    // sp-gated prefix count of preg-needing slots before i) must be less
    // than fl_avail_count returned by the free list.  If a slot needed a
    // preg but pool exhausted, it doesn't advance and its preg position
    // won't be consumed by free_list (fl_req_count is sp-gated too, so
    // free_list only clears bits that will actually be used).
    // =========================================================================
    always_comb begin
        preg_consumed_before[0] = '0;
        rob_consumed_before[0]  = '0;
        ckpt_consumed_before[0] = 1'b0;
        in_order_open[0]        = 1'b1;

        found_ckpt_branch = 1'b0;
        ckpt_branch_slot  = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            has_preg[i] = 1'b1;
            if (work_valid[i] && slot_needs_preg[i]) begin
                has_preg[i] = (fl_slot_idx[i] < fl_avail_count);
            end

            slot_can_advance[i] = slot_can_advance_sp[i] &&
                                  in_order_open[i] &&
                                  has_preg[i];

            preg_consumed_before[i+1] = preg_consumed_before[i];
            rob_consumed_before[i+1]  = rob_consumed_before[i];
            ckpt_consumed_before[i+1] = ckpt_consumed_before[i];
            in_order_open[i+1]        = in_order_open[i];

            if (work_valid[i] && !slot_can_advance[i]) begin
                in_order_open[i+1] = 1'b0;
            end

            if (slot_can_advance[i]) begin
                if (slot_needs_preg[i]) begin
                    preg_consumed_before[i+1] = preg_consumed_before[i] + 3'd1;
                end
                rob_consumed_before[i+1] = rob_consumed_before[i] + 3'd1;
                if (slot_needs_ckpt[i]) begin
                    ckpt_consumed_before[i+1] = 1'b1;
                    found_ckpt_branch = 1'b1;
                    ckpt_branch_slot  = 3'(i);
                end
            end
        end
    end

    // =========================================================================
    // Checkpoint save: triggered when a branch slot advances
    // =========================================================================
    assign ckpt_save_valid = found_ckpt_branch;

    // Snapshot data for checkpoint module.
    // The RAT and free_list each save their own internal state via ckpt_save.
    // We provide the ROB tail to the checkpoint module.
    always_comb begin
        for (int i = 0; i < 32; i++) begin
            rat_snapshot[i] = '0;
        end
        fl_bitmap_snapshot = '0;
        rob_tail_snapshot  = rob_alloc_idx[0];
    end

    // =========================================================================
    // RAT read/write wiring
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Source lookups
            rat_rs1_arch[i] = work_insn[i].rs1_arch;
            rat_rs2_arch[i] = work_insn[i].rs2_arch;

            // Destination writes: only for advancing slots with valid rd
            rat_wr_en[i]   = 1'b0;
            rat_wr_arch[i] = work_insn[i].rd_arch;
            rat_wr_phys[i] = '0;

            if (slot_can_advance[i] && work_insn[i].rd_valid &&
                work_insn[i].rd_arch != 5'd0) begin
                rat_wr_en[i] = 1'b1;

                if (is_zero_elim[i]) begin
                    rat_wr_phys[i] = {PHYS_REG_BITS{1'b0}};
                end else if (is_move_elim[i]) begin
                    rat_wr_phys[i] = rat_rs1_phys[i];
                end else begin
                    rat_wr_phys[i] = fl_alloc_preg[fl_slot_idx[i]];
                end
            end
        end
    end

    // =========================================================================
    // Output renamed instructions
    //
    // Compact advancing slots into contiguous output positions.
    // Use a running output index accumulated across the loop.
    // =========================================================================
    // Prefix sum of advancing slots for output compaction
    logic [2:0] advance_prefix [0:PIPE_WIDTH];

    always_comb begin
        advance_prefix[0] = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            out_dest[i] = advance_prefix[i];
            if (slot_can_advance[i]) begin
                advance_prefix[i+1] = advance_prefix[i] + 3'd1;
            end else begin
                advance_prefix[i+1] = advance_prefix[i];
            end
        end
        ren_count = advance_prefix[PIPE_WIDTH];
    end

    int lq_cnt;
    int sq_cnt;

    always_comb begin
        // Running counters for LQ/SQ allocation among advancing slots
        lq_cnt = 0;
        sq_cnt = 0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ren_insn[i] = '0;
        end

        // Default: nothing eliminated
        ren_move_eliminated = '0;
        ren_zero_eliminated = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (slot_can_advance[i]) begin
                ren_insn[out_dest[i]].base = work_insn[i];

                // Physical register mappings
                ren_insn[out_dest[i]].rs1_phys = rat_rs1_phys[i];
                ren_insn[out_dest[i]].rs2_phys = rat_rs2_phys[i];

                // Destination physical register
                if (work_insn[i].rd_valid && work_insn[i].rd_arch != 5'd0) begin
                    if (is_zero_elim[i]) begin
                        ren_insn[out_dest[i]].pdst = {PHYS_REG_BITS{1'b0}};
                    end else if (is_move_elim[i]) begin
                        ren_insn[out_dest[i]].pdst = rat_rs1_phys[i];
                    end else begin
                        ren_insn[out_dest[i]].pdst = fl_alloc_preg[fl_slot_idx[i]];
                    end
                end else begin
                    ren_insn[out_dest[i]].pdst = '0;
                end

                // Old physical destination (for free list release at commit)
                ren_insn[out_dest[i]].old_pdst = rat_old_phys[i];

                // Source readiness from PRF ready table
                if (work_insn[i].rs1_valid && work_insn[i].rs1_arch != 5'd0) begin
                    ren_insn[out_dest[i]].rs1_ready = preg_ready_table[rat_rs1_phys[i]];
                end else begin
                    ren_insn[out_dest[i]].rs1_ready = 1'b1;
                end

                if (work_insn[i].rs2_valid && work_insn[i].rs2_arch != 5'd0) begin
                    ren_insn[out_dest[i]].rs2_ready = preg_ready_table[rat_rs2_phys[i]];
                end else begin
                    ren_insn[out_dest[i]].rs2_ready = 1'b1;
                end

                // Intra-batch dependency: if an earlier slot in this batch
                // allocates a new physical register that matches our source,
                // the source is NOT ready (the producer hasn't executed yet).
                // Skip zero-elim and move-elim producers: they don't allocate
                // a new physical register, so the existing mapping is already valid.
                for (int j = 0; j < i; j++) begin
                    if (slot_can_advance[j] && work_insn[j].rd_valid &&
                        work_insn[j].rd_arch != 5'd0 &&
                        !is_zero_elim[j] && !is_move_elim[j]) begin
                        if (work_insn[i].rs1_valid && work_insn[i].rs1_arch != 5'd0 &&
                            rat_rs1_phys[i] == rat_wr_phys[j]) begin
                            ren_insn[out_dest[i]].rs1_ready = 1'b0;
                        end
                        if (work_insn[i].rs2_valid && work_insn[i].rs2_arch != 5'd0 &&
                            rat_rs2_phys[i] == rat_wr_phys[j]) begin
                            ren_insn[out_dest[i]].rs2_ready = 1'b0;
                        end
                    end
                end

                // Move-eliminated instructions are ready at rename
                if (is_move_elim[i] || is_zero_elim[i]) begin
                    ren_insn[out_dest[i]].rs1_ready = 1'b1;
                    ren_insn[out_dest[i]].rs2_ready = 1'b1;
                end

                // Flag eliminated instructions for the core top-level
                if (is_move_elim[i])
                    ren_move_eliminated[out_dest[i]] = 1'b1;
                if (is_zero_elim[i])
                    ren_zero_eliminated[out_dest[i]] = 1'b1;

                // ROB index
                ren_insn[out_dest[i]].rob_idx = rob_alloc_idx[out_dest[i]];

                // Checkpoint
                if (work_insn[i].is_branch && found_ckpt_branch &&
                    ckpt_branch_slot == 3'(i)) begin
                    ren_insn[out_dest[i]].checkpoint_id   = ckpt_save_id;
                    ren_insn[out_dest[i]].uses_checkpoint  = 1'b1;
                end else begin
                    ren_insn[out_dest[i]].checkpoint_id   = '0;
                    ren_insn[out_dest[i]].uses_checkpoint  = 1'b0;
                end

                // LQ/SQ indices: use running counters, not output position,
                // because alloc_idx arrays are indexed by store/load number
                // within the batch, not by overall instruction position.
                if (work_insn[i].is_load) begin
                    ren_insn[out_dest[i]].lq_idx = lq_alloc_idx[lq_cnt];
                    lq_cnt = lq_cnt + 1;
                end else begin
                    ren_insn[out_dest[i]].lq_idx = '0;
                end
                if (work_insn[i].is_store) begin
                    ren_insn[out_dest[i]].sq_idx = sq_alloc_idx[sq_cnt];
                    sq_cnt = sq_cnt + 1;
                end else begin
                    ren_insn[out_dest[i]].sq_idx = '0;
                end
            end
        end
    end

    // =========================================================================
    // Stall: backpressure to decode/fetch
    //
    // The hold buffer owns rename while active because fresh decode slots are
    // not merged into the held work set. For a fresh decode packet, assert
    // backpressure only when no slot can advance; partial progress captures
    // the non-advanced tail into hold and lets decode accept the next packet.
    // =========================================================================
    assign any_work_advance_c = |slot_can_advance;
    assign capture_nonadvance_c = hold_active_c || any_work_advance_c;
    assign stall = hold_active_c ||
                   ((|work_valid) && !any_work_advance_c);

    // =========================================================================
    // Holding register next-state compaction indices
    // =========================================================================
    logic [2:0] nonadv_prefix [0:PIPE_WIDTH];

    always_comb begin
        nonadv_prefix[0] = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            next_hold_dest[i] = nonadv_prefix[i];
            if (work_valid[i] && !slot_can_advance[i]) begin
                nonadv_prefix[i+1] = nonadv_prefix[i] + 3'd1;
            end else begin
                nonadv_prefix[i+1] = nonadv_prefix[i];
            end
        end
    end

    // =========================================================================
    // Holding register update (sequential)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_valid <= '0;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                hold_insn_flat[i] <= '0;
            end
        end else if (do_flush || do_ckpt_restore) begin
            hold_valid <= '0;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                hold_insn_flat[i] <= '0;
            end
        end else begin
            // Clear all slots first
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                hold_valid[i] <= 1'b0;
                hold_insn_flat[i] <= '0;
            end
            // Pack non-advanced work slots into bottom of holding register
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (capture_nonadvance_c &&
                    work_valid[i] &&
                    !slot_can_advance[i]) begin
                    hold_valid[next_hold_dest[i]] <= 1'b1;
                    hold_insn_flat[next_hold_dest[i]]  <= HI_W'(work_insn[i]);
                end
            end
        end
    end

    // =========================================================================
    // STAT_DUMP: per-cycle rename stall accounting (sim-only, +STAT_DUMP gate)
    //
    // Counts for every work_valid slot across the run:
    //   - total slot-cycles observed
    //   - slot-cycles that successfully advanced
    //   - per-reason stall attribution (has_preg=0, has_rob=0, etc.)
    //   - cycle-level aggregates: any/all slots stalled
    //
    // Final report printed via `final` block.  Goal: distinguish the primary
    // stall cause between CoreMark and Dhrystone when the same RTL is run.
    // =========================================================================
`ifdef SIMULATION
    integer rn_leak_cyc;
    logic   rn_stat_en;
    integer stall_preg_cnt, stall_rob_cnt, stall_ckpt_cnt;
    integer stall_lq_cnt,   stall_sq_cnt,  stall_dq_cnt;
    integer total_work_slot_cycles;
    integer total_advanced_slot_cycles;
    integer cycle_any_stall;
    integer cycle_full_stall;
    integer cycle_any_valid;
    integer cycle_rename_stall_out;
    integer zero_elim_cnt;
    integer move_elim_cnt;

    initial rn_stat_en = ($test$plusargs("STAT_DUMP") ? 1'b1 : 1'b0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rn_leak_cyc                <= 0;
            stall_preg_cnt             <= 0;
            stall_rob_cnt              <= 0;
            stall_ckpt_cnt             <= 0;
            stall_lq_cnt               <= 0;
            stall_sq_cnt               <= 0;
            stall_dq_cnt               <= 0;
            total_work_slot_cycles     <= 0;
            total_advanced_slot_cycles <= 0;
            cycle_any_stall            <= 0;
            cycle_full_stall           <= 0;
            cycle_any_valid            <= 0;
            cycle_rename_stall_out     <= 0;
            zero_elim_cnt              <= 0;
            move_elim_cnt              <= 0;
        end else begin
            rn_leak_cyc <= rn_leak_cyc + 1;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (work_valid[i]) begin
                    total_work_slot_cycles <= total_work_slot_cycles + 1;
                    if (slot_can_advance[i]) begin
                        total_advanced_slot_cycles <= total_advanced_slot_cycles + 1;
                        if (is_zero_elim[i]) zero_elim_cnt <= zero_elim_cnt + 1;
                        if (is_move_elim[i]) move_elim_cnt <= move_elim_cnt + 1;
                    end else begin
                        if (slot_needs_preg[i] && !has_preg[i]) stall_preg_cnt <= stall_preg_cnt + 1;
                        if (!has_rob[i])                        stall_rob_cnt  <= stall_rob_cnt + 1;
                        if (slot_needs_ckpt[i] && !has_ckpt[i]) stall_ckpt_cnt <= stall_ckpt_cnt + 1;
                        if (slot_needs_lq[i] && !has_lq[i])     stall_lq_cnt   <= stall_lq_cnt + 1;
                        if (slot_needs_sq[i] && !has_sq[i])     stall_sq_cnt   <= stall_sq_cnt + 1;
                        if (!has_dq[i])                         stall_dq_cnt   <= stall_dq_cnt + 1;
                    end
                end
            end

            if (|work_valid)                            cycle_any_valid        <= cycle_any_valid + 1;
            if (|(work_valid & ~slot_can_advance))      cycle_any_stall        <= cycle_any_stall + 1;
            if ((|work_valid) && ~(|slot_can_advance))  cycle_full_stall       <= cycle_full_stall + 1;
            if (stall)                                  cycle_rename_stall_out <= cycle_rename_stall_out + 1;
        end
    end

    final begin
        $display("");
        $display("=== RENAME STALL SUMMARY (cyc=%0d) ===", rn_leak_cyc);
        $display("Total work-slot cycles:     %0d", total_work_slot_cycles);
        $display("Total advanced slot cycles: %0d", total_advanced_slot_cycles);
        if (total_work_slot_cycles > 0) begin
            $display("Slot advance rate:          %0d%%",
                (total_advanced_slot_cycles * 100) / total_work_slot_cycles);
        end
        $display("Cycles with any valid slot:   %0d", cycle_any_valid);
        $display("Cycles any slot stalled:      %0d", cycle_any_stall);
        $display("Cycles ALL slots stalled:     %0d", cycle_full_stall);
        $display("Cycles rename.stall asserted: %0d", cycle_rename_stall_out);
        $display("Stall reason (slot-cycles, non-exclusive):");
        $display("  has_preg=0: %0d", stall_preg_cnt);
        $display("  has_rob=0:  %0d", stall_rob_cnt);
        $display("  has_ckpt=0: %0d", stall_ckpt_cnt);
        $display("  has_lq=0:   %0d", stall_lq_cnt);
        $display("  has_sq=0:   %0d", stall_sq_cnt);
        $display("  has_dq=0:   %0d", stall_dq_cnt);
        $display("Eliminated at rename:");
        $display("  zero:       %0d", zero_elim_cnt);
        $display("  move:       %0d", move_elim_cnt);
    end
`endif

endmodule
