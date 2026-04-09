/* file: bypass_network.sv
 * Description: Purely combinational 6-source bypass network for one operand.
 *              Checks ALU0-3, MUL, and Load0 bypass sources and forwards data
 *              when a tag match is found. Highest-index match wins (newest result).
 * Version: 2.0
 */

`ifndef BYPASS_NETWORK_SV
`define BYPASS_NETWORK_SV

module bypass_network
    import rv64gc_pkg::*;
(
    // 6 bypass sources (ALU0-3, MUL, Load0)
    input  logic [5:0]               bypass_valid,
    input  logic [PHYS_REG_BITS-1:0] bypass_tag  [0:5],
    input  logic [63:0]              bypass_data [0:5],
    // Operand to check
    input  logic [PHYS_REG_BITS-1:0] need_tag,
    input  logic [63:0]              prf_data,      // data from PRF read
    // Output
    output logic [63:0]              result_data,   // bypassed or PRF data
    output logic                     hit            // bypass matched
);

    // Per-source match signals
    logic [5:0] match;

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
