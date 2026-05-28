/* file: issue_queue.sv
 Description: 32-entry issue queue with dual oldest-ready select.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module issue_queue
    import rv64gc_pkg::*;
    import uarch_pkg::*;
#(
    parameter int DEPTH      = 32,
    parameter int NUM_ENQUEUE = 2,
    parameter int NUM_SELECT  = 2,
    parameter int SUPPORT_ENQ_ISSUE_BYPASS = 0,
    // When non-zero, entries whose fu_type matches PORT0_ONLY_FU are
    // excluded from port 1 selection (they can only issue on port 0).
    // Set to a fu_type_e value (e.g., 3'd1 for FU_BRU) or 0 to disable.
    parameter int PORT0_ONLY_FU = 0
)(
    input  wire clk,
    input  wire rst_n,

    // Enqueue (from dispatch, up to NUM_ENQUEUE per cycle)
    input  wire [NUM_ENQUEUE-1:0] enq_valid,
    input  iq_entry_t              enq_data [0:NUM_ENQUEUE-1],
    output logic                   full,       // no space for NUM_ENQUEUE entries

    // Wakeup via CDB broadcast
    input  wire [CDB_WIDTH-1:0]     cdb_valid,
    input  wire [PHYS_REG_BITS-1:0] cdb_tag [0:CDB_WIDTH-1],

    // Speculative wakeup (from load AGU -- may be cancelled on cache miss)
    input  wire                     spec_wk_valid,
    input  wire [PHYS_REG_BITS-1:0] spec_wk_tag,
    input  wire                     spec_wk_valid1,
    input  wire [PHYS_REG_BITS-1:0] spec_wk_tag1,
    // Speculative cancel (cache miss -- undo speculative wakeup, replay)
    input  wire                     spec_cancel_valid,
    input  wire [PHYS_REG_BITS-1:0] spec_cancel_tag,
    input  wire                     spec_cancel_valid1,
    input  wire [PHYS_REG_BITS-1:0] spec_cancel_tag1,
    // Definitive load writeback wakeup (Stage 2: loads removed from CDB).
    // Fires on the cycle the load data is available (combinational, matches
    // the PRF write).  Two ports for the 2 load writeback lanes.  Unlike
    // spec_wk, this is non-speculative: no cancel path needed.
    input  wire                     load_wb_wk_valid0,
    input  wire [PHYS_REG_BITS-1:0] load_wb_wk_tag0,
    input  wire                     load_wb_wk_valid1,
    input  wire [PHYS_REG_BITS-1:0] load_wb_wk_tag1,

    // PRF ready table: lets enqueue see "already-broadcast" producers even
    // when the entry arrives several cycles after the CDB pulse.
    input  wire [PHYS_TAG_COUNT-1:0] preg_ready_table,

    // Issue output (NUM_SELECT ports)
    // issue_candidate_valid is the oldest-ready selection before suppression.
    // issue_valid is the final fire signal after per-port suppress/hold.
    output logic [NUM_SELECT-1:0]  issue_candidate_valid,
    output logic [NUM_SELECT-1:0]  issue_valid,
    output iq_entry_t              issue_data [0:NUM_SELECT-1],

    // Backpressure: suppress issue on selected ports and preserve the
    // corresponding entry for re-issue on a later cycle.
    input  wire [NUM_SELECT-1:0]  issue_suppress,
    input  wire                   enq_issue_bypass_enable,
    input  wire                   enq_issue_bypass_alu_only,
    input  wire [1:0]             older_probe_valid,
    input  wire [ROB_IDX_BITS-1:0] older_probe_rob_idx [0:1],
    output logic [1:0]             has_older_entry,

    // ROB head for age comparison
    input  wire [ROB_IDX_BITS-1:0] rob_head,

    // Flush
    input  wire                    flush_valid,
    input  wire [ROB_IDX_BITS-1:0] flush_rob_tail,  // first ROB entry to invalidate
    input  wire                    flush_full,        // invalidate everything

    // Current occupancy (for dispatch load-balancing)
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);

    // =====================================================================
    // Local parameters
    // =====================================================================
    localparam int IDX_BITS  = $clog2(DEPTH);
    localparam int ENQ_IDX_BITS = (NUM_ENQUEUE <= 1) ? 1 : $clog2(NUM_ENQUEUE);
    localparam int PW        = $bits(iq_entry_t);
    // For age calculations with non-power-of-2 ROB
    localparam int AGE_BITS  = ROB_IDX_BITS + 1;  // extra bit for wrapping

    // =====================================================================
    // Storage arrays -- flat, separate CAM fields for fast wakeup
    // =====================================================================
    logic [DEPTH-1:0]              entry_valid;
    logic [PHYS_REG_BITS-1:0]     rs1_phys_r   [0:DEPTH-1];
    logic [PHYS_REG_BITS-1:0]     rs2_phys_r   [0:DEPTH-1];
    logic [PHYS_REG_BITS-1:0]     rs3_phys_r   [0:DEPTH-1];
    logic [ROB_IDX_BITS-1:0]      rob_idx_r    [0:DEPTH-1];
    logic [2:0]                   fu_type_r    [0:DEPTH-1];  // for port restriction
    logic [DEPTH-1:0]             src1_ready;
    logic [DEPTH-1:0]             src2_ready;
    logic [DEPTH-1:0]             src3_ready;
    logic [DEPTH-1:0]             src1_spec;     // rs1 was woken speculatively
    logic [DEPTH-1:0]             src2_spec;     // rs2 was woken speculatively
    logic [DEPTH-1:0]             src3_spec;     // rs3 was woken speculatively
    // Store payload as flat bit vectors to avoid Verilator packed-struct
    // array misalignment.  Cast to/from iq_entry_t at write/read boundaries.
    logic [PW-1:0]                payload_r    [0:DEPTH-1];
    logic [NUM_ENQUEUE-1:0]       enq_ready_candidate;
    logic [NUM_ENQUEUE-1:0]       enq_ready_hidden;
    logic [NUM_ENQUEUE-1:0]       enq_ready_issued_bypass;
    logic [NUM_ENQUEUE-1:0]       enq_wakeup_hit;
    logic [NUM_ENQUEUE-1:0]       enq_spec_wakeup;
    logic [NUM_ENQUEUE-1:0]       enq_spec_cancelled;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_suppressed;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked_bru_cond;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked_bru_backedge;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked_bru_jal;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked_bru_jalr;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_blocked_serial;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_fu_allowed;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_alu;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_bru;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_bru_cond;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_bru_backedge;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_bru_jal;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_bru_jalr;
    logic [NUM_ENQUEUE-1:0]       enq_bypass_is_serial;
    logic [NUM_ENQUEUE-1:0]       enq_ready_for_bypass;

    // =====================================================================
    // Entry count and full flag
    // =====================================================================
    logic [IDX_BITS:0] count_r;
    assign full = (count_r >= (DEPTH[IDX_BITS:0] - NUM_ENQUEUE[IDX_BITS:0]));
    assign occupancy = count_r[$clog2(DEPTH+1)-1:0];

    // =====================================================================
    // Age calculation helper function
    // Computes the ROB distance from rob_head using wrap_sub for
    // non-power-of-2 ROB_DEPTH.
    // =====================================================================
    // rob_age inlined at each usage site:
    // (idx >= head) ? ({1'b0, idx} - {1'b0, head})
    //              : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, head} + {1'b0, idx})

    // =====================================================================
    // Wakeup logic (combinational)
    //
    // CDB wakeup is COMBINATIONAL: cdb_valid is the registered cdb_r from
    // the core top, so the producer broadcast on cdb is already 1 cycle
    // delayed from the producer's compute cycle.  A consumer that observes
    // a CDB hit can issue THIS cycle and read the right operand from the
    // PRF (the PRF write fired the same cycle as the producer's combinational
    // CDB, so the latched PRF data is current as of this cycle).
    //
    // SPECULATIVE wakeup is NOT applied to the combinational eligibility.
    // It only sets the registered src1_ready / src1_spec flops, taking effect
    // 1 cycle later.  For a one-cycle D-cache hit, the LSU pulses spec_wk when
    // the load request fires; the dependent becomes eligible the next cycle,
    // exactly when the load result is on the combinational CDB/bypass.  If the
    // load misses, spec_cancel clears the speculative ready before eligibility.
    // =====================================================================
    logic [DEPTH-1:0] next_src1_ready;
    logic [DEPTH-1:0] next_src2_ready;
    logic [DEPTH-1:0] next_src3_ready;
    logic [DEPTH-1:0] next_src1_spec;
    logic [DEPTH-1:0] next_src2_spec;
    logic [DEPTH-1:0] next_src3_spec;
    // Latched spec wakeup: written into src1_ready / src1_spec at the next
    // clock edge.  These are NOT visible to the same-cycle eligibility scan.
    logic [DEPTH-1:0] spec_set_src1;
    logic [DEPTH-1:0] spec_set_src2;
    logic [DEPTH-1:0] spec_set_src3;

    // Per-entry CDB match signals (declared outside the always_comb)
    logic [DEPTH-1:0] rs1_cdb_hit;
    logic [DEPTH-1:0] rs2_cdb_hit;
    logic [DEPTH-1:0] rs3_cdb_hit;
    logic [DEPTH-1:0] rs1_load_wb_hit;
    logic [DEPTH-1:0] rs2_load_wb_hit;
    logic [DEPTH-1:0] rs3_load_wb_hit;

    // Per-entry spec-cancel match (combinational, used by both paths)
    logic [DEPTH-1:0] spec_cancel_rs1;
    logic [DEPTH-1:0] spec_cancel_rs2;
    logic [DEPTH-1:0] spec_cancel_rs3;
    logic [NUM_ENQUEUE-1:0] enq_s1_rdy;
    logic [NUM_ENQUEUE-1:0] enq_s2_rdy;
    logic [NUM_ENQUEUE-1:0] enq_s3_rdy;
    logic [NUM_ENQUEUE-1:0] enq_s1_wakeup_hit;
    logic [NUM_ENQUEUE-1:0] enq_s2_wakeup_hit;
    logic [NUM_ENQUEUE-1:0] enq_s3_wakeup_hit;
    logic [NUM_ENQUEUE-1:0] enq_s1_spec_match;
    logic [NUM_ENQUEUE-1:0] enq_s2_spec_match;
    logic [NUM_ENQUEUE-1:0] enq_s3_spec_match;
    logic [NUM_ENQUEUE-1:0] enq_s1_spec_cancel;
    logic [NUM_ENQUEUE-1:0] enq_s2_spec_cancel;
    logic [NUM_ENQUEUE-1:0] enq_s3_spec_cancel;
    logic [NUM_ENQUEUE-1:0] enq_s1_spec_wakeup;
    logic [NUM_ENQUEUE-1:0] enq_s2_spec_wakeup;
    logic [NUM_ENQUEUE-1:0] enq_s3_spec_wakeup;
    logic [NUM_ENQUEUE-1:0] enq_s1_spec_cancelled;
    logic [NUM_ENQUEUE-1:0] enq_s2_spec_cancelled;
    logic [NUM_ENQUEUE-1:0] enq_s3_spec_cancelled;

    always_comb begin
        next_src1_ready = src1_ready;
        next_src2_ready = src2_ready;
        next_src3_ready = src3_ready;
        next_src1_spec  = src1_spec;
        next_src2_spec  = src2_spec;
        next_src3_spec  = src3_spec;

        for (int e = 0; e < DEPTH; e++) begin
            rs1_cdb_hit[e]     = 1'b0;
            rs2_cdb_hit[e]     = 1'b0;
            rs3_cdb_hit[e]     = 1'b0;
            rs1_load_wb_hit[e] = 1'b0;
            rs2_load_wb_hit[e] = 1'b0;
            rs3_load_wb_hit[e] = 1'b0;
            spec_set_src1[e]   = 1'b0;
            spec_set_src2[e]   = 1'b0;
            spec_set_src3[e]   = 1'b0;
            spec_cancel_rs1[e] = 1'b0;
            spec_cancel_rs2[e] = 1'b0;
            spec_cancel_rs3[e] = 1'b0;
        end

        for (int e = 0; e < DEPTH; e++) begin
            // -- CDB definitive wakeup --
            for (int c = 0; c < CDB_WIDTH; c++) begin
                if (cdb_valid[c] && (cdb_tag[c] == rs1_phys_r[e]))
                    rs1_cdb_hit[e] = 1'b1;
                if (cdb_valid[c] && (cdb_tag[c] == rs2_phys_r[e]))
                    rs2_cdb_hit[e] = 1'b1;
                if (cdb_valid[c] && (cdb_tag[c] == rs3_phys_r[e]))
                    rs3_cdb_hit[e] = 1'b1;
            end

            if (entry_valid[e]) begin
                // CDB wakeup: combinational override of next_src1_ready so
                // the consumer can issue the same cycle.  Clears spec flag.
                if (rs1_cdb_hit[e] && !src1_ready[e]) begin
                    next_src1_ready[e] = 1'b1;
                    next_src1_spec[e]  = 1'b0;
                end
                if (rs2_cdb_hit[e] && !src2_ready[e]) begin
                    next_src2_ready[e] = 1'b1;
                    next_src2_spec[e]  = 1'b0;
                end
                if (rs3_cdb_hit[e] && !src3_ready[e]) begin
                    next_src3_ready[e] = 1'b1;
                    next_src3_spec[e]  = 1'b0;
                end

                // -- Definitive load writeback wakeup (Stage 2: loads off CDB)
                // Fires combinationally on the cycle load data is written to
                // PRF.  Treated exactly like CDB wakeup: definitive, clears
                // spec bit, no cancel path needed.  Allows instructions that
                // depend on load results to see the definitive wake even when
                // a cache miss cancelled the earlier speculative wakeup.
                rs1_load_wb_hit[e] =
                    (load_wb_wk_valid0 && (load_wb_wk_tag0 == rs1_phys_r[e])) ||
                    (load_wb_wk_valid1 && (load_wb_wk_tag1 == rs1_phys_r[e]));
                rs2_load_wb_hit[e] =
                    (load_wb_wk_valid0 && (load_wb_wk_tag0 == rs2_phys_r[e])) ||
                    (load_wb_wk_valid1 && (load_wb_wk_tag1 == rs2_phys_r[e]));
                rs3_load_wb_hit[e] =
                    (load_wb_wk_valid0 && (load_wb_wk_tag0 == rs3_phys_r[e])) ||
                    (load_wb_wk_valid1 && (load_wb_wk_tag1 == rs3_phys_r[e]));

                if (rs1_load_wb_hit[e]) begin
                    next_src1_ready[e] = 1'b1;
                    next_src1_spec[e]  = 1'b0;
                end
                if (rs2_load_wb_hit[e]) begin
                    next_src2_ready[e] = 1'b1;
                    next_src2_spec[e]  = 1'b0;
                end
                if (rs3_load_wb_hit[e]) begin
                    next_src3_ready[e] = 1'b1;
                    next_src3_spec[e]  = 1'b0;
                end

                // -- Speculative wakeup (load request issue, 1 cycle pre-CDB) --
                // LATCHED only: do NOT override next_src1_ready.  The
                // sequential block below will write src*_ready=1 at the next
                // clock edge so the consumer becomes eligible when the load hit
                // result lands on the combinational CDB/bypass.
                if (((spec_wk_valid && (spec_wk_tag == rs1_phys_r[e])) ||
                     (spec_wk_valid1 && (spec_wk_tag1 == rs1_phys_r[e]))) &&
                    !src1_ready[e] && !rs1_cdb_hit[e]) begin
                    spec_set_src1[e] = 1'b1;
                end
                if (((spec_wk_valid && (spec_wk_tag == rs2_phys_r[e])) ||
                     (spec_wk_valid1 && (spec_wk_tag1 == rs2_phys_r[e]))) &&
                    !src2_ready[e] && !rs2_cdb_hit[e]) begin
                    spec_set_src2[e] = 1'b1;
                end
                if (((spec_wk_valid && (spec_wk_tag == rs3_phys_r[e])) ||
                     (spec_wk_valid1 && (spec_wk_tag1 == rs3_phys_r[e]))) &&
                    !src3_ready[e] && !rs3_cdb_hit[e]) begin
                    spec_set_src3[e] = 1'b1;
                end

                // -- Speculative cancel (cache miss) --
                // Cancel undoes any speculative wakeup that already latched
                // into src1_ready, AND prevents this cycle's spec_set from
                // taking effect.  CDB wakeup is unaffected (CDB is the
                // authoritative result and overrides cancel).
                if (((spec_cancel_valid && (spec_cancel_tag == rs1_phys_r[e])) ||
                     (spec_cancel_valid1 && (spec_cancel_tag1 == rs1_phys_r[e]))) &&
                    src1_spec[e] && !rs1_cdb_hit[e] && !rs1_load_wb_hit[e]) begin
                    next_src1_ready[e] = 1'b0;
                    next_src1_spec[e]  = 1'b0;
                    spec_cancel_rs1[e] = 1'b1;
                end
                if (((spec_cancel_valid && (spec_cancel_tag == rs2_phys_r[e])) ||
                     (spec_cancel_valid1 && (spec_cancel_tag1 == rs2_phys_r[e]))) &&
                    src2_spec[e] && !rs2_cdb_hit[e] && !rs2_load_wb_hit[e]) begin
                    next_src2_ready[e] = 1'b0;
                    next_src2_spec[e]  = 1'b0;
                    spec_cancel_rs2[e] = 1'b1;
                end
                if (((spec_cancel_valid && (spec_cancel_tag == rs3_phys_r[e])) ||
                     (spec_cancel_valid1 && (spec_cancel_tag1 == rs3_phys_r[e]))) &&
                    src3_spec[e] && !rs3_cdb_hit[e] && !rs3_load_wb_hit[e]) begin
                    next_src3_ready[e] = 1'b0;
                    next_src3_spec[e]  = 1'b0;
                    spec_cancel_rs3[e] = 1'b1;
                end
            end
        end
    end

    // =====================================================================
    // Eligibility: valid && both sources ready (after wakeup)
    // =====================================================================
    logic [DEPTH-1:0] eligible;
    // Port 1 eligibility: exclude entries with PORT0_ONLY_FU
    logic [DEPTH-1:0] eligible_port1;

    always_comb begin
        for (int e = 0; e < DEPTH; e++) begin
            eligible[e] = entry_valid[e] & next_src1_ready[e] &
                          next_src2_ready[e] & next_src3_ready[e];
            if (PORT0_ONLY_FU != 0 && fu_type_r[e] == PORT0_ONLY_FU[2:0])
                eligible_port1[e] = 1'b0;
            else
                eligible_port1[e] = eligible[e];
        end
    end

    // =====================================================================
    // Dual oldest-ready selection
    // Port 0: oldest eligible entry (minimum ROB age).
    // Port 1: second-oldest eligible entry (excluding port 0 winner).
    // =====================================================================
    logic [IDX_BITS-1:0] sel_idx    [0:NUM_SELECT-1];
    logic [NUM_SELECT-1:0] sel_found;
    logic [NUM_SELECT-1:0] issue_from_enq;
    logic [ENQ_IDX_BITS-1:0] issue_enq_lane [0:NUM_SELECT-1];

    // Pre-compute ages for all entries (outside the selection always_comb)
    logic [AGE_BITS-1:0] entry_age [0:DEPTH-1];

    always_comb begin
        for (int e = 0; e < DEPTH; e++) begin
            entry_age[e] = ((rob_idx_r[e] >= rob_head) ? ({1'b0, rob_idx_r[e]} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, rob_idx_r[e]}));
        end
    end

    logic [AGE_BITS-1:0] older_probe_age [0:1];

    always_comb begin
        for (int p = 0; p < 2; p++) begin
            older_probe_age[p] = ((older_probe_rob_idx[p] >= rob_head) ? ({1'b0, older_probe_rob_idx[p]} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, older_probe_rob_idx[p]}));
            has_older_entry[p] = 1'b0;
            if (older_probe_valid[p]) begin
                for (int e = 0; e < DEPTH; e++) begin
                    logic entry_issues_now;

                    entry_issues_now = 1'b0;
                    for (int s = 0; s < NUM_SELECT; s++) begin
                        if (sel_found[s] && !issue_suppress[s] &&
                            (e[IDX_BITS-1:0] == sel_idx[s])) begin
                            entry_issues_now = 1'b1;
                        end
                    end

                    if (entry_valid[e] &&
                        !entry_issues_now &&
                        (entry_age[e] < older_probe_age[p]))
                        has_older_entry[p] = 1'b1;
                end
            end
        end
    end

    // Port 0 selection: oldest eligible entry
    always_comb begin
        sel_found[0] = 1'b0;
        sel_idx[0]   = '0;
        for (int e = 0; e < DEPTH; e++) begin
            if (eligible[e]) begin
                if (!sel_found[0]) begin
                    sel_found[0] = 1'b1;
                    sel_idx[0]   = e[IDX_BITS-1:0];
                end else if (entry_age[e] < entry_age[sel_idx[0]]) begin
                    sel_idx[0] = e[IDX_BITS-1:0];
                end
            end
        end
    end

    // Port 1 selection: only synthesised when the IQ is dual-issue.
    // Single-issue variants (NUM_SELECT=1) skip this logic entirely so that
    // no instruction is silently retired without a functional unit consuming it.
    generate
        if (NUM_SELECT >= 2) begin : gen_port1_select
            always_comb begin
                sel_found[1] = 1'b0;
                sel_idx[1]   = '0;
                for (int e = 0; e < DEPTH; e++) begin
                    if (eligible_port1[e] && !(sel_found[0] && (e[IDX_BITS-1:0] == sel_idx[0]))) begin
                        if (!sel_found[1]) begin
                            sel_found[1] = 1'b1;
                            sel_idx[1]   = e[IDX_BITS-1:0];
                        end else if (entry_age[e] < entry_age[sel_idx[1]]) begin
                            sel_idx[1] = e[IDX_BITS-1:0];
                        end
                    end
                end
            end
        end
    endgenerate

    // =====================================================================
    // Ready enqueue idle-port bypass
    //
    // This does not participate in the resident oldest-ready arbitration. It
    // only fills issue ports left unused by resident entries, then suppresses
    // allocation for the fired enqueue lane.
    // =====================================================================
    always_comb begin
        enq_ready_issued_bypass = '0;
        for (int p = 0; p < NUM_SELECT; p++) begin
            issue_from_enq[p] = 1'b0;
            issue_enq_lane[p] = '0;
        end

        if ((SUPPORT_ENQ_ISSUE_BYPASS != 0) &&
            enq_issue_bypass_enable &&
            !flush_valid) begin
            for (int p = 0; p < NUM_SELECT; p++) begin
                if (!sel_found[p] && !issue_suppress[p]) begin
                    for (int q = 0; q < NUM_ENQUEUE; q++) begin
                        if (!issue_from_enq[p] &&
                            !enq_ready_issued_bypass[q] &&
                            enq_ready_candidate[q] &&
                            !(PORT0_ONLY_FU != 0 && p != 0 &&
                              enq_data[q].fu_type == PORT0_ONLY_FU[2:0])) begin
                            issue_from_enq[p] = 1'b1;
                            issue_enq_lane[p] = ENQ_IDX_BITS'(q);
                            enq_ready_issued_bypass[q] = 1'b1;
                        end
                    end
                end
            end
        end
    end

    // Drive issue outputs
    always_comb begin
        for (int p = 0; p < NUM_SELECT; p++) begin
            issue_candidate_valid[p] = sel_found[p] || issue_from_enq[p];
            issue_valid[p] = (sel_found[p] || issue_from_enq[p]) & ~issue_suppress[p];
            if (issue_from_enq[p]) begin
                issue_data[p] = enq_data[issue_enq_lane[p]];
                issue_data[p].rs1_ready = enq_s1_rdy[issue_enq_lane[p]];
                issue_data[p].rs2_ready = enq_s2_rdy[issue_enq_lane[p]];
                issue_data[p].rs3_ready = enq_s3_rdy[issue_enq_lane[p]];
            end else if (sel_found[p]) begin
                issue_data[p]  = iq_entry_t'(payload_r[sel_idx[p]]);
                // Override ready flags with wakeup results so downstream sees
                // correct readiness even on the issue cycle.
                issue_data[p].rs1_ready = next_src1_ready[sel_idx[p]];
                issue_data[p].rs2_ready = next_src2_ready[sel_idx[p]];
                issue_data[p].rs3_ready = next_src3_ready[sel_idx[p]];
            end else begin
                issue_data[p] = '0;
            end
        end
    end

    // =====================================================================
    // Free-slot finder: find up to NUM_ENQUEUE free slots for enqueue
    // =====================================================================
    logic [IDX_BITS-1:0] free_idx  [0:NUM_ENQUEUE-1];
    logic [NUM_ENQUEUE-1:0] free_found;

    logic [DEPTH-1:0] fs_occupied;
    int               slots_found;

    always_comb begin
        // Slots that are occupied after considering this-cycle issue
        // invalidations (not yet committed to flops, so we compute
        // effective validity for the free-slot scan).
        fs_occupied = entry_valid;
        // Entries that actually fire this cycle will be freed -- suppressed
        // selections stay resident and must not be overwritten by enqueue.
        for (int p = 0; p < NUM_SELECT; p++) begin
            if (sel_found[p] && !issue_suppress[p])
                fs_occupied[sel_idx[p]] = 1'b0;
        end

        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            free_found[q] = 1'b0;
            free_idx[q]   = '0;
        end

        slots_found = 0;
        if ((SUPPORT_ENQ_ISSUE_BYPASS != 0) &&
            enq_issue_bypass_enable) begin
            for (int q = 0; q < NUM_ENQUEUE; q++) begin
                if (enq_ready_issued_bypass[q]) begin
                    free_found[q] = 1'b1;
                end else if (enq_valid[q]) begin
                    for (int e = 0; e < DEPTH; e++) begin
                        if (!fs_occupied[e] && !free_found[q]) begin
                            free_idx[q]   = e[IDX_BITS-1:0];
                            free_found[q] = 1'b1;
                            fs_occupied[e] = 1'b1;
                        end
                    end
                end
            end
        end else begin
            for (int e = 0; e < DEPTH; e++) begin
                if (!fs_occupied[e] && slots_found < NUM_ENQUEUE) begin
                    free_idx[slots_found]   = e[IDX_BITS-1:0];
                    free_found[slots_found] = 1'b1;
                    fs_occupied[e] = 1'b1;  // mark taken for subsequent searches
                    slots_found = slots_found + 1;
                end
            end
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (rst_n && !(flush_valid && flush_full)) begin
            for (int q = 0; q < NUM_ENQUEUE; q++) begin
                if (enq_valid[q] && !free_found[q]) begin
                    $error("[SVA IQ_ENQ_NO_FREE] enq lane=%0d has no free slot count=%0d valid=%b",
                           q, count_r, entry_valid);
                end
            end
        end
    end
`endif

    // =====================================================================
    // Flush logic: determine which entries to invalidate
    // =====================================================================
    logic [DEPTH-1:0] flush_remove;
    logic [AGE_BITS-1:0] flush_tail_age;
    logic [AGE_BITS-1:0] flush_entry_age;

    always_comb begin
        flush_remove = '0;
        flush_tail_age = ((flush_rob_tail >= rob_head) ? ({1'b0, flush_rob_tail} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, flush_rob_tail}));
        flush_entry_age = '0;

        if (flush_valid && !flush_full) begin
            for (int e = 0; e < DEPTH; e++) begin
                if (entry_valid[e]) begin
                    flush_entry_age = ((rob_idx_r[e] >= rob_head) ? ({1'b0, rob_idx_r[e]} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, rob_idx_r[e]}));
                    if (flush_entry_age >= flush_tail_age)
                        flush_remove[e] = 1'b1;
                end
            end
        end
    end

    // =====================================================================
    // Count update
    // =====================================================================
    logic [IDX_BITS:0] count_next;

    always_comb begin
        count_next = count_r;
        // Subtract issued entries
        for (int p = 0; p < NUM_SELECT; p++) begin
            if (sel_found[p] && !issue_suppress[p])
                count_next = count_next - 1'b1;
        end
        // Add enqueued entries
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            if (enq_valid[q] && free_found[q] && !enq_ready_issued_bypass[q])
                count_next = count_next + 1'b1;
        end
    end

    // =====================================================================
    // Partial-flush recount (combinational, for ff count update)
    // =====================================================================
    logic [IDX_BITS:0]  flush_valid_count;
    logic [DEPTH-1:0]   flush_survives;

    always_comb begin
        flush_valid_count = '0;
        for (int e = 0; e < DEPTH; e++) begin
            flush_survives[e] = entry_valid[e] && !flush_remove[e];
            for (int p = 0; p < NUM_SELECT; p++) begin
                if (sel_found[p] && (e[IDX_BITS-1:0] == sel_idx[p]))
                    flush_survives[e] = 1'b0;
            end
            if (flush_survives[e])
                flush_valid_count = flush_valid_count + 1'b1;
        end
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            if (enq_valid[q] && free_found[q] && !enq_ready_issued_bypass[q])
                flush_valid_count = flush_valid_count + 1'b1;
        end
    end

    // =====================================================================
    // Enqueue source readiness (combinational, for ff enqueue path)
    // =====================================================================
    always_comb begin
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            enq_s1_rdy[q] = enq_data[q].rs1_ready;
            enq_s2_rdy[q] = enq_data[q].rs2_ready;
            enq_s3_rdy[q] = enq_data[q].rs3_ready;
            enq_s1_wakeup_hit[q] = 1'b0;
            enq_s2_wakeup_hit[q] = 1'b0;
            enq_s3_wakeup_hit[q] = 1'b0;
            enq_s1_spec_match[q] =
                (spec_wk_valid && (spec_wk_tag == enq_data[q].rs1_phys)) ||
                (spec_wk_valid1 && (spec_wk_tag1 == enq_data[q].rs1_phys));
            enq_s2_spec_match[q] =
                (spec_wk_valid && (spec_wk_tag == enq_data[q].rs2_phys)) ||
                (spec_wk_valid1 && (spec_wk_tag1 == enq_data[q].rs2_phys));
            enq_s3_spec_match[q] =
                (spec_wk_valid && (spec_wk_tag == enq_data[q].rs3_phys)) ||
                (spec_wk_valid1 && (spec_wk_tag1 == enq_data[q].rs3_phys));
            enq_s1_spec_cancel[q] =
                (spec_cancel_valid && (spec_cancel_tag == enq_data[q].rs1_phys)) ||
                (spec_cancel_valid1 && (spec_cancel_tag1 == enq_data[q].rs1_phys));
            enq_s2_spec_cancel[q] =
                (spec_cancel_valid && (spec_cancel_tag == enq_data[q].rs2_phys)) ||
                (spec_cancel_valid1 && (spec_cancel_tag1 == enq_data[q].rs2_phys));
            enq_s3_spec_cancel[q] =
                (spec_cancel_valid && (spec_cancel_tag == enq_data[q].rs3_phys)) ||
                (spec_cancel_valid1 && (spec_cancel_tag1 == enq_data[q].rs3_phys));
            enq_s1_spec_wakeup[q] = 1'b0;
            enq_s2_spec_wakeup[q] = 1'b0;
            enq_s3_spec_wakeup[q] = 1'b0;
            enq_s1_spec_cancelled[q] = 1'b0;
            enq_s2_spec_cancelled[q] = 1'b0;
            enq_s3_spec_cancelled[q] = 1'b0;
            // preg_ready_table snoop (covers older broadcasts)
            if (preg_ready_table[enq_data[q].rs1_phys])
                enq_s1_rdy[q] = 1'b1;
            if (preg_ready_table[enq_data[q].rs2_phys])
                enq_s2_rdy[q] = 1'b1;
            if (preg_ready_table[enq_data[q].rs3_phys])
                enq_s3_rdy[q] = 1'b1;
            // Check CDB for source match (override ready to 1)
            for (int c = 0; c < CDB_WIDTH; c++) begin
                if (cdb_valid[c]) begin
                    if (cdb_tag[c] == enq_data[q].rs1_phys) begin
                        enq_s1_rdy[q] = 1'b1;
                        enq_s1_wakeup_hit[q] = 1'b1;
                    end
                    if (cdb_tag[c] == enq_data[q].rs2_phys) begin
                        enq_s2_rdy[q] = 1'b1;
                        enq_s2_wakeup_hit[q] = 1'b1;
                    end
                    if (cdb_tag[c] == enq_data[q].rs3_phys) begin
                        enq_s3_rdy[q] = 1'b1;
                        enq_s3_wakeup_hit[q] = 1'b1;
                    end
                end
            end
            // Check load_wb sideband for source match at enqueue time.
            // Handles instructions enqueued on the same cycle a load writes
            // back (preg_ready_table may not yet be updated).
            if (load_wb_wk_valid0) begin
                if (load_wb_wk_tag0 == enq_data[q].rs1_phys) begin
                    enq_s1_rdy[q] = 1'b1;
                    enq_s1_wakeup_hit[q] = 1'b1;
                end
                if (load_wb_wk_tag0 == enq_data[q].rs2_phys) begin
                    enq_s2_rdy[q] = 1'b1;
                    enq_s2_wakeup_hit[q] = 1'b1;
                end
                if (load_wb_wk_tag0 == enq_data[q].rs3_phys) begin
                    enq_s3_rdy[q] = 1'b1;
                    enq_s3_wakeup_hit[q] = 1'b1;
                end
            end
            if (load_wb_wk_valid1) begin
                if (load_wb_wk_tag1 == enq_data[q].rs1_phys) begin
                    enq_s1_rdy[q] = 1'b1;
                    enq_s1_wakeup_hit[q] = 1'b1;
                end
                if (load_wb_wk_tag1 == enq_data[q].rs2_phys) begin
                    enq_s2_rdy[q] = 1'b1;
                    enq_s2_wakeup_hit[q] = 1'b1;
                end
                if (load_wb_wk_tag1 == enq_data[q].rs3_phys) begin
                    enq_s3_rdy[q] = 1'b1;
                    enq_s3_wakeup_hit[q] = 1'b1;
                end
            end
            // Speculative load wakeup for a newly allocated entry.  This does
            // not feed same-cycle enqueue issue bypass; it only writes the
            // registered ready/spec bits below so the uop can wake next cycle.
            if (enq_s1_spec_match[q] && !enq_s1_rdy[q]) begin
                if (enq_s1_spec_cancel[q])
                    enq_s1_spec_cancelled[q] = 1'b1;
                else
                    enq_s1_spec_wakeup[q] = 1'b1;
            end
            if (enq_s2_spec_match[q] && !enq_s2_rdy[q]) begin
                if (enq_s2_spec_cancel[q])
                    enq_s2_spec_cancelled[q] = 1'b1;
                else
                    enq_s2_spec_wakeup[q] = 1'b1;
            end
            if (enq_s3_spec_match[q] && !enq_s3_rdy[q]) begin
                if (enq_s3_spec_cancel[q])
                    enq_s3_spec_cancelled[q] = 1'b1;
                else
                    enq_s3_spec_wakeup[q] = 1'b1;
            end
        end
    end

    always_comb begin
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            enq_bypass_is_alu[q] =
                (enq_data[q].fu_type == FU_ALU);
            enq_bypass_is_bru[q] =
                (enq_data[q].fu_type == FU_BRU);
            enq_bypass_is_bru_jal[q] =
                enq_bypass_is_bru[q] &&
                (enq_data[q].br_op == BR_JAL);
            enq_bypass_is_bru_jalr[q] =
                enq_bypass_is_bru[q] &&
                (enq_data[q].br_op == BR_JALR);
            enq_bypass_is_bru_cond[q] =
                enq_bypass_is_bru[q] &&
                !enq_bypass_is_bru_jal[q] &&
                !enq_bypass_is_bru_jalr[q];
            enq_bypass_is_bru_backedge[q] =
                enq_bypass_is_bru_cond[q] &&
                enq_data[q].bp_taken &&
                (enq_data[q].bp_target < enq_data[q].pc);
            enq_bypass_is_serial[q] =
                (enq_data[q].fu_type == FU_MUL) ||
                (enq_data[q].fu_type == FU_DIV) ||
                (enq_data[q].fu_type == FU_CSR);
            enq_bypass_fu_allowed[q] =
                !enq_issue_bypass_alu_only ||
                enq_bypass_is_alu[q];
            enq_ready_for_bypass[q] =
                (SUPPORT_ENQ_ISSUE_BYPASS != 0) &&
                enq_issue_bypass_enable &&
                enq_valid[q] &&
                enq_s1_rdy[q] &&
                enq_s2_rdy[q] &&
                enq_s3_rdy[q] &&
                !flush_valid;
            enq_ready_candidate[q] =
                enq_ready_for_bypass[q] &&
                enq_bypass_fu_allowed[q];
            enq_bypass_fu_blocked[q] =
                enq_ready_for_bypass[q] &&
                !enq_bypass_fu_allowed[q];
            enq_bypass_fu_blocked_bru_cond[q] =
                enq_bypass_fu_blocked[q] &&
                enq_bypass_is_bru_cond[q];
            enq_bypass_fu_blocked_bru_backedge[q] =
                enq_bypass_fu_blocked[q] &&
                enq_bypass_is_bru_backedge[q];
            enq_bypass_fu_blocked_bru_jal[q] =
                enq_bypass_fu_blocked[q] &&
                enq_bypass_is_bru_jal[q];
            enq_bypass_fu_blocked_bru_jalr[q] =
                enq_bypass_fu_blocked[q] &&
                enq_bypass_is_bru_jalr[q];
            enq_bypass_fu_blocked_serial[q] =
                enq_bypass_fu_blocked[q] &&
                enq_bypass_is_serial[q];
            enq_wakeup_hit[q] =
                enq_valid[q] &&
                ((enq_s1_wakeup_hit[q] && !enq_data[q].rs1_ready) ||
                 (enq_s2_wakeup_hit[q] && !enq_data[q].rs2_ready) ||
                 (enq_s3_wakeup_hit[q] && !enq_data[q].rs3_ready));
            enq_spec_wakeup[q] =
                enq_valid[q] &&
                (enq_s1_spec_wakeup[q] ||
                 enq_s2_spec_wakeup[q] ||
                 enq_s3_spec_wakeup[q]);
            enq_spec_cancelled[q] =
                enq_valid[q] &&
                (enq_s1_spec_cancelled[q] ||
                 enq_s2_spec_cancelled[q] ||
                 enq_s3_spec_cancelled[q]);
        end
    end

    always_comb begin
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            enq_ready_hidden[q] =
                enq_valid[q] &&
                enq_s1_rdy[q] &&
                enq_s2_rdy[q] &&
                enq_s3_rdy[q] &&
                !enq_ready_issued_bypass[q] &&
                !flush_valid;
            enq_bypass_suppressed[q] =
                enq_ready_candidate[q] &&
                !enq_ready_issued_bypass[q];
        end
    end

    // =====================================================================
    // Per-entry speculative wakeup gating (combinational, for ff update)
    // =====================================================================
    logic [DEPTH-1:0] do_spec1;
    logic [DEPTH-1:0] do_spec2;
    logic [DEPTH-1:0] do_spec3;

    always_comb begin
        for (int e = 0; e < DEPTH; e++) begin
            do_spec1[e] = spec_set_src1[e] & ~spec_cancel_rs1[e];
            do_spec2[e] = spec_set_src2[e] & ~spec_cancel_rs2[e];
            do_spec3[e] = spec_set_src3[e] & ~spec_cancel_rs3[e];
        end
    end

    // =====================================================================
    // Sequential state update
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (flush_valid && flush_full)) begin
            entry_valid <= '0;
            src1_ready  <= '0;
            src2_ready  <= '0;
            src3_ready  <= '0;
            src1_spec   <= '0;
            src2_spec   <= '0;
            src3_spec   <= '0;
            count_r     <= '0;
        end else begin
            // ---- Wakeup: update ready / spec bits for all entries ----
            // Start from the combinational wakeup result (CDB + cancel),
            // then OR in the latched spec wakeup so it appears as "ready"
            // on the *next* cycle (matching the load result on combinational
            // CDB / bypass network).  Spec-set bits also light the spec flag
            // so a cache miss can later cancel them.
            //
            // If a spec-cancel already fired this cycle for an entry, do
            // NOT spec-set it (cancel wins over a same-cycle re-wake).
            for (int e = 0; e < DEPTH; e++) begin
                src1_ready[e] <= next_src1_ready[e] | do_spec1[e];
                src2_ready[e] <= next_src2_ready[e] | do_spec2[e];
                src3_ready[e] <= next_src3_ready[e] | do_spec3[e];
                src1_spec[e]  <= next_src1_spec[e]  | do_spec1[e];
                src2_spec[e]  <= next_src2_spec[e]  | do_spec2[e];
                src3_spec[e]  <= next_src3_spec[e]  | do_spec3[e];
            end

            // ---- Issue: invalidate selected entries ----
            // Skip invalidation when the selected port is suppressed
            // (entry re-issues on a later cycle).
            for (int p = 0; p < NUM_SELECT; p++) begin
                if (sel_found[p] && !issue_suppress[p]) begin
                    entry_valid[sel_idx[p]] <= 1'b0;
                    src1_ready[sel_idx[p]]  <= 1'b0;
                    src2_ready[sel_idx[p]]  <= 1'b0;
                    src3_ready[sel_idx[p]]  <= 1'b0;
                    src1_spec[sel_idx[p]]   <= 1'b0;
                    src2_spec[sel_idx[p]]   <= 1'b0;
                    src3_spec[sel_idx[p]]   <= 1'b0;
                end
            end

            // ---- Enqueue: write new entries into free slots ----
            // Snoop the current CDB broadcast at enqueue time to avoid
            // the classic simultaneous-enqueue-plus-wakeup race: a new
            // entry arrives the same cycle its producer broadcasts, but
            // the wakeup logic only sees entries that are already valid.
            //
            // Additionally snoop preg_ready_table to catch producers that
            // broadcast BEFORE this enqueue cycle (e.g., the dispatch queue
            // held the consumer in the FIFO while the producer already
            // wrote back through the CDB).
            for (int q = 0; q < NUM_ENQUEUE; q++) begin
                if (enq_valid[q] && free_found[q] && !enq_ready_issued_bypass[q]) begin
                    entry_valid[free_idx[q]] <= 1'b1;
                    payload_r[free_idx[q]]   <= PW'(enq_data[q]);
                    rs1_phys_r[free_idx[q]]  <= enq_data[q].rs1_phys;
                    rs2_phys_r[free_idx[q]]  <= enq_data[q].rs2_phys;
                    rs3_phys_r[free_idx[q]]  <= enq_data[q].rs3_phys;
                    rob_idx_r[free_idx[q]]   <= enq_data[q].rob_idx;
                    fu_type_r[free_idx[q]]   <= enq_data[q].fu_type;
                    src1_ready[free_idx[q]]  <= enq_s1_rdy[q] | enq_s1_spec_wakeup[q];
                    src2_ready[free_idx[q]]  <= enq_s2_rdy[q] | enq_s2_spec_wakeup[q];
                    src3_ready[free_idx[q]]  <= enq_s3_rdy[q] | enq_s3_spec_wakeup[q];
                    src1_spec[free_idx[q]]   <= enq_s1_spec_wakeup[q];
                    src2_spec[free_idx[q]]   <= enq_s2_spec_wakeup[q];
                    src3_spec[free_idx[q]]   <= enq_s3_spec_wakeup[q];
                end
            end

            // ---- Partial flush: invalidate younger entries ----
            if (flush_valid && !flush_full) begin
                for (int e = 0; e < DEPTH; e++) begin
                    if (flush_remove[e]) begin
                        entry_valid[e] <= 1'b0;
                        src1_ready[e]  <= 1'b0;
                        src2_ready[e]  <= 1'b0;
                        src3_ready[e]  <= 1'b0;
                        src1_spec[e]   <= 1'b0;
                        src2_spec[e]   <= 1'b0;
                        src3_spec[e]   <= 1'b0;
                    end
                end
            end

            // ---- Update count ----
            if (flush_valid && !flush_full) begin
                // On partial flush use pre-computed recount
                count_r <= flush_valid_count;
            end else begin
                count_r <= count_next;
            end
        end
    end

endmodule
