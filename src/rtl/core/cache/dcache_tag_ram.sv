/* file: dcache_tag_ram.sv
 * Description: Tag RAM for the 64 kB 4-way set-associative L1 D-cache.
 *              256 sets x 4 ways.
 *              Each entry: valid (1 bit) + dirty (1 bit) + tag (L1D_TAG_BITS bits).
 *              Synchronous write, synchronous read (1-cycle read latency).
 *              invalidate_all clears every valid/dirty bit in one cycle.
 * Version: 2.0
 */
module dcache_tag_ram
    import rv64gc_pkg::*;
(
    input  logic                        clk,
    // Read port
    input  logic [L1D_SET_BITS-1:0]     raddr,
    output logic [L1D_WAYS-1:0]         valid_out,
    output logic [L1D_WAYS-1:0]         dirty_out,
    output logic [L1D_TAG_BITS-1:0]     tag_out [0:L1D_WAYS-1],
    // Write port
    input  logic                        we,
    input  logic [L1D_SET_BITS-1:0]     waddr,
    input  logic [1:0]                  wway,
    input  logic                        wvalid,
    input  logic                        wdirty,
    input  logic [L1D_TAG_BITS-1:0]     wtag,
    // Dirty bit update (store hit — update dirty without full write)
    input  logic                        dirty_we,
    input  logic [L1D_SET_BITS-1:0]     dirty_waddr,
    input  logic [1:0]                  dirty_wway,
    // Invalidate
    input  logic                        invalidate_all
);

    // =========================================================================
    // Storage
    // =========================================================================
    logic                    valid_arr [L1D_SETS][L1D_WAYS];
    logic                    dirty_arr [L1D_SETS][L1D_WAYS];
    logic [L1D_TAG_BITS-1:0] tag_arr   [L1D_SETS][L1D_WAYS];

    // =========================================================================
    // Write / invalidate (synchronous)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (invalidate_all) begin
            for (int s = 0; s < L1D_SETS; s++) begin
                for (int w = 0; w < L1D_WAYS; w++) begin
                    valid_arr[s][w] <= 1'b0;
                    dirty_arr[s][w] <= 1'b0;
                end
            end
        end else begin
            if (we) begin
                valid_arr[waddr][wway] <= wvalid;
                dirty_arr[waddr][wway] <= wdirty;
                tag_arr  [waddr][wway] <= wtag;
            end
            if (dirty_we) begin
                dirty_arr[dirty_waddr][dirty_wway] <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Read (synchronous, 1-cycle latency)
    // =========================================================================
    always_ff @(posedge clk) begin
        for (int w = 0; w < L1D_WAYS; w++) begin
            valid_out[w] <= valid_arr[raddr][w];
            dirty_out[w] <= dirty_arr[raddr][w];
            tag_out[w]   <= tag_arr  [raddr][w];
        end
    end

endmodule
