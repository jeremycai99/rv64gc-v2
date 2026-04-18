/* file: icache_tag_ram.sv
 Description: Tag RAM for 32 kB 4-way L1 I-cache (128 sets).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module icache_tag_ram
    import rv64gc_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,
    // Read port
    input  logic [L1I_SET_BITS-1:0]     raddr,
    output logic [L1I_WAYS-1:0]         valid_out,
    output logic [L1I_TAG_BITS-1:0]     tag_out [0:L1I_WAYS-1],
    // Write port
    input  logic                        we,
    input  logic [L1I_SET_BITS-1:0]     waddr,
    input  logic [1:0]                  wway,       // which way to write
    input  logic                        wvalid,
    input  logic [L1I_TAG_BITS-1:0]     wtag,
    // Invalidation
    input  logic                        invalidate_all
);

    // =========================================================================
    // Storage
    // =========================================================================
    logic                    valid_arr [L1I_SETS][L1I_WAYS];
    logic [L1I_TAG_BITS-1:0] tag_arr   [L1I_SETS][L1I_WAYS];

    // =========================================================================
    // Write / invalidate (synchronous)
    //
    // ASIC-CORRECT RESET DISCIPLINE:
    // valid_arr is L1I_SETS x L1I_WAYS = 512 flops; resetting them all on
    // hardware reset exceeds the reset-net fanout budget of modern nodes.
    // Boot-ROM firmware must issue a FENCE.I (invalidate_all pulse) to
    // clear the cache at startup; this is the normal ISA mechanism and
    // is already wired through the icache controller.  Simulation-only
    // `initial` handles 4-state X-propagation without synthesis reset load.
    // =========================================================================
`ifdef SIMULATION
    initial begin
        for (int s = 0; s < L1I_SETS; s++) begin
            for (int w = 0; w < L1I_WAYS; w++) begin
                valid_arr[s][w] = 1'b0;
            end
        end
    end
`endif

    always_ff @(posedge clk) begin
        if (invalidate_all) begin
            for (int s = 0; s < L1I_SETS; s++) begin
                for (int w = 0; w < L1I_WAYS; w++) begin
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
    // Address is latched at posedge clk; data appears at the next edge.
    // No write-first bypass: the icache controller arbitrates writes
    // (fill installs) with reads via invalidate_busy / install bubbles.
    // =========================================================================
    always_ff @(posedge clk) begin
        for (int w = 0; w < L1I_WAYS; w++) begin
            valid_out[w]  <= valid_arr[raddr][w];
            tag_out[w]    <= tag_arr  [raddr][w];
        end
    end

endmodule
