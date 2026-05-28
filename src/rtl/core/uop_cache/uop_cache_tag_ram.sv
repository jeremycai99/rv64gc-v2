/* file: uop_cache_tag_ram.sv
 Description: Tag RAM for the gen-2 µop cache.
              32 sets × 8 ways. Sync-read SRAM-macro semantics.
 Author: Jeremy Cai
 Date: Apr. 25, 2026
 Version: 2.0
*/
`ifndef UOP_CACHE_TAG_RAM_SV
`define UOP_CACHE_TAG_RAM_SV

module uop_cache_tag_ram
    import rv64gc_pkg::*;
(
    input  wire                        clk,
    input  wire                        rst_n,
    // Read port (F0 → F1)
    input  wire [UOC_INDEX_BITS-1:0]   raddr,
    output logic [UOC_WAYS-1:0]         valid_out,
    output logic [UOC_TAG_BITS-1:0]     tag_out  [0:UOC_WAYS-1],
    // Write port (F2 fill)
    input  wire                        we,
    input  wire [UOC_INDEX_BITS-1:0]   waddr,
    input  wire [UOC_WAY_BITS-1:0]     wway,
    input  wire                        wvalid,
    input  wire [UOC_TAG_BITS-1:0]     wtag,
    // Invalidation (FENCE.I, exception, full flush)
    input  wire                        invalidate_all
);

    // =========================================================================
    // Storage
    //
    // ASIC-CORRECT RESET DISCIPLINE:
    // valid_arr is UOC_SETS × UOC_WAYS = 256 flops; that fits the reset-net
    // fanout budget at modern nodes, so it IS reset on rst_n.  tag_arr
    // (256 × 58 = ~14.8K flops) is data, never directly read when its
    // valid bit is 0; ifdef SIMULATION init handles X-prop in 4-state sims.
    // =========================================================================
    logic                    valid_arr [UOC_SETS][UOC_WAYS];
    logic [UOC_TAG_BITS-1:0] tag_arr   [UOC_SETS][UOC_WAYS];

`ifdef SIMULATION
    initial begin
        for (int s = 0; s < UOC_SETS; s++) begin
            for (int w = 0; w < UOC_WAYS; w++) begin
                valid_arr[s][w] = 1'b0;
                tag_arr[s][w]   = '0;
            end
        end
    end
`endif

    always_ff @(posedge clk) begin
        if (!rst_n || invalidate_all) begin
            for (int s = 0; s < UOC_SETS; s++) begin
                for (int w = 0; w < UOC_WAYS; w++) begin
                    valid_arr[s][w] <= 1'b0;
                end
            end
        end else if (we) begin
            valid_arr[waddr][wway] <= wvalid;
            tag_arr  [waddr][wway] <= wtag;
        end
    end

    // =========================================================================
    // Read (synchronous, 1-cycle latency — SRAM-macro semantics).
    // Address latched at posedge T; data appears at T+1.
    // No write-first bypass: fills happen on F2 cycles when no concurrent
    // F0 lookup targets the same set (uop_cache top arbitrates).
    // =========================================================================
    always_ff @(posedge clk) begin
        for (int w = 0; w < UOC_WAYS; w++) begin
            valid_out[w] <= valid_arr[raddr][w];
            tag_out[w]   <= tag_arr  [raddr][w];
        end
    end

endmodule
`endif
