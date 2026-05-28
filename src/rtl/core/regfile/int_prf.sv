/* file: int_prf.sv
 Description: 160x64 integer PRF with 12 read and PRF_WRITE_PORTS write ports.
 Stage 2 (4-wide refactor): PRF_WRITE_PORTS=6 retained (see rv64gc_core_top.sv
 comment for port-count analysis).  Read ports remain 12R (4 FU pairs × 2 srcs
 + 2 load AGU + STA rs1 + STD rs2 = 12 structurally required).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef INT_PRF_SV
`define INT_PRF_SV

module int_prf
    import rv64gc_pkg::*;
(
    input  wire                      clk,
    input  wire                      rst_n,
    // 12 read ports (6 pairs)
    input  wire [PHYS_REG_BITS-1:0] raddr [0:11],
    output reg [63:0]              rdata [0:11],
    // PRF_WRITE_PORTS write ports
    input  wire [PRF_WRITE_PORTS-1:0] wen,
    input  wire [PHYS_REG_BITS-1:0]   waddr [0:PRF_WRITE_PORTS-1],
    input  wire [63:0]                 wdata [0:PRF_WRITE_PORTS-1]
);

    // -------------------------------------------------------------------------
    // Storage: 6 identical copies, each with 2 read ports served from them
    // -------------------------------------------------------------------------
    logic [63:0] regfile_copy0 [0:INT_PRF_DEPTH-1];
    logic [63:0] regfile_copy1 [0:INT_PRF_DEPTH-1];
    logic [63:0] regfile_copy2 [0:INT_PRF_DEPTH-1];
    logic [63:0] regfile_copy3 [0:INT_PRF_DEPTH-1];
    logic [63:0] regfile_copy4 [0:INT_PRF_DEPTH-1];
    logic [63:0] regfile_copy5 [0:INT_PRF_DEPTH-1];

    // -------------------------------------------------------------------------
    // Synchronous writes – all 6 write ports broadcast to all 6 copies.
    //
    // ASIC-CORRECT RESET DISCIPLINE:
    // In silicon, PRF entries must NOT be reset.  160 entries x 6 copies x
    // 64 bits = 61,440 flops sharing one reset net — vastly exceeds the
    // ~20-30 fanout budget at modern nodes.  The PRF's contents are
    // irrelevant at power-on because the rename logic's committed_rat and
    // free-list bitmap control which entries are architecturally live; any
    // un-renamed read returns an architecturally-meaningless value that is
    // never committed.
    //
    // For simulation only (4-state xsim), we zero the arrays via an
    // `initial` block so X values don't propagate through misspeculation.
    // synthesis tools ignore `initial` blocks.
    // -------------------------------------------------------------------------
`ifdef SIMULATION
    initial begin
        for (int i = 0; i < INT_PRF_DEPTH; i++) begin
            regfile_copy0[i] = 64'd0;
            regfile_copy1[i] = 64'd0;
            regfile_copy2[i] = 64'd0;
            regfile_copy3[i] = 64'd0;
            regfile_copy4[i] = 64'd0;
            regfile_copy5[i] = 64'd0;
        end
    end
`endif

    always_ff @(posedge clk) begin
        for (int wp = 0; wp < PRF_WRITE_PORTS; wp++) begin
            if (wen[wp]) begin
                regfile_copy0[waddr[wp]] <= wdata[wp];
                regfile_copy1[waddr[wp]] <= wdata[wp];
                regfile_copy2[waddr[wp]] <= wdata[wp];
                regfile_copy3[waddr[wp]] <= wdata[wp];
                regfile_copy4[waddr[wp]] <= wdata[wp];
                regfile_copy5[waddr[wp]] <= wdata[wp];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational reads with write-first bypass
    // Pair [0:1]   → copy 0
    // Pair [2:3]   → copy 1
    // Pair [4:5]   → copy 2
    // Pair [6:7]   → copy 3
    // Pair [8:9]   → copy 4
    // Pair [10:11] → copy 5
    //
    // Bypass priority: highest-indexed matching write port wins.
    // p0 (physical register 0) always reads as zero.
    // -------------------------------------------------------------------------

    // Base read values (from the copy assigned to this read port pair):
    logic [63:0] base_rdata [0:11];

    assign base_rdata[0]  = regfile_copy0[raddr[0]];
    assign base_rdata[1]  = regfile_copy0[raddr[1]];
    assign base_rdata[2]  = regfile_copy1[raddr[2]];
    assign base_rdata[3]  = regfile_copy1[raddr[3]];
    assign base_rdata[4]  = regfile_copy2[raddr[4]];
    assign base_rdata[5]  = regfile_copy2[raddr[5]];
    assign base_rdata[6]  = regfile_copy3[raddr[6]];
    assign base_rdata[7]  = regfile_copy3[raddr[7]];
    assign base_rdata[8]  = regfile_copy4[raddr[8]];
    assign base_rdata[9]  = regfile_copy4[raddr[9]];
    assign base_rdata[10] = regfile_copy5[raddr[10]];
    assign base_rdata[11] = regfile_copy5[raddr[11]];

    // Read with p0 zero rule (no write-first bypass; the bypass_network
    // already handles same-cycle CDB forwarding, avoiding a combinational loop)
    always_comb begin
        for (int rp = 0; rp < 12; rp++) begin
            if (raddr[rp] == '0) begin
                rdata[rp] = 64'h0;
            end else begin
                rdata[rp] = base_rdata[rp];
            end
        end
    end

endmodule

`endif // INT_PRF_SV
