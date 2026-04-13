/* file: rob.sv
 Description: 192-entry circular reorder buffer with 6-wide alloc/commit.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rob
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Allocate: up to 6 entries per cycle from rename
    input  logic [2:0]              alloc_count,     // 0..6 valid entries to allocate
    output logic [ROB_IDX_BITS-1:0] alloc_idx [0:PIPE_WIDTH-1],  // allocated ROB indices
    output logic                    alloc_ready,     // can accept alloc_count entries
    // Data to write at allocation time (per-entry fields)
    input  logic [63:0]             alloc_pc [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   alloc_is_branch,
    input  logic [2:0]             alloc_bpu_type [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]   alloc_is_store,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_load,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_csr,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fence,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_fence_i,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_mret,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_sret,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_sfence_vma,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_ecall,
    input  logic [PIPE_WIDTH-1:0]   alloc_is_wfi,

    // Writeback: CDB marks entries as complete (up to 6 per cycle)
    input  logic [CDB_WIDTH-1:0]              wb_valid,
    input  logic [ROB_IDX_BITS-1:0]           wb_idx [0:CDB_WIDTH-1],
    input  logic [CDB_WIDTH-1:0]              wb_has_exception,
    input  logic [3:0]                        wb_exc_code [0:CDB_WIDTH-1],
    // Branch resolution fields
    input  logic [CDB_WIDTH-1:0]              wb_is_branch,
    input  logic [CDB_WIDTH-1:0]              wb_branch_taken,
    input  logic [63:0]                       wb_branch_target [0:CDB_WIDTH-1],
    input  logic [CDB_WIDTH-1:0]              wb_branch_mispredict,
    // CSR writeback fields
    input  logic [CDB_WIDTH-1:0]              wb_csr_we,
    input  logic [11:0]                       wb_csr_addr [0:CDB_WIDTH-1],
    input  logic [63:0]                       wb_csr_wdata [0:CDB_WIDTH-1],

    // STA sideband writeback (marks store ROB entry as ready, no data)
    input  logic                              sta_wb_valid,
    input  logic [ROB_IDX_BITS-1:0]           sta_wb_rob_idx,

    // Memory ordering violation: a younger load executed before an older
    // store with overlapping bytes was visible.  Force the violating load
    // to be marked ready + mispredicted so the commit unit replays it (and
    // every younger entry) by flushing to its own PC.
    input  logic                              ordering_violation_valid,
    input  logic [ROB_IDX_BITS-1:0]           ordering_violation_rob_idx,

    // Commit: read head entries for commit unit
    output logic [ROB_IDX_BITS-1:0]           head_idx,
    output logic [PIPE_WIDTH-1:0]             head_valid,     // which of the 6 head entries are valid
    output logic [PIPE_WIDTH-1:0]             head_ready,     // which are completed (ready to retire)
    output logic [63:0]                       head_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_has_exception,
    output logic [3:0]                        head_exc_code [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_is_branch,
    output logic [2:0]                       head_bpu_type [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_is_store,
    output logic [PIPE_WIDTH-1:0]             head_is_load,
    output logic [PIPE_WIDTH-1:0]             head_is_csr,
    output logic [PIPE_WIDTH-1:0]             head_is_fence,
    output logic [PIPE_WIDTH-1:0]             head_is_fence_i,
    output logic [PIPE_WIDTH-1:0]             head_is_mret,
    output logic [PIPE_WIDTH-1:0]             head_is_sret,
    output logic [PIPE_WIDTH-1:0]             head_is_sfence_vma,
    output logic [PIPE_WIDTH-1:0]             head_is_ecall,
    output logic [PIPE_WIDTH-1:0]             head_is_wfi,
    output logic [PIPE_WIDTH-1:0]             head_branch_taken,
    output logic [63:0]                       head_branch_target [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_branch_mispredict,
    output logic [11:0]                       head_csr_addr [0:PIPE_WIDTH-1],
    output logic [63:0]                       head_csr_wdata [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0]             head_csr_we,

    // Commit acknowledgment: advance head pointer
    input  logic [2:0]              commit_count,    // 0..6 entries committed this cycle

    // Flush
    input  logic                    flush_valid,
    input  logic [ROB_IDX_BITS-1:0] flush_rob_tail,  // restore tail to this value (from checkpoint)
    input  logic                    flush_full,       // full flush: reset head and tail to 0

    // Status
    output logic [ROB_IDX_BITS-1:0] tail_idx,
    output logic                    empty,
    output logic                    full
);

    // =========================================================================
    // Constants for modular arithmetic (ROB_DEPTH=192 is not power of 2)
    // =========================================================================
    localparam logic [7:0] ROB_DEPTH_U8 = 8'(ROB_DEPTH);

    // =========================================================================
    // Head and tail pointers, entry count
    // =========================================================================
    reg [7:0] head_r;
    reg [7:0] tail_r;
    reg [7:0] count_r;

    assign head_idx = head_r;
    assign tail_idx = tail_r;
    assign empty    = (count_r == 8'd0);
    assign full     = (count_r + 8'd6 > ROB_DEPTH_U8);

    // alloc_ready: true when free entries >= PIPE_WIDTH
    wire [7:0] free_count = ROB_DEPTH_U8 - count_r;
    assign alloc_ready = (free_count >= 8'd6);

    // =========================================================================
    // Allocation indices: combinational output (inline wrap-add)
    // =========================================================================
    logic [8:0] alloc_sum [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            alloc_sum[i] = {1'b0, tail_r} + 9'(i);
            alloc_idx[i] = (alloc_sum[i] >= 9'(ROB_DEPTH))
                           ? alloc_sum[i][7:0] - ROB_DEPTH_U8
                           : alloc_sum[i][7:0];
        end
    end

    // =========================================================================
    // Head read indices: combinational (inline wrap-add)
    // =========================================================================
    logic [8:0] head_sum_w [0:PIPE_WIDTH-1];
    logic [7:0] head_idx_w [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            head_sum_w[i] = {1'b0, head_r} + 9'(i);
            head_idx_w[i] = (head_sum_w[i] >= 9'(ROB_DEPTH))
                            ? head_sum_w[i][7:0] - ROB_DEPTH_U8
                            : head_sum_w[i][7:0];
        end
    end

    // =========================================================================
    // Storage: flat arrays (Verilator-friendly)
    // =========================================================================
    reg [ROB_DEPTH-1:0]          valid_r;
    reg [ROB_DEPTH-1:0]          ready_r;
    reg [64*ROB_DEPTH-1:0]       pc_packed;
    reg [ROB_DEPTH-1:0]          has_exc_r;
    reg [4*ROB_DEPTH-1:0]        exc_code_packed;
    reg [ROB_DEPTH-1:0]          is_branch_r;
    reg [2:0]                    bpu_type_r [0:ROB_DEPTH-1];
    reg [ROB_DEPTH-1:0]          is_store_r;
    reg [ROB_DEPTH-1:0]          is_load_r;
    reg [ROB_DEPTH-1:0]          is_csr_r;
    reg [ROB_DEPTH-1:0]          is_fence_r;
    reg [ROB_DEPTH-1:0]          is_fence_i_r;
    reg [ROB_DEPTH-1:0]          is_mret_r;
    reg [ROB_DEPTH-1:0]          is_sret_r;
    reg [ROB_DEPTH-1:0]          is_sfence_vma_r;
    reg [ROB_DEPTH-1:0]          is_ecall_r;
    reg [ROB_DEPTH-1:0]          is_wfi_r;
    reg [ROB_DEPTH-1:0]          branch_taken_r;
    reg [64*ROB_DEPTH-1:0]       branch_target_packed;
    reg [ROB_DEPTH-1:0]          branch_mispredict_r;
    reg [12*ROB_DEPTH-1:0]       csr_addr_packed;
    reg [64*ROB_DEPTH-1:0]       csr_wdata_packed;
    reg [ROB_DEPTH-1:0]          csr_we_r;

    // =========================================================================
    // Commit read: combinational from head
    // Gate head_valid on count_r to prevent reading stale valid bits after
    // partial flush (partial flush resets tail/count but does NOT eagerly
    // clear valid_r for every squashed entry).
    // =========================================================================
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            head_valid[i]            = valid_r[head_idx_w[i]] && (count_r > 8'(i));
            head_ready[i]            = ready_r[head_idx_w[i]];
            head_pc[i]               = pc_packed[head_idx_w[i]*64 +: 64];
            head_has_exception[i]    = has_exc_r[head_idx_w[i]];
            head_exc_code[i]         = exc_code_packed[head_idx_w[i]*4 +: 4];
            head_is_branch[i]        = is_branch_r[head_idx_w[i]];
            head_bpu_type[i]         = bpu_type_r[head_idx_w[i]];
            head_is_store[i]         = is_store_r[head_idx_w[i]];
            head_is_load[i]          = is_load_r[head_idx_w[i]];
            head_is_csr[i]           = is_csr_r[head_idx_w[i]];
            head_is_fence[i]         = is_fence_r[head_idx_w[i]];
            head_is_fence_i[i]       = is_fence_i_r[head_idx_w[i]];
            head_is_mret[i]          = is_mret_r[head_idx_w[i]];
            head_is_sret[i]          = is_sret_r[head_idx_w[i]];
            head_is_sfence_vma[i]    = is_sfence_vma_r[head_idx_w[i]];
            head_is_ecall[i]         = is_ecall_r[head_idx_w[i]];
            head_is_wfi[i]           = is_wfi_r[head_idx_w[i]];
            head_branch_taken[i]     = branch_taken_r[head_idx_w[i]];
            head_branch_target[i]    = branch_target_packed[head_idx_w[i]*64 +: 64];
            head_branch_mispredict[i]= branch_mispredict_r[head_idx_w[i]];
            head_csr_addr[i]         = csr_addr_packed[head_idx_w[i]*12 +: 12];
            head_csr_wdata[i]        = csr_wdata_packed[head_idx_w[i]*64 +: 64];
            head_csr_we[i]           = csr_we_r[head_idx_w[i]];
        end
    end

    // =========================================================================
    // Flush helper: precompute in-range for every entry (inline)
    // rob_in_range[i] = 1 when entry i is in [flush_rob_tail, tail_r)
    // =========================================================================
    logic [ROB_DEPTH-1:0] rob_in_range;
    always_comb begin
        for (int i = 0; i < ROB_DEPTH; i++) begin
            if (flush_rob_tail == tail_r)
                rob_in_range[i] = 1'b0;
            else if (flush_rob_tail < tail_r)
                rob_in_range[i] = (8'(i) >= flush_rob_tail) && (8'(i) < tail_r);
            else
                rob_in_range[i] = (8'(i) >= flush_rob_tail) || (8'(i) < tail_r);
        end
    end

    // =========================================================================
    // Combinational signals replacing automatic variables in always_ff
    // =========================================================================

    // --- Next-head computation (commit pointer advance) ---
    logic [8:0] nh_sum;
    logic [7:0] nh;
    assign nh_sum = {1'b0, head_r} + {6'd0, commit_count};
    assign nh     = (nh_sum >= 9'(ROB_DEPTH)) ? nh_sum[7:0] - ROB_DEPTH_U8 : nh_sum[7:0];

    // --- Flush count recomputation (partial flush + commit) ---
    logic [7:0] max_valid;
    logic [7:0] raw_count;
    assign max_valid = count_r - {5'd0, commit_count};
    always_comb begin
        if (flush_rob_tail >= nh)
            raw_count = flush_rob_tail - nh;
        else
            raw_count = ROB_DEPTH_U8 - nh + flush_rob_tail;
    end

    // --- Next-tail computation (alloc pointer advance) ---
    logic [8:0] nt_sum;
    logic [7:0] nt;
    assign nt_sum = {1'b0, tail_r} + {6'd0, alloc_count};
    assign nt     = (nt_sum >= 9'(ROB_DEPTH)) ? nt_sum[7:0] - ROB_DEPTH_U8 : nt_sum[7:0];

    // --- Per-slot alloc index (inside for loop) ---
    logic [8:0] ai_sum_w [0:PIPE_WIDTH-1];
    logic [7:0] ai_w    [0:PIPE_WIDTH-1];
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ai_sum_w[i] = {1'b0, tail_r} + 9'(i);
            ai_w[i]     = (ai_sum_w[i] >= 9'(ROB_DEPTH))
                          ? ai_sum_w[i][7:0] - ROB_DEPTH_U8
                          : ai_sum_w[i][7:0];
        end
    end

    // =========================================================================
    // Sequential logic: allocate, writeback, commit, flush
    // Pointer updates (next_tail, next_head) are computed inline to avoid
    // evaluation-order issues with external combinational wires.
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_r   <= '0;
            tail_r   <= '0;
            count_r  <= '0;
            valid_r  <= '0;
            ready_r  <= '0;
            has_exc_r        <= '0;
            is_branch_r      <= '0;
            is_store_r       <= '0;
            is_load_r        <= '0;
            is_csr_r         <= '0;
            is_fence_r       <= '0;
            is_fence_i_r     <= '0;
            is_mret_r        <= '0;
            is_sret_r        <= '0;
            is_sfence_vma_r  <= '0;
            is_ecall_r       <= '0;
            is_wfi_r         <= '0;
            branch_taken_r       <= '0;
            branch_mispredict_r  <= '0;
            csr_we_r             <= '0;
            /* verilator lint_off WIDTHCONCAT */
            pc_packed            <= '0;
            exc_code_packed      <= '0;
            branch_target_packed <= '0;
            csr_addr_packed      <= '0;
            csr_wdata_packed     <= '0;
            /* verilator lint_on WIDTHCONCAT */
        end else if (flush_valid && flush_full) begin
            head_r   <= '0;
            tail_r   <= '0;
            count_r  <= '0;
            valid_r  <= '0;
            ready_r  <= '0;
            has_exc_r        <= '0;
            is_branch_r      <= '0;
            is_store_r       <= '0;
            is_load_r        <= '0;
            is_csr_r         <= '0;
            is_fence_r       <= '0;
            is_fence_i_r     <= '0;
            is_mret_r        <= '0;
            is_sret_r        <= '0;
            is_sfence_vma_r  <= '0;
            is_ecall_r       <= '0;
            is_wfi_r         <= '0;
            branch_taken_r       <= '0;
            branch_mispredict_r  <= '0;
            csr_we_r             <= '0;
        end else if (flush_valid) begin
            // Partial flush (checkpoint restore)
            for (int i = 0; i < ROB_DEPTH; i++) begin
                if (rob_in_range[i]) begin
                    valid_r[i]  <= 1'b0;
                    ready_r[i]  <= 1'b0;
                    is_branch_r[i]     <= 1'b0;
                    is_store_r[i]      <= 1'b0;
                    is_load_r[i]       <= 1'b0;
                    is_csr_r[i]        <= 1'b0;
                    is_fence_r[i]      <= 1'b0;
                    is_fence_i_r[i]    <= 1'b0;
                    is_mret_r[i]       <= 1'b0;
                    is_sret_r[i]       <= 1'b0;
                    is_sfence_vma_r[i] <= 1'b0;
                    is_ecall_r[i]      <= 1'b0;
                    is_wfi_r[i]        <= 1'b0;
                    has_exc_r[i]       <= 1'b0;
                    branch_taken_r[i]      <= 1'b0;
                    branch_mispredict_r[i] <= 1'b0;
                    csr_we_r[i]            <= 1'b0;
                end
            end

            tail_r <= flush_rob_tail;

            // Commit on same cycle as partial flush
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_count > i[2:0]) begin
                    valid_r[head_idx_w[i]]      <= 1'b0;
                    is_branch_r[head_idx_w[i]]  <= 1'b0;
                    is_store_r[head_idx_w[i]]   <= 1'b0;
                    is_load_r[head_idx_w[i]]    <= 1'b0;
                    is_csr_r[head_idx_w[i]]     <= 1'b0;
                    is_fence_r[head_idx_w[i]]   <= 1'b0;
                    is_fence_i_r[head_idx_w[i]] <= 1'b0;
                    is_mret_r[head_idx_w[i]]    <= 1'b0;
                    is_sret_r[head_idx_w[i]]    <= 1'b0;
                    is_sfence_vma_r[head_idx_w[i]] <= 1'b0;
                    is_ecall_r[head_idx_w[i]]   <= 1'b0;
                    is_wfi_r[head_idx_w[i]]     <= 1'b0;
                end
            end
            if (commit_count > 0)
                head_r <= nh;

            // Recompute count — cap at pre-flush occupancy to avoid
            // wrap-around error when head advances past restored tail
            if (raw_count <= max_valid) begin
                count_r <= raw_count;
            end else begin
                count_r <= 8'd0;
                head_r  <= flush_rob_tail;  // head=tail when empty
            end

            // Writebacks to surviving entries
            // (do not clobber a previously-marked ordering violation; see
            // the same comment in the normal-path block below.)
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (wb_valid[i]) begin
                    ready_r[wb_idx[i]] <= 1'b1;
                    if (wb_has_exception[i]) begin
                        has_exc_r[wb_idx[i]] <= 1'b1;
                        exc_code_packed[wb_idx[i]*4 +: 4] <= wb_exc_code[i];
                    end
                    if (!branch_mispredict_r[wb_idx[i]]) begin
                        branch_taken_r[wb_idx[i]]                <= wb_branch_taken[i];
                        branch_target_packed[wb_idx[i]*64 +: 64] <= wb_branch_target[i];
                        branch_mispredict_r[wb_idx[i]]           <= wb_branch_mispredict[i];
                    end
                    csr_we_r[wb_idx[i]]                     <= wb_csr_we[i];
                    csr_addr_packed[wb_idx[i]*12 +: 12]     <= wb_csr_addr[i];
                    csr_wdata_packed[wb_idx[i]*64 +: 64]    <= wb_csr_wdata[i];
                end
            end

            // STA sideband: mark store entry as ready
            if (sta_wb_valid)
                ready_r[sta_wb_rob_idx] <= 1'b1;

            // Ordering violation: see comment in normal-path block below.
            if (ordering_violation_valid) begin
                ready_r[ordering_violation_rob_idx]             <= 1'b1;
                has_exc_r[ordering_violation_rob_idx]           <= 1'b1;
                exc_code_packed[ordering_violation_rob_idx*4 +: 4] <= 4'd15;
            end
        end else begin
            // Normal operation

            // Allocate new entries at tail
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (alloc_count > i[2:0]) begin
                    valid_r[ai_w[i]]  <= 1'b1;
                    ready_r[ai_w[i]]  <= 1'b0;
                    pc_packed[ai_w[i]*64 +: 64]       <= alloc_pc[i];
                    has_exc_r[ai_w[i]]                <= 1'b0;
                    exc_code_packed[ai_w[i]*4 +: 4]   <= 4'd0;
                    is_branch_r[ai_w[i]]      <= alloc_is_branch[i];
                    bpu_type_r[ai_w[i]]       <= alloc_bpu_type[i];
                    is_store_r[ai_w[i]]       <= alloc_is_store[i];
                    is_load_r[ai_w[i]]        <= alloc_is_load[i];
                    is_csr_r[ai_w[i]]         <= alloc_is_csr[i];
                    is_fence_r[ai_w[i]]       <= alloc_is_fence[i];
                    is_fence_i_r[ai_w[i]]     <= alloc_is_fence_i[i];
                    is_mret_r[ai_w[i]]        <= alloc_is_mret[i];
                    is_sret_r[ai_w[i]]        <= alloc_is_sret[i];
                    is_sfence_vma_r[ai_w[i]]  <= alloc_is_sfence_vma[i];
                    is_ecall_r[ai_w[i]]       <= alloc_is_ecall[i];
                    is_wfi_r[ai_w[i]]         <= alloc_is_wfi[i];
                    branch_taken_r[ai_w[i]]       <= 1'b0;
                    branch_target_packed[ai_w[i]*64 +: 64] <= 64'd0;
                    branch_mispredict_r[ai_w[i]]  <= 1'b0;
                    csr_we_r[ai_w[i]]             <= 1'b0;
                    csr_addr_packed[ai_w[i]*12 +: 12]   <= 12'd0;
                    csr_wdata_packed[ai_w[i]*64 +: 64]  <= 64'd0;
                end
            end
            if (alloc_count > 0)
                tail_r <= nt;

            // Writeback: mark entries as ready
            // NB: do NOT clobber branch_mispredict_r/branch_target/branch_taken
            // for an entry that has already been marked by an ordering
            // violation in a previous cycle.  The load's normal CDB writeback
            // arrives 1 cycle later (registered cdb_r) and would otherwise
            // overwrite the violation marking.
            for (int i = 0; i < CDB_WIDTH; i++) begin
                if (wb_valid[i]) begin
                    ready_r[wb_idx[i]] <= 1'b1;
                    if (wb_has_exception[i]) begin
                        has_exc_r[wb_idx[i]] <= 1'b1;
                        exc_code_packed[wb_idx[i]*4 +: 4] <= wb_exc_code[i];
                    end
                    if (!branch_mispredict_r[wb_idx[i]]) begin
                        branch_taken_r[wb_idx[i]]                <= wb_branch_taken[i];
                        branch_target_packed[wb_idx[i]*64 +: 64] <= wb_branch_target[i];
                        branch_mispredict_r[wb_idx[i]]           <= wb_branch_mispredict[i];
                    end
                    csr_we_r[wb_idx[i]]                     <= wb_csr_we[i];
                    csr_addr_packed[wb_idx[i]*12 +: 12]     <= wb_csr_addr[i];
                    csr_wdata_packed[wb_idx[i]*64 +: 64]    <= wb_csr_wdata[i];
                end
            end

            // STA sideband: mark store entry as ready
            if (sta_wb_valid)
                ready_r[sta_wb_rob_idx] <= 1'b1;

            // Ordering violation: mark the violating load as ready, flag it
            // with the EXC_LOAD_REPLAY (4'd15) special exception code so the
            // commit unit can recognise it and redirect to the load's own
            // PC without committing the load (its data is wrong; it must
            // re-execute against the now-visible store).
            if (ordering_violation_valid) begin
                ready_r[ordering_violation_rob_idx]             <= 1'b1;
                has_exc_r[ordering_violation_rob_idx]           <= 1'b1;
                exc_code_packed[ordering_violation_rob_idx*4 +: 4] <= 4'd15;
            end

            // Commit: advance head, clear valid and instruction-type flags
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_count > i[2:0]) begin
                    valid_r[head_idx_w[i]]      <= 1'b0;
                    is_branch_r[head_idx_w[i]]  <= 1'b0;
                    is_store_r[head_idx_w[i]]   <= 1'b0;
                    is_load_r[head_idx_w[i]]    <= 1'b0;
                    is_csr_r[head_idx_w[i]]     <= 1'b0;
                    is_fence_r[head_idx_w[i]]   <= 1'b0;
                    is_fence_i_r[head_idx_w[i]] <= 1'b0;
                    is_mret_r[head_idx_w[i]]    <= 1'b0;
                    is_sret_r[head_idx_w[i]]    <= 1'b0;
                    is_sfence_vma_r[head_idx_w[i]] <= 1'b0;
                    is_ecall_r[head_idx_w[i]]   <= 1'b0;
                    is_wfi_r[head_idx_w[i]]     <= 1'b0;
                end
            end
            if (commit_count > 0)
                head_r <= nh;

            // Update count
            count_r <= count_r + {5'd0, alloc_count} - {5'd0, commit_count};
        end
    end

endmodule
