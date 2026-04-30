/* file: loop_buffer.sv
 Description: Loop stream detector and buffer for small hot loops.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef LOOP_BUFFER_SV
`define LOOP_BUFFER_SV

module loop_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Input from decode (capture phase)
    input  decoded_insn_t dec_insn [0:PIPE_WIDTH-1],
    input  logic [2:0]    dec_count,
    input  logic          backward_branch_taken,  // BPU detected backward taken branch

    // Output to rename (playback phase)
    output decoded_insn_t lb_insn [0:PIPE_WIDTH-1],
    output logic [2:0]    lb_count,
    output logic          active,      // 1 = playing back from loop buffer
    output logic          capturing,   // 1 = forming a candidate loop body
    output logic          handoff_valid,
    output logic [63:0]   handoff_pc,

    // Invalidate (on mispredict, loop exit, or any flush)
    input  logic          invalidate,
    input  logic          redirect_valid,
    input  logic [63:0]   redirect_pc,

    // Stall from rename
    input  logic          stall
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int DEPTH    = LOOP_BUF_DEPTH;   // 64
    localparam int IDX_BITS = $clog2(DEPTH);    // 6
    localparam int EXIT_PRED_ENTRIES = 16;
    localparam int FWD_EXIT_PRED_ENTRIES = 16;
    localparam int EXIT_CNT_BITS = 14;
    localparam logic [3:0] EXIT_PRED_DEFAULT_LEAD = 4'd1;
    localparam logic [3:0] FWD_EXIT_TRACK_AGE = 4'd8;
    localparam logic [3:0] LB_BACKEDGE_REPLAY_CREDIT_DEFAULT = 4'd7;
    localparam logic [3:0] LB_POINTER_CHASE_CREDIT_DEFAULT = 4'd0;

    // =========================================================================
    // State encoding
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE      = 2'd0,
        CAPTURING = 2'd1,
        PLAYING   = 2'd2
    } lb_state_e;

    lb_state_e state_r, state_next;

    // =========================================================================
    // Storage
    // =========================================================================
    decoded_insn_t buf_r [0:DEPTH-1];

    // Capture write pointer (free-running 6-bit index into buf_r)
    logic [IDX_BITS-1:0] wr_ptr_r;

    // Index within buf_r where the current loop body starts
    logic [IDX_BITS-1:0] loop_start_r;

    // Number of entries in the captured loop body (0..DEPTH)
    logic [IDX_BITS:0]   body_len_r;

    // Playback: offset within body (0..body_len_r-1)
    logic [IDX_BITS:0]   rd_ptr_r;

    // The taken backward-branch target that opened the current capture
    // candidate. A valid loop body must close on the same target; otherwise
    // the candidate mixed two different backedges and is unsafe to replay.
    logic [63:0]         capture_target_pc_r;
    logic                capture_has_taken_fwd_cond_r;

    // =========================================================================
    // Combinational helpers (module-scope to avoid latch warnings)
    // =========================================================================
    logic [IDX_BITS:0]   pb_remaining;  // entries left in this pass
    logic [IDX_BITS:0]   pb_avail;      // entries to emit this cycle
    logic [IDX_BITS:0]   pb_control_span;
    logic                backward_branch_found_c;
    logic [63:0]         backward_branch_target_c;
    logic                forward_taken_cond_found_c;
    logic                capture_target_mismatch_c;
    logic                capture_target_mismatch_abort_c;
    logic                playback_handoff_valid_c;
    logic [63:0]         playback_handoff_pc_c;
    logic                playback_backedge_emit_c;
    logic                playback_backedge_pred_exit_c;
    logic [63:0]         playback_backedge_pc_c;
    logic [63:0]         playback_backedge_target_c;
    logic [63:0]         playback_backedge_fallthrough_c;
    logic                playback_forward_emit_c;
    logic                playback_forward_pred_exit_c;
    logic                playback_forward_jump_valid_c;
    logic [IDX_BITS:0]   playback_forward_jump_offset_c;
    logic [63:0]         playback_forward_pc_c;
    logic [63:0]         playback_forward_target_c;
    logic [63:0]         playback_forward_fallthrough_c;

    logic [EXIT_CNT_BITS-1:0] playback_iter_count_r;
    logic                last_backedge_valid_r;
    logic                last_backedge_pred_exit_r;
    logic [63:0]         last_backedge_pc_r;
    logic [63:0]         last_backedge_target_r;
    logic [63:0]         last_backedge_fallthrough_r;
    logic [EXIT_CNT_BITS-1:0] last_backedge_iter_r;
    logic                last_forward_valid_r;
    logic                last_forward_pred_exit_r;
    logic [63:0]         last_forward_pc_r;
    logic [63:0]         last_forward_target_r;
    logic [63:0]         last_forward_fallthrough_r;
    logic [EXIT_CNT_BITS-1:0] last_forward_iter_r;
    logic [3:0]          last_forward_age_r;
    logic                exit_pred_learn_event_c;
    logic                exit_pred_bad_event_c;
    logic                fwd_exit_pred_learn_event_c;
    logic                fwd_exit_pred_bad_event_c;
    logic                playback_backedge_drain_c;
    logic [3:0]          exit_drain_count_r;
    logic                exit_drain_used_r;

    logic                exit_pred_valid_r [0:EXIT_PRED_ENTRIES-1];
    logic [63:0]         exit_pred_pc_r [0:EXIT_PRED_ENTRIES-1];
    logic [63:0]         exit_pred_target_r [0:EXIT_PRED_ENTRIES-1];
    logic [EXIT_CNT_BITS-1:0] exit_pred_limit_r [0:EXIT_PRED_ENTRIES-1];
    logic [1:0]          exit_pred_conf_r [0:EXIT_PRED_ENTRIES-1];
    logic [$clog2(EXIT_PRED_ENTRIES)-1:0] exit_pred_replace_r;

    logic                fwd_exit_pred_valid_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [63:0]         fwd_exit_pred_pc_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [63:0]         fwd_exit_pred_target_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [EXIT_CNT_BITS-1:0] fwd_exit_pred_limit_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [1:0]          fwd_exit_pred_conf_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic                fwd_exit_pred_blocked_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [3:0]          fwd_exit_pred_cooldown_r [0:FWD_EXIT_PRED_ENTRIES-1];
    logic [$clog2(FWD_EXIT_PRED_ENTRIES)-1:0] fwd_exit_pred_replace_r;
`ifdef SIMULATION
    logic                sim_pb_mixedpath_c;
    logic [63:0]         sim_pb_start_pc_c;
    logic [63:0]         sim_pb_forward_pc_c;
    logic [63:0]         sim_pb_backedge_pc_c;
    logic [63:0]         sim_pb_backedge_target_c;
    logic                sim_disable_lb;
    logic                sim_lb_handoff_backedge;
    logic                sim_lb_handoff_all_backedges;
    logic                sim_lb_allow_nt_cond_chain;
    logic                sim_lb_allow_cond_chain_all;
    logic                sim_lb_capture_last_backedge;
    logic                sim_lb_rearm_mixedpath;
    logic                sim_lb_rearm_abort;
    logic                sim_disable_fwd_exit_pred;
    logic                sim_assert_mixedpath_en;
    logic                sim_trace_exit_pred_en;
    logic                sim_trace_capture_en;
    logic [3:0]          sim_exit_pred_lead;
    logic [3:0]          sim_exit_drain_cycles;
    logic [2:0]          sim_fwd_exit_min_body_len;
    logic                sim_fwd_exit_block_on_bad;
    logic [3:0]          sim_fwd_exit_bad_cooldown;
    logic [3:0]          sim_lb_backedge_replay_credit;
    logic [3:0]          sim_lb_pointer_chase_credit;
    integer              sim_cnt_pb_mixedpath;
    integer              sim_cnt_pb_backedge_handoff;
    integer              sim_cnt_capture_rearm;
    integer              sim_cnt_capture_abort;
    integer              sim_cnt_exit_pred_learn;
    integer              sim_cnt_exit_pred_use;
    integer              sim_cnt_exit_pred_bad;
    integer              sim_cnt_exit_drain;
    integer              sim_cnt_fwd_exit_pred_learn;
    integer              sim_cnt_fwd_exit_pred_use;
    integer              sim_cnt_fwd_exit_pred_bad;
    integer              sim_cnt_fwd_exit_pred_jump;
`else
    localparam logic     sim_disable_lb = 1'b0;
    localparam logic     sim_lb_handoff_backedge = 1'b0;
    localparam logic     sim_lb_handoff_all_backedges = 1'b0;
    localparam logic     sim_lb_allow_nt_cond_chain = 1'b0;
    localparam logic     sim_lb_allow_cond_chain_all = 1'b0;
    localparam logic     sim_lb_capture_last_backedge = 1'b0;
    localparam logic     sim_lb_rearm_mixedpath = 1'b0;
    localparam logic     sim_lb_rearm_abort = 1'b0;
    localparam logic     sim_disable_fwd_exit_pred = 1'b0;
    localparam logic [3:0] sim_exit_pred_lead = EXIT_PRED_DEFAULT_LEAD;
    localparam logic [3:0] sim_exit_drain_cycles = 4'd0;
    localparam logic [2:0] sim_fwd_exit_min_body_len = 3'd0;
    localparam logic     sim_fwd_exit_block_on_bad = 1'b0;
    localparam logic [3:0] sim_fwd_exit_bad_cooldown = 4'd0;
    localparam logic [3:0] sim_lb_backedge_replay_credit = LB_BACKEDGE_REPLAY_CREDIT_DEFAULT;
    localparam logic [3:0] sim_lb_pointer_chase_credit = LB_POINTER_CHASE_CREDIT_DEFAULT;
`endif

    // Captured body length (combinational, computed at back-edge)
    logic [IDX_BITS:0] cap_len;
    logic [IDX_BITS:0] cap_close_len;

    function automatic logic replay_stop(input decoded_insn_t insn);
        begin
            if (insn.is_branch) begin
                // Default: a conditional branch is a replay boundary.
                // Experimentally, a captured not-taken conditional can stay
                // inside the replay chunk; it does not redirect the stored
                // path, and a later taken outcome will flush normally.
                if (sim_lb_allow_cond_chain_all)
                    replay_stop = 1'b0;
                else
                    replay_stop =
                        insn.bp_taken || !sim_lb_allow_nt_cond_chain;
            end else begin
                replay_stop = insn.bp_taken && (insn.is_jal || insn.is_jalr);
            end
        end
    endfunction

    function automatic logic [63:0] branch_fallthrough(input decoded_insn_t insn);
        begin
            branch_fallthrough = insn.pc + (insn.is_rvc ? 64'd2 : 64'd4);
        end
    endfunction

    function automatic logic [63:0] branch_target(input decoded_insn_t insn);
        begin
            branch_target = insn.pc + insn.imm;
        end
    endfunction

    function automatic logic is_forward_cond(input decoded_insn_t insn);
        begin
            is_forward_cond =
                insn.is_branch &&
                !insn.is_jal &&
                !insn.is_jalr &&
                !insn.imm[63];
        end
    endfunction

    function automatic int exit_pred_lookup(input logic [63:0] pc,
                                            input logic [63:0] target);
        begin
            exit_pred_lookup = -1;
            for (int e = 0; e < EXIT_PRED_ENTRIES; e++) begin
                if (exit_pred_valid_r[e] &&
                    (exit_pred_pc_r[e] == pc) &&
                    (exit_pred_target_r[e] == target)) begin
                    exit_pred_lookup = e;
                end
            end
        end
    endfunction

    function automatic int fwd_exit_pred_lookup(input logic [63:0] pc,
                                                input logic [63:0] target);
        begin
            fwd_exit_pred_lookup = -1;
            for (int e = 0; e < FWD_EXIT_PRED_ENTRIES; e++) begin
                if (fwd_exit_pred_valid_r[e] &&
                    (fwd_exit_pred_pc_r[e] == pc) &&
                    (fwd_exit_pred_target_r[e] == target)) begin
                    fwd_exit_pred_lookup = e;
                end
            end
        end
    endfunction

    function automatic logic exit_pred_ready(input decoded_insn_t insn);
        int eidx;
        begin
            eidx = exit_pred_lookup(insn.pc, insn.bp_target);
            exit_pred_ready =
                insn.bp_taken &&
                insn.is_branch &&
                !insn.is_jal &&
                !insn.is_jalr &&
                (insn.bp_target < insn.pc) &&
                (eidx >= 0) &&
                (exit_pred_conf_r[eidx] == 2'b11) &&
                (exit_pred_limit_r[eidx] != '0) &&
                ((playback_iter_count_r +
                  {{(EXIT_CNT_BITS-4){1'b0}}, sim_exit_pred_lead}) >=
                 exit_pred_limit_r[eidx]);
        end
    endfunction

    function automatic logic fwd_exit_pred_ready(input decoded_insn_t insn);
        int eidx;
        begin
            eidx = fwd_exit_pred_lookup(insn.pc, branch_target(insn));
            fwd_exit_pred_ready =
                !sim_disable_fwd_exit_pred &&
                is_forward_cond(insn) &&
                (body_len_r >= {{(IDX_BITS-2){1'b0}}, sim_fwd_exit_min_body_len}) &&
                (eidx >= 0) &&
                !fwd_exit_pred_blocked_r[eidx] &&
                (fwd_exit_pred_cooldown_r[eidx] == 4'd0) &&
                (fwd_exit_pred_conf_r[eidx] == 2'b11) &&
                 (fwd_exit_pred_limit_r[eidx] == playback_iter_count_r);
        end
    endfunction

    function automatic logic exit_pred_drain_ready(input decoded_insn_t insn);
        int eidx;
        begin
            eidx = exit_pred_lookup(insn.pc, insn.bp_target);
            exit_pred_drain_ready =
                (sim_exit_drain_cycles != 4'd0) &&
                !exit_drain_used_r &&
                insn.bp_taken &&
                insn.is_branch &&
                !insn.is_jal &&
                !insn.is_jalr &&
                (insn.bp_target < insn.pc) &&
                (eidx >= 0) &&
                (exit_pred_conf_r[eidx] == 2'b11) &&
                (exit_pred_limit_r[eidx] != '0) &&
                !exit_pred_ready(insn) &&
                ((playback_iter_count_r +
                  {{(EXIT_CNT_BITS-4){1'b0}}, sim_exit_pred_lead} +
                  {{(EXIT_CNT_BITS-4){1'b0}}, sim_exit_drain_cycles}) >=
                 exit_pred_limit_r[eidx]);
        end
    endfunction

    function automatic logic [IDX_BITS:0] body_pc_offset(input logic [63:0] pc);
        begin
            body_pc_offset = (IDX_BITS+1)'(DEPTH);
            for (int e = 0; e < DEPTH; e++) begin
                if (((IDX_BITS+1)'(e) < body_len_r) &&
                    (buf_r[loop_start_r + IDX_BITS'(e)].pc == pc)) begin
                    body_pc_offset = (IDX_BITS+1)'(e);
                end
            end
        end
    endfunction

    function automatic logic fwd_target_span_has_call(
        input logic [IDX_BITS:0] current_offset,
        input logic [63:0] target_pc
    );
        logic done;
        begin
            fwd_target_span_has_call = 1'b0;
            done = 1'b0;
            for (int e = 0; e < DEPTH; e++) begin
                if (!done &&
                    ((IDX_BITS+1)'(e) > current_offset) &&
                    ((IDX_BITS+1)'(e) < body_len_r)) begin
                    logic [IDX_BITS-1:0] scan_idx;
                    scan_idx = loop_start_r + IDX_BITS'(e);
                    if (buf_r[scan_idx].pc == target_pc) begin
                        done = 1'b1;
                    end else if (buf_r[scan_idx].is_jal ||
                                 buf_r[scan_idx].is_jalr) begin
                        fwd_target_span_has_call = 1'b1;
                        done = 1'b1;
                    end
                end
            end
        end
    endfunction

    function automatic logic backedge_load_tainted_source(
        input logic [IDX_BITS:0] branch_offset,
        input decoded_insn_t branch_insn
    );
        logic [31:0] tainted_arch;
        begin
            tainted_arch = '0;
            for (int e = 0; e < DEPTH; e++) begin
                if (((IDX_BITS+1)'(e) < branch_offset) &&
                    ((IDX_BITS+1)'(e) < body_len_r)) begin
                    decoded_insn_t scan_insn;
                    logic          src_tainted;

                    scan_insn = buf_r[loop_start_r + IDX_BITS'(e)];
                    src_tainted =
                        (scan_insn.rs1_valid &&
                         tainted_arch[scan_insn.rs1_arch]) ||
                        (scan_insn.rs2_valid &&
                         tainted_arch[scan_insn.rs2_arch]);

                    if (scan_insn.rd_valid &&
                        (scan_insn.rd_arch != 5'd0)) begin
                        if (scan_insn.is_load)
                            tainted_arch[scan_insn.rd_arch] = 1'b1;
                        else
                            tainted_arch[scan_insn.rd_arch] = src_tainted;
                    end
                end
            end

            backedge_load_tainted_source =
                (branch_insn.rs1_valid &&
                 tainted_arch[branch_insn.rs1_arch]) ||
                (branch_insn.rs2_valid &&
                 tainted_arch[branch_insn.rs2_arch]);
        end
    endfunction

    function automatic logic backedge_pointer_chase_source(
        input logic [IDX_BITS:0] branch_offset,
        input decoded_insn_t branch_insn
    );
        begin
            backedge_pointer_chase_source = 1'b0;
            for (int e = 0; e < DEPTH; e++) begin
                if (((IDX_BITS+1)'(e) < branch_offset) &&
                    ((IDX_BITS+1)'(e) < body_len_r)) begin
                    decoded_insn_t scan_insn;

                    scan_insn = buf_r[loop_start_r + IDX_BITS'(e)];
                    if (scan_insn.is_load &&
                        scan_insn.rs1_valid &&
                        scan_insn.rd_valid &&
                        (scan_insn.rd_arch != 5'd0) &&
                        (scan_insn.rd_arch == scan_insn.rs1_arch) &&
                        ((branch_insn.rs1_valid &&
                          (branch_insn.rs1_arch == scan_insn.rd_arch)) ||
                         (branch_insn.rs2_valid &&
                          (branch_insn.rs2_arch == scan_insn.rd_arch)))) begin
                        backedge_pointer_chase_source = 1'b1;
                    end
                end
            end
        end
    endfunction

    always_comb begin
        pb_remaining = body_len_r - rd_ptr_r;
        pb_control_span = '0;
        playback_handoff_valid_c = 1'b0;
        playback_handoff_pc_c    = '0;
        playback_backedge_emit_c = 1'b0;
        playback_backedge_pred_exit_c = 1'b0;
        playback_backedge_pc_c = '0;
        playback_backedge_target_c = '0;
        playback_backedge_fallthrough_c = '0;
        playback_forward_emit_c = 1'b0;
        playback_forward_pred_exit_c = 1'b0;
        playback_forward_jump_valid_c = 1'b0;
        playback_forward_jump_offset_c = '0;
        playback_forward_pc_c = '0;
        playback_forward_target_c = '0;
        playback_forward_fallthrough_c = '0;
        playback_backedge_drain_c = 1'b0;
`ifdef SIMULATION
        sim_pb_mixedpath_c      = 1'b0;
        sim_pb_start_pc_c       = '0;
        sim_pb_forward_pc_c     = '0;
        sim_pb_backedge_pc_c    = '0;
        sim_pb_backedge_target_c = '0;
        if (pb_remaining != '0) begin
            sim_pb_start_pc_c = buf_r[loop_start_r +
                                      IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].pc;
        end
`endif

        // Keep call/return/indirect-jump boundaries intact during replay.
        // Dhrystone exposed a real correctness bug when a single playback
        // chunk crossed Proc_5 ret -> Proc_4 call -> Proc_4 ret. Conditional
        // branches usually remain replayable inside the chunk so CoreMark hot
        // loops do not collapse to 2- or 4-wide slices, but a later
        // different-target taken backedge after a taken forward conditional is
        // the exact mixed-path signature observed in the CoreMark stuck trace.
        if (exit_drain_count_r == 4'd0) begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            logic [IDX_BITS-1:0] rd_idx;
            logic                stop_replay;
            logic                handoff_before_branch;
            logic                backedge_is_pointer_chase;
            logic [IDX_BITS:0]   current_offset;
            logic                fwd_ready;
            if ((IDX_BITS+1)'(i) < pb_remaining &&
                (pb_control_span == (IDX_BITS+1)'(i))) begin
                rd_idx = loop_start_r +
                         IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                         IDX_BITS'(i);
                current_offset = rd_ptr_r + (IDX_BITS+1)'(i);
                fwd_ready = fwd_exit_pred_ready(buf_r[rd_idx]);
                backedge_is_pointer_chase =
                    backedge_pointer_chase_source(current_offset,
                                                  buf_r[rd_idx]);
                handoff_before_branch =
                    sim_lb_handoff_backedge &&
                    buf_r[rd_idx].bp_taken &&
                    buf_r[rd_idx].is_branch &&
                    !buf_r[rd_idx].is_jal &&
                    !buf_r[rd_idx].is_jalr &&
                    (buf_r[rd_idx].bp_target < buf_r[rd_idx].pc) &&
                    (sim_lb_handoff_all_backedges ||
                     (backedge_is_pointer_chase
                      ? (playback_iter_count_r >=
                         {{(EXIT_CNT_BITS-4){1'b0}},
                          sim_lb_pointer_chase_credit})
                      : (playback_iter_count_r >=
                         {{(EXIT_CNT_BITS-4){1'b0}},
                          sim_lb_backedge_replay_credit})));

                if (!playback_backedge_emit_c &&
                    buf_r[rd_idx].bp_taken &&
                    buf_r[rd_idx].is_branch &&
                    !buf_r[rd_idx].is_jal &&
                    !buf_r[rd_idx].is_jalr &&
                    (buf_r[rd_idx].bp_target < buf_r[rd_idx].pc)) begin
                    playback_backedge_emit_c = 1'b1;
                    playback_backedge_pc_c = buf_r[rd_idx].pc;
                    playback_backedge_target_c = buf_r[rd_idx].bp_target;
                    playback_backedge_fallthrough_c =
                        branch_fallthrough(buf_r[rd_idx]);
                end

                if (!playback_forward_emit_c &&
                    is_forward_cond(buf_r[rd_idx])) begin
                    playback_forward_emit_c = 1'b1;
                    playback_forward_pred_exit_c = fwd_ready;
                    playback_forward_pc_c = buf_r[rd_idx].pc;
                    playback_forward_target_c =
                        branch_target(buf_r[rd_idx]);
                    playback_forward_fallthrough_c =
                        branch_fallthrough(buf_r[rd_idx]);
                end

                if (fwd_ready) begin
                    logic [IDX_BITS:0] target_offset;

                    target_offset = body_pc_offset(branch_target(buf_r[rd_idx]));

                    pb_control_span = (IDX_BITS+1)'(i + 1);
                    stop_replay = 1'b1;
                    if ((target_offset < body_len_r) &&
                        (target_offset > current_offset)) begin
                        playback_forward_jump_valid_c = 1'b1;
                        playback_forward_jump_offset_c = target_offset;
                    end else begin
                        playback_handoff_valid_c = 1'b1;
                        playback_handoff_pc_c = branch_target(buf_r[rd_idx]);
                    end
                end else if (exit_pred_drain_ready(buf_r[rd_idx])) begin
                    // Emit the current backedge, then briefly stop LB replay
                    // so older copies of the same branch can resolve before
                    // the predicted loop-exit instance is injected.
                    pb_control_span = (IDX_BITS+1)'(i + 1);
                    stop_replay = 1'b1;
                    playback_backedge_drain_c = 1'b1;
                end else if (exit_pred_ready(buf_r[rd_idx])) begin
                    // Emit the branch with bp_taken forced low in output
                    // logic, then restart normal fetch at the fall-through.
                    // Without advancing pb_control_span here, the predictor's
                    // use counter can tick while the branch never reaches
                    // rename, leaving the original taken prediction in flight.
                    pb_control_span = (IDX_BITS+1)'(i + 1);
                    stop_replay = 1'b1;
                    playback_handoff_valid_c = 1'b1;
                    playback_handoff_pc_c = branch_fallthrough(buf_r[rd_idx]);
                    playback_backedge_pred_exit_c = 1'b1;
                end else if (handoff_before_branch) begin
                    stop_replay = 1'b1;
                    playback_handoff_valid_c = 1'b1;
                    playback_handoff_pc_c    = buf_r[rd_idx].pc;
                end else begin
                    pb_control_span = (IDX_BITS+1)'(i + 1);
                    stop_replay = replay_stop(buf_r[rd_idx]);
                end

                if (!stop_replay &&
                    buf_r[rd_idx].bp_taken &&
                    buf_r[rd_idx].is_branch &&
                    !buf_r[rd_idx].is_jal &&
                    !buf_r[rd_idx].is_jalr &&
                    (buf_r[rd_idx].bp_target > buf_r[rd_idx].pc)) begin
                    for (int j = i + 1; j < int'(pb_remaining); j++) begin
                        logic [IDX_BITS-1:0] scan_idx;
                        scan_idx = loop_start_r +
                                   IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                   IDX_BITS'(j);
                        if (buf_r[scan_idx].bp_taken &&
                            buf_r[scan_idx].is_branch &&
                            (buf_r[scan_idx].bp_target < buf_r[scan_idx].pc) &&
                            (buf_r[scan_idx].bp_target != capture_target_pc_r)) begin
                            stop_replay = 1'b1;
                            playback_handoff_valid_c = 1'b1;
                            playback_handoff_pc_c    = buf_r[rd_idx].bp_target;
`ifdef SIMULATION
                            sim_pb_mixedpath_c       = 1'b1;
                            sim_pb_forward_pc_c      = buf_r[rd_idx].pc;
                            sim_pb_backedge_pc_c     = buf_r[scan_idx].pc;
                            sim_pb_backedge_target_c = buf_r[scan_idx].bp_target;
`endif
                            break;
                        end
                    end
                end

                if (stop_replay)
                    break;
            end
        end
        end

        pb_avail = pb_control_span;
    end

    always_comb begin
        backward_branch_found_c   = 1'b0;
        backward_branch_target_c  = '0;
        forward_taken_cond_found_c = 1'b0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            if ((3'(i) < dec_count) &&
                dec_insn[i].bp_taken &&
                dec_insn[i].is_branch &&
                (dec_insn[i].bp_target < dec_insn[i].pc)) begin
                if (!backward_branch_found_c || sim_lb_capture_last_backedge) begin
                    backward_branch_found_c  = 1'b1;
                    backward_branch_target_c = dec_insn[i].bp_target;
                end
            end

            if (!forward_taken_cond_found_c &&
                (3'(i) < dec_count) &&
                dec_insn[i].bp_taken &&
                dec_insn[i].is_branch &&
                !dec_insn[i].is_jal &&
                !dec_insn[i].is_jalr &&
                (dec_insn[i].bp_target > dec_insn[i].pc)) begin
                forward_taken_cond_found_c = 1'b1;
            end
        end
    end

    always_comb begin
        if (wr_ptr_r >= loop_start_r)
            cap_len = {1'b0, wr_ptr_r} - {1'b0, loop_start_r};
        else
            cap_len = (IDX_BITS+1)'(DEPTH);  // wrapped: treat as overflow

        cap_close_len = cap_len + {{(IDX_BITS-2){1'b0}}, dec_count};
    end

    assign capture_target_mismatch_c =
        backward_branch_taken &&
        backward_branch_found_c &&
        (backward_branch_target_c != capture_target_pc_r);

    // A candidate that has already crossed a taken forward conditional can
    // contain instructions from one side path before seeing a different
    // backedge.  Abort that candidate instead of re-arming it into playback.
    assign capture_target_mismatch_abort_c =
        sim_lb_rearm_abort ||
        (capture_has_taken_fwd_cond_r && !sim_lb_rearm_mixedpath);

    assign exit_pred_learn_event_c =
        redirect_valid &&
        last_backedge_valid_r &&
        (redirect_pc == last_backedge_fallthrough_r) &&
        (last_backedge_iter_r != '0);

    assign exit_pred_bad_event_c =
        redirect_valid &&
        last_backedge_valid_r &&
        last_backedge_pred_exit_r &&
        (redirect_pc == last_backedge_target_r);

    assign fwd_exit_pred_learn_event_c =
        redirect_valid &&
        !sim_disable_fwd_exit_pred &&
        last_forward_valid_r &&
        !last_forward_pred_exit_r &&
        (redirect_pc == last_forward_target_r);

    assign fwd_exit_pred_bad_event_c =
        redirect_valid &&
        !sim_disable_fwd_exit_pred &&
        last_forward_valid_r &&
        last_forward_pred_exit_r &&
        (redirect_pc == last_forward_fallthrough_r);

    // =========================================================================
    // State register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_r <= IDLE;
        else
            state_r <= state_next;
    end

    // =========================================================================
    // Next-state logic
    // =========================================================================
    always_comb begin
        state_next = state_r;
        case (state_r)
            IDLE: begin
                if (!sim_disable_lb && backward_branch_taken && backward_branch_found_c && !invalidate)
                    state_next = CAPTURING;
            end
            CAPTURING: begin
                if (sim_disable_lb || invalidate) begin
                    state_next = IDLE;
                end else if (cap_len >= (IDX_BITS+1)'(DEPTH)) begin
                    // Capture overflow: loop body too large, abort.
                    state_next = IDLE;
                end else if (backward_branch_taken && backward_branch_found_c) begin
                    // Second back-edge: body complete.
                    if ((cap_close_len > '0) &&
                        (cap_close_len < (IDX_BITS+1)'(DEPTH)) &&
                        (backward_branch_target_c == capture_target_pc_r))
                        state_next = PLAYING;
                    else if (capture_target_mismatch_c)
                        state_next =
                            capture_target_mismatch_abort_c ? IDLE
                                                            : CAPTURING;
                    else
                        state_next = IDLE;
                end
            end
            PLAYING: begin
                if (sim_disable_lb || invalidate || playback_handoff_valid_c)
                    state_next = IDLE;
            end
            default: state_next = IDLE;
        endcase
    end

    // =========================================================================
    // Capture logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_r     <= '0;
            loop_start_r <= '0;
            body_len_r   <= '0;
            capture_target_pc_r <= '0;
            capture_has_taken_fwd_cond_r <= 1'b0;
            playback_iter_count_r <= '0;
            last_backedge_valid_r <= 1'b0;
            last_backedge_pred_exit_r <= 1'b0;
            last_backedge_pc_r <= '0;
            last_backedge_target_r <= '0;
            last_backedge_fallthrough_r <= '0;
            last_backedge_iter_r <= '0;
            last_forward_valid_r <= 1'b0;
            last_forward_pred_exit_r <= 1'b0;
            last_forward_pc_r <= '0;
            last_forward_target_r <= '0;
            last_forward_fallthrough_r <= '0;
            last_forward_iter_r <= '0;
            last_forward_age_r <= '0;
            exit_drain_count_r <= '0;
            exit_drain_used_r <= 1'b0;
            exit_pred_replace_r <= '0;
            fwd_exit_pred_replace_r <= '0;
            for (int e = 0; e < EXIT_PRED_ENTRIES; e++) begin
                exit_pred_valid_r[e] <= 1'b0;
                exit_pred_pc_r[e] <= '0;
                exit_pred_target_r[e] <= '0;
                exit_pred_limit_r[e] <= '0;
                exit_pred_conf_r[e] <= '0;
            end
            for (int e = 0; e < FWD_EXIT_PRED_ENTRIES; e++) begin
                fwd_exit_pred_valid_r[e] <= 1'b0;
                fwd_exit_pred_pc_r[e] <= '0;
                fwd_exit_pred_target_r[e] <= '0;
                fwd_exit_pred_limit_r[e] <= '0;
                fwd_exit_pred_conf_r[e] <= '0;
                fwd_exit_pred_blocked_r[e] <= 1'b0;
                fwd_exit_pred_cooldown_r[e] <= '0;
            end
        end else begin
            if (redirect_valid && last_backedge_valid_r) begin
                int hit_idx;
                int free_idx;
                int repl_idx;

                hit_idx = -1;
                free_idx = -1;
                repl_idx = int'(exit_pred_replace_r);
                for (int e = 0; e < EXIT_PRED_ENTRIES; e++) begin
                    if (exit_pred_valid_r[e] &&
                        (exit_pred_pc_r[e] == last_backedge_pc_r) &&
                        (exit_pred_target_r[e] == last_backedge_target_r)) begin
                        hit_idx = e;
                    end
                    if (!exit_pred_valid_r[e] && (free_idx < 0))
                        free_idx = e;
                end

                if (exit_pred_learn_event_c) begin
                    if (hit_idx >= 0) begin
                        if (exit_pred_limit_r[hit_idx] == last_backedge_iter_r) begin
                            if (exit_pred_conf_r[hit_idx] != 2'b11)
                                exit_pred_conf_r[hit_idx] <=
                                    exit_pred_conf_r[hit_idx] + 2'd1;
                        end else begin
                            exit_pred_limit_r[hit_idx] <= last_backedge_iter_r;
                            exit_pred_conf_r[hit_idx] <= 2'd0;
                        end
                    end else begin
                        if (free_idx >= 0)
                            repl_idx = free_idx;
                        exit_pred_valid_r[repl_idx] <= 1'b1;
                        exit_pred_pc_r[repl_idx] <= last_backedge_pc_r;
                        exit_pred_target_r[repl_idx] <= last_backedge_target_r;
                        exit_pred_limit_r[repl_idx] <= last_backedge_iter_r;
                        exit_pred_conf_r[repl_idx] <= 2'd0;
                        exit_pred_replace_r <=
                            exit_pred_replace_r + {{($bits(exit_pred_replace_r)-1){1'b0}}, 1'b1};
                    end
                end else if (exit_pred_bad_event_c && (hit_idx >= 0)) begin
                    exit_pred_conf_r[hit_idx] <= '0;
                end
            end

            if (redirect_valid && last_forward_valid_r) begin
                int hit_idx;
                int free_idx;
                int repl_idx;

                hit_idx = -1;
                free_idx = -1;
                repl_idx = int'(fwd_exit_pred_replace_r);
                for (int e = 0; e < FWD_EXIT_PRED_ENTRIES; e++) begin
                    if (fwd_exit_pred_valid_r[e] &&
                        (fwd_exit_pred_pc_r[e] == last_forward_pc_r) &&
                        (fwd_exit_pred_target_r[e] == last_forward_target_r)) begin
                        hit_idx = e;
                    end
                    if (!fwd_exit_pred_valid_r[e] && (free_idx < 0))
                        free_idx = e;
                end

                if (fwd_exit_pred_learn_event_c) begin
                    if (hit_idx >= 0) begin
                        if (fwd_exit_pred_cooldown_r[hit_idx] != 4'd0)
                            fwd_exit_pred_cooldown_r[hit_idx] <=
                                fwd_exit_pred_cooldown_r[hit_idx] - 4'd1;
                        if (fwd_exit_pred_limit_r[hit_idx] ==
                            last_forward_iter_r) begin
                            if (fwd_exit_pred_conf_r[hit_idx] != 2'b11)
                                fwd_exit_pred_conf_r[hit_idx] <=
                                    fwd_exit_pred_conf_r[hit_idx] + 2'd1;
                        end else begin
                            fwd_exit_pred_limit_r[hit_idx] <=
                                last_forward_iter_r;
                            fwd_exit_pred_conf_r[hit_idx] <= 2'd0;
                        end
                    end else begin
                        if (free_idx >= 0)
                            repl_idx = free_idx;
                        fwd_exit_pred_valid_r[repl_idx] <= 1'b1;
                        fwd_exit_pred_pc_r[repl_idx] <= last_forward_pc_r;
                        fwd_exit_pred_target_r[repl_idx] <=
                            last_forward_target_r;
                        fwd_exit_pred_limit_r[repl_idx] <=
                            last_forward_iter_r;
                        fwd_exit_pred_conf_r[repl_idx] <= 2'd0;
                        fwd_exit_pred_blocked_r[repl_idx] <= 1'b0;
                        fwd_exit_pred_cooldown_r[repl_idx] <= 4'd0;
                        fwd_exit_pred_replace_r <=
                            fwd_exit_pred_replace_r +
                            {{($bits(fwd_exit_pred_replace_r)-1){1'b0}}, 1'b1};
                    end
                end else if (fwd_exit_pred_bad_event_c && (hit_idx >= 0)) begin
                    fwd_exit_pred_conf_r[hit_idx] <= '0;
                    fwd_exit_pred_cooldown_r[hit_idx] <=
                        sim_fwd_exit_bad_cooldown;
                    if (sim_fwd_exit_block_on_bad)
                        fwd_exit_pred_blocked_r[hit_idx] <= 1'b1;
                end
            end

            if ((state_r != PLAYING) || invalidate || playback_handoff_valid_c) begin
                playback_iter_count_r <= '0;
                last_backedge_valid_r <= 1'b0;
                last_backedge_pred_exit_r <= 1'b0;
                last_backedge_pc_r <= '0;
                last_backedge_target_r <= '0;
                last_backedge_fallthrough_r <= '0;
                last_backedge_iter_r <= '0;
                exit_drain_count_r <= '0;
                exit_drain_used_r <= 1'b0;
            end else if (!stall && playback_backedge_emit_c) begin
                last_backedge_valid_r <= 1'b1;
                last_backedge_pred_exit_r <= playback_backedge_pred_exit_c;
                last_backedge_pc_r <= playback_backedge_pc_c;
                last_backedge_target_r <= playback_backedge_target_c;
                last_backedge_fallthrough_r <= playback_backedge_fallthrough_c;
                last_backedge_iter_r <= playback_iter_count_r;
                if (!playback_backedge_pred_exit_c)
                    playback_iter_count_r <= playback_iter_count_r + {{(EXIT_CNT_BITS-1){1'b0}}, 1'b1};
            end

            if ((state_r == PLAYING) && !invalidate &&
                !playback_handoff_valid_c && !stall) begin
                if (exit_drain_count_r != 4'd0) begin
                    exit_drain_count_r <= exit_drain_count_r - 4'd1;
                end else if (playback_backedge_drain_c) begin
                    exit_drain_count_r <= sim_exit_drain_cycles;
                    exit_drain_used_r <= 1'b1;
                end
            end

            if (sim_disable_lb || invalidate ||
                (redirect_valid && last_forward_valid_r)) begin
                last_forward_valid_r <= 1'b0;
                last_forward_pred_exit_r <= 1'b0;
                last_forward_pc_r <= '0;
                last_forward_target_r <= '0;
                last_forward_fallthrough_r <= '0;
                last_forward_iter_r <= '0;
                last_forward_age_r <= '0;
            end else if ((state_r == PLAYING) && !stall &&
                         playback_forward_emit_c &&
                         !last_forward_valid_r) begin
                last_forward_valid_r <= 1'b1;
                last_forward_pred_exit_r <= playback_forward_pred_exit_c;
                last_forward_pc_r <= playback_forward_pc_c;
                last_forward_target_r <= playback_forward_target_c;
                last_forward_fallthrough_r <= playback_forward_fallthrough_c;
                last_forward_iter_r <= playback_iter_count_r;
                last_forward_age_r <= FWD_EXIT_TRACK_AGE;
            end else if (last_forward_valid_r) begin
                if (last_forward_age_r == '0) begin
                    last_forward_valid_r <= 1'b0;
                    last_forward_pred_exit_r <= 1'b0;
                    last_forward_pc_r <= '0;
                    last_forward_target_r <= '0;
                    last_forward_fallthrough_r <= '0;
                    last_forward_iter_r <= '0;
                end else begin
                    last_forward_age_r <= last_forward_age_r - 4'd1;
                end
            end

            if (sim_disable_lb) begin
                wr_ptr_r     <= '0;
                loop_start_r <= '0;
                body_len_r   <= '0;
                capture_target_pc_r <= '0;
                capture_has_taken_fwd_cond_r <= 1'b0;
            end else case (state_r)
                IDLE: begin
                    if (backward_branch_taken && backward_branch_found_c && !invalidate) begin
                        loop_start_r       <= wr_ptr_r;
                        body_len_r         <= '0;
                        capture_target_pc_r <= backward_branch_target_c;
                        capture_has_taken_fwd_cond_r <= 1'b0;
                    end
                end
                CAPTURING: begin
                    if (invalidate) begin
                        wr_ptr_r           <= '0;
                        loop_start_r       <= '0;
                        body_len_r         <= '0;
                        capture_target_pc_r <= '0;
                        capture_has_taken_fwd_cond_r <= 1'b0;
                    end else if (cap_len >= (IDX_BITS+1)'(DEPTH)) begin
                        wr_ptr_r           <= '0;
                        loop_start_r       <= '0;
                        body_len_r         <= '0;
                        capture_target_pc_r <= '0;
                        capture_has_taken_fwd_cond_r <= 1'b0;
                    end else if (backward_branch_taken && backward_branch_found_c) begin
                        // Second back-edge: this decode group starts with the
                        // closing backward branch.  Capture all instructions in
                        // the group (including the branch at slot 0) before
                        // locking the body length.  Without capturing the
                        // branch, playback would emit the loop body without
                        // its exit branch, causing an infinite loop.
                        if (capture_target_mismatch_c) begin
                            wr_ptr_r           <= '0;
                            loop_start_r       <= '0;
                            body_len_r         <= '0;
                            capture_target_pc_r <=
                                capture_target_mismatch_abort_c
                                    ? 64'd0
                                    : backward_branch_target_c;
                            capture_has_taken_fwd_cond_r <= 1'b0;
                        end else begin
                            for (int i = 0; i < PIPE_WIDTH; i++) begin
                                if (i < int'(dec_count)) begin
                                    buf_r[wr_ptr_r + IDX_BITS'(i)] <= dec_insn[i];
                                end
                            end
                            wr_ptr_r   <= wr_ptr_r + IDX_BITS'(dec_count);
                            body_len_r <= cap_close_len;
                            capture_has_taken_fwd_cond_r <= 1'b0;
                        end
                    end else begin
                        // Absorb dec_count instructions this cycle
                        for (int i = 0; i < PIPE_WIDTH; i++) begin
                            if (i < int'(dec_count)) begin
                                buf_r[wr_ptr_r + IDX_BITS'(i)] <= dec_insn[i];
                            end
                        end
                        wr_ptr_r <= wr_ptr_r + IDX_BITS'(dec_count);
                        if (forward_taken_cond_found_c)
                            capture_has_taken_fwd_cond_r <= 1'b1;
                    end
                end
                PLAYING: begin
                    if (invalidate) begin
                        wr_ptr_r           <= '0;
                        loop_start_r       <= '0;
                        body_len_r         <= '0;
                        capture_target_pc_r <= '0;
                        capture_has_taken_fwd_cond_r <= 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Playback read pointer
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_r <= '0;
        end else begin
            if (sim_disable_lb || state_r != PLAYING || invalidate) begin
                rd_ptr_r <= '0;
            end else if (!stall) begin
                if (playback_forward_jump_valid_c)
                    rd_ptr_r <= playback_forward_jump_offset_c;
                else if (rd_ptr_r + pb_avail >= body_len_r)
                    rd_ptr_r <= '0;
                else
                    rd_ptr_r <= rd_ptr_r + pb_avail;
            end
        end
    end

    // =========================================================================
    // Output logic (combinational, no local variables)
    // =========================================================================
    always_comb begin
        active    = (state_r == PLAYING);
        capturing = (state_r == CAPTURING);
        lb_count = 3'd0;
        handoff_valid = 1'b0;
        handoff_pc    = '0;

        for (int i = 0; i < PIPE_WIDTH; i++)
            lb_insn[i] = '0;

        if (state_r == PLAYING && !invalidate) begin
            lb_count = pb_avail[2:0];
            handoff_valid = playback_handoff_valid_c;
            handoff_pc    = playback_handoff_pc_c;
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if ((IDX_BITS+1)'(i) < pb_avail) begin
                    automatic decoded_insn_t out_insn;
                    logic [IDX_BITS:0] out_offset;
                    logic              out_fwd_ready;
                    out_insn = buf_r[loop_start_r +
                                     IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                     IDX_BITS'(i)];
                    out_offset = rd_ptr_r + (IDX_BITS+1)'(i);
                    out_fwd_ready = fwd_exit_pred_ready(out_insn);
                    if (out_fwd_ready) begin
                        out_insn.bp_taken = 1'b1;
                        out_insn.bp_target = branch_target(out_insn);
                    end else if (exit_pred_ready(out_insn)) begin
                        out_insn.bp_taken = 1'b0;
                        out_insn.bp_target = branch_fallthrough(out_insn);
                    end
                    lb_insn[i] = out_insn;
                end
            end
        end
    end

`ifdef SIMULATION
    initial begin
        sim_assert_mixedpath_en = 1'b0;
        sim_disable_lb = 1'b0;
        sim_lb_handoff_backedge = 1'b0;
        sim_lb_handoff_all_backedges = 1'b0;
        sim_lb_allow_nt_cond_chain = 1'b0;
        sim_lb_allow_cond_chain_all = 1'b0;
        sim_lb_capture_last_backedge = 1'b0;
        sim_lb_rearm_mixedpath = 1'b0;
        sim_lb_rearm_abort = 1'b0;
        sim_disable_fwd_exit_pred = 1'b0;
        sim_trace_exit_pred_en = 1'b0;
        sim_trace_capture_en = 1'b0;
        sim_exit_pred_lead = EXIT_PRED_DEFAULT_LEAD;
        sim_exit_drain_cycles = 4'd0;
        sim_fwd_exit_min_body_len = 3'd0;
        sim_fwd_exit_block_on_bad = 1'b0;
        sim_fwd_exit_bad_cooldown = 4'd0;
        sim_lb_backedge_replay_credit = LB_BACKEDGE_REPLAY_CREDIT_DEFAULT;
        sim_lb_pointer_chase_credit = LB_POINTER_CHASE_CREDIT_DEFAULT;
        if ($test$plusargs("DISABLE_LB"))
            sim_disable_lb = 1'b1;
        if ($test$plusargs("LB_HANDOFF_BACKEDGE"))
            sim_lb_handoff_all_backedges = 1'b1;
        if ($test$plusargs("LB_HANDOFF_ALL_BACKEDGES"))
            sim_lb_handoff_all_backedges = 1'b1;
        if ($test$plusargs("LB_SELECTIVE_BACKEDGE_HANDOFF"))
            sim_lb_handoff_all_backedges = 1'b0;
        if ($test$plusargs("LB_ENABLE_BACKEDGE_HANDOFF"))
            sim_lb_handoff_backedge = 1'b1;
        if ($test$plusargs("LB_NO_HANDOFF_BACKEDGE"))
            sim_lb_handoff_backedge = 1'b0;
        if ($test$plusargs("LB_BACKEDGE_CREDIT0"))
            sim_lb_backedge_replay_credit = 4'd0;
        if ($test$plusargs("LB_BACKEDGE_CREDIT1"))
            sim_lb_backedge_replay_credit = 4'd1;
        if ($test$plusargs("LB_BACKEDGE_CREDIT2"))
            sim_lb_backedge_replay_credit = 4'd2;
        if ($test$plusargs("LB_BACKEDGE_CREDIT4"))
            sim_lb_backedge_replay_credit = 4'd4;
        if ($test$plusargs("LB_BACKEDGE_CREDIT7"))
            sim_lb_backedge_replay_credit = 4'd7;
        if ($test$plusargs("LB_BACKEDGE_CREDIT15"))
            sim_lb_backedge_replay_credit = 4'd15;
        if ($test$plusargs("LB_POINTER_CREDIT0"))
            sim_lb_pointer_chase_credit = 4'd0;
        if ($test$plusargs("LB_POINTER_CREDIT1"))
            sim_lb_pointer_chase_credit = 4'd1;
        if ($test$plusargs("LB_POINTER_CREDIT2"))
            sim_lb_pointer_chase_credit = 4'd2;
        if ($test$plusargs("LB_ALLOW_NT_COND_CHAIN"))
            sim_lb_allow_nt_cond_chain = 1'b1;
        if ($test$plusargs("LB_ALLOW_COND_CHAIN_ALL"))
            sim_lb_allow_cond_chain_all = 1'b1;
        if ($test$plusargs("LB_CAPTURE_LAST_BACKEDGE"))
            sim_lb_capture_last_backedge = 1'b1;
        if ($test$plusargs("LB_REARM_MIXEDPATH"))
            sim_lb_rearm_mixedpath = 1'b1;
        if ($test$plusargs("LB_REARM_ABORT"))
            sim_lb_rearm_abort = 1'b1;
        if ($test$plusargs("NO_LBFWD_EXIT"))
            sim_disable_fwd_exit_pred = 1'b1;
        if ($test$plusargs("ASSERT_LB_MIXEDPATH"))
            sim_assert_mixedpath_en = 1'b1;
        if ($test$plusargs("TRACE_LB_EXIT_PRED"))
            sim_trace_exit_pred_en = 1'b1;
        if ($test$plusargs("TRACE_LB_CAPTURE"))
            sim_trace_capture_en = 1'b1;
        if ($test$plusargs("LB_FWD_EXIT_MIN_BODY6"))
            sim_fwd_exit_min_body_len = 3'd6;
        if ($test$plusargs("LB_FWD_EXIT_BLOCK_ON_BAD"))
            sim_fwd_exit_block_on_bad = 1'b1;
        if ($test$plusargs("LB_FWD_EXIT_BAD_COOLDOWN2"))
            sim_fwd_exit_bad_cooldown = 4'd2;
        if ($test$plusargs("LB_FWD_EXIT_BAD_COOLDOWN4"))
            sim_fwd_exit_bad_cooldown = 4'd4;
        if ($test$plusargs("LB_FWD_EXIT_BAD_COOLDOWN8"))
            sim_fwd_exit_bad_cooldown = 4'd8;
        if ($test$plusargs("LB_EXIT_LEAD0"))
            sim_exit_pred_lead = 4'd0;
        if ($test$plusargs("LB_EXIT_LEAD1"))
            sim_exit_pred_lead = 4'd1;
        if ($test$plusargs("LB_EXIT_LEAD2"))
            sim_exit_pred_lead = 4'd2;
        if ($test$plusargs("LB_EXIT_LEAD3"))
            sim_exit_pred_lead = 4'd3;
        if ($test$plusargs("LB_EXIT_LEAD4"))
            sim_exit_pred_lead = 4'd4;
        if ($test$plusargs("LB_EXIT_DRAIN"))
            sim_exit_drain_cycles = 4'd1;
        if ($test$plusargs("LB_EXIT_DRAIN1"))
            sim_exit_drain_cycles = 4'd1;
        if ($test$plusargs("LB_EXIT_DRAIN2"))
            sim_exit_drain_cycles = 4'd2;
        if ($test$plusargs("LB_EXIT_DRAIN3"))
            sim_exit_drain_cycles = 4'd3;
        if ($test$plusargs("LB_EXIT_DRAIN4"))
            sim_exit_drain_cycles = 4'd4;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_cnt_pb_mixedpath <= 0;
            sim_cnt_pb_backedge_handoff <= 0;
            sim_cnt_capture_rearm <= 0;
            sim_cnt_capture_abort <= 0;
            sim_cnt_exit_pred_learn <= 0;
            sim_cnt_exit_pred_use <= 0;
            sim_cnt_exit_pred_bad <= 0;
            sim_cnt_exit_drain <= 0;
            sim_cnt_fwd_exit_pred_learn <= 0;
            sim_cnt_fwd_exit_pred_use <= 0;
            sim_cnt_fwd_exit_pred_bad <= 0;
            sim_cnt_fwd_exit_pred_jump <= 0;
        end else begin
            if ((state_r == PLAYING) && !stall && !invalidate &&
                sim_pb_mixedpath_c) begin
                sim_cnt_pb_mixedpath <= sim_cnt_pb_mixedpath + 1;
            end
            if ((state_r == PLAYING) && !stall && !invalidate &&
                playback_handoff_valid_c &&
                sim_lb_handoff_backedge) begin
                sim_cnt_pb_backedge_handoff <= sim_cnt_pb_backedge_handoff + 1;
            end
            if ((state_r == CAPTURING) && !invalidate &&
                backward_branch_taken && backward_branch_found_c &&
                capture_target_mismatch_c) begin
                sim_cnt_capture_rearm <= sim_cnt_capture_rearm + 1;
            end
            if ((state_r == CAPTURING) && !invalidate &&
                backward_branch_taken && backward_branch_found_c &&
                capture_target_mismatch_c &&
                capture_target_mismatch_abort_c) begin
                sim_cnt_capture_abort <= sim_cnt_capture_abort + 1;
            end
            if (sim_trace_capture_en &&
                (state_r == IDLE) &&
                !invalidate &&
                backward_branch_taken &&
                backward_branch_found_c) begin
                $display("[LBCAP] open target=%016h dec_count=%0d pc0=%016h pc1=%016h pc2=%016h pc3=%016h pc4=%016h pc5=%016h",
                         backward_branch_target_c,
                         dec_count,
                         dec_insn[0].pc,
                         dec_insn[1].pc,
                         dec_insn[2].pc,
                         dec_insn[3].pc,
                         dec_insn[4].pc,
                         dec_insn[5].pc);
            end
            if (sim_trace_capture_en &&
                (state_r == CAPTURING) &&
                !invalidate &&
                backward_branch_taken &&
                backward_branch_found_c) begin
                if (capture_target_mismatch_c &&
                    capture_target_mismatch_abort_c) begin
                    $display("[LBCAP] abort old_target=%016h new_target=%016h cap_len=%0d close_len=%0d dec_count=%0d had_fwd=%0d pc0=%016h pc1=%016h pc2=%016h pc3=%016h pc4=%016h pc5=%016h",
                             capture_target_pc_r,
                             backward_branch_target_c,
                             cap_len,
                             cap_close_len,
                             dec_count,
                             capture_has_taken_fwd_cond_r,
                             dec_insn[0].pc,
                             dec_insn[1].pc,
                             dec_insn[2].pc,
                             dec_insn[3].pc,
                             dec_insn[4].pc,
                             dec_insn[5].pc);
                end else if (capture_target_mismatch_c) begin
                    $display("[LBCAP] rearm old_target=%016h new_target=%016h cap_len=%0d close_len=%0d dec_count=%0d pc0=%016h pc1=%016h pc2=%016h pc3=%016h pc4=%016h pc5=%016h",
                             capture_target_pc_r,
                             backward_branch_target_c,
                             cap_len,
                             cap_close_len,
                             dec_count,
                             dec_insn[0].pc,
                             dec_insn[1].pc,
                             dec_insn[2].pc,
                             dec_insn[3].pc,
                             dec_insn[4].pc,
                             dec_insn[5].pc);
                end else begin
                    $display("[LBCAP] close target=%016h cap_len=%0d close_len=%0d dec_count=%0d pc0=%016h pc1=%016h pc2=%016h pc3=%016h pc4=%016h pc5=%016h",
                             capture_target_pc_r,
                             cap_len,
                             cap_close_len,
                             dec_count,
                             dec_insn[0].pc,
                             dec_insn[1].pc,
                             dec_insn[2].pc,
                             dec_insn[3].pc,
                             dec_insn[4].pc,
                             dec_insn[5].pc);
                end
            end
            if (exit_pred_learn_event_c)
                sim_cnt_exit_pred_learn <= sim_cnt_exit_pred_learn + 1;
            if ((state_r == PLAYING) && !stall && !invalidate &&
                playback_backedge_emit_c && playback_backedge_pred_exit_c)
                sim_cnt_exit_pred_use <= sim_cnt_exit_pred_use + 1;
            if (exit_pred_bad_event_c)
                sim_cnt_exit_pred_bad <= sim_cnt_exit_pred_bad + 1;
            if ((state_r == PLAYING) && !stall && !invalidate &&
                playback_backedge_drain_c)
                sim_cnt_exit_drain <= sim_cnt_exit_drain + 1;
            if (fwd_exit_pred_learn_event_c)
                sim_cnt_fwd_exit_pred_learn <=
                    sim_cnt_fwd_exit_pred_learn + 1;
            if ((state_r == PLAYING) && !stall && !invalidate &&
                playback_forward_emit_c && playback_forward_pred_exit_c)
                sim_cnt_fwd_exit_pred_use <=
                    sim_cnt_fwd_exit_pred_use + 1;
            if (fwd_exit_pred_bad_event_c)
                sim_cnt_fwd_exit_pred_bad <=
                    sim_cnt_fwd_exit_pred_bad + 1;
            if ((state_r == PLAYING) && !stall && !invalidate &&
                playback_forward_jump_valid_c)
                sim_cnt_fwd_exit_pred_jump <=
                    sim_cnt_fwd_exit_pred_jump + 1;

            if (sim_trace_exit_pred_en && exit_pred_learn_event_c) begin
                $display("[LBEXIT] learn pc=%016h target=%016h fallthrough=%016h iter=%0d redirect=%016h state=%0d body_len=%0d rd_ptr=%0d",
                         last_backedge_pc_r,
                         last_backedge_target_r,
                         last_backedge_fallthrough_r,
                         last_backedge_iter_r,
                         redirect_pc,
                         state_r,
                         body_len_r,
                         rd_ptr_r);
            end
            if (sim_trace_exit_pred_en &&
                (state_r == PLAYING) && !stall && !invalidate &&
                playback_backedge_emit_c) begin
                $display("[LBEXIT] emit pc=%016h target=%016h fallthrough=%016h iter=%0d lead=%0d pred_exit=%b drain=%b drain_count=%0d handoff=%b handoff_pc=%016h lb_count=%0d body_len=%0d rd_ptr=%0d",
                         playback_backedge_pc_c,
                         playback_backedge_target_c,
                         playback_backedge_fallthrough_c,
                         playback_iter_count_r,
                         sim_exit_pred_lead,
                         playback_backedge_pred_exit_c,
                         playback_backedge_drain_c,
                         exit_drain_count_r,
                         playback_handoff_valid_c,
                         playback_handoff_pc_c,
                         pb_avail,
                         body_len_r,
                         rd_ptr_r);
            end
            if (sim_trace_exit_pred_en && exit_pred_bad_event_c) begin
                $display("[LBEXIT] bad pc=%016h target=%016h fallthrough=%016h iter=%0d redirect=%016h state=%0d",
                         last_backedge_pc_r,
                         last_backedge_target_r,
                         last_backedge_fallthrough_r,
                         last_backedge_iter_r,
                         redirect_pc,
                         state_r);
            end
            if (sim_trace_exit_pred_en &&
                (state_r == PLAYING) && !stall && !invalidate &&
                playback_forward_emit_c) begin
                $display("[LBFWD] emit pc=%016h target=%016h fallthrough=%016h iter=%0d pred_exit=%b jump=%b jump_off=%0d handoff=%b handoff_pc=%016h age=%0d",
                         playback_forward_pc_c,
                         playback_forward_target_c,
                         playback_forward_fallthrough_c,
                         playback_iter_count_r,
                         playback_forward_pred_exit_c,
                         playback_forward_jump_valid_c,
                         playback_forward_jump_offset_c,
                         playback_handoff_valid_c,
                         playback_handoff_pc_c,
                         last_forward_age_r);
            end
            if (sim_trace_exit_pred_en && redirect_valid &&
                last_forward_valid_r) begin
                $display("[LBFWD] redirect pc=%016h target=%016h fallthrough=%016h iter=%0d pred_exit=%b redirect=%016h learn=%b bad=%b age=%0d",
                         last_forward_pc_r,
                         last_forward_target_r,
                         last_forward_fallthrough_r,
                         last_forward_iter_r,
                         last_forward_pred_exit_r,
                         redirect_pc,
                         fwd_exit_pred_learn_event_c,
                         fwd_exit_pred_bad_event_c,
                         last_forward_age_r);
            end
        end
    end

    property p_no_mixedpath_playback_chunk;
        @(posedge clk) disable iff (!rst_n)
        (sim_assert_mixedpath_en && (state_r == PLAYING) && !stall && !invalidate)
            |-> !sim_pb_mixedpath_c;
    endproperty

    a_no_mixedpath_playback_chunk:
        assert property (p_no_mixedpath_playback_chunk)
        else $error("[LB MIXEDPATH] start_pc=%016h forward_pc=%016h backedge_pc=%016h backedge_target=%016h body_len=%0d rd_ptr=%0d capture_tgt=%016h slot0_pc=%016h slot0_br=%b slot0_jal=%b slot0_jalr=%b slot0_tk=%b slot0_tgt=%016h slot1_pc=%016h slot1_br=%b slot1_jal=%b slot1_jalr=%b slot1_tk=%b slot1_tgt=%016h",
                    sim_pb_start_pc_c, sim_pb_forward_pc_c,
                    sim_pb_backedge_pc_c, sim_pb_backedge_target_c,
                    body_len_r, rd_ptr_r, capture_target_pc_r,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].pc,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].is_branch,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].is_jal,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].is_jalr,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].bp_taken,
                    buf_r[loop_start_r +
                          IDX_BITS'(rd_ptr_r[IDX_BITS-1:0])].bp_target,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].pc
                        : 64'd0,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].is_branch
                        : 1'b0,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].is_jal
                        : 1'b0,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].is_jalr
                        : 1'b0,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].bp_taken
                        : 1'b0,
                    ((rd_ptr_r + 1) < body_len_r)
                        ? buf_r[loop_start_r +
                                IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                IDX_BITS'(1)].bp_target
                        : 64'd0);

    final begin
        $display("[LB SUMMARY] mixed-path playback windows: %0d",
                 sim_cnt_pb_mixedpath);
        $display("[LB SUMMARY] backedge handoffs: %0d",
                 sim_cnt_pb_backedge_handoff);
        $display("[LB SUMMARY] capture target re-arms: %0d",
                 sim_cnt_capture_rearm);
        $display("[LB SUMMARY] capture target aborts: %0d",
                 sim_cnt_capture_abort);
        $display("[LB SUMMARY] exit-pred learn/use/bad: %0d / %0d / %0d",
                 sim_cnt_exit_pred_learn,
                 sim_cnt_exit_pred_use,
                 sim_cnt_exit_pred_bad);
        $display("[LB SUMMARY] exit-pred drains: %0d",
                 sim_cnt_exit_drain);
        $display("[LB SUMMARY] fwd-exit learn/use/bad: %0d / %0d / %0d",
                 sim_cnt_fwd_exit_pred_learn,
                 sim_cnt_fwd_exit_pred_use,
                 sim_cnt_fwd_exit_pred_bad);
        $display("[LB SUMMARY] fwd-exit internal jumps: %0d",
                 sim_cnt_fwd_exit_pred_jump);
    end
`endif

endmodule

`endif  // LOOP_BUFFER_SV
