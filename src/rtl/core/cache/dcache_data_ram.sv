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
    // Read port
    input  logic [L1D_SET_BITS-1:0]     raddr,
    input  logic [1:0]                  rway,
    output logic [LINE_SIZE*8-1:0]      rdata,
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
    // =========================================================================
    logic [L1D_SET_BITS-1:0] raddr_q;
    logic [1:0]              rway_q;

    always_ff @(posedge clk) begin
        raddr_q <= raddr;
        rway_q  <= rway;
    end

    assign rdata = data_arr[raddr_q][rway_q];

endmodule
