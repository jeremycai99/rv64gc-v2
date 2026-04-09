/* file: icache_data_ram.sv
 * Description: Data RAM for the 32 kB 4-way set-associative L1 I-cache.
 *              128 sets x 4 ways x 64 bytes = 32 KB total.
 *              Synchronous write, synchronous read (1-cycle read latency).
 *              Read way is registered alongside the address to match the
 *              tag-RAM read pipeline.
 * Version: 2.0
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
    // Storage: 4 independent way-banks for area efficiency
    // =========================================================================
    logic [LINE_SIZE*8-1:0] data_arr [L1I_SETS][L1I_WAYS];

    // =========================================================================
    // Write (synchronous)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (we) begin
            data_arr[waddr][wway] <= wdata;
        end
    end

    // =========================================================================
    // Read (synchronous) – register address + way, output next cycle
    // =========================================================================
    logic [L1I_SET_BITS-1:0] raddr_q;
    logic [1:0]              rway_q;

    always_ff @(posedge clk) begin
        raddr_q <= raddr;
        rway_q  <= rway;
    end

    assign rdata = data_arr[raddr_q][rway_q];

endmodule
