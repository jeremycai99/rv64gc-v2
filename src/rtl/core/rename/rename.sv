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

    // Commit: release old_pdst to free list
    input  logic [2:0]               commit_count,
    input  logic [PHYS_REG_BITS-1:0] commit_old_pdst [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]    commit_rd_valid,
    // Checkpoint release from commit
    input  logic [PIPE_WIDTH-1:0]              commit_release_cp,
    input  logic [CHECKPOINT_BITS-1:0]         commit_cp_id [0:PIPE_WIDTH-1]
);

    // =========================================================================
    // Holding register: retains decoded instructions that could not advance
    // =========================================================================
    decoded_insn_t hold_insn [0:PIPE_WIDTH-1];
    logic [PIPE_WIDTH-1:0] hold_valid;

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
    logic [2:0] remaining_count;

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
    // Commit release: build release vector for free list
    // =========================================================================
    always_comb begin
        fl_release_count = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            fl_release_preg[i] = commit_old_pdst[i];
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

        // Pass 2: fill remaining work slots with new decode input
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if ((3'(i) < dec_count) && dec_insn[i].valid &&
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

                // mv rd, rs = ADDI rd, rs1, 0
                if (work_insn[i].alu_op == ALU_ADD &&
                    work_insn[i].use_imm &&
                    work_insn[i].imm == 64'd0 &&
                    work_insn[i].rs1_arch != 5'd0) begin
                    is_move_elim[i] = 1'b1;
                end

                // li rd, 0 = ADDI rd, x0, 0
                if (work_insn[i].alu_op == ALU_ADD &&
                    work_insn[i].use_imm &&
                    work_insn[i].imm == 64'd0 &&
                    work_insn[i].rs1_arch == 5'd0) begin
                    is_zero_elim[i] = 1'b1;
                end

                // xor rd, rd, rd (self-XOR clears register)
                if (work_insn[i].alu_op == ALU_XOR &&
                    !work_insn[i].use_imm &&
                    work_insn[i].rs1_arch == work_insn[i].rs2_arch) begin
                    is_zero_elim[i] = 1'b1;
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
    // Free list allocation request count
    // =========================================================================
    always_comb begin
        fl_req_count = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (slot_needs_preg[i]) begin
                fl_req_count = fl_req_count + 3'd1;
            end
        end
    end

    // =========================================================================
    // Map each preg-needing slot to its index in fl_alloc_preg[]
    // Uses a running counter across the loop.
    // =========================================================================
    always_comb begin
        // Initialize with a prefix-sum approach using fl_slot_idx directly
        // We track the count so far in a separate signal array
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            fl_slot_idx[i] = '0;
        end

        // Sequential scan to assign indices
        fl_slot_idx[0] = '0; // first needing slot always gets index 0
        for (int i = 1; i < PIPE_WIDTH; i++) begin
            fl_slot_idx[i] = fl_slot_idx[i-1];
            if (slot_needs_preg[i-1]) begin
                fl_slot_idx[i] = fl_slot_idx[i-1] + 3'd1;
            end
        end
    end

    // =========================================================================
    // Per-slot advance logic (combinational)
    //
    // A slot can advance if all required resources are available.
    // Resource counters accumulate across slots to prevent double-allocation.
    // =========================================================================
    always_comb begin
        // Initialize prefix counters
        preg_consumed_before[0] = '0;
        rob_consumed_before[0]  = '0;
        ckpt_consumed_before[0] = 1'b0;

        found_ckpt_branch = 1'b0;
        ckpt_branch_slot  = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            slot_can_advance[i] = 1'b0;
            has_preg[i] = 1'b1;
            has_lq[i]   = 1'b1;
            has_sq[i]   = 1'b1;
            has_ckpt[i] = 1'b1;
            has_rob[i]  = 1'b1;
            has_dq[i]   = 1'b1;

            if (work_valid[i]) begin
                // Physical register check
                if (slot_needs_preg[i]) begin
                    has_preg[i] = ((preg_consumed_before[i] + 3'd1) <= fl_avail_count);
                end

                // LQ check
                if (slot_needs_lq[i]) begin
                    has_lq[i] = !lq_full;
                end

                // SQ check
                if (slot_needs_sq[i]) begin
                    has_sq[i] = !sq_full;
                end

                // Checkpoint check (only first branch per cycle)
                if (slot_needs_ckpt[i]) begin
                    if (!ckpt_consumed_before[i]) begin
                        has_ckpt[i] = ckpt_save_avail;
                    end else begin
                        has_ckpt[i] = 1'b0;
                    end
                end

                // ROB entry check
                has_rob[i] = rob_alloc_ready;

                // Dispatch queue check
                has_dq[i] = !dq_full;

                // Slot can advance if all resources available
                slot_can_advance[i] = has_preg[i] && has_lq[i] && has_sq[i] &&
                                      has_ckpt[i] && has_rob[i] && has_dq[i];
            end

            // Update prefix counters for next slot
            preg_consumed_before[i+1] = preg_consumed_before[i];
            rob_consumed_before[i+1]  = rob_consumed_before[i];
            ckpt_consumed_before[i+1] = ckpt_consumed_before[i];

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

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ren_insn[i] = '0;
        end

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

                // Move-eliminated instructions are ready at rename
                if (is_move_elim[i] || is_zero_elim[i]) begin
                    ren_insn[out_dest[i]].rs1_ready = 1'b1;
                    ren_insn[out_dest[i]].rs2_ready = 1'b1;
                end

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

                // LQ/SQ indices
                ren_insn[out_dest[i]].lq_idx = lq_alloc_idx[out_dest[i]];
                ren_insn[out_dest[i]].sq_idx = sq_alloc_idx[out_dest[i]];
            end
        end
    end

    // =========================================================================
    // Stall: backpressure to decode/fetch
    //
    // Stall when the holding register will still be non-empty after this
    // cycle (some work slots didn't advance) and there is no room for new
    // decode input.
    // =========================================================================
    always_comb begin
        remaining_count = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (work_valid[i] && !slot_can_advance[i]) begin
                remaining_count = remaining_count + 3'd1;
            end
        end

        // Stall if remaining non-advanced insns fill all slots,
        // or if holding register is occupied and nothing advanced.
        stall = (remaining_count >= 3'(PIPE_WIDTH)) ||
                ((|hold_valid) && !(|slot_can_advance));
    end

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
                hold_insn[i] <= '0;
            end
        end else if (do_flush || do_ckpt_restore) begin
            hold_valid <= '0;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                hold_insn[i] <= '0;
            end
        end else begin
            // Clear all slots first
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                hold_valid[i] <= 1'b0;
                hold_insn[i]  <= '0;
            end
            // Pack non-advanced work slots into bottom of holding register
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (work_valid[i] && !slot_can_advance[i]) begin
                    hold_valid[next_hold_dest[i]] <= 1'b1;
                    hold_insn[next_hold_dest[i]]  <= work_insn[i];
                end
            end
        end
    end

endmodule
