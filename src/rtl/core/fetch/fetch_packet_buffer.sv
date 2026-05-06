/* file: fetch_packet_buffer.sv
 Description: Small FIFO of fetch packets between IFU and decode.
 Author: Jeremy Cai
 Date: Apr. 18, 2026
 Version: 2.0
*/
module fetch_packet_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          flush,

    input  logic          enq_valid,
    input  fetch_packet_t enq_packet,
    output logic          enq_ready,

    input  logic          deq_ready,
    output logic          deq_valid,
    output fetch_packet_t deq_packet,

    output logic          full,
    output logic          empty,
    output logic [3:0]    count
);

    localparam int DEPTH = 8;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int PKT_W = $bits(fetch_packet_t);

    logic [PKT_W-1:0] mem_r [0:DEPTH-1];
    logic [PTR_W-1:0] rd_ptr_r, wr_ptr_r;
    logic [PTR_W:0]   count_r;
    fetch_packet_t    head_packet_c;

    assign empty     = (count_r == '0);
    assign full      = (count_r == DEPTH);
    assign enq_ready = !full;
    assign deq_valid = !empty;
    assign count     = count_r;

    always_comb begin
        if (!empty) begin
            head_packet_c = fetch_packet_t'(mem_r[rd_ptr_r]);
        end else begin
            head_packet_c = '0;
        end
    end
    assign deq_packet = head_packet_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_r <= '0;
            wr_ptr_r <= '0;
            count_r  <= '0;
        end else if (flush) begin
            rd_ptr_r <= '0;
            wr_ptr_r <= '0;
            count_r  <= '0;
        end else begin
            case ({enq_valid && enq_ready, deq_valid && deq_ready})
                2'b10: begin
                    mem_r[wr_ptr_r] <= PKT_W'(enq_packet);
                    wr_ptr_r        <= wr_ptr_r + PTR_W'(1);
                    count_r         <= count_r + {{PTR_W{1'b0}}, 1'b1};
                end
                2'b01: begin
                    rd_ptr_r        <= rd_ptr_r + PTR_W'(1);
                    count_r         <= count_r - {{PTR_W{1'b0}}, 1'b1};
                end
                2'b11: begin
                    mem_r[wr_ptr_r] <= PKT_W'(enq_packet);
                    wr_ptr_r        <= wr_ptr_r + PTR_W'(1);
                    rd_ptr_r        <= rd_ptr_r + PTR_W'(1);
                end
                default: begin
                end
            endcase
        end
    end

endmodule
