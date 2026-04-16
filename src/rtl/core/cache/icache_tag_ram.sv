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
    // Reset clears valid bits so the cache behaves as empty on power-up;
    // tag_arr is left uninitialized (only read when valid=1).
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < L1I_SETS; s++) begin
                for (int w = 0; w < L1I_WAYS; w++) begin
                    valid_arr[s][w] <= 1'b0;
                end
            end
        end else if (invalidate_all) begin
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
    // Read (combinational / asynchronous for single-cycle cache hit)
    // =========================================================================
    always_comb begin
        for (int w = 0; w < L1I_WAYS; w++) begin
            valid_out[w]  = valid_arr[raddr][w];
            tag_out[w]    = tag_arr  [raddr][w];
        end
    end

endmodule
