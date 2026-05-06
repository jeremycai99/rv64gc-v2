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

    input  logic                         ifu_req_pop_valid,
    input  logic                         pop_valid,

    output logic                         head_valid,
    output ftq_entry_t                   head_entry,
    output logic [FTQ_IDX_BITS-1:0]      head_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] head_tag,

    output logic                         ifu_owner_valid,
    output ftq_entry_t                   ifu_owner_entry,
    output logic [FTQ_IDX_BITS-1:0]      ifu_owner_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] ifu_owner_tag,
    output logic                         ifu_wb_owner_valid,
    output ftq_entry_t                   ifu_wb_owner_entry,
    output logic [FTQ_IDX_BITS-1:0]      ifu_wb_owner_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] ifu_wb_owner_tag,
    output logic                         next_ifu_owner_valid,
    output ftq_entry_t                   next_ifu_owner_entry,
    output logic [FTQ_IDX_BITS-1:0]      next_ifu_owner_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] next_ifu_owner_tag,

    input  logic                         commit_pop_valid,
    output logic                         commit_head_valid,
    output ftq_entry_t                   commit_head_entry,
    output logic [FTQ_IDX_BITS-1:0]      commit_head_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] commit_head_tag,

    output logic                         commit_owner_valid,
    output ftq_entry_t                   commit_owner_entry,
    output logic [FTQ_IDX_BITS-1:0]      commit_owner_idx,
    output logic [FTQ_ALLOC_TAG_BITS-1:0] commit_owner_tag,

    output logic [FTQ_EPOCH_BITS-1:0]    current_epoch,
    output logic [FTQ_IDX_BITS:0]        count,
    output logic [FTQ_IDX_BITS:0]        count_alloc_to_ifu,
    output logic [FTQ_IDX_BITS:0]        count_ifu_to_wb,
    output logic [FTQ_IDX_BITS:0]        count_ifu_to_commit,
    output logic                         full,
    output logic                         empty
);

    localparam int DEPTH   = FTQ_DEPTH;
    localparam int ENTRY_W = $bits(ftq_entry_t);

    logic [ENTRY_W-1:0] mem_r [0:DEPTH-1];
    logic [FTQ_ALLOC_TAG_BITS-1:0] tag_mem_r [0:DEPTH-1];
    logic [FTQ_IDX_BITS-1:0] ifu_req_ptr_r, ifu_wb_ptr_r;
    logic [FTQ_IDX_BITS-1:0] commit_ptr_r, wr_ptr_r;
    logic [FTQ_IDX_BITS:0]   count_alloc_to_ifu_r;
    logic [FTQ_IDX_BITS:0]   count_ifu_to_wb_r;
    logic [FTQ_IDX_BITS:0]   count_wb_to_commit_r;
    logic [FTQ_IDX_BITS:0]   total_count_c;
    logic [FTQ_EPOCH_BITS-1:0] epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] alloc_tag_r;
    ftq_entry_t ifu_owner_entry_c;
    ftq_entry_t ifu_wb_owner_entry_c;
    ftq_entry_t commit_owner_entry_c;
    ftq_entry_t next_ifu_owner_entry_c;
    logic [FTQ_IDX_BITS-1:0] ifu_owner_idx_c;
    logic [FTQ_IDX_BITS-1:0] ifu_wb_owner_idx_c;
    logic [FTQ_IDX_BITS-1:0] commit_owner_idx_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ifu_owner_tag_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ifu_wb_owner_tag_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0] commit_owner_tag_c;
    logic ifu_owner_valid_c;
    logic ifu_wb_owner_valid_c;
    logic commit_owner_valid_c;
    logic [FTQ_IDX_BITS-1:0] next_ifu_req_ptr_c;
    logic [FTQ_IDX_BITS-1:0] next_ifu_wb_ptr_c;
    logic [FTQ_IDX_BITS-1:0] next_commit_ptr_c;
    logic [FTQ_IDX_BITS:0] next_count_alloc_to_ifu_c;
    logic [FTQ_IDX_BITS:0] next_count_ifu_to_wb_c;
    logic [FTQ_IDX_BITS:0] next_count_wb_to_commit_c;
    logic ifu_req_pop_existing_c;
    logic ifu_req_pop_from_enq_c;
    logic ifu_req_pop_fire_c;
    logic ifu_wb_pop_fire_c;
    logic commit_pop_fire_c;
    logic commit_pop_possible_c;
    logic enq_fire_c;
    logic [FTQ_IDX_BITS-1:0] ifu_req_pop_idx_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ifu_req_pop_tag_c;
    ftq_entry_t ifu_req_pop_entry_c;
    logic next_ifu_owner_from_enq_c;

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

    assign total_count_c = count_alloc_to_ifu_r +
                           count_ifu_to_wb_r +
                           count_wb_to_commit_r;
    assign empty         = (total_count_c == '0);
    assign full          = (total_count_c == DEPTH);
    assign ifu_owner_valid_c = (count_alloc_to_ifu_r != '0);
    assign ifu_wb_owner_valid_c = (count_ifu_to_wb_r != '0) ||
                                  ifu_req_pop_fire_c;
    assign commit_owner_valid_c = (count_wb_to_commit_r != '0) ||
                                  ifu_wb_pop_fire_c;
    assign head_valid    = ifu_wb_owner_valid_c;
    assign commit_head_valid = commit_owner_valid_c;
    assign commit_pop_possible_c = commit_pop_valid && commit_head_valid;
    assign enq_ready     = flush || !full || commit_pop_possible_c;
    assign enq_idx       = flush ? '0 : wr_ptr_r;
    assign enq_epoch     = flush ? (epoch_r + FTQ_EPOCH_BITS'(1)) : epoch_r;
    assign enq_tag       = alloc_tag_r;
    assign current_epoch = epoch_r;
    assign count         = count_alloc_to_ifu_r + count_ifu_to_wb_r;
    assign count_alloc_to_ifu = count_alloc_to_ifu_r;
    assign count_ifu_to_wb = count_ifu_to_wb_r;
    assign enq_fire_c    = enq_valid && enq_ready;
    assign ifu_req_pop_existing_c = !flush && ifu_req_pop_valid &&
                                     ifu_owner_valid_c;
    assign ifu_req_pop_from_enq_c = !flush && ifu_req_pop_valid &&
                                    !ifu_owner_valid_c && enq_fire_c;
    assign ifu_req_pop_fire_c = ifu_req_pop_existing_c ||
                                ifu_req_pop_from_enq_c;
    assign ifu_wb_pop_fire_c = !flush && pop_valid &&
                               ((count_ifu_to_wb_r != '0) ||
                                ifu_req_pop_existing_c);
    assign commit_pop_fire_c = !flush && commit_pop_valid &&
                               commit_owner_valid_c;
    assign count_ifu_to_commit = count_ifu_to_wb_r + count_wb_to_commit_r;

    assign ifu_owner_idx_c = ifu_req_ptr_r;
    assign ifu_owner_tag_c =
        ifu_owner_valid_c ? tag_mem_r[ifu_req_ptr_r] : '0;
    always_comb begin
        if (ifu_owner_valid_c)
            ifu_owner_entry_c = ftq_entry_t'(mem_r[ifu_req_ptr_r]);
        else
            ifu_owner_entry_c = '0;
    end

    assign ifu_req_pop_idx_c =
        ifu_req_pop_from_enq_c ? wr_ptr_r : ifu_owner_idx_c;
    assign ifu_req_pop_tag_c =
        ifu_req_pop_from_enq_c ? alloc_tag_r : ifu_owner_tag_c;
    always_comb begin
        if (ifu_req_pop_from_enq_c)
            ifu_req_pop_entry_c = enq_entry;
        else
            ifu_req_pop_entry_c = ifu_owner_entry_c;
    end

    assign ifu_wb_owner_idx_c =
        (count_ifu_to_wb_r != '0) ? ifu_wb_ptr_r : ifu_req_pop_idx_c;
    assign ifu_wb_owner_tag_c =
        !ifu_wb_owner_valid_c
            ? '0
            : ((count_ifu_to_wb_r != '0)
                  ? tag_mem_r[ifu_wb_owner_idx_c]
                  : ifu_req_pop_tag_c);
    always_comb begin
        if (!ifu_wb_owner_valid_c)
            ifu_wb_owner_entry_c = '0;
        else if (count_ifu_to_wb_r != '0)
            ifu_wb_owner_entry_c = ftq_entry_t'(mem_r[ifu_wb_owner_idx_c]);
        else
            ifu_wb_owner_entry_c = ifu_req_pop_entry_c;
    end

    assign commit_owner_idx_c =
        (count_wb_to_commit_r != '0) ? commit_ptr_r : ifu_wb_owner_idx_c;
    assign commit_owner_tag_c =
        commit_owner_valid_c ? tag_mem_r[commit_owner_idx_c] : '0;
    always_comb begin
        if (commit_owner_valid_c)
            commit_owner_entry_c = ftq_entry_t'(mem_r[commit_owner_idx_c]);
        else
            commit_owner_entry_c = '0;
    end

    assign head_entry = ifu_wb_owner_entry_c;
    assign head_idx   = ifu_wb_owner_idx_c;
    assign head_tag   = ifu_wb_owner_tag_c;
    assign ifu_owner_valid = ifu_owner_valid_c;
    assign ifu_owner_entry = ifu_owner_entry_c;
    assign ifu_owner_idx   = ifu_owner_idx_c;
    assign ifu_owner_tag   = ifu_owner_tag_c;
    assign ifu_wb_owner_valid = ifu_wb_owner_valid_c;
    assign ifu_wb_owner_entry = ifu_wb_owner_entry_c;
    assign ifu_wb_owner_idx   = ifu_wb_owner_idx_c;
    assign ifu_wb_owner_tag   = ifu_wb_owner_tag_c;
    assign commit_head_entry = commit_owner_entry_c;
    assign commit_head_idx   = commit_owner_idx_c;
    assign commit_head_tag   = commit_owner_tag_c;
    assign commit_owner_valid = commit_owner_valid_c;
    assign commit_owner_entry = commit_owner_entry_c;
    assign commit_owner_idx   = commit_owner_idx_c;
    assign commit_owner_tag   = commit_owner_tag_c;

    always_comb begin
        next_count_alloc_to_ifu_c = count_alloc_to_ifu_r +
            (enq_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0) -
            (ifu_req_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0);
        next_count_ifu_to_wb_c = count_ifu_to_wb_r +
            (ifu_req_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0) -
            (ifu_wb_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0);
        next_count_wb_to_commit_c = count_wb_to_commit_r +
            (ifu_wb_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0) -
            (commit_pop_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0);

        if (flush) begin
            next_count_alloc_to_ifu_c =
                enq_fire_c ? {{FTQ_IDX_BITS{1'b0}}, 1'b1} : '0;
            next_count_ifu_to_wb_c = '0;
            next_count_wb_to_commit_c = '0;
        end
    end

    always_comb begin
        next_ifu_req_ptr_c = ifu_req_ptr_r;

        if (flush) begin
            next_ifu_req_ptr_c = '0;
        end else if (ifu_req_pop_existing_c) begin
            if (count_alloc_to_ifu_r > {{FTQ_IDX_BITS{1'b0}}, 1'b1})
                next_ifu_req_ptr_c = ptr_next(ifu_req_ptr_r);
            else if (enq_fire_c)
                next_ifu_req_ptr_c = wr_ptr_r;
            else
                next_ifu_req_ptr_c = ptr_next(ifu_req_ptr_r);
        end else if (ifu_req_pop_from_enq_c) begin
            next_ifu_req_ptr_c = ptr_next(wr_ptr_r);
        end else if ((count_alloc_to_ifu_r == '0) && enq_fire_c) begin
            next_ifu_req_ptr_c = wr_ptr_r;
        end
    end

    always_comb begin
        next_ifu_wb_ptr_c = ifu_wb_ptr_r;

        if (flush) begin
            next_ifu_wb_ptr_c = '0;
        end else if (ifu_wb_pop_fire_c) begin
            if (count_ifu_to_wb_r > {{FTQ_IDX_BITS{1'b0}}, 1'b1})
                next_ifu_wb_ptr_c = ptr_next(ifu_wb_ptr_r);
            else if (ifu_req_pop_fire_c)
                next_ifu_wb_ptr_c = ifu_req_pop_idx_c;
            else
                next_ifu_wb_ptr_c = ptr_next(ifu_wb_ptr_r);
        end else if ((count_ifu_to_wb_r == '0) && ifu_req_pop_fire_c) begin
            next_ifu_wb_ptr_c = ifu_req_pop_idx_c;
        end
    end

    always_comb begin
        next_commit_ptr_c = commit_ptr_r;

        if (flush) begin
            next_commit_ptr_c = '0;
        end else if (commit_pop_fire_c) begin
            if (count_wb_to_commit_r > {{FTQ_IDX_BITS{1'b0}}, 1'b1})
                next_commit_ptr_c = ptr_next(commit_ptr_r);
            else if (ifu_wb_pop_fire_c)
                next_commit_ptr_c = ifu_wb_owner_idx_c;
            else
                next_commit_ptr_c = ptr_next(commit_ptr_r);
        end else if ((count_wb_to_commit_r == '0) && ifu_wb_pop_fire_c) begin
            next_commit_ptr_c = ifu_wb_owner_idx_c;
        end
    end

    always_comb begin
        next_ifu_owner_entry_c = '0;

        if (next_count_ifu_to_wb_c != '0) begin
            if (next_ifu_owner_from_enq_c)
                next_ifu_owner_entry_c = enq_entry;
            else
                next_ifu_owner_entry_c = ftq_entry_t'(mem_r[next_ifu_wb_ptr_c]);
        end
    end

    assign next_ifu_owner_from_enq_c =
        (next_count_ifu_to_wb_c != '0) &&
        ifu_req_pop_from_enq_c &&
        (next_ifu_wb_ptr_c == wr_ptr_r);
    assign next_ifu_owner_valid = (next_count_ifu_to_wb_c != '0);
    assign next_ifu_owner_entry = next_ifu_owner_entry_c;
    assign next_ifu_owner_idx   = next_ifu_wb_ptr_c;
    assign next_ifu_owner_tag   =
        !next_ifu_owner_valid
            ? '0
            : (next_ifu_owner_from_enq_c
                  ? alloc_tag_r
                  : tag_mem_r[next_ifu_wb_ptr_c]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifu_req_ptr_r         <= '0;
            ifu_wb_ptr_r          <= '0;
            commit_ptr_r          <= '0;
            wr_ptr_r              <= '0;
            count_alloc_to_ifu_r  <= '0;
            count_ifu_to_wb_r     <= '0;
            count_wb_to_commit_r  <= '0;
            epoch_r               <= '0;
            alloc_tag_r           <= '0;
        end else begin
            if (flush) begin
                ifu_req_ptr_r         <= '0;
                ifu_wb_ptr_r          <= '0;
                commit_ptr_r          <= '0;
                wr_ptr_r              <= '0;
                count_alloc_to_ifu_r  <= '0;
                count_ifu_to_wb_r     <= '0;
                count_wb_to_commit_r  <= '0;
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

                ifu_req_ptr_r <= next_ifu_req_ptr_c;
                ifu_wb_ptr_r  <= next_ifu_wb_ptr_c;
                commit_ptr_r  <= next_commit_ptr_c;

                count_alloc_to_ifu_r  <= next_count_alloc_to_ifu_c;
                count_ifu_to_wb_r     <= next_count_ifu_to_wb_c;
                count_wb_to_commit_r  <= next_count_wb_to_commit_c;
            end
        end
    end

endmodule
