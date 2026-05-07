/* file: uop_cache_data_ram.sv
 Description: Data RAM bank for the gen-2 µop cache.
              One bank = one way; uop_cache.sv instantiates UOC_WAYS of these.
              Each entry stores PIPE_WIDTH decoded_insn_t µops + a 3-bit count.
              Sync-read SRAM-macro semantics.
 Author: Jeremy Cai
 Date: Apr. 25, 2026
 Version: 2.0
*/
`ifndef UOP_CACHE_DATA_RAM_SV
`define UOP_CACHE_DATA_RAM_SV

module uop_cache_data_ram
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                        clk,
    // Read port (F0 → F1)
    input  logic [UOC_INDEX_BITS-1:0]   raddr,
    output decoded_insn_t               rdata [0:UOC_PER_ENTRY-1],
    output logic [2:0]                  rcount,
    // Write port (F2 fill)
    input  logic                        we,
    input  logic [UOC_INDEX_BITS-1:0]   waddr,
    input  decoded_insn_t               wdata [0:UOC_PER_ENTRY-1],
    input  logic [2:0]                  wcount
);

    // =========================================================================
    // Storage: one way-bank.  Each set holds PIPE_WIDTH packed decoded_insn_t
    // payloads + a 3-bit count.
    //
    // ASIC-CORRECT RESET DISCIPLINE:
    // No reset on data array — controlled by valid bit in tag RAM.  This is
    // the same pattern as icache_data_ram (LINE_SIZE×8 bits per set, no
    // reset).  Reading an entry whose valid=0 in the tag RAM is suppressed
    // upstream by the tag comparison, so X content here is harmless.
    // ifdef SIMULATION init exists below to keep 4-state sims (xsim) clean.
    // =========================================================================
    decoded_insn_t insn_arr  [UOC_SETS][0:UOC_PER_ENTRY-1];
    logic [2:0]    count_arr [UOC_SETS];

`ifdef SIMULATION
    initial begin
        for (int s = 0; s < UOC_SETS; s++) begin
            count_arr[s] = '0;
            for (int u = 0; u < UOC_PER_ENTRY; u++) begin
                insn_arr[s][u] = '0;
            end
        end
    end
`endif

    // =========================================================================
    // Write (synchronous)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (we) begin
            count_arr[waddr] <= wcount;
            for (int u = 0; u < UOC_PER_ENTRY; u++) begin
                insn_arr[waddr][u] <= wdata[u];
            end
        end
    end

    // =========================================================================
    // Read (synchronous, 1-cycle latency).  Latched at posedge T; data
    // appears at T+1.
    // =========================================================================
    always_ff @(posedge clk) begin
        rcount <= count_arr[raddr];
        for (int u = 0; u < UOC_PER_ENTRY; u++) begin
            rdata[u] <= insn_arr[raddr][u];
        end
    end

endmodule
`endif
