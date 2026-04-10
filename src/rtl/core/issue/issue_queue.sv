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
    // When non-zero, entries whose fu_type matches PORT0_ONLY_FU are
    // excluded from port 1 selection (they can only issue on port 0).
    // Set to a fu_type_e value (e.g., 3'd1 for FU_BRU) or 0 to disable.
    parameter int PORT0_ONLY_FU = 0
)(
    input  logic clk,
    input  logic rst_n,

    // Enqueue (from dispatch, up to NUM_ENQUEUE per cycle)
    input  logic [NUM_ENQUEUE-1:0] enq_valid,
    input  iq_entry_t              enq_data [0:NUM_ENQUEUE-1],
    output logic                   full,       // no space for NUM_ENQUEUE entries

    // Wakeup via CDB broadcast
    input  logic [CDB_WIDTH-1:0]     cdb_valid,
    input  logic [PHYS_REG_BITS-1:0] cdb_tag [0:CDB_WIDTH-1],

    // Speculative wakeup (from load AGU -- may be cancelled on cache miss)
    input  logic                     spec_wk_valid,
    input  logic [PHYS_REG_BITS-1:0] spec_wk_tag,
    // Speculative cancel (cache miss -- undo speculative wakeup, replay)
    input  logic                     spec_cancel_valid,
    input  logic [PHYS_REG_BITS-1:0] spec_cancel_tag,

    // Issue output (NUM_SELECT ports)
    output logic [NUM_SELECT-1:0]  issue_valid,
    output iq_entry_t              issue_data [0:NUM_SELECT-1],

    // ROB head for age comparison
    input  logic [ROB_IDX_BITS-1:0] rob_head,

    // Flush
    input  logic                    flush_valid,
    input  logic [ROB_IDX_BITS-1:0] flush_rob_tail,  // invalidate entries younger than this
    input  logic                    flush_full         // invalidate everything
);

    // =====================================================================
    // Local parameters
    // =====================================================================
    localparam int IDX_BITS  = $clog2(DEPTH);
    localparam int PW        = $bits(iq_entry_t);
    // For age calculations with non-power-of-2 ROB
    localparam int AGE_BITS  = ROB_IDX_BITS + 1;  // extra bit for wrapping

    // =====================================================================
    // Storage arrays -- flat, separate CAM fields for fast wakeup
    // =====================================================================
    logic [DEPTH-1:0]              entry_valid;
    logic [PHYS_REG_BITS-1:0]     rs1_phys_r   [0:DEPTH-1];
    logic [PHYS_REG_BITS-1:0]     rs2_phys_r   [0:DEPTH-1];
    logic [ROB_IDX_BITS-1:0]      rob_idx_r    [0:DEPTH-1];
    logic [2:0]                   fu_type_r    [0:DEPTH-1];  // for port restriction
    logic [DEPTH-1:0]             src1_ready;
    logic [DEPTH-1:0]             src2_ready;
    logic [DEPTH-1:0]             src1_spec;     // rs1 was woken speculatively
    logic [DEPTH-1:0]             src2_spec;     // rs2 was woken speculatively
    // Store payload as flat bit vectors to avoid Verilator packed-struct
    // array misalignment.  Cast to/from iq_entry_t at write/read boundaries.
    logic [PW-1:0]                payload_r    [0:DEPTH-1];

    // =====================================================================
    // Entry count and full flag
    // =====================================================================
    logic [IDX_BITS:0] count_r;
    assign full = (count_r >= (DEPTH[IDX_BITS:0] - NUM_ENQUEUE[IDX_BITS:0]));

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
    // For every valid entry, check CDB tags and speculative wakeup tag
    // against rs1_phys / rs2_phys.
    // =====================================================================
    logic [DEPTH-1:0] next_src1_ready;
    logic [DEPTH-1:0] next_src2_ready;
    logic [DEPTH-1:0] next_src1_spec;
    logic [DEPTH-1:0] next_src2_spec;

    // Per-entry CDB match signals (declared outside the always_comb)
    logic [DEPTH-1:0] rs1_cdb_hit;
    logic [DEPTH-1:0] rs2_cdb_hit;

    always_comb begin
        next_src1_ready = src1_ready;
        next_src2_ready = src2_ready;
        next_src1_spec  = src1_spec;
        next_src2_spec  = src2_spec;

        for (int e = 0; e < DEPTH; e++) begin
            rs1_cdb_hit[e] = 1'b0;
            rs2_cdb_hit[e] = 1'b0;
        end

        for (int e = 0; e < DEPTH; e++) begin
            // -- CDB definitive wakeup --
            for (int c = 0; c < CDB_WIDTH; c++) begin
                if (cdb_valid[c] && (cdb_tag[c] == rs1_phys_r[e]))
                    rs1_cdb_hit[e] = 1'b1;
                if (cdb_valid[c] && (cdb_tag[c] == rs2_phys_r[e]))
                    rs2_cdb_hit[e] = 1'b1;
            end

            if (entry_valid[e]) begin
                // CDB wakeup: set ready, clear speculative flag
                if (rs1_cdb_hit[e] && !src1_ready[e]) begin
                    next_src1_ready[e] = 1'b1;
                    next_src1_spec[e]  = 1'b0;
                end
                if (rs2_cdb_hit[e] && !src2_ready[e]) begin
                    next_src2_ready[e] = 1'b1;
                    next_src2_spec[e]  = 1'b0;
                end

                // -- Speculative wakeup (load AGU) --
                if (spec_wk_valid && !src1_ready[e] && !rs1_cdb_hit[e] &&
                    (spec_wk_tag == rs1_phys_r[e])) begin
                    next_src1_ready[e] = 1'b1;
                    next_src1_spec[e]  = 1'b1;
                end
                if (spec_wk_valid && !src2_ready[e] && !rs2_cdb_hit[e] &&
                    (spec_wk_tag == rs2_phys_r[e])) begin
                    next_src2_ready[e] = 1'b1;
                    next_src2_spec[e]  = 1'b1;
                end

                // -- Speculative cancel (cache miss) --
                if (spec_cancel_valid &&
                    (spec_cancel_tag == rs1_phys_r[e]) &&
                    next_src1_spec[e]) begin
                    next_src1_ready[e] = 1'b0;
                    next_src1_spec[e]  = 1'b0;
                end
                if (spec_cancel_valid &&
                    (spec_cancel_tag == rs2_phys_r[e]) &&
                    next_src2_spec[e]) begin
                    next_src2_ready[e] = 1'b0;
                    next_src2_spec[e]  = 1'b0;
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
            eligible[e] = entry_valid[e] & next_src1_ready[e] & next_src2_ready[e];
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

    // Pre-compute ages for all entries (outside the selection always_comb)
    logic [AGE_BITS-1:0] entry_age [0:DEPTH-1];

    always_comb begin
        for (int e = 0; e < DEPTH; e++) begin
            entry_age[e] = ((rob_idx_r[e] >= rob_head) ? ({1'b0, rob_idx_r[e]} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, rob_idx_r[e]}));
        end
    end

    always_comb begin
        // -- Port 0 selection --
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

        // -- Port 1 selection (exclude port 0's winner and port0-only entries) --
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

    // Drive issue outputs
    always_comb begin
        for (int p = 0; p < NUM_SELECT; p++) begin
            issue_valid[p] = sel_found[p];
            issue_data[p]  = iq_entry_t'(payload_r[sel_idx[p]]);
            // Override ready flags with wakeup results so downstream sees
            // correct readiness even on the issue cycle.
            issue_data[p].rs1_ready = next_src1_ready[sel_idx[p]];
            issue_data[p].rs2_ready = next_src2_ready[sel_idx[p]];
        end
    end

    // =====================================================================
    // Free-slot finder: find up to NUM_ENQUEUE free slots for enqueue
    // =====================================================================
    logic [IDX_BITS-1:0] free_idx  [0:NUM_ENQUEUE-1];
    logic [NUM_ENQUEUE-1:0] free_found;

    always_comb begin
        logic [DEPTH-1:0] occupied;
        int slots_found;

        // Slots that are occupied after considering this-cycle issue
        // invalidations (not yet committed to flops, so we compute
        // effective validity for the free-slot scan).
        occupied = entry_valid;
        // Entries about to be issued will be freed -- exclude them from
        // occupied so that back-to-back dispatch is not stalled.
        for (int p = 0; p < NUM_SELECT; p++) begin
            if (sel_found[p])
                occupied[sel_idx[p]] = 1'b0;
        end

        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            free_found[q] = 1'b0;
            free_idx[q]   = '0;
        end

        slots_found = 0;
        for (int e = 0; e < DEPTH; e++) begin
            if (!occupied[e] && slots_found < NUM_ENQUEUE) begin
                free_idx[slots_found]   = e[IDX_BITS-1:0];
                free_found[slots_found] = 1'b1;
                occupied[e] = 1'b1;  // mark taken for subsequent searches
                slots_found = slots_found + 1;
            end
        end
    end

    // =====================================================================
    // Flush logic: determine which entries to invalidate
    // =====================================================================
    logic [DEPTH-1:0] flush_remove;

    always_comb begin
        logic [AGE_BITS-1:0] tail_age;
        logic [AGE_BITS-1:0] fl_entry_age;

        flush_remove = '0;
        tail_age = ((flush_rob_tail >= rob_head) ? ({1'b0, flush_rob_tail} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, flush_rob_tail}));
        fl_entry_age = '0;

        if (flush_valid && !flush_full) begin
            for (int e = 0; e < DEPTH; e++) begin
                if (entry_valid[e]) begin
                    fl_entry_age = ((rob_idx_r[e] >= rob_head) ? ({1'b0, rob_idx_r[e]} - {1'b0, rob_head}) : (ROB_DEPTH[AGE_BITS-1:0] - {1'b0, rob_head} + {1'b0, rob_idx_r[e]}));
                    if (fl_entry_age > tail_age)
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
            if (sel_found[p])
                count_next = count_next - 1'b1;
        end
        // Add enqueued entries
        for (int q = 0; q < NUM_ENQUEUE; q++) begin
            if (enq_valid[q] && free_found[q])
                count_next = count_next + 1'b1;
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
            src1_spec   <= '0;
            src2_spec   <= '0;
            count_r     <= '0;
        end else begin
            // ---- Wakeup: update ready / spec bits for all entries ----
            src1_ready <= next_src1_ready;
            src2_ready <= next_src2_ready;
            src1_spec  <= next_src1_spec;
            src2_spec  <= next_src2_spec;

            // ---- Issue: invalidate selected entries ----
            for (int p = 0; p < NUM_SELECT; p++) begin
                if (sel_found[p]) begin
                    entry_valid[sel_idx[p]] <= 1'b0;
                    src1_ready[sel_idx[p]]  <= 1'b0;
                    src2_ready[sel_idx[p]]  <= 1'b0;
                    src1_spec[sel_idx[p]]   <= 1'b0;
                    src2_spec[sel_idx[p]]   <= 1'b0;
                end
            end

            // ---- Enqueue: write new entries into free slots ----
            // Snoop the current CDB broadcast at enqueue time to avoid
            // the classic simultaneous-enqueue-plus-wakeup race: a new
            // entry arrives the same cycle its producer broadcasts, but
            // the wakeup logic only sees entries that are already valid.
            for (int q = 0; q < NUM_ENQUEUE; q++) begin
                if (enq_valid[q] && free_found[q]) begin
                    automatic logic enq_s1_rdy;
                    automatic logic enq_s2_rdy;
                    enq_s1_rdy = enq_data[q].rs1_ready;
                    enq_s2_rdy = enq_data[q].rs2_ready;
                    // Check CDB for source match (override ready to 1)
                    for (int c = 0; c < CDB_WIDTH; c++) begin
                        if (cdb_valid[c]) begin
                            if (cdb_tag[c] == enq_data[q].rs1_phys)
                                enq_s1_rdy = 1'b1;
                            if (cdb_tag[c] == enq_data[q].rs2_phys)
                                enq_s2_rdy = 1'b1;
                        end
                    end
                    entry_valid[free_idx[q]] <= 1'b1;
                    payload_r[free_idx[q]]   <= PW'(enq_data[q]);
                    rs1_phys_r[free_idx[q]]  <= enq_data[q].rs1_phys;
                    rs2_phys_r[free_idx[q]]  <= enq_data[q].rs2_phys;
                    rob_idx_r[free_idx[q]]   <= enq_data[q].rob_idx;
                    fu_type_r[free_idx[q]]   <= enq_data[q].fu_type;
                    src1_ready[free_idx[q]]  <= enq_s1_rdy;
                    src2_ready[free_idx[q]]  <= enq_s2_rdy;
                    src1_spec[free_idx[q]]   <= 1'b0;
                    src2_spec[free_idx[q]]   <= 1'b0;
                end
            end

            // ---- Partial flush: invalidate younger entries ----
            if (flush_valid && !flush_full) begin
                for (int e = 0; e < DEPTH; e++) begin
                    if (flush_remove[e]) begin
                        entry_valid[e] <= 1'b0;
                        src1_ready[e]  <= 1'b0;
                        src2_ready[e]  <= 1'b0;
                        src1_spec[e]   <= 1'b0;
                        src2_spec[e]   <= 1'b0;
                    end
                end
            end

            // ---- Update count ----
            if (flush_valid && !flush_full) begin
                // On partial flush recount valid entries
                automatic logic [IDX_BITS:0] valid_count;
                logic survives;
                valid_count = '0;
                for (int e = 0; e < DEPTH; e++) begin
                    survives = entry_valid[e] && !flush_remove[e];
                    for (int p = 0; p < NUM_SELECT; p++) begin
                        if (sel_found[p] && (e[IDX_BITS-1:0] == sel_idx[p]))
                            survives = 1'b0;
                    end
                    if (survives)
                        valid_count = valid_count + 1'b1;
                end
                for (int q = 0; q < NUM_ENQUEUE; q++) begin
                    if (enq_valid[q] && free_found[q])
                        valid_count = valid_count + 1'b1;
                end
                count_r <= valid_count;
            end else begin
                count_r <= count_next;
            end
        end
    end

endmodule
