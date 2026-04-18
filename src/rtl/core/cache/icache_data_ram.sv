/* file: icache_data_ram.sv
 Description: Data RAM for 32 kB 4-way L1 I-cache (128 sets).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module icache_data_ram
    import rv64gc_pkg::*;
(
    input  logic                        clk,
    // Read port
    input  logic [L1I_SET_BITS-1:0]     raddr,
    input  logic [1:0]                  rway,
    output logic [LINE_SIZE*8-1:0]      rdata,
    // Write port
    input  logic                        we,
    input  logic [L1I_SET_BITS-1:0]     waddr,
    input  logic [1:0]                  wway,
    input  logic [LINE_SIZE*8-1:0]      wdata
);

    // =========================================================================
    // Storage: single way-bank (one instance per way in the cache)
    // =========================================================================
    logic [LINE_SIZE*8-1:0] data_arr [L1I_SETS];

    // =========================================================================
    // Write (synchronous)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (we) begin
            data_arr[waddr] <= wdata;
        end
    end

    // =========================================================================
    // Read (synchronous, 1-cycle latency — SRAM-macro semantics).
    // Address is latched at posedge clk; data appears at the next edge.
    // =========================================================================
    logic [LINE_SIZE*8-1:0] rdata_r;
    always_ff @(posedge clk) begin
        rdata_r <= data_arr[raddr];
    end
    assign rdata = rdata_r;

endmodule
