/* file: fetch_unit.sv
 Description: Fetch unit with branch prediction and I-cache interface.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module fetch_unit
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Output to decode
    output logic [2:0]  fetch_count,
    output logic [31:0] fetch_insn [0:PIPE_WIDTH-1],
    output logic [63:0] fetch_pc [0:PIPE_WIDTH-1],
    output logic [PIPE_WIDTH-1:0] fetch_is_rvc,
    output logic [PIPE_WIDTH-1:0] fetch_bp_taken,
    output logic [63:0] fetch_bp_target [0:PIPE_WIDTH-1],

    // Stall from downstream (decode/rename backpressure)
    input  logic        backend_stall,

    // Redirect (from commit -- mispredict or exception)
    input  logic        redirect_valid,
    input  logic [63:0] redirect_pc,

    // BPU update (from commit -- actual branch outcome)
    input  logic        bpu_update_valid,
    input  logic [63:0] bpu_update_pc,
    input  logic        bpu_update_taken,
    input  logic        bpu_update_mispredict,
    input  logic [63:0] bpu_update_target,
    input  logic [2:0]  bpu_update_type,     // branch type for BTB

    // GHR checkpoint restore
    input  logic        ghr_restore_valid,
    input  logic [GHR_BITS-1:0] ghr_restore_val,
    output logic [GHR_BITS-1:0] ghr_out,

    // RAS restore
    input  logic        ras_restore_valid,
    input  logic [4:0]  ras_restore_tos,

    // Memory interface (I-cache to L2)
    output logic        icache_fill_req_valid,
    output logic [63:0] icache_fill_req_addr,
    input  logic        icache_fill_resp_valid,
    input  logic [63:0] icache_fill_resp_addr,
    input  logic [511:0] icache_fill_resp_data,

    // Invalidate (FENCE.I)
    input  logic        fence_i
);

    // =========================================================================
    // Branch type encoding (BTB)
    //   0 = conditional, 1 = JAL, 2 = JALR, 3 = CALL, 4 = RET
    // =========================================================================
    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;

    // =========================================================================
    // F1 stage signals
    // =========================================================================
    logic [63:0] f1_pc;
    logic        f1_valid;

    // BPU redirect from F2 (predicted-taken branch)
    logic        f2_bpu_redirect;
    logic [63:0] f2_bpu_target;

    // Sequential next PC: computed from how many bytes F2 consumed
    logic [63:0] f2_seq_next_pc;
    logic        f2_seq_valid;

    // consumed_remainder_r: latched when the current cycle's extraction
    // consumed a straddle remainder AND emitted at least one instruction.
    // The following cycle must bypass the normal f1->f2 pipeline
    // (which otherwise leaves f2_pc_r pointing at the already-processed
    // cache-line base) and instead advance f2_pc_r directly to the
    // f2_seq_next_pc captured on the consume cycle.
    logic        consumed_remainder_r;
    logic [63:0] post_remainder_pc_r;

    // =========================================================================
    // PC generation (F1)
    // Priority: redirect > BPU redirect > sequential
    // =========================================================================
    logic [63:0] next_pc;
    logic        next_valid;

    always_comb begin
        if (redirect_valid) begin
            next_pc    = redirect_pc;
            next_valid = 1'b1;
        end else if (f2_bpu_redirect) begin
            next_pc    = f2_bpu_target;
            next_valid = 1'b1;
        end else if (f2_seq_valid) begin
            next_pc    = f2_seq_next_pc;
            next_valid = 1'b1;
        end else begin
            next_pc    = f1_pc;
            next_valid = f1_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1_pc    <= RESET_VECTOR;
            f1_valid <= 1'b1;
        end else if (redirect_valid) begin
            f1_pc    <= redirect_pc;
            f1_valid <= 1'b1;
        end else if (!backend_stall) begin
            // When the cycle after a remainder-consume is using the saved
            // post-remainder PC, keep f1_pc matching f2_pc_r so the pipeline
            // re-syncs (f1 should lead f2 again starting the cycle after).
            if (consumed_remainder_r)
                f1_pc    <= post_remainder_pc_r;
            else
                f1_pc    <= next_pc;
            f1_valid <= next_valid;
        end
    end

    // =========================================================================
    // I-Cache instance
    // =========================================================================
    logic        ic_req_valid;
    logic [63:0] ic_req_addr;
    logic        ic_resp_valid;
    logic [511:0] ic_resp_data;
    logic        ic_resp_hit;
    logic        ic_invalidate_busy;

    // Request to I-cache: issue when F1 is valid and not stalled
    assign ic_req_valid = f1_valid && !backend_stall;
    // On BPU redirect, bypass f1_pc and send the redirect target directly
    // to the icache.  This reduces the taken-branch fetch bubble from 2
    // cycles to 1: the icache starts the new lookup in the SAME cycle as
    // the redirect instead of waiting for f1_pc to update next cycle.
    assign ic_req_addr  = (f2_bpu_redirect && !redirect_valid)
                          ? f2_bpu_target : f1_pc;

    // I-cache raw combinational outputs (same-cycle as request)
    logic        ic_resp_valid_comb;
    logic [511:0] ic_resp_data_comb;
    logic        ic_resp_hit_comb;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid      (ic_req_valid),
        .req_addr       (ic_req_addr),
        .resp_valid     (ic_resp_valid_comb),
        .resp_data      (ic_resp_data_comb),
        .resp_hit       (ic_resp_hit_comb),
        .fill_req_valid (icache_fill_req_valid),
        .fill_req_addr  (icache_fill_req_addr),
        .fill_resp_valid(icache_fill_resp_valid),
        .fill_resp_addr (icache_fill_resp_addr),
        .fill_resp_data (icache_fill_resp_data),
        .invalidate_all (fence_i),
        .invalidate_busy(ic_invalidate_busy)
    );

    // Register I-cache response to align with F2 stage (1-cycle delay)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ic_resp_valid <= 1'b0;
            ic_resp_data  <= '0;
            ic_resp_hit   <= 1'b0;
        end else begin
            ic_resp_valid <= ic_resp_valid_comb;
            ic_resp_data  <= ic_resp_data_comb;
            ic_resp_hit   <= ic_resp_hit_comb;
        end
    end

    // =========================================================================
    // BTB instance (combinational lookup in F1)
    // =========================================================================
    logic        btb_hit;
    logic [63:0] btb_target;
    logic [2:0]  btb_branch_type;
    logic [5:0]  btb_branch_offset;

    btb u_btb (
        .clk           (clk),
        .rst_n         (rst_n),
        .lookup_pc     (f1_pc),
        .hit           (btb_hit),
        .target        (btb_target),
        .branch_type   (btb_branch_type),
        .branch_offset (btb_branch_offset),
        .update_valid  (bpu_update_valid),
        .update_pc     (bpu_update_pc),
        .update_target (bpu_update_target),
        .update_type   (bpu_update_type),
        .flush         (1'b0)
    );

    // =========================================================================
    // TAGE-SC-L instance (combinational lookup in F1)
    // =========================================================================
    logic tage_pred_taken;
    logic tage_pred_confident;

    // Speculative GHR update: when we predict a branch as taken in F2
    logic tage_spec_update_valid;
    logic tage_spec_taken;

    tage_sc_l u_tage_sc_l (
        .clk              (clk),
        .rst_n            (rst_n),
        .pc               (f1_pc),
        .pred_taken       (tage_pred_taken),
        .pred_confident   (tage_pred_confident),
        .update_valid     (bpu_update_valid),
        .update_pc        (bpu_update_pc),
        .update_taken     (bpu_update_taken),
        .update_mispredict(bpu_update_mispredict),
        .spec_update_valid(tage_spec_update_valid),
        .spec_taken       (tage_spec_taken),
        .ghr_restore_valid(ghr_restore_valid),
        .ghr_restore_val  (ghr_restore_val),
        .ghr_out          (ghr_out),
        .flush            (redirect_valid)
    );

    // =========================================================================
    // RAS instance
    // =========================================================================
    logic        ras_push_valid;
    logic [63:0] ras_push_addr;
    logic        ras_pop_valid;
    logic [63:0] ras_pop_addr;
    logic [4:0]  ras_tos;

    ras u_ras (
        .clk          (clk),
        .rst_n        (rst_n),
        .push_valid   (ras_push_valid),
        .push_addr    (ras_push_addr),
        .pop_valid    (ras_pop_valid),
        .pop_addr     (ras_pop_addr),
        .tos          (ras_tos),
        .restore_valid(ras_restore_valid),
        .restore_tos  (ras_restore_tos)
    );

    // =========================================================================
    // F1 -> F2 pipeline registers
    // =========================================================================
    logic        f2_valid_r;
    logic [63:0] f2_pc_r;
    logic        f2_btb_hit_r;
    logic [63:0] f2_btb_target_r;
    logic [2:0]  f2_btb_type_r;
    logic [5:0]  f2_btb_offset_r;
    logic        f2_tage_taken_r;
    logic        f2_tage_confident_r;

    // On the cycle where f2 consumes a straddle remainder (start_offset=0,
    // remainder_valid_r=1 and one or more instructions were emitted), the
    // usual f1->f2 pipeline would leave f2_pc_r at the same cache-line base
    // next cycle (because f1_pc lagged behind by one cycle across the
    // straddle). Detect the consume event combinationally and advance
    // f2_pc_r directly to f2_seq_next_pc so the following cycle processes
    // the next real instruction stream.
    logic consume_remainder_c;
    assign consume_remainder_c = remainder_valid_r && f2_valid_r &&
                                 ic_resp_valid && (start_offset == 6'd0) &&
                                 (extract_count > 3'd0);

    // Track whether the current f2_pc_r has already produced an emit.
    // The f1->f2 pipeline currently leaves f2_pc_r unchanged for two
    // consecutive cycles (f1_pc holds for one cycle while f2_pc_r catches
    // up). We use this flag to suppress the second emit so each fetch
    // group is delivered to decode exactly once.
    logic f2_already_emitted_r;
    logic f2_will_emit_c;
    assign f2_will_emit_c = f2_valid_r && ic_resp_valid &&
                             (extract_count > 3'd0) &&
                             !f2_already_emitted_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f2_valid_r          <= 1'b0;
            f2_pc_r             <= '0;
            f2_btb_hit_r        <= 1'b0;
            f2_btb_target_r     <= '0;
            f2_btb_type_r       <= '0;
            f2_btb_offset_r     <= '0;
            f2_tage_taken_r     <= 1'b0;
            f2_tage_confident_r <= 1'b0;
            consumed_remainder_r <= 1'b0;
            post_remainder_pc_r  <= '0;
            f2_already_emitted_r <= 1'b0;
        end else if (redirect_valid) begin
            // Flush F2 on redirect and clear the duplicate-suppress flag
            f2_valid_r           <= 1'b0;
            consumed_remainder_r <= 1'b0;
            f2_already_emitted_r <= 1'b0;
        end else if (f2_bpu_redirect && !backend_stall) begin
            // BPU redirect: set f2_pc to target so the icache bypass
            // response (arriving next cycle) matches the expected PC.
            f2_valid_r          <= 1'b1;
            f2_pc_r             <= f2_bpu_target;
            f2_already_emitted_r <= 1'b0;
        end else if (!backend_stall) begin
            f2_valid_r          <= f1_valid;
            if (consume_remainder_c)
                f2_pc_r         <= f2_seq_next_pc;
            else if (consumed_remainder_r)
                f2_pc_r         <= post_remainder_pc_r;
            else
                f2_pc_r         <= f1_pc;
            f2_btb_hit_r        <= btb_hit;
            f2_btb_target_r     <= btb_target;
            f2_btb_type_r       <= btb_branch_type;
            f2_btb_offset_r     <= btb_branch_offset;
            f2_tage_taken_r     <= tage_pred_taken;
            f2_tage_confident_r <= tage_pred_confident;

            // Latch the consume event and the post-remainder PC so the
            // next cycle can also advance f1_pc in lock-step.
            if (consume_remainder_c) begin
                consumed_remainder_r <= 1'b1;
                post_remainder_pc_r  <= f2_seq_next_pc;
            end else begin
                consumed_remainder_r <= 1'b0;
            end

            // Update the "already emitted for this f2_pc_r" flag.
            // Set it to 1 when we emit this cycle (so next cycle's stale
            // replay is suppressed). Clear it when f2_pc_r is about to
            // change to a new value.
            if (f2_will_emit_c &&
                ((!consume_remainder_c) && (!consumed_remainder_r) &&
                 (f1_pc == f2_pc_r))) begin
                // f2_pc_r will hold its current value next cycle (because
                // f1_pc has not advanced past it yet). Mark this group
                // as already emitted.
                f2_already_emitted_r <= 1'b1;
            end else begin
                // f2_pc_r is going to change next cycle (or we are in
                // a remainder-bypass case). Clear the flag.
                f2_already_emitted_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // F2: Instruction extraction from cache line
    //
    // The I-cache returns a full 512-bit (64-byte) line. We extract up to
    // PIPE_WIDTH=6 instructions starting at the byte offset indicated by
    // f2_pc_r[5:0]. Each instruction is either 16-bit compressed (bits[1:0]
    // != 2'b11) or 32-bit.
    // =========================================================================
    localparam int MAX_EXTRACT_BYTES = 62; // max bytes we can look at

    // Raw extracted halfwords and full instruction words before decompression
    logic [15:0] raw_hw [0:PIPE_WIDTH-1];        // raw 16-bit parcel
    logic [31:0] raw_insn [0:PIPE_WIDTH-1];      // 32-bit (either native or zero-extended)
    logic        slot_is_rvc [0:PIPE_WIDTH-1];
    logic        slot_valid [0:PIPE_WIDTH-1];
    logic [63:0] slot_pc [0:PIPE_WIDTH-1];
    logic [2:0]  extract_count;

    // Byte offset within the 64-byte line
    logic [5:0] start_offset;
    assign start_offset = f2_pc_r[5:0];

    // ---- Cross-line remainder buffer ----
    // When a 32-bit instruction straddles a cache-line boundary, the first
    // 2 bytes are saved here. On the next cache-line fetch the remainder is
    // combined with the first 2 bytes of the new line to form the complete
    // instruction. This prevents the fetch unit from stalling forever.
    logic        remainder_valid_r;
    logic [15:0] remainder_hw_r;       // first 2 bytes (lower half)
    logic [63:0] remainder_pc_r;       // PC of the straddling instruction

    // Combinational: detect straddling 32-bit instruction at line end
    logic        straddle_detected;
    logic [15:0] straddle_hw;
    logic [63:0] straddle_pc;

    // Extract instructions from the cache line combinationally
    always_comb begin
        // Default all slots
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            raw_hw[i]      = 16'h0;
            raw_insn[i]    = 32'h0000_0013; // NOP
            slot_is_rvc[i] = 1'b0;
            slot_valid[i]  = 1'b0;
            slot_pc[i]     = '0;
        end
        extract_count      = 3'd0;
        straddle_detected  = 1'b0;
        straddle_hw        = 16'h0;
        straddle_pc        = '0;

        if (f2_valid_r && ic_resp_valid) begin
            automatic logic [6:0] byte_pos;
            automatic int slot_idx;
            byte_pos = {1'b0, start_offset};
            slot_idx = 0;

            // If the remainder buffer holds the first half of a straddling
            // instruction, combine it with the start of this cache line.
            if (remainder_valid_r && byte_pos == 7'd0) begin
                // The remainder holds the low 16 bits; read bytes 0-1 of
                // this line for the high 16 bits.
                automatic logic [31:0] word32;
                word32[15:0]  = remainder_hw_r;
                word32[23:16] = ic_resp_data[0 +: 8];
                word32[31:24] = ic_resp_data[8 +: 8];

                slot_is_rvc[0] = 1'b0;
                raw_insn[0]    = word32;
                slot_valid[0]  = 1'b1;
                slot_pc[0]     = remainder_pc_r;
                extract_count  = 3'd1;
                byte_pos       = 7'd2;   // consumed 2 bytes from this line
                slot_idx       = 1;
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (i >= slot_idx) begin
                // Check if we have at least 2 bytes remaining in the line
                if (byte_pos <= 7'd62) begin
                    // Read 16-bit parcel at current position
                    // Each byte is at bit position byte_pos*8
                    automatic logic [15:0] hw;
                    automatic logic [6:0]  bp;
                    bp = byte_pos;
                    hw = {ic_resp_data[bp*8 +: 8], ic_resp_data[bp*8 +: 8]};
                    // Correct: read two bytes in little-endian order
                    hw[7:0]  = ic_resp_data[bp*8 +: 8];
                    hw[15:8] = ic_resp_data[(bp+7'd1)*8 +: 8];

                    raw_hw[i]  = hw;
                    slot_pc[i] = {f2_pc_r[63:6], bp[5:0]};

                    if (hw[1:0] != 2'b11) begin
                        // 16-bit compressed instruction
                        slot_is_rvc[i] = 1'b1;
                        raw_insn[i]    = {16'h0, hw};
                        slot_valid[i]  = 1'b1;
                        extract_count  = 3'(i + 1);
                        byte_pos       = byte_pos + 7'd2;
                    end else if (byte_pos <= 7'd60) begin
                        // 32-bit instruction: need 4 bytes
                        automatic logic [31:0] word32;
                        automatic logic [6:0]  bp2;
                        bp2 = byte_pos;
                        word32[7:0]   = ic_resp_data[bp2*8 +: 8];
                        word32[15:8]  = ic_resp_data[(bp2+7'd1)*8 +: 8];
                        word32[23:16] = ic_resp_data[(bp2+7'd2)*8 +: 8];
                        word32[31:24] = ic_resp_data[(bp2+7'd3)*8 +: 8];

                        slot_is_rvc[i] = 1'b0;
                        raw_insn[i]    = word32;
                        slot_valid[i]  = 1'b1;
                        extract_count  = 3'(i + 1);
                        byte_pos       = byte_pos + 7'd4;
                    end else begin
                        // 32-bit instruction crosses line boundary.
                        // Save the first 2 bytes for the next cache line.
                        straddle_detected = 1'b1;
                        straddle_hw       = hw;
                        straddle_pc       = {f2_pc_r[63:6], bp[5:0]};
                    end
                end
                // else: past end of line, stop
                end
            end
        end
    end

    // =========================================================================
    // RVC decompression: 6 instances (one per slot)
    // =========================================================================
    logic [15:0] decomp_in  [0:PIPE_WIDTH-1];
    logic [31:0] decomp_out [0:PIPE_WIDTH-1];
    logic        decomp_is_rvc [0:PIPE_WIDTH-1];
    logic        decomp_illegal [0:PIPE_WIDTH-1];

    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_rvc_decomp
            rvc_decompress u_rvc_decomp (
                .insn_in (raw_hw[gi]),
                .insn_out(decomp_out[gi]),
                .is_rvc  (decomp_is_rvc[gi]),
                .illegal (decomp_illegal[gi])
            );
        end
    endgenerate

    // =========================================================================
    // F2: Branch prediction resolution
    //
    // Scan extracted instructions for the branch predicted by BTB. If BTB hit
    // in F1 and TAGE predicts taken, truncate fetch at the branch and redirect
    // to the predicted target. For RET, use RAS pop address as target.
    // For CALL, push return address onto RAS.
    // =========================================================================
    logic        bp_branch_found;
    logic [2:0]  bp_branch_slot;
    logic [63:0] bp_target_addr;
    logic        bp_taken;
    logic [2:0]  bp_truncated_count;

    always_comb begin
        bp_branch_found    = 1'b0;
        bp_branch_slot     = 3'd0;
        bp_target_addr     = '0;
        bp_taken           = 1'b0;
        bp_truncated_count = extract_count;

        if (f2_valid_r && ic_resp_valid && f2_btb_hit_r) begin
            // Determine prediction action based on BTB type
            case (f2_btb_type_r)
                BT_COND: begin
                    // Conditional branch: use TAGE direction prediction
                    if (f2_tage_taken_r) begin
                        bp_branch_found = 1'b1;
                        bp_taken        = 1'b1;
                        bp_target_addr  = f2_btb_target_r;
                    end
                end
                BT_JAL: begin
                    // Unconditional direct jump: always taken
                    bp_branch_found = 1'b1;
                    bp_taken        = 1'b1;
                    bp_target_addr  = f2_btb_target_r;
                end
                BT_JALR: begin
                    // Indirect jump: always taken, use BTB target
                    bp_branch_found = 1'b1;
                    bp_taken        = 1'b1;
                    bp_target_addr  = f2_btb_target_r;
                end
                BT_CALL: begin
                    // Call: always taken, push return address
                    bp_branch_found = 1'b1;
                    bp_taken        = 1'b1;
                    bp_target_addr  = f2_btb_target_r;
                end
                BT_RET: begin
                    // Return: use RAS pop address if non-zero (non-empty).
                    // When the RAS is empty, stack returns 0x0 — do not
                    // predict in that case; let the BRU resolve it.
                    if (ras_pop_addr != 64'd0) begin
                        bp_branch_found = 1'b1;
                        bp_taken        = 1'b1;
                        bp_target_addr  = ras_pop_addr;
                    end
                end
                default: begin
                    bp_branch_found = 1'b0;
                end
            endcase

            // If a taken branch is found, truncate fetch after the branch.
            // The BTB stores the branch's byte offset within the cache line
            // (f2_btb_offset_r).  Scan extracted slots for the one whose PC
            // matches that offset; truncate immediately after it.
            if (bp_branch_found && bp_taken) begin
                // Default: include all extracted instructions (no truncation).
                // This covers the case where the BTB entry is aliased and the
                // branch isn't actually in this fetch group.
                bp_truncated_count = extract_count;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (slot_valid[i] && (slot_pc[i][5:0] == f2_btb_offset_r)) begin
                        bp_branch_slot     = 3'(i);
                        bp_truncated_count = 3'(i + 1);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Compute sequential next PC from bytes consumed
    // =========================================================================
    logic [63:0] last_slot_pc;
    logic        last_slot_rvc;
    logic [2:0]  final_count;

    always_comb begin
        // Use branch-truncated count if a taken branch was found
        if (bp_branch_found && bp_taken) begin
            final_count = bp_truncated_count;
        end else begin
            final_count = extract_count;
        end

        // Compute sequential next PC based on the last instruction delivered
        if (final_count > 3'd0) begin
            automatic int last_idx;
            last_idx = int'(final_count) - 1;
            last_slot_pc  = slot_pc[last_idx];
            last_slot_rvc = slot_is_rvc[last_idx];
            f2_seq_next_pc = last_slot_pc + (last_slot_rvc ? 64'd2 : 64'd4);
            f2_seq_valid   = 1'b1;
        end else if (straddle_detected) begin
            // No complete instructions extracted, but a straddling 32-bit
            // instruction was found. Advance to the next cache line so
            // the remainder buffer can be combined with the new data.
            last_slot_pc   = straddle_pc;
            last_slot_rvc  = 1'b0;
            f2_seq_next_pc = {f2_pc_r[63:6] + 58'd1, 6'd0};  // next line
            f2_seq_valid   = 1'b1;
        end else begin
            last_slot_pc   = f2_pc_r;
            last_slot_rvc  = 1'b0;
            f2_seq_next_pc = f2_pc_r;
            f2_seq_valid   = 1'b0;
        end
    end

    // =========================================================================
    // BPU redirect to F1
    // =========================================================================
    assign f2_bpu_redirect = bp_branch_found && bp_taken && !backend_stall
                             && !redirect_valid;
    assign f2_bpu_target   = bp_target_addr;

    // =========================================================================
    // RAS push/pop control
    //
    // Push on CALL (return address = branch PC + 4 or +2 for RVC).
    // Pop on RET.
    // Only active when F2 is delivering valid instructions and not stalled.
    // =========================================================================
    always_comb begin
        ras_push_valid = 1'b0;
        ras_push_addr  = '0;
        ras_pop_valid  = 1'b0;

        if (f2_valid_r && ic_resp_valid && f2_btb_hit_r && !backend_stall
            && !redirect_valid) begin
            if (f2_btb_type_r == BT_CALL) begin
                ras_push_valid = 1'b1;
                // Push return address: PC of the call + instruction size
                ras_push_addr  = slot_pc[bp_branch_slot]
                                 + (slot_is_rvc[bp_branch_slot] ? 64'd2 : 64'd4);
            end else if (f2_btb_type_r == BT_RET) begin
                ras_pop_valid = 1'b1;
            end
        end
    end

    // =========================================================================
    // Speculative GHR update
    //
    // When a conditional branch is predicted, speculatively shift the GHR.
    // =========================================================================
    always_comb begin
        tage_spec_update_valid = 1'b0;
        tage_spec_taken        = 1'b0;

        if (f2_valid_r && ic_resp_valid && f2_btb_hit_r && !backend_stall
            && !redirect_valid) begin
            if (f2_btb_type_r == BT_COND) begin
                tage_spec_update_valid = 1'b1;
                tage_spec_taken        = f2_tage_taken_r;
            end
        end
    end

    // =========================================================================
    // Remainder buffer: save the first 2 bytes of a straddling instruction
    //
    // The remainder must persist until the next cache line is actually
    // available and the extraction logic consumes it (consume_remainder_c).
    // If the next line misses in the I-cache, we may idle for several
    // cycles with a valid remainder waiting for data.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            remainder_valid_r <= 1'b0;
            remainder_hw_r    <= 16'h0;
            remainder_pc_r    <= '0;
        end else if (redirect_valid) begin
            remainder_valid_r <= 1'b0;
        end else if (!backend_stall) begin
            if (straddle_detected && f2_valid_r && ic_resp_valid) begin
                // New straddle detected on the current cache line: latch the
                // first 2 bytes so the next cache line can complete it.
                remainder_valid_r <= 1'b1;
                remainder_hw_r    <= straddle_hw;
                remainder_pc_r    <= straddle_pc;
            end else if (consume_remainder_c) begin
                // Successfully combined remainder with the new cache line;
                // clear the buffer.
                remainder_valid_r <= 1'b0;
            end
            // Otherwise: hold the remainder while we wait for the next
            // cache line to arrive (I-cache miss, backend stall, etc.).
        end
    end

    // =========================================================================
    // F2 output register (to decode stage)
    //
    // Gated on f2_will_emit_c so that the same fetch group is delivered
    // exactly once even though the f1->f2 pipeline holds f2_pc_r for two
    // cycles.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_count <= 3'd0;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                fetch_insn[i]      <= 32'h0000_0013; // NOP
                fetch_pc[i]        <= '0;
                fetch_bp_target[i] <= '0;
            end
            fetch_is_rvc   <= '0;
            fetch_bp_taken <= '0;
        end else if (redirect_valid) begin
            // Flush output
            fetch_count    <= 3'd0;
            fetch_is_rvc   <= '0;
            fetch_bp_taken <= '0;
        end else if (!backend_stall) begin
            if (f2_will_emit_c) begin
                fetch_count    <= final_count;
                fetch_is_rvc   <= '0;
                fetch_bp_taken <= '0;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (3'(i) < final_count && slot_valid[i]) begin
                        // Use decompressed instruction for RVC, raw for 32-bit
                        if (slot_is_rvc[i]) begin
                            fetch_insn[i] <= decomp_out[i];
                        end else begin
                            fetch_insn[i] <= raw_insn[i];
                        end
                        fetch_pc[i]        <= slot_pc[i];
                        fetch_is_rvc[i]    <= slot_is_rvc[i];

                        // Mark branch prediction info on the branch slot
                        if (bp_branch_found && bp_taken && (3'(i) == bp_branch_slot)) begin
                            fetch_bp_taken[i]  <= 1'b1;
                            fetch_bp_target[i] <= bp_target_addr;
                        end else begin
                            fetch_bp_taken[i]  <= 1'b0;
                            fetch_bp_target[i] <= '0;
                        end
                    end else begin
                        fetch_insn[i]      <= 32'h0000_0013; // NOP
                        fetch_pc[i]        <= '0;
                        fetch_is_rvc[i]    <= 1'b0;
                        fetch_bp_taken[i]  <= 1'b0;
                        fetch_bp_target[i] <= '0;
                    end
                end
            end else begin
                // No fresh emit this cycle (stale replay or no extract).
                // Drive a bubble so decode does not double-latch the
                // previous group's data.
                fetch_count    <= 3'd0;
                fetch_is_rvc   <= '0;
                fetch_bp_taken <= '0;
                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    fetch_insn[i]      <= 32'h0000_0013; // NOP
                    fetch_pc[i]        <= '0;
                    fetch_bp_target[i] <= '0;
                end
            end
        end
        // On backend_stall, hold outputs (implicit latch behavior)
    end

endmodule
