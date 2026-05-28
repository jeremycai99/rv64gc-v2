/* file: fetch_packet_buffer.sv
 Description: Owner-aware instruction buffer between IFU and decode.
 Author: Jeremy Cai
 Date: Apr. 18, 2026
 Version: 2.0
*/
module fetch_packet_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          flush,

    input  wire          enq_valid,
    input  fetch_packet_t enq_packet,
    output reg          enq_ready,
    output reg          enq_fire,

    input  wire          deq_ready,
    output reg          deq_valid,
    output fetch_packet_t deq_packet,
    output reg          deq_fire,
    output reg          deq_flowthrough,

    input  wire                          owner_valid,
    input  wire [FTQ_IDX_BITS-1:0]       owner_idx,
    input  wire [FTQ_EPOCH_BITS-1:0]     owner_epoch,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] owner_tag,
    output reg                          deq_owner_match,
    output reg                          deq_stale_owner,
    output reg                          deq_owner_complete,

    output reg          full,
    output reg          empty,
    output reg [3:0]    count
);

    localparam int DEPTH = 8;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int PKT_W = $bits(fetch_packet_t);

    logic [PKT_W-1:0] mem_r [0:DEPTH-1];
    fetch_packet_t    mem_packet_c [0:DEPTH-1];
    logic [PTR_W:0]   count_r;
    logic [PTR_W:0]   deq_sel_c;
    fetch_packet_t    head_packet_c;
    fetch_packet_t    selected_packet_c;
    logic             deq_match_found_c;
    logic             deq_owner_ready_c;

    genvar gi;
    generate
        for (gi = 0; gi < DEPTH; gi++) begin : gen_mem_packet
            assign mem_packet_c[gi] = fetch_packet_t'(mem_r[gi]);
        end
    endgenerate

    assign empty     = (count_r == '0);
    assign full      = (count_r == DEPTH);
    assign deq_valid = !empty || (enq_valid && empty);
    assign enq_fire  = enq_valid && enq_ready;
    assign count     = count_r;

    always_comb begin
        deq_sel_c          = '0;
        deq_match_found_c  = 1'b0;
        selected_packet_c  = '0;

        for (int i = 0; i < DEPTH; i++) begin
            if ((PTR_W+1)'(i) < count_r) begin
                if (!deq_match_found_c &&
                    mem_packet_c[i].valid &&
                    owner_valid &&
                    (mem_packet_c[i].ftq_idx == owner_idx) &&
                    (mem_packet_c[i].ftq_epoch == owner_epoch) &&
                    (mem_packet_c[i].ftq_alloc_tag == owner_tag)) begin
                    deq_sel_c         = (PTR_W+1)'(i);
                    selected_packet_c = mem_packet_c[i];
                    deq_match_found_c = 1'b1;
                end
            end
        end
    end

    always_comb begin
        if (deq_match_found_c) begin
            head_packet_c = selected_packet_c;
        end else if (!empty) begin
            head_packet_c = mem_packet_c[0];
        end else if (enq_valid) begin
            head_packet_c = enq_packet;
        end else begin
            head_packet_c = '0;
        end
    end
    assign deq_packet = head_packet_c;
    assign deq_owner_complete =
        deq_valid && head_packet_c.valid && head_packet_c.ftq_owner_complete;
    assign deq_owner_match =
        deq_valid &&
        head_packet_c.valid &&
        owner_valid &&
        (head_packet_c.ftq_idx == owner_idx) &&
        (head_packet_c.ftq_epoch == owner_epoch) &&
        (head_packet_c.ftq_alloc_tag == owner_tag);
    assign deq_stale_owner =
        deq_valid &&
        head_packet_c.valid &&
        (!owner_valid ||
         (head_packet_c.ftq_idx != owner_idx) ||
         (head_packet_c.ftq_epoch != owner_epoch) ||
         (head_packet_c.ftq_alloc_tag != owner_tag));
    assign deq_owner_ready_c = deq_ready && deq_owner_match;
    assign enq_ready = !full || deq_owner_ready_c;
    assign deq_fire  = deq_valid && deq_owner_ready_c;
    assign deq_flowthrough = empty && enq_valid && deq_owner_ready_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_r <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                mem_r[i] <= '0;
            end
        end else if (flush) begin
            count_r <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                mem_r[i] <= '0;
            end
        end else begin
            if (empty && enq_fire && deq_fire) begin
                // Empty-buffer flow-through: delivered directly from
                // enq_packet, so no storage state changes.
            end else if (enq_fire && deq_fire) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if ((PTR_W+1)'(i) < deq_sel_c) begin
                        mem_r[i] <= mem_r[i];
                    end else if ((i < (DEPTH - 1)) &&
                                 ((PTR_W+1)'(i) < (count_r - 1'b1))) begin
                        mem_r[i] <= mem_r[i+1];
                    end else if ((PTR_W+1)'(i) == (count_r - 1'b1)) begin
                        mem_r[i] <= PKT_W'(enq_packet);
                    end else begin
                        mem_r[i] <= '0;
                    end
                end
            end else if (deq_fire) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if ((PTR_W+1)'(i) < deq_sel_c) begin
                        mem_r[i] <= mem_r[i];
                    end else if ((i < (DEPTH - 1)) &&
                                 ((PTR_W+1)'(i) < (count_r - 1'b1))) begin
                        mem_r[i] <= mem_r[i+1];
                    end else begin
                        mem_r[i] <= '0;
                    end
                end
                count_r <= count_r - {{PTR_W{1'b0}}, 1'b1};
            end else if (enq_fire) begin
                mem_r[count_r[PTR_W-1:0]] <= PKT_W'(enq_packet);
                count_r <= count_r + {{PTR_W{1'b0}}, 1'b1};
            end
        end
    end

endmodule
