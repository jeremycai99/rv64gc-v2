/* file: dcache_data_ram.sv
 Description: Data RAM for 64 kB 4-way L1 D-cache (256 sets).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module dcache_data_ram
    import rv64gc_pkg::*;
(
    input  logic                        clk,
    // Read port: returns the line for the current raddr, one per way.
    // Consumers mux by hit_way downstream.
    input  logic [L1D_SET_BITS-1:0]     raddr,
    input  logic [1:0]                  rway,       // unused (legacy), kept for compat
    output logic [LINE_SIZE*8-1:0]      rdata,       // muxed: way selected by rway_q
    output logic [LINE_SIZE*8-1:0]      rdata_all [0:L1D_WAYS-1], // all ways
    // Write port (full cache-line, e.g., fill from L2)
    input  logic                        we,
    input  logic [L1D_SET_BITS-1:0]     waddr,
    input  logic [1:0]                  wway,
    input  logic [LINE_SIZE*8-1:0]      wdata,
    // Byte-enable write port (store hit — partial line update)
    input  logic                        bwe,
    input  logic [L1D_SET_BITS-1:0]     bwaddr,
    input  logic [1:0]                  bwway,
    input  logic [LINE_SIZE*8-1:0]      bwdata,
    input  logic [LINE_SIZE-1:0]        bwmask    // 1 bit per byte
);

    // =========================================================================
    // Storage: 256 sets x 4 ways x 64 bytes
    // =========================================================================
    logic [LINE_SIZE*8-1:0] data_arr [L1D_SETS][L1D_WAYS];

    // =========================================================================
    // Write (synchronous)
    // Full-line write and byte-enable write may not occur simultaneously on the
    // same address from the cache controller, but we prioritise full-line write.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (we) begin
            data_arr[waddr][wway] <= wdata;
        end else if (bwe) begin
            for (int b = 0; b < LINE_SIZE; b++) begin
                if (bwmask[b]) begin
                    data_arr[bwaddr][bwway][b*8 +: 8] <= bwdata[b*8 +: 8];
                end
            end
        end
    end

    // =========================================================================
    // Read (synchronous, 1-cycle latency)
    //
    // We expose all 4 ways so the dcache can mux on hit_way after tag
    // comparison.  We also provide a single-way `rdata` output (muxed by
    // the registered rway_q) for legacy consumers that select ahead of
    // time (e.g., writeback eviction).
    // =========================================================================
    logic [L1D_SET_BITS-1:0] raddr_q;
    logic [1:0]              rway_q;

    always_ff @(posedge clk) begin
        raddr_q <= raddr;
        rway_q  <= rway;
    end

    always_comb begin
        for (int w = 0; w < L1D_WAYS; w++) begin
            rdata_all[w] = data_arr[raddr_q][w];
        end
    end

    assign rdata = data_arr[raddr_q][rway_q];

endmodule
