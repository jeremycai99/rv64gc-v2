/* file: clint.sv
 Description: Single hart CLINT timer and software interrupt block.
 Author: Jeremy Cai
 Date: May 10, 2026
 Version: 1.0
*/
module clint #(
    parameter int unsigned MTIME_DIV_P = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid_i,
    input  wire        req_we_i,
    input  wire [15:0] req_addr_i,
    input  wire [63:0] req_wdata_i,
    input  wire [7:0]  req_wmask_i,
    output reg [63:0] resp_rdata_o,

    output reg [63:0] mtime_o,
    output reg        msip_o,
    output reg        mtip_o
);

    localparam logic [15:0] MSIP_OFFSET     = 16'h0000;
    localparam logic [15:0] MTIMECMP_OFFSET = 16'h4000;
    localparam logic [15:0] MTIME_OFFSET    = 16'hbff8;
    localparam int unsigned MTIME_DIV_EFF_P = (MTIME_DIV_P < 1) ? 1 : MTIME_DIV_P;
    localparam int unsigned MTIME_DIV_W     = (MTIME_DIV_EFF_P <= 1) ? 1 : $clog2(MTIME_DIV_EFF_P);

    logic [63:0] mtime_r;
    logic [63:0] mtimecmp_r;
    logic [MTIME_DIV_W-1:0] mtime_div_count_r;
    logic        msip_r;
    logic [63:0] read_raw;
    logic [5:0]  read_shift;
    logic        mtime_tick;

    always_comb begin
        read_raw = 64'd0;
        if (req_valid_i && !req_we_i) begin
            if (req_addr_i[15:2] == MSIP_OFFSET[15:2]) begin
                read_raw = {63'd0, msip_r};
            end else if (req_addr_i[15:3] == MTIMECMP_OFFSET[15:3]) begin
                read_raw = mtimecmp_r;
            end else if (req_addr_i[15:3] == MTIME_OFFSET[15:3]) begin
                read_raw = mtime_r;
            end
        end
    end

    assign read_shift   = {req_addr_i[2:0], 3'b000};
    assign resp_rdata_o = read_raw >> read_shift;
    assign mtime_tick   = (MTIME_DIV_EFF_P == 1) ||
                          (mtime_div_count_r == (MTIME_DIV_EFF_P - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime_r           <= 64'd0;
            mtimecmp_r        <= 64'hffff_ffff_ffff_ffff;
            mtime_div_count_r <= {MTIME_DIV_W{1'b0}};
            msip_r            <= 1'b0;
        end else begin
            if (mtime_tick) begin
                mtime_r           <= mtime_r + 64'd1;
                mtime_div_count_r <= {MTIME_DIV_W{1'b0}};
            end else begin
                mtime_div_count_r <= mtime_div_count_r + 1'b1;
            end

            if (req_valid_i && req_we_i) begin
                if (req_addr_i[15:2] == MSIP_OFFSET[15:2]) begin
                    if (req_wmask_i[0])
                        msip_r <= req_wdata_i[0];
                end else if (req_addr_i[15:3] == MTIMECMP_OFFSET[15:3]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (req_wmask_i[b] &&
                            (({1'b0, req_addr_i[2:0]} + 4'(b)) < 4'd8)) begin
                            mtimecmp_r[
                                (({1'b0, req_addr_i[2:0]} + 4'(b)) * 8) +: 8
                            ] <= req_wdata_i[b*8 +: 8];
                        end
                    end
                end else if (req_addr_i[15:3] == MTIME_OFFSET[15:3]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (req_wmask_i[b] &&
                            (({1'b0, req_addr_i[2:0]} + 4'(b)) < 4'd8)) begin
                            mtime_r[
                                (({1'b0, req_addr_i[2:0]} + 4'(b)) * 8) +: 8
                            ] <= req_wdata_i[b*8 +: 8];
                        end
                    end
                end
            end
        end
    end

    assign mtime_o = mtime_r;
    assign msip_o  = msip_r;
    assign mtip_o  = (mtime_r >= mtimecmp_r);

endmodule
