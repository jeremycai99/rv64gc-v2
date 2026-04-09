/* file: free_list.sv
 Description: Free list for physical register allocation using a 256-bit
              bitmap. Supports up to 6 allocations and 6 releases per cycle
              with 4 checkpoint slots for branch recovery.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/

module free_list
    import rv64gc_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Allocate: up to 6 per cycle
    input logic [2:0] alloc_req_count,
    output logic [PHYS_REG_BITS-1:0] alloc_preg [0:PIPE_WIDTH-1],
    output logic [2:0] alloc_avail_count,

    // Release: up to 6 per cycle (from commit, old_pdst returns to free)
    input logic [2:0] release_count,
    input logic [PHYS_REG_BITS-1:0] release_preg [0:PIPE_WIDTH-1],

    // Checkpoint save
    input logic ckpt_save,
    input logic [CHECKPOINT_BITS-1:0] ckpt_save_id,
    // Checkpoint restore
    input logic ckpt_restore,
    input logic [CHECKPOINT_BITS-1:0] ckpt_restore_id,
    // Full flush
    input logic flush
);

    // -------------------------------------------------------------------------
    // Free bitmap: bit i = 1 means physical register i is free
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] free_bitmap;

    // Initial state constant: regs 0-31 in use, 32-255 free
    localparam logic [INT_PRF_DEPTH-1:0] INIT_BITMAP = {{(INT_PRF_DEPTH - ARCH_REGS){1'b1}}, {ARCH_REGS{1'b0}}};

    // -------------------------------------------------------------------------
    // Checkpoint storage
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] ckpt_bitmap [0:NUM_CHECKPOINTS-1];

    // -------------------------------------------------------------------------
    // Cascading priority encoder for allocation
    //
    // Each stage finds the lowest set bit in a working bitmap, records it,
    // then clears that bit for the next stage.
    // -------------------------------------------------------------------------
    logic [INT_PRF_DEPTH-1:0] work_bitmap [0:PIPE_WIDTH];
    logic [PHYS_REG_BITS-1:0] found_idx [0:PIPE_WIDTH-1];
    logic found_valid [0:PIPE_WIDTH-1];

    always_comb begin
        work_bitmap[0] = free_bitmap;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Default: nothing found
            found_idx[i]   = '0;
            found_valid[i] = 1'b0;

            // Find lowest set bit via one-hot isolation
            // one_hot = bitmap & (-bitmap) isolates the lowest set bit
            // Then encode it to an index with a priority scan
            if (work_bitmap[i] != '0) begin
                found_valid[i] = 1'b1;
                found_idx[i]   = '0;
                for (int b = 0; b < INT_PRF_DEPTH; b++) begin
                    if (work_bitmap[i][b]) begin
                        found_idx[i] = PHYS_REG_BITS'(b);
                        break;
                    end
                end
            end

            // Clear the found bit for the next stage
            if (found_valid[i]) begin
                work_bitmap[i+1] = work_bitmap[i] & ~(INT_PRF_DEPTH'(1) << found_idx[i]);
            end else begin
                work_bitmap[i+1] = work_bitmap[i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output: allocated registers and available count
    // -------------------------------------------------------------------------
    always_comb begin
        alloc_avail_count = 3'b0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            alloc_preg[i] = found_idx[i];
            if (found_valid[i] && (3'(i) < alloc_req_count)) begin
                alloc_avail_count = 3'(i + 1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential: bitmap update, release, checkpoint, flush
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap <= INIT_BITMAP;
        end else if (flush) begin
            free_bitmap <= INIT_BITMAP;
        end else if (ckpt_restore) begin
            free_bitmap <= ckpt_bitmap[ckpt_restore_id];
        end else begin
            // Start with current bitmap
            // Apply allocations: clear bits for allocated registers
            // Apply releases: set bits for released registers
            // Allocations and releases in the same cycle: alloc reads
            // pre-release state (combinational), release happens at edge.
            // Both modifications apply at the clock edge.
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                // Allocations: clear bits that were allocated
                if (found_valid[i] && (3'(i) < alloc_req_count)) begin
                    free_bitmap[found_idx[i]] <= 1'b0;
                end
                // Releases: set bits back to free (never release p0)
                if ((3'(i) < release_count) && (release_preg[i] != '0)) begin
                    free_bitmap[release_preg[i]] <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Checkpoint save (independent of bitmap update)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < NUM_CHECKPOINTS; c++) begin
                ckpt_bitmap[c] <= INIT_BITMAP;
            end
        end else if (ckpt_save) begin
            ckpt_bitmap[ckpt_save_id] <= free_bitmap;
        end
    end

endmodule
