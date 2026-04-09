/* file: wakeup_network.sv
 Description: CDB-based wakeup network for issue queue entries.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module wakeup_network
    import rv64gc_pkg::*;
(
    // CDB broadcast (CDB_WIDTH = 6 sources)
    input  logic [CDB_WIDTH-1:0]     cdb_valid,
    input  logic [PHYS_REG_BITS-1:0] cdb_tag [0:CDB_WIDTH-1],

    // Entry's source tags to check
    input  logic [PHYS_REG_BITS-1:0] entry_rs1_tag,
    input  logic [PHYS_REG_BITS-1:0] entry_rs2_tag,
    input  logic                     entry_rs1_ready,
    input  logic                     entry_rs2_ready,

    // Speculative wakeup (from load issue / AGU)
    input  logic                     spec_wakeup_valid,
    input  logic [PHYS_REG_BITS-1:0] spec_wakeup_tag,

    // Output: new ready status
    output logic                     rs1_wakeup,       // rs1 becomes definitively ready this cycle
    output logic                     rs2_wakeup,
    output logic                     rs1_spec_wakeup,  // rs1 speculatively ready this cycle
    output logic                     rs2_spec_wakeup
);

    // -----------------------------------------------------------------------
    // CDB match: any cdb_valid[i] with matching tag
    // -----------------------------------------------------------------------
    logic rs1_cdb_match;
    logic rs2_cdb_match;

    always_comb begin
        rs1_cdb_match = 1'b0;
        rs2_cdb_match = 1'b0;
        for (int i = 0; i < CDB_WIDTH; i++) begin
            if (cdb_valid[i] && (cdb_tag[i] == entry_rs1_tag))
                rs1_cdb_match = 1'b1;
            if (cdb_valid[i] && (cdb_tag[i] == entry_rs2_tag))
                rs2_cdb_match = 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Speculative match
    // -----------------------------------------------------------------------
    logic rs1_spec_match;
    logic rs2_spec_match;

    assign rs1_spec_match = spec_wakeup_valid && (spec_wakeup_tag == entry_rs1_tag);
    assign rs2_spec_match = spec_wakeup_valid && (spec_wakeup_tag == entry_rs2_tag);

    // -----------------------------------------------------------------------
    // Output wakeup signals -- suppressed when source already ready
    // -----------------------------------------------------------------------
    assign rs1_wakeup      = rs1_cdb_match  & ~entry_rs1_ready;
    assign rs2_wakeup      = rs2_cdb_match  & ~entry_rs2_ready;
    assign rs1_spec_wakeup = rs1_spec_match & ~entry_rs1_ready & ~rs1_cdb_match;
    assign rs2_spec_wakeup = rs2_spec_match & ~entry_rs2_ready & ~rs2_cdb_match;

endmodule
