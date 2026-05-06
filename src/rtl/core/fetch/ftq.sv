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

    input  logic                         commit_pop_valid,
    output logic                         commit_head_valid,
    output ftq_entry_t                   commit_head_entry,
    output logic [FTQ_IDX_BITS-1:0]      commit_head_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] commit_head_tag,

    output logic [FTQ_EPOCH_BITS-1:0]    current_epoch,
    output logic [FTQ_IDX_BITS:0]        count,
    output logic [FTQ_IDX_BITS:0]        count_alloc_to_ifu,
    output logic [FTQ_IDX_BITS:0]        count_ifu_to_commit,
    output logic                         full,
    output logic                         empty
);

    localparam int DEPTH   = FTQ_DEPTH;
    localparam int ENTRY_W = $bits(ftq_entry_t);

    logic [ENTRY_W-1:0] mem_r [0:DEPTH-1];
    logic [FTQ_ALLOC_TAG_BITS-1:0] tag_mem_r [0:DEPTH-1];
    logic [FTQ_IDX_BITS-1:0] ifu_ptr_r, commit_ptr_r, wr_ptr_r;
    logic [FTQ_IDX_BITS:0]   count_alloc_to_ifu_r;
    logic [FTQ_IDX_BITS:0]   count_ifu_to_commit_r;
    logic [FTQ_IDX_BITS:0]   total_count_c;
    logic [FTQ_EPOCH_BITS-1:0] epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] alloc_tag_r;
    ftq_entry_t head_entry_c;
    ftq_entry_t commit_head_entry_c;
    logic ifu_pop_fire_c;
    logic commit_pop_fire_c;
    logic commit_pop_possible_c;
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

    assign total_count_c = count_alloc_to_ifu_r + count_ifu_to_commit_r;
    assign empty         = (count_alloc_to_ifu_r == '0);
    assign full          = (total_count_c == DEPTH);
    assign head_valid    = !empty;
    assign commit_head_valid = (count_ifu_to_commit_r != '0) ||
                               (pop_valid && head_valid);
    assign commit_pop_possible_c = commit_pop_valid && commit_head_valid;
    assign enq_ready     = flush || !full || commit_pop_possible_c;
    assign enq_idx       = flush ? '0 : wr_ptr_r;
    assign enq_epoch     = flush ? (epoch_r + FTQ_EPOCH_BITS'(1)) : epoch_r;
    assign enq_tag       = alloc_tag_r;
    assign head_idx      = ifu_ptr_r;
    assign head_tag      = empty ? '0 : tag_mem_r[ifu_ptr_r];
    assign commit_head_idx = commit_ptr_r;
    assign commit_head_tag =
        commit_head_valid ? tag_mem_r[commit_ptr_r] : '0;
    assign current_epoch = epoch_r;
    assign count         = count_alloc_to_ifu_r;
    assign count_alloc_to_ifu = count_alloc_to_ifu_r;
    assign count_ifu_to_commit = count_ifu_to_commit_r;
    assign ifu_pop_fire_c = pop_valid && head_valid;
    assign commit_pop_fire_c = commit_pop_valid &&
                               ((count_ifu_to_commit_r != '0) ||
                                ifu_pop_fire_c);
    assign enq_fire_c    = enq_valid && enq_ready;

    always_comb begin
        if (!empty)
            head_entry_c = ftq_entry_t'(mem_r[ifu_ptr_r]);
        else
            head_entry_c = '0;
    end
    assign head_entry = head_entry_c;

    always_comb begin
        if (commit_head_valid)
            commit_head_entry_c = ftq_entry_t'(mem_r[commit_ptr_r]);
        else
            commit_head_entry_c = '0;
    end
    assign commit_head_entry = commit_head_entry_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifu_ptr_r             <= '0;
            commit_ptr_r          <= '0;
            wr_ptr_r              <= '0;
            count_alloc_to_ifu_r  <= '0;
            count_ifu_to_commit_r <= '0;
            epoch_r               <= '0;
            alloc_tag_r           <= '0;
        end else begin
            if (flush) begin
                ifu_ptr_r             <= '0;
                commit_ptr_r          <= '0;
                wr_ptr_r              <= '0;
                count_alloc_to_ifu_r  <= '0;
                count_ifu_to_commit_r <= '0;
                epoch_r               <= epoch_r + FTQ_EPOCH_BITS'(1);
                if (enq_fire_c)
                    alloc_tag_r <= alloc_tag_r + FTQ_ALLOC_TAG_BITS'(1);

                if (enq_fire_c) begin
                    mem_r[0]     <= ENTRY_W'(enq_entry);
                    tag_mem_r[0] <= alloc_tag_r;
                    wr_ptr_r     <= FTQ_IDX_BITS'(1);
                    count_alloc_to_ifu_r <=
                        {{FTQ_IDX_BITS{1'b0}}, 1'b1};
                end
            end else begin
                if (enq_fire_c)
                    alloc_tag_r <= alloc_tag_r + FTQ_ALLOC_TAG_BITS'(1);

                if (enq_fire_c) begin
                    mem_r[wr_ptr_r]     <= ENTRY_W'(enq_entry);
                    tag_mem_r[wr_ptr_r] <= alloc_tag_r;
                    wr_ptr_r            <= ptr_next(wr_ptr_r);
                end

                if (ifu_pop_fire_c)
                    ifu_ptr_r <= ptr_next(ifu_ptr_r);

                if (commit_pop_fire_c)
                    commit_ptr_r <= ptr_next(commit_ptr_r);

                count_alloc_to_ifu_r <= count_alloc_to_ifu_r +
                    (enq_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0) -
                    (ifu_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0);
                count_ifu_to_commit_r <= count_ifu_to_commit_r +
                    (ifu_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0) -
                    (commit_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0);
            end
        end
    end

endmodule
