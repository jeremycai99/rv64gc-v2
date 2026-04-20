/* file: ftq.sv
 Description: Fetch target queue for block-level frontend metadata ownership.
 Author: Jeremy Cai
 Date: Apr. 18, 2026
 Version: 2.0
*/
module ftq
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         flush,

    input  logic                         enq_valid,
    input  ftq_entry_t                   enq_entry,
    output logic                         enq_ready,
    output logic [FTQ_IDX_BITS-1:0]      enq_idx,
    output logic [FTQ_EPOCH_BITS-1:0]    enq_epoch,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] enq_tag,

    input  logic                         pop_valid,

    output logic                         head_valid,
    output ftq_entry_t                   head_entry,
    output logic [FTQ_IDX_BITS-1:0]      head_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] head_tag,

    output logic [FTQ_EPOCH_BITS-1:0]    current_epoch,
    output logic [FTQ_IDX_BITS:0]        count,
    output logic                         full,
    output logic                         empty
);

    localparam int DEPTH   = FTQ_DEPTH;
    localparam int ENTRY_W = $bits(ftq_entry_t);

    logic [ENTRY_W-1:0] mem_r [0:DEPTH-1];
    logic [FTQ_ALLOC_TAG_BITS-1:0] tag_mem_r [0:DEPTH-1];
    logic [FTQ_IDX_BITS-1:0] rd_ptr_r, wr_ptr_r;
    logic [FTQ_IDX_BITS:0]   count_r;
    logic [FTQ_EPOCH_BITS-1:0] epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] alloc_tag_r;
    ftq_entry_t head_entry_c;
    logic pop_fire_c;
    logic enq_fire_c;

    function automatic logic [FTQ_IDX_BITS-1:0] ptr_next(
        input logic [FTQ_IDX_BITS-1:0] ptr
    );
        begin
            if (ptr == FTQ_IDX_BITS'(DEPTH - 1))
                ptr_next = '0;
            else
                ptr_next = ptr + FTQ_IDX_BITS'(1);
        end
    endfunction

    assign empty         = (count_r == '0);
    assign full          = (count_r == DEPTH);
    assign head_valid    = !empty;
    assign enq_ready     = !full || pop_valid;
    assign enq_idx       = flush ? '0 : wr_ptr_r;
    assign enq_epoch     = flush ? (epoch_r + FTQ_EPOCH_BITS'(1)) : epoch_r;
    assign enq_tag       = alloc_tag_r;
    assign head_idx      = rd_ptr_r;
    assign head_tag      = empty ? '0 : tag_mem_r[rd_ptr_r];
    assign current_epoch = epoch_r;
    assign count         = count_r;
    assign pop_fire_c    = pop_valid && head_valid;
    assign enq_fire_c    = enq_valid && enq_ready;

    always_comb begin
        if (!empty)
            head_entry_c = ftq_entry_t'(mem_r[rd_ptr_r]);
        else
            head_entry_c = '0;
    end
    assign head_entry = head_entry_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_r <= '0;
            wr_ptr_r <= '0;
            count_r  <= '0;
            epoch_r  <= '0;
            alloc_tag_r <= '0;
        end else begin
            if (flush) begin
                rd_ptr_r <= '0;
                wr_ptr_r <= '0;
                count_r  <= '0;
                epoch_r  <= epoch_r + FTQ_EPOCH_BITS'(1);
                if (enq_fire_c)
                    alloc_tag_r <= alloc_tag_r + FTQ_ALLOC_TAG_BITS'(1);

                if (enq_fire_c) begin
                    mem_r[0] <= ENTRY_W'(enq_entry);
                    tag_mem_r[0] <= alloc_tag_r;
                    wr_ptr_r  <= FTQ_IDX_BITS'(1);
                    count_r   <= {{FTQ_IDX_BITS{1'b0}}, 1'b1};
                end
            end else begin
                if (enq_fire_c)
                    alloc_tag_r <= alloc_tag_r + FTQ_ALLOC_TAG_BITS'(1);

                case ({enq_fire_c, pop_fire_c})
                    2'b10: begin
                        mem_r[wr_ptr_r] <= ENTRY_W'(enq_entry);
                        tag_mem_r[wr_ptr_r] <= alloc_tag_r;
                        wr_ptr_r        <= ptr_next(wr_ptr_r);
                        count_r         <= count_r + {{FTQ_IDX_BITS{1'b0}}, 1'b1};
                    end
                    2'b01: begin
                        rd_ptr_r        <= ptr_next(rd_ptr_r);
                        count_r         <= count_r - {{FTQ_IDX_BITS{1'b0}}, 1'b1};
                    end
                    2'b11: begin
                        mem_r[wr_ptr_r] <= ENTRY_W'(enq_entry);
                        tag_mem_r[wr_ptr_r] <= alloc_tag_r;
                        wr_ptr_r        <= ptr_next(wr_ptr_r);
                        rd_ptr_r        <= ptr_next(rd_ptr_r);
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
