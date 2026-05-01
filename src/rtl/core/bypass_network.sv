/* file: bypass_network.sv
 Description: Combinational 6-source bypass network for one operand.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef BYPASS_NETWORK_SV
`define BYPASS_NETWORK_SV

module bypass_network
    import rv64gc_pkg::*;
(
    // NUM_BYPASS_SRCS bypass sources (ALU0-2, MUL/DIV/CSR, Load0, Load1
    // for 4-wide: 4 sources total driven by CDB_WIDTH slots)
    input  logic [NUM_BYPASS_SRCS-1:0]    bypass_valid,
    input  logic [PHYS_REG_BITS-1:0]      bypass_tag  [0:NUM_BYPASS_SRCS-1],
    input  logic [63:0]                    bypass_data [0:NUM_BYPASS_SRCS-1],
    // Operand to check
    input  logic [PHYS_REG_BITS-1:0] need_tag,
    input  logic [63:0]              prf_data,      // data from PRF read
    // Output
    output logic [63:0]              result_data,   // bypassed or PRF data
    output logic                     hit            // bypass matched
);

    // Per-source match signals
    logic [NUM_BYPASS_SRCS-1:0] match;

    always_comb begin
        for (int i = 0; i < NUM_BYPASS_SRCS; i++) begin
            match[i] = bypass_valid[i] && (bypass_tag[i] == need_tag);
        end
    end

    // Priority mux: highest index wins; fall back to PRF data on no match
    always_comb begin
        hit         = 1'b0;
        result_data = prf_data;

        for (int i = 0; i < NUM_BYPASS_SRCS; i++) begin
            if (match[i]) begin
                result_data = bypass_data[i];
                hit         = 1'b1;
            end
        end
    end

endmodule

`endif
