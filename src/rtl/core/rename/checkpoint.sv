/* file: checkpoint.sv
 Description: Checkpoint manager for speculative rename recovery.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module checkpoint
    import rv64gc_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Save: allocate a checkpoint (triggered at predicted-taken branches)
    input  logic                       save_valid,
    output logic [CHECKPOINT_BITS-1:0] save_id,      // which slot was allocated
    output logic                       save_avail,   // at least 1 slot free

    // Snapshot data to save
    input  logic [PHYS_REG_BITS-1:0]   rat_snapshot [0:31],
    input  logic [INT_PRF_DEPTH-1:0]   fl_bitmap_snapshot,
    input  logic [ROB_IDX_BITS-1:0]    rob_tail_snapshot,

    // Restore: triggered on branch mispredict (frees all checkpoints)
    input  logic                       restore_valid,
    input  logic [CHECKPOINT_BITS-1:0] restore_id,
    output logic [PHYS_REG_BITS-1:0]   restored_rat [0:31],
    output logic [INT_PRF_DEPTH-1:0]   restored_fl_bitmap,
    output logic [ROB_IDX_BITS-1:0]    restored_rob_tail,

    // Release: checkpoint no longer needed (branch committed without mispredict)
    input  logic [PIPE_WIDTH-1:0]              release_valid,  // per-commit-slot release
    input  logic [CHECKPOINT_BITS-1:0]         release_id [0:PIPE_WIDTH-1],

    // Full flush
    input  logic                       flush
);

    // -------------------------------------------------------------------------
    // Checkpoint storage: 4 slots
    // Each slot holds a 32-entry RAT, INT_PRF_DEPTH-bit free list, and
    // ROB_IDX_BITS-bit ROB tail pointer.
    // -------------------------------------------------------------------------
    logic [PHYS_REG_BITS-1:0] slot_rat      [0:NUM_CHECKPOINTS-1][0:31];
    logic [INT_PRF_DEPTH-1:0] slot_fl_bitmap [0:NUM_CHECKPOINTS-1];
    logic [ROB_IDX_BITS-1:0]  slot_rob_tail  [0:NUM_CHECKPOINTS-1];

    // -------------------------------------------------------------------------
    // Occupancy tracking: bit i = 1 means slot i is in use
    // -------------------------------------------------------------------------
    logic [NUM_CHECKPOINTS-1:0] occupied;

    // -------------------------------------------------------------------------
    // Save allocation observes same-cycle checkpoint releases.  This matters
    // when the file is full and commit frees a slot in the same cycle rename
    // wants to allocate a new branch checkpoint.
    // -------------------------------------------------------------------------
    logic [NUM_CHECKPOINTS-1:0] release_mask;
    logic [NUM_CHECKPOINTS-1:0] occupied_after_release;

    always_comb begin
        release_mask = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (release_valid[i]) begin
                release_mask[release_id[i]] = 1'b1;
            end
        end
    end

    assign occupied_after_release = occupied & ~release_mask;
    assign save_avail = (occupied_after_release != {NUM_CHECKPOINTS{1'b1}});

    // -------------------------------------------------------------------------
    // save_id: lowest-numbered slot free after same-cycle releases.
    // -------------------------------------------------------------------------
    always_comb begin
        save_id = '0;
        for (int i = NUM_CHECKPOINTS-1; i >= 0; i--) begin
            if (!occupied_after_release[i]) begin
                save_id = CHECKPOINT_BITS'(i);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational restore: drive snapshot data from the requested slot
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 32; i++) begin
            restored_rat[i] = slot_rat[restore_id][i];
        end
        restored_fl_bitmap = slot_fl_bitmap[restore_id];
        restored_rob_tail  = slot_rob_tail[restore_id];
    end

    // -------------------------------------------------------------------------
    // Sequential: occupancy update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occupied <= '0;
        end else if (flush) begin
            occupied <= '0;
        end else begin
            // Release: clear slots for committed branches (no mispredict)
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (release_valid[i]) begin
                    occupied[release_id[i]] <= 1'b0;
                end
            end
            // Save: mark the allocated slot as occupied
            // Save is applied after releases so a slot freed this cycle can
            // be immediately reallocated (save_id picks from pre-save state).
            if (save_valid && save_avail) begin
                occupied[save_id] <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential: snapshot storage
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < NUM_CHECKPOINTS; c++) begin
                for (int i = 0; i < 32; i++) begin
                    slot_rat[c][i] <= PHYS_REG_BITS'(i);
                end
                slot_fl_bitmap[c] <= '0;
                slot_rob_tail[c]  <= '0;
            end
        end else if (save_valid && save_avail) begin
            for (int i = 0; i < 32; i++) begin
                slot_rat[save_id][i] <= rat_snapshot[i];
            end
            slot_fl_bitmap[save_id] <= fl_bitmap_snapshot;
            slot_rob_tail[save_id]  <= rob_tail_snapshot;
        end
    end

`ifdef SIMULATION
    logic ckpt_stat_en;
    integer ckpt_cyc;
    integer ckpt_save_req_cnt;
    integer ckpt_save_success_cnt;
    integer ckpt_save_block_full_cnt;
    integer ckpt_release_cnt;
    integer ckpt_full_pre_release_cyc;
    integer ckpt_full_after_release_cyc;
    integer ckpt_release_when_full_cyc;
    integer ckpt_max_occupied;
    integer ckpt_occupied_now;
    integer ckpt_occupied_after_release_now;
    integer ckpt_release_count_now;

    initial ckpt_stat_en =
        ($test$plusargs("PERF_PROFILE") || $test$plusargs("STAT_DUMP")) ? 1'b1 : 1'b0;

    function automatic integer ckpt_popcount(input logic [NUM_CHECKPOINTS-1:0] bits);
        integer count;
        begin
            count = 0;
            for (int i = 0; i < NUM_CHECKPOINTS; i++) begin
                if (bits[i]) count++;
            end
            ckpt_popcount = count;
        end
    endfunction

    always_comb begin
        ckpt_occupied_now = ckpt_popcount(occupied);
        ckpt_occupied_after_release_now = ckpt_popcount(occupied_after_release);
        ckpt_release_count_now = 0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if (release_valid[i])
                ckpt_release_count_now++;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ckpt_cyc                    <= 0;
            ckpt_save_req_cnt           <= 0;
            ckpt_save_success_cnt       <= 0;
            ckpt_save_block_full_cnt    <= 0;
            ckpt_release_cnt            <= 0;
            ckpt_full_pre_release_cyc   <= 0;
            ckpt_full_after_release_cyc <= 0;
            ckpt_release_when_full_cyc  <= 0;
            ckpt_max_occupied           <= 0;
        end else if (ckpt_stat_en) begin
            ckpt_cyc <= ckpt_cyc + 1;

            if (ckpt_occupied_now > ckpt_max_occupied)
                ckpt_max_occupied <= ckpt_occupied_now;

            if (occupied == {NUM_CHECKPOINTS{1'b1}})
                ckpt_full_pre_release_cyc <= ckpt_full_pre_release_cyc + 1;
            if (occupied_after_release == {NUM_CHECKPOINTS{1'b1}})
                ckpt_full_after_release_cyc <= ckpt_full_after_release_cyc + 1;

            if ((occupied == {NUM_CHECKPOINTS{1'b1}}) && (release_mask != '0))
                ckpt_release_when_full_cyc <= ckpt_release_when_full_cyc + 1;

            if (save_valid) begin
                ckpt_save_req_cnt <= ckpt_save_req_cnt + 1;
                if (save_avail)
                    ckpt_save_success_cnt <= ckpt_save_success_cnt + 1;
                else
                    ckpt_save_block_full_cnt <= ckpt_save_block_full_cnt + 1;
            end

            ckpt_release_cnt <= ckpt_release_cnt + ckpt_release_count_now;
        end
    end

    final begin
        if (ckpt_stat_en) begin
            $display("");
            $display("=== CHECKPOINT SUMMARY ===");
            $display("Cycles sampled:             %0d", ckpt_cyc);
            $display("Max occupied:               %0d / %0d", ckpt_max_occupied, NUM_CHECKPOINTS);
            $display("Full cycles pre-release:    %0d", ckpt_full_pre_release_cyc);
            $display("Full cycles after-release:  %0d", ckpt_full_after_release_cyc);
            $display("Release while full cycles:  %0d", ckpt_release_when_full_cyc);
            $display("Save req/success/blocked:   %0d / %0d / %0d",
                     ckpt_save_req_cnt, ckpt_save_success_cnt, ckpt_save_block_full_cnt);
            $display("Release count:              %0d", ckpt_release_cnt);
        end
    end
`endif

endmodule
