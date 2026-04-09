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

    // Restore: triggered on branch mispredict
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
    // save_avail: at least one slot is free
    // -------------------------------------------------------------------------
    assign save_avail = (occupied != {NUM_CHECKPOINTS{1'b1}});

    // -------------------------------------------------------------------------
    // save_id: lowest-numbered free slot (priority encoder on ~occupied)
    // -------------------------------------------------------------------------
    always_comb begin
        save_id = '0;
        for (int i = NUM_CHECKPOINTS-1; i >= 0; i--) begin
            if (!occupied[i]) begin
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

endmodule
