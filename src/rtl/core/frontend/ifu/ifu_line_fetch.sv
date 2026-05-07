/* file: ifu_line_fetch.sv
 Description: IFU line request adapter for I-cache and next-line prefetch data.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ifu_line_fetch
    import rv64gc_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 flush_i,
    input  logic                 fence_i,

    input  logic                 req_valid_i,
    input  logic [63:0]          req_addr_i,
    input  logic [63:0]          aux_lookup_addr_i,
    input  logic                 f1_valid_i,
    input  logic                 stall_i,
    input  logic                 work_line_valid_i,
    input  logic [63:LINE_BITS]  work_line_addr_i,

    output logic                 line_resp_valid_o,
    output logic [511:0]         line_resp_data_o,
    output logic                 line_resp_hit_o,
    output logic                 nlpb_hit_o,
    output logic                 nlpb_aux_hit_o,

    output logic                 icache_fill_req_valid,
    output logic [63:0]          icache_fill_req_addr,
    input  logic                 icache_fill_resp_valid,
    input  logic [63:0]          icache_fill_resp_addr,
    input  logic [511:0]         icache_fill_resp_data,
    output logic                 icache_invalidate_busy,

    output logic                 pf_l2_req_valid,
    output logic [63:0]          pf_l2_req_addr,
    input  logic                 pf_l2_req_ready,
    input  logic                 pf_l2_resp_valid,
    input  logic [63:0]          pf_l2_resp_addr,
    input  logic [511:0]         pf_l2_resp_data
);

    logic         ic_resp_valid_comb;
    logic [511:0] ic_resp_data_comb;
    logic         ic_resp_hit_comb;
    logic         nlpb_hit_comb;
    logic [511:0] nlpb_data_comb;
    logic         nlpb_aux_hit_comb;
    logic [511:0] nlpb_aux_data_comb;
    logic         nlpb_resp_valid_r;
    logic [63:0]  nlpb_resp_addr_r;
    logic [511:0] nlpb_resp_data_r;
    logic         nlpb_resp_match_c;
    logic         nlpb_trigger;
    logic [63:0]  nlpb_trigger_addr;

    assign nlpb_trigger      = ic_resp_valid_comb && ic_resp_hit_comb;
    assign nlpb_trigger_addr = {req_addr_i[63:6], 6'b0};
    assign nlpb_resp_match_c =
        nlpb_resp_valid_r &&
        work_line_valid_i &&
        (nlpb_resp_addr_r[63:LINE_BITS] == work_line_addr_i);
    assign line_resp_valid_o = ic_resp_valid_comb || nlpb_resp_match_c;
    assign line_resp_data_o  =
        ic_resp_valid_comb ? ic_resp_data_comb : nlpb_resp_data_r;
    assign line_resp_hit_o   = ic_resp_hit_comb || nlpb_resp_match_c;
    assign nlpb_hit_o        = nlpb_hit_comb;
    assign nlpb_aux_hit_o    = nlpb_aux_hit_comb;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid      (req_valid_i),
        .req_addr       (req_addr_i),
        .resp_valid     (ic_resp_valid_comb),
        .resp_data      (ic_resp_data_comb),
        .resp_hit       (ic_resp_hit_comb),
        .fill_req_valid (icache_fill_req_valid),
        .fill_req_addr  (icache_fill_req_addr),
        .fill_resp_valid(icache_fill_resp_valid),
        .fill_resp_addr (icache_fill_resp_addr),
        .fill_resp_data (icache_fill_resp_data),
        .invalidate_all (fence_i),
        .invalidate_busy(icache_invalidate_busy)
    );

    next_line_prefetch_buffer u_nlpb (
        .clk             (clk),
        .rst_n           (rst_n),
        .lookup_valid    (f1_valid_i && !stall_i),
        .lookup_addr     (req_addr_i),
        .hit             (nlpb_hit_comb),
        .hit_data        (nlpb_data_comb),
        .aux_lookup_valid(f1_valid_i && !stall_i),
        .aux_lookup_addr (aux_lookup_addr_i),
        .aux_hit         (nlpb_aux_hit_comb),
        .aux_hit_data    (nlpb_aux_data_comb),
        .trigger_valid   (nlpb_trigger),
        .trigger_addr    (nlpb_trigger_addr),
        .flush           (flush_i),
        .fence_i         (fence_i),
        .pf_req_valid    (pf_l2_req_valid),
        .pf_req_addr     (pf_l2_req_addr),
        .pf_req_ready    (pf_l2_req_ready),
        .pf_resp_valid   (pf_l2_resp_valid),
        .pf_resp_addr    (pf_l2_resp_addr),
        .pf_resp_data    (pf_l2_resp_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
        end else if (flush_i) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
        end else begin
            nlpb_resp_valid_r <= f1_valid_i && !stall_i && nlpb_hit_comb;
            nlpb_resp_addr_r  <= {req_addr_i[63:LINE_BITS], {LINE_BITS{1'b0}}};
            nlpb_resp_data_r  <= nlpb_data_comb;
        end
    end

endmodule
