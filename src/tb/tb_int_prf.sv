/* file: tb_int_prf.sv
 * Description: SystemVerilog wrapper / DUT instantiation for the integer PRF
 *              testbench.  The C++ driver (tb_int_prf.cpp) exercises all
 *              five test cases via the Verilated model.
 */

`ifndef TB_INT_PRF_SV
`define TB_INT_PRF_SV

module tb_int_prf
    import rv64gc_pkg::*;
(
    input  wire                      clk,
    // 12 read ports
    input  wire [PHYS_REG_BITS-1:0] raddr [0:11],
    output reg [63:0]              rdata [0:11],
    // 6 write ports
    input  wire [5:0]               wen,
    input  wire [PHYS_REG_BITS-1:0] waddr [0:5],
    input  wire [63:0]              wdata [0:5]
);

    int_prf dut (
        .clk   (clk),
        .raddr (raddr),
        .rdata (rdata),
        .wen   (wen),
        .waddr (waddr),
        .wdata (wdata)
    );

endmodule

`endif // TB_INT_PRF_SV
