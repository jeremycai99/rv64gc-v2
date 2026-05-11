/* file: fp_prf.sv
 Description: Floating-point physical register file. 80 x 64-bit, 8 read
 ports, 4 write ports. Mirrors the integer PRF banking style so Phase 5 can
 reuse the same issue/read/write timing assumptions without FPGA-specific RAMs.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.1
*/

module fp_prf
    import rv64gc_pkg::*;
(
    input  logic clk,
    input  logic [6:0] rd_addr [0:7],
    output logic [63:0] rd_data [0:7],
    input  logic [3:0] wr_en,
    input  logic [6:0] wr_addr [0:3],
    input  logic [63:0] wr_data [0:3]
);

    logic [63:0] regfile_copy0 [0:FP_PRF_DEPTH-1];
    logic [63:0] regfile_copy1 [0:FP_PRF_DEPTH-1];
    logic [63:0] regfile_copy2 [0:FP_PRF_DEPTH-1];
    logic [63:0] regfile_copy3 [0:FP_PRF_DEPTH-1];

`ifdef SIMULATION
    initial begin
        for (int i = 0; i < FP_PRF_DEPTH; i++) begin
            regfile_copy0[i] = 64'd0;
            regfile_copy1[i] = 64'd0;
            regfile_copy2[i] = 64'd0;
            regfile_copy3[i] = 64'd0;
        end
    end
`endif

    always_ff @(posedge clk) begin
        for (int wp = 0; wp < 4; wp++) begin
            if (wr_en[wp] && (wr_addr[wp] < FP_PRF_DEPTH[6:0])) begin
                regfile_copy0[wr_addr[wp]] <= wr_data[wp];
                regfile_copy1[wr_addr[wp]] <= wr_data[wp];
                regfile_copy2[wr_addr[wp]] <= wr_data[wp];
                regfile_copy3[wr_addr[wp]] <= wr_data[wp];
            end
        end
    end

    logic [63:0] base_rdata [0:7];

    assign base_rdata[0] = regfile_copy0[rd_addr[0]];
    assign base_rdata[1] = regfile_copy0[rd_addr[1]];
    assign base_rdata[2] = regfile_copy1[rd_addr[2]];
    assign base_rdata[3] = regfile_copy1[rd_addr[3]];
    assign base_rdata[4] = regfile_copy2[rd_addr[4]];
    assign base_rdata[5] = regfile_copy2[rd_addr[5]];
    assign base_rdata[6] = regfile_copy3[rd_addr[6]];
    assign base_rdata[7] = regfile_copy3[rd_addr[7]];

    always_comb begin
        for (int rp = 0; rp < 8; rp++) begin
            rd_data[rp] = base_rdata[rp];
            for (int wp = 0; wp < 4; wp++) begin
                if (wr_en[wp] && (wr_addr[wp] < FP_PRF_DEPTH[6:0]) &&
                    (rd_addr[rp] == wr_addr[wp])) begin
                    rd_data[rp] = wr_data[wp];
                end
            end
        end
    end

endmodule
