/* file: tage_sc_l.sv
 Description: TAGE-SC-L branch predictor with statistical corrector.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module tage_sc_l
    import rv64gc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Predict (combinational lookup)
    input  logic [63:0] pc,
    output logic        pred_taken,
    output logic        pred_confident,   // high confidence -> no checkpoint needed

    // Update (from commit — actual branch outcome)
    input  logic        update_valid,
    input  logic [63:0] update_pc,
    input  logic        update_taken,
    input  logic        update_mispredict,

    // GHR management
    input  logic        spec_update_valid,  // speculatively shift GHR on prediction
    input  logic        spec_taken,
    input  logic        ghr_restore_valid,  // restore GHR on mispredict
    input  logic [GHR_BITS-1:0] ghr_restore_val,
    output logic [GHR_BITS-1:0] ghr_out,   // current GHR for checkpoint save

    // Flush
    input  logic        flush
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int BASE_IDX_BITS   = $clog2(TAGE_BASE_ENTRIES);  // 12
    localparam int TAGE_IDX_BITS   = $clog2(TAGE_TABLE_ENTRIES); // 8
    localparam int SC_IDX_BITS     = $clog2(SC_ENTRIES);         // 10
    localparam int LOOP_IDX_BITS   = $clog2(LOOP_PRED_ENTRIES);  // 6
    localparam int TAGE_CTR_BITS   = 3;
    localparam int BASE_CTR_BITS   = 2;
    localparam int SC_CTR_BITS     = 6;
    localparam int USEFUL_BITS     = 2;
    localparam int LOOP_TAG_BITS   = 12;
    localparam int LOOP_CNT_BITS   = 14;
    localparam int LOOP_CONF_BITS  = 2;

    // Geometric history lengths for the 4 tagged tables
    localparam int GHR_LENGTHS [TAGE_NUM_TABLES] = '{8, 16, 32, 64};

    // Useful-counter reset period (every 256K branches)
    localparam int USEFUL_RESET_PERIOD = 18;  // log2(256K) = 18

    // =========================================================================
    // GHR (Global History Register) — 64-bit shift register
    // =========================================================================
    logic [GHR_BITS-1:0] ghr_r;

    assign ghr_out = ghr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghr_r <= '0;
        end else if (flush) begin
            ghr_r <= '0;
        end else if (ghr_restore_valid) begin
            ghr_r <= ghr_restore_val;
        end else if (spec_update_valid) begin
            ghr_r <= {ghr_r[GHR_BITS-2:0], spec_taken};
        end
    end

    // =========================================================================
    // Combinational hash wires: fold_ghr, index_hash, tag_hash (inlined)
    // =========================================================================
    logic [TAGE_IDX_BITS-1:0] fold_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] fold_tag1 [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] fold_tag2 [TAGE_NUM_TABLES];
    logic [TAGE_IDX_BITS-1:0] upd_fold_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] upd_fold_tag1 [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] upd_fold_tag2 [TAGE_NUM_TABLES];

    always_comb begin
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            fold_idx[t] = '0;
            fold_tag1[t] = '0;
            fold_tag2[t] = '0;
            upd_fold_idx[t] = '0;
            upd_fold_tag1[t] = '0;
            upd_fold_tag2[t] = '0;
            for (int i = 0; i < GHR_BITS; i++) begin
                if (i < GHR_LENGTHS[t]) begin
                    fold_idx[t][i % TAGE_IDX_BITS] = fold_idx[t][i % TAGE_IDX_BITS] ^ ghr_r[i];
                    fold_tag1[t][i % TAGE_TAG_BITS] = fold_tag1[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                    upd_fold_idx[t][i % TAGE_IDX_BITS] = upd_fold_idx[t][i % TAGE_IDX_BITS] ^ ghr_r[i];
                    upd_fold_tag1[t][i % TAGE_TAG_BITS] = upd_fold_tag1[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                end
                if (i < (GHR_LENGTHS[t] + 3)) begin
                    fold_tag2[t][i % TAGE_TAG_BITS] = fold_tag2[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                    upd_fold_tag2[t][i % TAGE_TAG_BITS] = upd_fold_tag2[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                end
            end
        end
    end

    // =========================================================================
    //  1. Base predictor — 4096-entry bimodal (2-bit counters)
    // =========================================================================
    logic [BASE_CTR_BITS-1:0] base_table [TAGE_BASE_ENTRIES];

    logic [BASE_IDX_BITS-1:0] base_lkp_idx;
    logic                     base_pred;

    assign base_lkp_idx = pc[BASE_IDX_BITS+1:2];
    assign base_pred    = base_table[base_lkp_idx][BASE_CTR_BITS-1]; // >= 2

    // =========================================================================
    //  2. Tagged tables (4 tables x 256 entries)
    // =========================================================================
    // Per-entry fields
    logic [TAGE_TAG_BITS-1:0]  tage_tags   [TAGE_NUM_TABLES][TAGE_TABLE_ENTRIES];
    logic [TAGE_CTR_BITS-1:0]  tage_ctrs   [TAGE_NUM_TABLES][TAGE_TABLE_ENTRIES];
    logic [USEFUL_BITS-1:0]    tage_useful [TAGE_NUM_TABLES][TAGE_TABLE_ENTRIES];
    logic                      tage_valid  [TAGE_NUM_TABLES][TAGE_TABLE_ENTRIES];

    // Lookup signals
    logic [TAGE_IDX_BITS-1:0]  tage_lkp_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0]  tage_lkp_tag [TAGE_NUM_TABLES];
    logic                      tage_hit     [TAGE_NUM_TABLES];
    logic [TAGE_CTR_BITS-1:0]  tage_hit_ctr [TAGE_NUM_TABLES];

    // Provider selection: longest-matching table
    logic                      tage_any_hit;
    logic [1:0]                tage_provider;        // table index of provider
    logic                      tage_pred;
    logic                      tage_pred_weak;       // counter near threshold

    always_comb begin
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            tage_lkp_idx[t] = pc[TAGE_IDX_BITS+1:2] ^ fold_idx[t] ^ TAGE_IDX_BITS'(pc[21:12] >> t);
            tage_lkp_tag[t] = pc[TAGE_TAG_BITS+1:2] ^ fold_tag1[t] ^ fold_tag2[t];
            tage_hit[t]     = tage_valid[t][tage_lkp_idx[t]] &&
                              (tage_tags[t][tage_lkp_idx[t]] == tage_lkp_tag[t]);
            tage_hit_ctr[t] = tage_ctrs[t][tage_lkp_idx[t]];
        end

        // Provider = longest-matching (highest-index) table
        tage_any_hit  = 1'b0;
        tage_provider = 2'd0;
        tage_pred     = base_pred;
        tage_pred_weak = 1'b0;

        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            if (tage_hit[t]) begin
                tage_any_hit  = 1'b1;
                tage_provider = 2'(t);
                tage_pred     = tage_hit_ctr[t] >= 3'(TAGE_CTR_BITS'(1) << (TAGE_CTR_BITS - 1));
            end
        end

        // Weak prediction: counter is 3 or 4 (one step from threshold 4)
        if (tage_any_hit) begin
            tage_pred_weak = (tage_hit_ctr[tage_provider] == 3'd3) ||
                             (tage_hit_ctr[tage_provider] == 3'd4);
        end else begin
            // Base predictor: weak when counter is 1 or 2
            tage_pred_weak = (base_table[base_lkp_idx] == 2'd1) ||
                             (base_table[base_lkp_idx] == 2'd2);
        end
    end

    // =========================================================================
    //  3. Statistical Corrector (SC) — 1024 entries, 6-bit signed counters
    // =========================================================================
    logic signed [SC_CTR_BITS-1:0] sc_table [SC_ENTRIES];

    logic [SC_IDX_BITS-1:0]        sc_lkp_idx;
    logic signed [SC_CTR_BITS-1:0] sc_ctr_val;
    logic signed [SC_CTR_BITS:0]   sc_sum;        // wider for addition
    logic                          sc_override;
    logic                          sc_pred;

    assign sc_lkp_idx = pc[SC_IDX_BITS+1:2] ^ SC_IDX_BITS'(ghr_r[7:0]);
    assign sc_ctr_val = sc_table[sc_lkp_idx];

    always_comb begin
        // TAGE confidence mapped to signed value: strong taken = +2, weak taken = +1,
        // weak not-taken = -1, strong not-taken = -2
        if (tage_pred_weak) begin
            sc_sum = tage_pred ? (sc_ctr_val + 7'(1))
                               : (sc_ctr_val - 7'(1));
        end else begin
            sc_sum = tage_pred ? (sc_ctr_val + 7'(2))
                               : (sc_ctr_val - 7'(2));
        end

        // SC overrides only on weak TAGE predictions
        sc_override = 1'b0;
        sc_pred     = tage_pred;
        if (tage_pred_weak) begin
            if (tage_pred && (sc_sum < 0)) begin
                sc_override = 1'b1;
                sc_pred     = 1'b0;
            end else if (!tage_pred && (sc_sum >= 0)) begin
                sc_override = 1'b1;
                sc_pred     = 1'b1;
            end
        end
    end

    // =========================================================================
    //  4. Loop Predictor — 64 entries
    //     {tag[11:0], count[13:0], limit[13:0], confidence[1:0], dir}
    // =========================================================================
    logic [LOOP_TAG_BITS-1:0]  loop_tags  [LOOP_PRED_ENTRIES];
    logic [LOOP_CNT_BITS-1:0]  loop_count [LOOP_PRED_ENTRIES];
    logic [LOOP_CNT_BITS-1:0]  loop_limit [LOOP_PRED_ENTRIES];
    logic [LOOP_CONF_BITS-1:0] loop_conf  [LOOP_PRED_ENTRIES];
    logic                      loop_dir   [LOOP_PRED_ENTRIES];
    logic                      loop_valid [LOOP_PRED_ENTRIES];

    logic [LOOP_IDX_BITS-1:0]  loop_lkp_idx;
    logic [LOOP_TAG_BITS-1:0]  loop_lkp_tag;
    logic                      loop_hit;
    logic                      loop_pred;
    logic                      loop_confident;
    logic                      loop_override;

    assign loop_lkp_idx = pc[LOOP_IDX_BITS+1:2];
    assign loop_lkp_tag = pc[LOOP_TAG_BITS+1:2];

    always_comb begin
        loop_hit       = loop_valid[loop_lkp_idx] &&
                         (loop_tags[loop_lkp_idx] == loop_lkp_tag);
        loop_pred      = 1'b0;
        loop_confident = 1'b0;
        loop_override  = 1'b0;

        if (loop_hit) begin
            loop_confident = (loop_conf[loop_lkp_idx] == {LOOP_CONF_BITS{1'b1}});
            if (loop_count[loop_lkp_idx] < loop_limit[loop_lkp_idx]) begin
                loop_pred = 1'b1;  // stay in loop
            end else begin
                loop_pred = 1'b0;  // exit loop
            end
            // Override TAGE+SC only with high confidence
            loop_override = loop_confident;
        end
    end

    // =========================================================================
    //  Final prediction mux
    // =========================================================================
    always_comb begin
        if (loop_override) begin
            pred_taken = loop_pred;
        end else begin
            pred_taken = sc_pred;
        end

        // Confidence: high if loop overrides, or if TAGE was strong and SC agreed
        pred_confident = loop_override || (!tage_pred_weak && !sc_override);
    end

    // =========================================================================
    //  Update path — all sequential on update_valid
    // =========================================================================

    // Recompute update hashes
    logic [BASE_IDX_BITS-1:0] upd_base_idx;
    logic [TAGE_IDX_BITS-1:0] upd_tage_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] upd_tage_tag [TAGE_NUM_TABLES];
    logic                     upd_tage_hit [TAGE_NUM_TABLES];
    logic [1:0]               upd_provider;
    logic                     upd_any_hit;
    logic [SC_IDX_BITS-1:0]   upd_sc_idx;
    logic [LOOP_IDX_BITS-1:0] upd_loop_idx;
    logic [LOOP_TAG_BITS-1:0] upd_loop_tag;
    logic                     upd_loop_hit;

    always_comb begin
        upd_base_idx = update_pc[BASE_IDX_BITS+1:2];
        upd_sc_idx   = update_pc[SC_IDX_BITS+1:2] ^ SC_IDX_BITS'(ghr_r[7:0]);
        upd_loop_idx = update_pc[LOOP_IDX_BITS+1:2];
        upd_loop_tag = update_pc[LOOP_TAG_BITS+1:2];

        upd_any_hit  = 1'b0;
        upd_provider = 2'd0;
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            upd_tage_idx[t] = update_pc[TAGE_IDX_BITS+1:2] ^ upd_fold_idx[t] ^ TAGE_IDX_BITS'(update_pc[21:12] >> t);
            upd_tage_tag[t] = update_pc[TAGE_TAG_BITS+1:2] ^ upd_fold_tag1[t] ^ upd_fold_tag2[t];
            upd_tage_hit[t] = tage_valid[t][upd_tage_idx[t]] &&
                              (tage_tags[t][upd_tage_idx[t]] == upd_tage_tag[t]);
            if (upd_tage_hit[t]) begin
                upd_any_hit  = 1'b1;
                upd_provider = 2'(t);
            end
        end

        upd_loop_hit = loop_valid[upd_loop_idx] &&
                       (loop_tags[upd_loop_idx] == upd_loop_tag);
    end

    // Useful-counter periodic reset
    logic [USEFUL_RESET_PERIOD-1:0] branch_count_r;

    // Saturating counter operations inlined at each call site below.

    // =========================================================================
    //  Sequential update logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ----- Reset base predictor -----
            for (int i = 0; i < TAGE_BASE_ENTRIES; i++) begin
                base_table[i] <= 2'd1; // weakly not-taken
            end
            // ----- Reset tagged tables -----
            for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                for (int e = 0; e < TAGE_TABLE_ENTRIES; e++) begin
                    tage_valid[t][e]  <= 1'b0;
                    tage_tags[t][e]   <= '0;
                    tage_ctrs[t][e]   <= '0;
                    tage_useful[t][e] <= '0;
                end
            end
            // ----- Reset SC -----
            for (int i = 0; i < SC_ENTRIES; i++) begin
                sc_table[i] <= '0;
            end
            // ----- Reset loop predictor -----
            for (int i = 0; i < LOOP_PRED_ENTRIES; i++) begin
                loop_valid[i] <= 1'b0;
                loop_tags[i]  <= '0;
                loop_count[i] <= '0;
                loop_limit[i] <= '0;
                loop_conf[i]  <= '0;
                loop_dir[i]   <= 1'b0;
            end
            branch_count_r <= '0;
        end else if (update_valid) begin
            branch_count_r <= branch_count_r + 1'b1;

            // =================================================================
            //  (1) Base predictor update
            // =================================================================
            if (update_taken) begin
                base_table[upd_base_idx] <= ((base_table[upd_base_idx] == {BASE_CTR_BITS{1'b1}}) ? base_table[upd_base_idx] : base_table[upd_base_idx] + {{(BASE_CTR_BITS-1){1'b0}}, 1'b1});
            end else begin
                base_table[upd_base_idx] <= ((base_table[upd_base_idx] == '0) ? base_table[upd_base_idx] : base_table[upd_base_idx] - {{(BASE_CTR_BITS-1){1'b0}}, 1'b1});
            end

            // =================================================================
            //  (2) Tagged tables update
            // =================================================================
            if (upd_any_hit) begin
                // Provider was correct: bump useful
                if (!update_mispredict) begin
                    tage_useful[upd_provider][upd_tage_idx[upd_provider]] <=
                        ((tage_useful[upd_provider][upd_tage_idx[upd_provider]] == {USEFUL_BITS{1'b1}}) ? tage_useful[upd_provider][upd_tage_idx[upd_provider]] : tage_useful[upd_provider][upd_tage_idx[upd_provider]] + {{(USEFUL_BITS-1){1'b0}}, 1'b1});
                end else begin
                    // Provider was wrong: decrement useful and adjust counter
                    tage_useful[upd_provider][upd_tage_idx[upd_provider]] <=
                        ((tage_useful[upd_provider][upd_tage_idx[upd_provider]] == '0) ? tage_useful[upd_provider][upd_tage_idx[upd_provider]] : tage_useful[upd_provider][upd_tage_idx[upd_provider]] - {{(USEFUL_BITS-1){1'b0}}, 1'b1});

                    if (update_taken) begin
                        tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] <=
                            ((tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] == {TAGE_CTR_BITS{1'b1}}) ? tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] : tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] + {{(TAGE_CTR_BITS-1){1'b0}}, 1'b1});
                    end else begin
                        tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] <=
                            ((tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] == '0) ? tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] : tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] - {{(TAGE_CTR_BITS-1){1'b0}}, 1'b1});
                    end

                    // Allocate in a longer table if one exists
                    for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                        if ((2'(t) > upd_provider) && !upd_tage_hit[t]) begin
                            // Steal entry with useful == 0
                            if (tage_useful[t][upd_tage_idx[t]] == '0 ||
                                !tage_valid[t][upd_tage_idx[t]]) begin
                                tage_valid[t][upd_tage_idx[t]]  <= 1'b1;
                                tage_tags[t][upd_tage_idx[t]]   <= upd_tage_tag[t];
                                tage_ctrs[t][upd_tage_idx[t]]   <= update_taken ? 3'd4 : 3'd3;
                                tage_useful[t][upd_tage_idx[t]] <= '0;
                            end
                        end
                    end
                end

                // Update provider counter toward correct direction (even on correct)
                if (!update_mispredict) begin
                    if (update_taken) begin
                        tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] <=
                            ((tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] == {TAGE_CTR_BITS{1'b1}}) ? tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] : tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] + {{(TAGE_CTR_BITS-1){1'b0}}, 1'b1});
                    end else begin
                        tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] <=
                            ((tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] == '0) ? tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] : tage_ctrs[upd_provider][upd_tage_idx[upd_provider]] - {{(TAGE_CTR_BITS-1){1'b0}}, 1'b1});
                    end
                end
            end

            // Periodic reset of all useful counters
            if (branch_count_r == '1) begin
                for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                    for (int e = 0; e < TAGE_TABLE_ENTRIES; e++) begin
                        tage_useful[t][e] <= tage_useful[t][e] >> 1;
                    end
                end
            end

            // =================================================================
            //  (3) SC update
            // =================================================================
            if (update_taken) begin
                sc_table[upd_sc_idx] <= ((sc_table[upd_sc_idx] == $signed({1'b0, {(SC_CTR_BITS-1){1'b1}}})) ? sc_table[upd_sc_idx] : sc_table[upd_sc_idx] + 6'(1));
            end else begin
                sc_table[upd_sc_idx] <= ((sc_table[upd_sc_idx] == $signed({1'b1, {(SC_CTR_BITS-1){1'b0}}})) ? sc_table[upd_sc_idx] : sc_table[upd_sc_idx] - 6'(1));
            end

            // =================================================================
            //  (4) Loop predictor update
            // =================================================================
            if (upd_loop_hit) begin
                if (update_taken) begin
                    // Branch taken — still in loop, increment count
                    loop_count[upd_loop_idx] <= loop_count[upd_loop_idx] + 14'd1;
                end else begin
                    // Branch not taken — loop exit
                    if (loop_count[upd_loop_idx] == loop_limit[upd_loop_idx]) begin
                        // Correct exit: boost confidence
                        loop_conf[upd_loop_idx]  <= loop_conf[upd_loop_idx] |
                                                    ((loop_conf[upd_loop_idx] != {LOOP_CONF_BITS{1'b1}})
                                                     ? {{(LOOP_CONF_BITS-1){1'b0}}, 1'b1} : '0);
                    end else begin
                        // Wrong limit — update limit, reset confidence
                        loop_limit[upd_loop_idx] <= loop_count[upd_loop_idx];
                        loop_conf[upd_loop_idx]  <= '0;
                    end
                    loop_count[upd_loop_idx] <= '0;
                    loop_dir[upd_loop_idx]   <= update_taken;
                end
            end else begin
                // No loop entry — allocate on backward-taken branch
                if (update_taken) begin
                    loop_valid[upd_loop_idx] <= 1'b1;
                    loop_tags[upd_loop_idx]  <= upd_loop_tag;
                    loop_count[upd_loop_idx] <= 14'd1;
                    loop_limit[upd_loop_idx] <= '0;
                    loop_conf[upd_loop_idx]  <= '0;
                    loop_dir[upd_loop_idx]   <= 1'b1;
                end
            end
        end // update_valid
    end

endmodule
