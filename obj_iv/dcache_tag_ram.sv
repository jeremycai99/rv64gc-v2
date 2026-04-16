/* file: dcache_tag_ram.sv
 Description: Tag RAM for 64 kB 4-way L1 D-cache (256 sets).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module dcache_tag_ram
    import rv64gc_pkg::*;
(
    input  logic                        clk,
    // Read port A (load port 0 / store)
    input  logic [L1D_SET_BITS-1:0]     raddr,
    output logic [L1D_WAYS-1:0]         valid_out,
    output logic [L1D_WAYS-1:0]         dirty_out,
    output logic [L1D_TAG_BITS-1:0]     tag_out [0:L1D_WAYS-1],
    // Read port B (load port 1)
    input  logic [L1D_SET_BITS-1:0]     raddr2,
    output logic [L1D_WAYS-1:0]         valid_out2,
    output logic [L1D_WAYS-1:0]         dirty_out2,
    output logic [L1D_TAG_BITS-1:0]     tag_out2 [0:L1D_WAYS-1],
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
    // Read port A (synchronous, 1-cycle latency, write-first bypass)
    // =========================================================================
    always_ff @(posedge clk) begin
        for (int w = 0; w < L1D_WAYS; w++) begin
            logic hit_way_write;
            logic hit_way_dirty;
            hit_way_write = we       && (waddr        == raddr) && (wway       == 2'(w));
            hit_way_dirty = dirty_we && (dirty_waddr  == raddr) && (dirty_wway == 2'(w));

            if (hit_way_write) begin
                valid_out[w] <= wvalid;
                dirty_out[w] <= wdirty;
                tag_out[w]   <= wtag;
            end else begin
                valid_out[w] <= valid_arr[raddr][w];
                tag_out[w]   <= tag_arr  [raddr][w];
                if (hit_way_dirty)
                    dirty_out[w] <= 1'b1;
                else
                    dirty_out[w] <= dirty_arr[raddr][w];
            end
        end
    end

    // =========================================================================
    // Read port B (synchronous, 1-cycle latency, write-first bypass)
    // =========================================================================
    always_ff @(posedge clk) begin
        for (int w = 0; w < L1D_WAYS; w++) begin
            logic hit_way_write2;
            logic hit_way_dirty2;
            hit_way_write2 = we       && (waddr        == raddr2) && (wway       == 2'(w));
            hit_way_dirty2 = dirty_we && (dirty_waddr  == raddr2) && (dirty_wway == 2'(w));

            if (hit_way_write2) begin
                valid_out2[w] <= wvalid;
                dirty_out2[w] <= wdirty;
                tag_out2[w]   <= wtag;
            end else begin
                valid_out2[w] <= valid_arr[raddr2][w];
                tag_out2[w]   <= tag_arr  [raddr2][w];
                if (hit_way_dirty2)
                    dirty_out2[w] <= 1'b1;
                else
                    dirty_out2[w] <= dirty_arr[raddr2][w];
            end
        end
    end

endmodule
