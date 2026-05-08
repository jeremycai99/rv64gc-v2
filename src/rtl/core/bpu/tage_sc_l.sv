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
    input  logic [63:0] target,
    output logic        pred_taken,
    output logic        pred_confident,   // high confidence -> no checkpoint needed
    input  logic [63:0] aux_pc,
    input  logic [63:0] aux_target,
    input  logic [GHR_BITS-1:0] aux_ghr,
    output logic        aux_pred_taken,
    output logic        aux_pred_confident,

    // Update (from commit — actual branch outcome)
    input  logic        update_valid,
    input  logic [63:0] update_pc,
    input  logic [63:0] update_target,
    input  logic        update_taken,
    input  logic        update_mispredict,
    input  logic [GHR_BITS-1:0] update_ghr,

    // GHR management
    input  logic        spec_update_valid,  // speculatively shift GHR on prediction
    input  logic        spec_taken,
    input  logic [63:0] spec_pc,
    input  logic [63:0] spec_target,
    input  logic        loop_spec_update_valid,
    input  logic        loop_spec_taken,
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
    localparam int LOCAL_IDX_BITS  = 9;
    localparam int LOCAL_HIST_BITS = 1;
    localparam int LOCAL_PHT_BITS  = LOCAL_IDX_BITS + LOCAL_HIST_BITS;
    localparam int LOCAL_HIST_ENTRIES = (1 << LOCAL_IDX_BITS);
    localparam int LOCAL_PHT_ENTRIES  = (1 << LOCAL_PHT_BITS);
    localparam int LOCAL_BIAS_BITS = 3;
    localparam logic [LOCAL_BIAS_BITS-1:0] LOCAL_BIAS_STRONG_NT = '0;
    localparam logic [LOCAL_BIAS_BITS-1:0] LOCAL_BIAS_STRONG_T =
        {LOCAL_BIAS_BITS{1'b1}};

`ifdef SIMULATION
    logic sim_disable_local_pred;
    logic sim_enable_local_pht_override;

    initial begin
        sim_disable_local_pred = $test$plusargs("DISABLE_LOCAL_PRED");
        sim_enable_local_pht_override =
            $test$plusargs("ENABLE_LOCAL_PHT_OVERRIDE");
    end
`else
    localparam logic sim_disable_local_pred = 1'b0;
    localparam logic sim_enable_local_pht_override = 1'b0;
`endif

    // Geometric history lengths for the 4 tagged tables
    // (individual params for iverilog compatibility — no unpacked array params)
    localparam int GHR_LEN_0 = 8;
    localparam int GHR_LEN_1 = 16;
    localparam int GHR_LEN_2 = 32;
    localparam int GHR_LEN_3 = 64;
    wire [31:0] GHR_LENGTHS [0:TAGE_NUM_TABLES-1];
    assign GHR_LENGTHS[0] = GHR_LEN_0;
    assign GHR_LENGTHS[1] = GHR_LEN_1;
    assign GHR_LENGTHS[2] = GHR_LEN_2;
    assign GHR_LENGTHS[3] = GHR_LEN_3;

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
        end else if (ghr_restore_valid) begin
            ghr_r <= ghr_restore_val;
        end else if (flush) begin
            ghr_r <= '0;
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
    logic [TAGE_IDX_BITS-1:0] aux_fold_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] aux_fold_tag1 [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] aux_fold_tag2 [TAGE_NUM_TABLES];
    logic [TAGE_IDX_BITS-1:0] upd_fold_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] upd_fold_tag1 [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0] upd_fold_tag2 [TAGE_NUM_TABLES];

    always_comb begin
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            fold_idx[t] = '0;
            fold_tag1[t] = '0;
            fold_tag2[t] = '0;
            aux_fold_idx[t] = '0;
            aux_fold_tag1[t] = '0;
            aux_fold_tag2[t] = '0;
            upd_fold_idx[t] = '0;
            upd_fold_tag1[t] = '0;
            upd_fold_tag2[t] = '0;
            for (int i = 0; i < GHR_BITS; i++) begin
                if (i < GHR_LENGTHS[t]) begin
                    fold_idx[t][i % TAGE_IDX_BITS] = fold_idx[t][i % TAGE_IDX_BITS] ^ ghr_r[i];
                    fold_tag1[t][i % TAGE_TAG_BITS] = fold_tag1[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                    aux_fold_idx[t][i % TAGE_IDX_BITS] = aux_fold_idx[t][i % TAGE_IDX_BITS] ^ aux_ghr[i];
                    aux_fold_tag1[t][i % TAGE_TAG_BITS] = aux_fold_tag1[t][i % TAGE_TAG_BITS] ^ aux_ghr[i];
                    upd_fold_idx[t][i % TAGE_IDX_BITS] = upd_fold_idx[t][i % TAGE_IDX_BITS] ^ update_ghr[i];
                    upd_fold_tag1[t][i % TAGE_TAG_BITS] = upd_fold_tag1[t][i % TAGE_TAG_BITS] ^ update_ghr[i];
                end
                if (i < (GHR_LENGTHS[t] + 3)) begin
                    fold_tag2[t][i % TAGE_TAG_BITS] = fold_tag2[t][i % TAGE_TAG_BITS] ^ ghr_r[i];
                    aux_fold_tag2[t][i % TAGE_TAG_BITS] = aux_fold_tag2[t][i % TAGE_TAG_BITS] ^ aux_ghr[i];
                    upd_fold_tag2[t][i % TAGE_TAG_BITS] = upd_fold_tag2[t][i % TAGE_TAG_BITS] ^ update_ghr[i];
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
    logic [BASE_IDX_BITS-1:0] aux_base_lkp_idx;
    logic                     aux_base_pred;

    assign base_lkp_idx = pc[BASE_IDX_BITS+1:2];
    assign base_pred    = base_table[base_lkp_idx][BASE_CTR_BITS-1]; // >= 2
    assign aux_base_lkp_idx = aux_pc[BASE_IDX_BITS+1:2];
    assign aux_base_pred    = base_table[aux_base_lkp_idx][BASE_CTR_BITS-1];

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
    logic [TAGE_IDX_BITS-1:0]  aux_tage_lkp_idx [TAGE_NUM_TABLES];
    logic [TAGE_TAG_BITS-1:0]  aux_tage_lkp_tag [TAGE_NUM_TABLES];
    logic                      aux_tage_hit     [TAGE_NUM_TABLES];
    logic [TAGE_CTR_BITS-1:0]  aux_tage_hit_ctr [TAGE_NUM_TABLES];

    // Provider selection: longest-matching table
    logic                      tage_any_hit;
    logic [1:0]                tage_provider;        // table index of provider
    logic                      tage_pred;
    logic                      tage_pred_weak;       // counter near threshold
    logic                      aux_tage_any_hit;
    logic [1:0]                aux_tage_provider;
    logic                      aux_tage_pred;
    logic                      aux_tage_pred_weak;

    always_comb begin
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            tage_lkp_idx[t] = pc[TAGE_IDX_BITS+1:2] ^ fold_idx[t] ^ TAGE_IDX_BITS'(pc[21:12] >> t);
            tage_lkp_tag[t] = pc[TAGE_TAG_BITS+1:2] ^ fold_tag1[t] ^ fold_tag2[t];
            tage_hit[t]     = tage_valid[t][tage_lkp_idx[t]] &&
                              (tage_tags[t][tage_lkp_idx[t]] == tage_lkp_tag[t]);
            tage_hit_ctr[t] = tage_ctrs[t][tage_lkp_idx[t]];
            aux_tage_lkp_idx[t] = aux_pc[TAGE_IDX_BITS+1:2] ^ aux_fold_idx[t] ^
                                  TAGE_IDX_BITS'(aux_pc[21:12] >> t);
            aux_tage_lkp_tag[t] = aux_pc[TAGE_TAG_BITS+1:2] ^ aux_fold_tag1[t] ^
                                  aux_fold_tag2[t];
            aux_tage_hit[t]     = tage_valid[t][aux_tage_lkp_idx[t]] &&
                                  (tage_tags[t][aux_tage_lkp_idx[t]] == aux_tage_lkp_tag[t]);
            aux_tage_hit_ctr[t] = tage_ctrs[t][aux_tage_lkp_idx[t]];
        end

        // Provider = longest-matching (highest-index) table
        tage_any_hit  = 1'b0;
        tage_provider = 2'd0;
        tage_pred     = base_pred;
        tage_pred_weak = 1'b0;
        aux_tage_any_hit  = 1'b0;
        aux_tage_provider = 2'd0;
        aux_tage_pred     = aux_base_pred;
        aux_tage_pred_weak = 1'b0;

        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            if (tage_hit[t]) begin
                tage_any_hit  = 1'b1;
                tage_provider = 2'(t);
                tage_pred     = tage_hit_ctr[t] >= 3'(TAGE_CTR_BITS'(1) << (TAGE_CTR_BITS - 1));
            end
            if (aux_tage_hit[t]) begin
                aux_tage_any_hit  = 1'b1;
                aux_tage_provider = 2'(t);
                aux_tage_pred     = aux_tage_hit_ctr[t] >= 3'(TAGE_CTR_BITS'(1) << (TAGE_CTR_BITS - 1));
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

        if (aux_tage_any_hit) begin
            aux_tage_pred_weak = (aux_tage_hit_ctr[aux_tage_provider] == 3'd3) ||
                                 (aux_tage_hit_ctr[aux_tage_provider] == 3'd4);
        end else begin
            aux_tage_pred_weak = (base_table[aux_base_lkp_idx] == 2'd1) ||
                                 (base_table[aux_base_lkp_idx] == 2'd2);
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
    logic [SC_IDX_BITS-1:0]        aux_sc_lkp_idx;
    logic signed [SC_CTR_BITS-1:0] aux_sc_ctr_val;
    logic signed [SC_CTR_BITS:0]   aux_sc_sum;
    logic                          aux_sc_override;
    logic                          aux_sc_pred;

    assign sc_lkp_idx = pc[SC_IDX_BITS+1:2] ^ SC_IDX_BITS'(ghr_r[7:0]);
    assign sc_ctr_val = sc_table[sc_lkp_idx];
    assign aux_sc_lkp_idx = aux_pc[SC_IDX_BITS+1:2] ^ SC_IDX_BITS'(aux_ghr[7:0]);
    assign aux_sc_ctr_val = sc_table[aux_sc_lkp_idx];

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

        if (aux_tage_pred_weak) begin
            aux_sc_sum = aux_tage_pred ? (aux_sc_ctr_val + 7'(1))
                                       : (aux_sc_ctr_val - 7'(1));
        end else begin
            aux_sc_sum = aux_tage_pred ? (aux_sc_ctr_val + 7'(2))
                                       : (aux_sc_ctr_val - 7'(2));
        end

        aux_sc_override = 1'b0;
        aux_sc_pred     = aux_tage_pred;
        if (aux_tage_pred_weak) begin
            if (aux_tage_pred && (aux_sc_sum < 0)) begin
                aux_sc_override = 1'b1;
                aux_sc_pred     = 1'b0;
            end else if (!aux_tage_pred && (aux_sc_sum >= 0)) begin
                aux_sc_override = 1'b1;
                aux_sc_pred     = 1'b1;
            end
        end
    end

    // =========================================================================
    //  3b. Local-history direction component
    //
    // Dhrystone has a hot forward conditional at 0x8000216a with an alternating
    // not-taken/taken pattern. A commit-trained local PHT sees stale history
    // when the same branch is fetched twice before the older copy resolves, so
    // add a forward-branch alternation detector with speculative last-outcome
    // state. Backward loop branches remain owned by the loop predictor.
    // =========================================================================
    logic [LOCAL_HIST_BITS-1:0] local_hist [LOCAL_HIST_ENTRIES];
    logic [BASE_CTR_BITS-1:0]   local_pht  [LOCAL_PHT_ENTRIES];
    logic                       local_last_actual [LOCAL_HIST_ENTRIES];
    logic                       local_last_spec   [LOCAL_HIST_ENTRIES];
    logic [1:0]                 local_alt_conf    [LOCAL_HIST_ENTRIES];
    logic [LOCAL_BIAS_BITS-1:0] local_bias         [LOCAL_HIST_ENTRIES];

    logic [LOCAL_IDX_BITS-1:0]  local_idx;
    logic [LOCAL_IDX_BITS-1:0]  aux_local_idx;
    logic [LOCAL_IDX_BITS-1:0]  upd_local_idx;
    logic [LOCAL_IDX_BITS-1:0]  spec_local_idx;
    logic [LOCAL_PHT_BITS-1:0]  local_pht_idx;
    logic [LOCAL_PHT_BITS-1:0]  aux_local_pht_idx;
    logic [LOCAL_PHT_BITS-1:0]  upd_local_pht_idx;
    logic [LOCAL_HIST_BITS-1:0] local_hist_val;
    logic [LOCAL_HIST_BITS-1:0] aux_local_hist_val;
    logic [LOCAL_HIST_BITS-1:0] upd_local_hist_val;
    logic [BASE_CTR_BITS-1:0]   local_ctr_val;
    logic [BASE_CTR_BITS-1:0]   aux_local_ctr_val;
    logic                       local_pred;
    logic                       local_strong;
    logic                       local_forward;
    logic                       local_override;
    logic                       local_alt_pred;
    logic                       local_alt_strong;
    logic [LOCAL_BIAS_BITS-1:0] local_bias_val;
    logic                       local_bias_against_alt;
    logic                       aux_local_pred;
    logic                       aux_local_strong;
    logic                       aux_local_forward;
    logic                       aux_local_override;
    logic                       aux_local_alt_pred;
    logic                       aux_local_alt_strong;
    logic [LOCAL_BIAS_BITS-1:0] aux_local_bias_val;
    logic                       aux_local_bias_against_alt;
    logic                       upd_local_forward;
    logic                       upd_local_alternates;

    assign local_idx = pc[LOCAL_IDX_BITS+1:2] ^
                       LOCAL_IDX_BITS'(pc[20:12]);
    assign aux_local_idx = aux_pc[LOCAL_IDX_BITS+1:2] ^
                           LOCAL_IDX_BITS'(aux_pc[20:12]);
    assign upd_local_idx = update_pc[LOCAL_IDX_BITS+1:2] ^
                           LOCAL_IDX_BITS'(update_pc[20:12]);
    assign spec_local_idx = spec_pc[LOCAL_IDX_BITS+1:2] ^
                            LOCAL_IDX_BITS'(spec_pc[20:12]);

    assign local_hist_val = local_hist[local_idx];
    assign aux_local_hist_val = local_hist[aux_local_idx];
    assign upd_local_hist_val = local_hist[upd_local_idx];

    assign local_pht_idx = {local_idx, local_hist_val};
    assign aux_local_pht_idx = {aux_local_idx, aux_local_hist_val};
    assign upd_local_pht_idx = {upd_local_idx, upd_local_hist_val};

    assign local_ctr_val = local_pht[local_pht_idx];
    assign aux_local_ctr_val = local_pht[aux_local_pht_idx];
    assign local_alt_pred = ~local_last_spec[local_idx];
    assign aux_local_alt_pred = ~local_last_spec[aux_local_idx];
    assign local_alt_strong = (local_alt_conf[local_idx] == 2'd3);
    assign aux_local_alt_strong = (local_alt_conf[aux_local_idx] == 2'd3);
    assign local_bias_val = local_bias[local_idx];
    assign aux_local_bias_val = local_bias[aux_local_idx];
    assign local_bias_against_alt =
        (local_alt_pred && (local_bias_val == LOCAL_BIAS_STRONG_NT)) ||
        (!local_alt_pred && (local_bias_val == LOCAL_BIAS_STRONG_T));
    assign aux_local_bias_against_alt =
        (aux_local_alt_pred && (aux_local_bias_val == LOCAL_BIAS_STRONG_NT)) ||
        (!aux_local_alt_pred && (aux_local_bias_val == LOCAL_BIAS_STRONG_T));
    assign local_pred = local_alt_strong ? local_alt_pred
                                         : local_ctr_val[BASE_CTR_BITS-1];
    assign aux_local_pred = aux_local_alt_strong ? aux_local_alt_pred
                                                 : aux_local_ctr_val[BASE_CTR_BITS-1];
    assign local_strong = local_alt_strong ||
                          (local_ctr_val == 2'd0) ||
                          (local_ctr_val == 2'd3);
    assign aux_local_strong = aux_local_alt_strong ||
                              (aux_local_ctr_val == 2'd0) ||
                              (aux_local_ctr_val == 2'd3);
    assign local_forward = (target != 64'd0) && (target > pc);
    assign aux_local_forward = (aux_target != 64'd0) && (aux_target > aux_pc);
    assign local_override =
        !sim_disable_local_pred &&
        local_forward &&
        ((local_alt_strong && tage_pred_weak && !local_bias_against_alt) ||
         (sim_enable_local_pht_override && local_strong));
    assign aux_local_override =
        !sim_disable_local_pred &&
        aux_local_forward &&
        ((aux_local_alt_strong && aux_tage_pred_weak && !aux_local_bias_against_alt) ||
         (sim_enable_local_pht_override && aux_local_strong));
    assign upd_local_forward = (update_target != 64'd0) && (update_target > update_pc);
    assign upd_local_alternates = update_taken != local_last_actual[upd_local_idx];

    // =========================================================================
    //  4. Loop Predictor
    //     {tag[11:0], count[13:0], limit[13:0], confidence[1:0], dir}
    // =========================================================================
    logic [LOOP_TAG_BITS-1:0]  loop_tags  [LOOP_PRED_ENTRIES];
    logic [LOOP_CNT_BITS-1:0]  loop_count [LOOP_PRED_ENTRIES];
    logic [LOOP_CNT_BITS-1:0]  loop_spec_count [LOOP_PRED_ENTRIES];
    logic [LOOP_CNT_BITS-1:0]  loop_limit [LOOP_PRED_ENTRIES];
    logic [LOOP_CONF_BITS-1:0] loop_conf  [LOOP_PRED_ENTRIES];
    // Per entry confidence for same cycle speculative-count bypass.
    logic [1:0]                loop_bypass_conf [LOOP_PRED_ENTRIES];
    logic                      loop_dir   [LOOP_PRED_ENTRIES];
    logic                      loop_valid [LOOP_PRED_ENTRIES];

    logic [LOOP_IDX_BITS-1:0]  loop_lkp_idx;
    logic [LOOP_TAG_BITS-1:0]  loop_lkp_tag;
    logic                      loop_hit;
    logic                      loop_pred;
    logic                      loop_confident;
    logic                      loop_override;
    logic [LOOP_IDX_BITS-1:0]  aux_loop_lkp_idx;
    logic [LOOP_TAG_BITS-1:0]  aux_loop_lkp_tag;
    logic                      aux_loop_hit;
    logic                      aux_loop_pred;
    logic                      aux_loop_confident;
    logic                      aux_loop_override;
    logic [LOOP_CNT_BITS-1:0]  loop_lookup_count;
    logic [LOOP_CNT_BITS-1:0]  aux_loop_lookup_count;
    logic [LOOP_IDX_BITS-1:0]  spec_loop_idx;
    logic [LOOP_TAG_BITS-1:0]  spec_loop_tag;
    logic                      spec_loop_hit;
    logic                      spec_loop_backward;
    logic                      loop_bypass_enabled;

    function automatic logic [LOOP_IDX_BITS-1:0] loop_idx_hash(input logic [63:0] pc_i);
        loop_idx_hash = pc_i[LOOP_IDX_BITS+1:2] ^
                        LOOP_IDX_BITS'(pc_i[13:8]) ^
                        LOOP_IDX_BITS'(pc_i[19:14]);
    endfunction

`ifdef SIMULATION
    logic sim_disable_loop_spec_count;

    initial begin
        sim_disable_loop_spec_count =
            $test$plusargs("NO_LOOP_SPEC_COUNT") ? 1'b1 : 1'b0;
    end
`else
    localparam logic sim_disable_loop_spec_count = 1'b0;
`endif

    assign loop_lkp_idx = loop_idx_hash(pc);
    assign loop_lkp_tag = pc[LOOP_TAG_BITS+1:2];
    assign aux_loop_lkp_idx = loop_idx_hash(aux_pc);
    assign aux_loop_lkp_tag = aux_pc[LOOP_TAG_BITS+1:2];
    assign loop_bypass_enabled = loop_bypass_conf[spec_loop_idx] >= 2'd2;

    always_comb begin
        if (!sim_disable_loop_spec_count) begin
            loop_lookup_count = loop_spec_count[loop_lkp_idx];
            aux_loop_lookup_count = loop_spec_count[aux_loop_lkp_idx];

            if (loop_spec_update_valid &&
                spec_loop_hit &&
                spec_loop_backward &&
                loop_bypass_enabled) begin
                if (spec_loop_idx == loop_lkp_idx) begin
                    loop_lookup_count = loop_spec_taken
                        ? loop_spec_count[loop_lkp_idx] + 14'd1
                        : '0;
                end
                if (spec_loop_idx == aux_loop_lkp_idx) begin
                    aux_loop_lookup_count = loop_spec_taken
                        ? loop_spec_count[aux_loop_lkp_idx] + 14'd1
                        : '0;
                end
            end
        end else begin
            loop_lookup_count = loop_count[loop_lkp_idx];
            aux_loop_lookup_count = loop_count[aux_loop_lkp_idx];
        end
    end

    always_comb begin
        loop_hit       = loop_valid[loop_lkp_idx] &&
                         (loop_tags[loop_lkp_idx] == loop_lkp_tag);
        loop_pred      = 1'b0;
        loop_confident = 1'b0;
        loop_override  = 1'b0;

        if (loop_hit) begin
            loop_confident = (loop_conf[loop_lkp_idx] == {LOOP_CONF_BITS{1'b1}});
            if (loop_lookup_count < loop_limit[loop_lkp_idx]) begin
                loop_pred = 1'b1;  // stay in loop
            end else begin
                loop_pred = 1'b0;  // exit loop
            end
            // Use the loop predictor as an exit corrector.  The base/TAGE
            // path already handles the common taken backedge; forcing taken
            // from the loop table on data-dependent backward branches is too
            // aggressive.
            loop_override = loop_confident && !loop_pred;
        end

        aux_loop_hit       = loop_valid[aux_loop_lkp_idx] &&
                             (loop_tags[aux_loop_lkp_idx] == aux_loop_lkp_tag);
        aux_loop_pred      = 1'b0;
        aux_loop_confident = 1'b0;
        aux_loop_override  = 1'b0;

        if (aux_loop_hit) begin
            aux_loop_confident = (loop_conf[aux_loop_lkp_idx] == {LOOP_CONF_BITS{1'b1}});
            if (aux_loop_lookup_count < loop_limit[aux_loop_lkp_idx]) begin
                aux_loop_pred = 1'b1;
            end else begin
                aux_loop_pred = 1'b0;
            end
            aux_loop_override = aux_loop_confident && !aux_loop_pred;
        end
    end

    // =========================================================================
    //  Final prediction mux
    // =========================================================================
    always_comb begin
        if (loop_override) begin
            pred_taken = loop_pred;
        end else if (local_override) begin
            pred_taken = local_pred;
        end else begin
            pred_taken = sc_pred;
        end

        // Confidence: high if loop overrides, or if TAGE was strong and SC agreed
        pred_confident = loop_override ||
                         local_override ||
                         (!tage_pred_weak && !sc_override);

        if (aux_loop_override) begin
            aux_pred_taken = aux_loop_pred;
        end else if (aux_local_override) begin
            aux_pred_taken = aux_local_pred;
        end else begin
            aux_pred_taken = aux_sc_pred;
        end

        aux_pred_confident = aux_loop_override ||
                             aux_local_override ||
                             (!aux_tage_pred_weak && !aux_sc_override);
    end

    // =========================================================================
    //  Update path hash signals
    // =========================================================================
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
    logic                     upd_loop_backward;
`ifdef SIMULATION
    // Hot-PC loop-predictor diagnostics. These are observational only and are
    // enabled by +TRACE_LOOPPRED, +PERF_PROFILE, or +STAT_DUMP.
    localparam int SIM_LOOPPRED_HOT_PCS = 8;
    localparam int SIM_BPU_HOT_PCS = 10;

    logic sim_looppred_en;
    logic sim_trace_looppred_en;
    logic sim_bpu_hot_en;
    integer sim_lp_primary_lookup      [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_primary_hit         [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_primary_override    [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_primary_pred_taken  [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_aux_lookup          [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_aux_hit             [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_aux_override        [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_aux_pred_taken      [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update              [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update_taken        [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update_not_taken    [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update_misp         [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update_backward     [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_update_hit          [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_exit_limit_match    [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_exit_limit_update   [0:SIM_LOOPPRED_HOT_PCS-1];
    integer sim_lp_conf_hist           [0:SIM_LOOPPRED_HOT_PCS-1][0:3];
    integer sim_bpu_primary_lookup     [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_taken      [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_confident  [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_loop_hit   [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_loop_ovr   [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_local_ovr  [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_tage_hit   [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_tage_weak  [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_primary_sc_ovr     [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_lookup         [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_taken          [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_confident      [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_loop_hit       [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_loop_ovr       [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_local_ovr      [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_tage_hit       [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_tage_weak      [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_aux_sc_ovr         [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update             [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_taken       [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_not_taken   [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_misp        [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_loop_hit    [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_tage_hit    [0:SIM_BPU_HOT_PCS-1];
    integer sim_bpu_update_provider    [0:SIM_BPU_HOT_PCS-1][0:3];

    logic   sim_watch_pc_valid;
    logic [63:0] sim_watch_pc;
    integer sim_watch_lp_primary_lookup;
    integer sim_watch_lp_primary_hit;
    integer sim_watch_lp_primary_override;
    integer sim_watch_lp_primary_pred_taken;
    integer sim_watch_lp_aux_lookup;
    integer sim_watch_lp_aux_hit;
    integer sim_watch_lp_aux_override;
    integer sim_watch_lp_aux_pred_taken;
    integer sim_watch_lp_update;
    integer sim_watch_lp_update_taken;
    integer sim_watch_lp_update_not_taken;
    integer sim_watch_lp_update_misp;
    integer sim_watch_lp_update_backward;
    integer sim_watch_lp_update_hit;
    integer sim_watch_lp_exit_limit_match;
    integer sim_watch_lp_exit_limit_update;
    integer sim_watch_lp_conf_hist [0:3];
    integer sim_watch_bpu_primary_lookup;
    integer sim_watch_bpu_primary_taken;
    integer sim_watch_bpu_primary_confident;
    integer sim_watch_bpu_primary_loop_hit;
    integer sim_watch_bpu_primary_loop_ovr;
    integer sim_watch_bpu_primary_local_ovr;
    integer sim_watch_bpu_primary_tage_hit;
    integer sim_watch_bpu_primary_tage_weak;
    integer sim_watch_bpu_primary_sc_ovr;
    integer sim_watch_bpu_aux_lookup;
    integer sim_watch_bpu_aux_taken;
    integer sim_watch_bpu_aux_confident;
    integer sim_watch_bpu_aux_loop_hit;
    integer sim_watch_bpu_aux_loop_ovr;
    integer sim_watch_bpu_aux_local_ovr;
    integer sim_watch_bpu_aux_tage_hit;
    integer sim_watch_bpu_aux_tage_weak;
    integer sim_watch_bpu_aux_sc_ovr;
    integer sim_watch_bpu_update;
    integer sim_watch_bpu_update_taken;
    integer sim_watch_bpu_update_not_taken;
    integer sim_watch_bpu_update_misp;
    integer sim_watch_bpu_update_loop_hit;
    integer sim_watch_bpu_update_tage_hit;
    integer sim_watch_bpu_update_provider [0:3];

    function automatic int sim_looppred_hot_idx(input logic [63:0] hot_pc);
        begin
            unique case (hot_pc)
                64'h0000_0000_8000_3176: sim_looppred_hot_idx = 0; // matrix_mul_matrix inner loop
                64'h0000_0000_8000_31ec: sim_looppred_hot_idx = 1; // matrix bitextract inner loop
                64'h0000_0000_8000_3aea: sim_looppred_hot_idx = 2; // crc16 byte0 loop
                64'h0000_0000_8000_3b12: sim_looppred_hot_idx = 3; // crc16 byte1 loop
                64'h0000_0000_8000_2446: sim_looppred_hot_idx = 4; // list reverse loop
                64'h0000_0000_8000_36b4: sim_looppred_hot_idx = 5; // state digit loop
                64'h0000_0000_8000_23ae: sim_looppred_hot_idx = 6; // mergesort compare select
                64'h0000_0000_8000_3710: sim_looppred_hot_idx = 7; // state exponent loop
                default:                 sim_looppred_hot_idx = -1;
            endcase
        end
    endfunction

    function automatic logic [63:0] sim_looppred_hot_pc(input int idx);
        begin
            unique case (idx)
                0: sim_looppred_hot_pc = 64'h0000_0000_8000_3176;
                1: sim_looppred_hot_pc = 64'h0000_0000_8000_31ec;
                2: sim_looppred_hot_pc = 64'h0000_0000_8000_3aea;
                3: sim_looppred_hot_pc = 64'h0000_0000_8000_3b12;
                4: sim_looppred_hot_pc = 64'h0000_0000_8000_2446;
                5: sim_looppred_hot_pc = 64'h0000_0000_8000_36b4;
                6: sim_looppred_hot_pc = 64'h0000_0000_8000_23ae;
                7: sim_looppred_hot_pc = 64'h0000_0000_8000_3710;
                default: sim_looppred_hot_pc = 64'd0;
            endcase
        end
    endfunction

    function automatic int sim_bpu_hot_idx(input logic [63:0] hot_pc);
        begin
            unique case (hot_pc)
                64'h0000_0000_8000_36b4: sim_bpu_hot_idx = 0; // state comma branch
                64'h0000_0000_8000_3176: sim_bpu_hot_idx = 1; // matrix inner loop
                64'h0000_0000_8000_31ec: sim_bpu_hot_idx = 2; // matrix bitextract inner loop
                64'h0000_0000_8000_3710: sim_bpu_hot_idx = 3; // state exponent branch
                64'h0000_0000_8000_23ae: sim_bpu_hot_idx = 4; // mergesort compare select
                64'h0000_0000_8000_2446: sim_bpu_hot_idx = 5; // list reverse loop
                64'h0000_0000_8000_36bc: sim_bpu_hot_idx = 6; // state decimal branch
                64'h0000_0000_8000_2380: sim_bpu_hot_idx = 7; // mergesort loop
                64'h0000_0000_8000_3b12: sim_bpu_hot_idx = 8; // crc16 byte1 loop
                64'h0000_0000_8000_3aea: sim_bpu_hot_idx = 9; // crc16 byte0 loop
                default:                 sim_bpu_hot_idx = -1;
            endcase
        end
    endfunction

    function automatic logic [63:0] sim_bpu_hot_pc(input int idx);
        begin
            unique case (idx)
                0: sim_bpu_hot_pc = 64'h0000_0000_8000_36b4;
                1: sim_bpu_hot_pc = 64'h0000_0000_8000_3176;
                2: sim_bpu_hot_pc = 64'h0000_0000_8000_31ec;
                3: sim_bpu_hot_pc = 64'h0000_0000_8000_3710;
                4: sim_bpu_hot_pc = 64'h0000_0000_8000_23ae;
                5: sim_bpu_hot_pc = 64'h0000_0000_8000_2446;
                6: sim_bpu_hot_pc = 64'h0000_0000_8000_36bc;
                7: sim_bpu_hot_pc = 64'h0000_0000_8000_2380;
                8: sim_bpu_hot_pc = 64'h0000_0000_8000_3b12;
                9: sim_bpu_hot_pc = 64'h0000_0000_8000_3aea;
                default: sim_bpu_hot_pc = 64'd0;
            endcase
        end
    endfunction

    initial begin
        sim_looppred_en =
            $test$plusargs("TRACE_LOOPPRED") ||
            $test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP");
        sim_trace_looppred_en = $test$plusargs("TRACE_LOOPPRED");
        sim_bpu_hot_en =
            $test$plusargs("TRACE_BPU_HOT") ||
            $test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP");
        sim_watch_pc_valid =
            $value$plusargs("LOOPPRED_WATCH_PC=%h", sim_watch_pc);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SIM_LOOPPRED_HOT_PCS; i++) begin
                sim_lp_primary_lookup[i]     <= 0;
                sim_lp_primary_hit[i]        <= 0;
                sim_lp_primary_override[i]   <= 0;
                sim_lp_primary_pred_taken[i] <= 0;
                sim_lp_aux_lookup[i]         <= 0;
                sim_lp_aux_hit[i]            <= 0;
                sim_lp_aux_override[i]       <= 0;
                sim_lp_aux_pred_taken[i]     <= 0;
                sim_lp_update[i]             <= 0;
                sim_lp_update_taken[i]       <= 0;
                sim_lp_update_not_taken[i]   <= 0;
                sim_lp_update_misp[i]        <= 0;
                sim_lp_update_backward[i]    <= 0;
                sim_lp_update_hit[i]         <= 0;
                sim_lp_exit_limit_match[i]   <= 0;
                sim_lp_exit_limit_update[i]  <= 0;
                for (int c = 0; c < 4; c++) begin
                    sim_lp_conf_hist[i][c] <= 0;
                end
            end
            for (int i = 0; i < SIM_BPU_HOT_PCS; i++) begin
                sim_bpu_primary_lookup[i]    <= 0;
                sim_bpu_primary_taken[i]     <= 0;
                sim_bpu_primary_confident[i] <= 0;
                sim_bpu_primary_loop_hit[i]  <= 0;
                sim_bpu_primary_loop_ovr[i]  <= 0;
                sim_bpu_primary_local_ovr[i] <= 0;
                sim_bpu_primary_tage_hit[i]  <= 0;
                sim_bpu_primary_tage_weak[i] <= 0;
                sim_bpu_primary_sc_ovr[i]    <= 0;
                sim_bpu_aux_lookup[i]        <= 0;
                sim_bpu_aux_taken[i]         <= 0;
                sim_bpu_aux_confident[i]     <= 0;
                sim_bpu_aux_loop_hit[i]      <= 0;
                sim_bpu_aux_loop_ovr[i]      <= 0;
                sim_bpu_aux_local_ovr[i]     <= 0;
                sim_bpu_aux_tage_hit[i]      <= 0;
                sim_bpu_aux_tage_weak[i]     <= 0;
                sim_bpu_aux_sc_ovr[i]        <= 0;
                sim_bpu_update[i]            <= 0;
                sim_bpu_update_taken[i]      <= 0;
                sim_bpu_update_not_taken[i]  <= 0;
                sim_bpu_update_misp[i]       <= 0;
                sim_bpu_update_loop_hit[i]   <= 0;
                sim_bpu_update_tage_hit[i]   <= 0;
                for (int t = 0; t < 4; t++) begin
                    sim_bpu_update_provider[i][t] <= 0;
                end
            end
            sim_watch_lp_primary_lookup <= 0;
            sim_watch_lp_primary_hit <= 0;
            sim_watch_lp_primary_override <= 0;
            sim_watch_lp_primary_pred_taken <= 0;
            sim_watch_lp_aux_lookup <= 0;
            sim_watch_lp_aux_hit <= 0;
            sim_watch_lp_aux_override <= 0;
            sim_watch_lp_aux_pred_taken <= 0;
            sim_watch_lp_update <= 0;
            sim_watch_lp_update_taken <= 0;
            sim_watch_lp_update_not_taken <= 0;
            sim_watch_lp_update_misp <= 0;
            sim_watch_lp_update_backward <= 0;
            sim_watch_lp_update_hit <= 0;
            sim_watch_lp_exit_limit_match <= 0;
            sim_watch_lp_exit_limit_update <= 0;
            for (int c = 0; c < 4; c++) begin
                sim_watch_lp_conf_hist[c] <= 0;
            end
            sim_watch_bpu_primary_lookup <= 0;
            sim_watch_bpu_primary_taken <= 0;
            sim_watch_bpu_primary_confident <= 0;
            sim_watch_bpu_primary_loop_hit <= 0;
            sim_watch_bpu_primary_loop_ovr <= 0;
            sim_watch_bpu_primary_local_ovr <= 0;
            sim_watch_bpu_primary_tage_hit <= 0;
            sim_watch_bpu_primary_tage_weak <= 0;
            sim_watch_bpu_primary_sc_ovr <= 0;
            sim_watch_bpu_aux_lookup <= 0;
            sim_watch_bpu_aux_taken <= 0;
            sim_watch_bpu_aux_confident <= 0;
            sim_watch_bpu_aux_loop_hit <= 0;
            sim_watch_bpu_aux_loop_ovr <= 0;
            sim_watch_bpu_aux_local_ovr <= 0;
            sim_watch_bpu_aux_tage_hit <= 0;
            sim_watch_bpu_aux_tage_weak <= 0;
            sim_watch_bpu_aux_sc_ovr <= 0;
            sim_watch_bpu_update <= 0;
            sim_watch_bpu_update_taken <= 0;
            sim_watch_bpu_update_not_taken <= 0;
            sim_watch_bpu_update_misp <= 0;
            sim_watch_bpu_update_loop_hit <= 0;
            sim_watch_bpu_update_tage_hit <= 0;
            for (int t = 0; t < 4; t++) begin
                sim_watch_bpu_update_provider[t] <= 0;
            end
        end else if (sim_looppred_en) begin
            int pidx;
            int aidx;
            int uidx;

            pidx = sim_looppred_hot_idx(pc);
            if (pidx >= 0) begin
                sim_lp_primary_lookup[pidx] <= sim_lp_primary_lookup[pidx] + 1;
                if (loop_hit)
                    sim_lp_primary_hit[pidx] <= sim_lp_primary_hit[pidx] + 1;
                if (loop_override)
                    sim_lp_primary_override[pidx] <= sim_lp_primary_override[pidx] + 1;
                if (pred_taken)
                    sim_lp_primary_pred_taken[pidx] <= sim_lp_primary_pred_taken[pidx] + 1;
            end
            if (sim_watch_pc_valid && (pc == sim_watch_pc)) begin
                sim_watch_lp_primary_lookup <= sim_watch_lp_primary_lookup + 1;
                if (loop_hit)
                    sim_watch_lp_primary_hit <= sim_watch_lp_primary_hit + 1;
                if (loop_override)
                    sim_watch_lp_primary_override <=
                        sim_watch_lp_primary_override + 1;
                if (pred_taken)
                    sim_watch_lp_primary_pred_taken <=
                        sim_watch_lp_primary_pred_taken + 1;
            end

            aidx = sim_looppred_hot_idx(aux_pc);
            if (aidx >= 0) begin
                sim_lp_aux_lookup[aidx] <= sim_lp_aux_lookup[aidx] + 1;
                if (aux_loop_hit)
                    sim_lp_aux_hit[aidx] <= sim_lp_aux_hit[aidx] + 1;
                if (aux_loop_override)
                    sim_lp_aux_override[aidx] <= sim_lp_aux_override[aidx] + 1;
                if (aux_pred_taken)
                    sim_lp_aux_pred_taken[aidx] <= sim_lp_aux_pred_taken[aidx] + 1;
            end
            if (sim_watch_pc_valid && (aux_pc == sim_watch_pc)) begin
                sim_watch_lp_aux_lookup <= sim_watch_lp_aux_lookup + 1;
                if (aux_loop_hit)
                    sim_watch_lp_aux_hit <= sim_watch_lp_aux_hit + 1;
                if (aux_loop_override)
                    sim_watch_lp_aux_override <= sim_watch_lp_aux_override + 1;
                if (aux_pred_taken)
                    sim_watch_lp_aux_pred_taken <=
                        sim_watch_lp_aux_pred_taken + 1;
            end

            uidx = sim_looppred_hot_idx(update_pc);
            if (update_valid && (uidx >= 0)) begin
                sim_lp_update[uidx] <= sim_lp_update[uidx] + 1;
                if (update_taken)
                    sim_lp_update_taken[uidx] <= sim_lp_update_taken[uidx] + 1;
                else
                    sim_lp_update_not_taken[uidx] <= sim_lp_update_not_taken[uidx] + 1;
                if (update_mispredict)
                    sim_lp_update_misp[uidx] <= sim_lp_update_misp[uidx] + 1;
                if (upd_loop_backward)
                    sim_lp_update_backward[uidx] <= sim_lp_update_backward[uidx] + 1;
                if (upd_loop_hit)
                    sim_lp_update_hit[uidx] <= sim_lp_update_hit[uidx] + 1;

                if (upd_loop_hit) begin
                    sim_lp_conf_hist[uidx][loop_conf[upd_loop_idx]] <=
                        sim_lp_conf_hist[uidx][loop_conf[upd_loop_idx]] + 1;
                end

                if (upd_loop_hit && upd_loop_backward && !update_taken) begin
                    if (loop_count[upd_loop_idx] == loop_limit[upd_loop_idx])
                        sim_lp_exit_limit_match[uidx] <=
                            sim_lp_exit_limit_match[uidx] + 1;
                    else
                        sim_lp_exit_limit_update[uidx] <=
                            sim_lp_exit_limit_update[uidx] + 1;
                end

                if (sim_trace_looppred_en) begin
                    $display("[LOOPPRED_UPD] pc=%016h taken=%b misp=%b back=%b hit=%b count=%0d limit=%0d conf=%0d pred_p=%b pred_a=%b lp_p_hit=%b lp_a_hit=%b lp_p_ovr=%b lp_a_ovr=%b",
                             update_pc, update_taken, update_mispredict,
                             upd_loop_backward, upd_loop_hit,
                             upd_loop_hit ? loop_count[upd_loop_idx] : 14'd0,
                             upd_loop_hit ? loop_limit[upd_loop_idx] : 14'd0,
                             upd_loop_hit ? loop_conf[upd_loop_idx] : 2'd0,
                             pred_taken, aux_pred_taken,
                             loop_hit, aux_loop_hit,
                             loop_override, aux_loop_override);
                end
            end
            if (update_valid && sim_watch_pc_valid &&
                (update_pc == sim_watch_pc)) begin
                sim_watch_lp_update <= sim_watch_lp_update + 1;
                if (update_taken)
                    sim_watch_lp_update_taken <=
                        sim_watch_lp_update_taken + 1;
                else
                    sim_watch_lp_update_not_taken <=
                        sim_watch_lp_update_not_taken + 1;
                if (update_mispredict)
                    sim_watch_lp_update_misp <= sim_watch_lp_update_misp + 1;
                if (upd_loop_backward)
                    sim_watch_lp_update_backward <=
                        sim_watch_lp_update_backward + 1;
                if (upd_loop_hit)
                    sim_watch_lp_update_hit <= sim_watch_lp_update_hit + 1;
                if (upd_loop_hit) begin
                    sim_watch_lp_conf_hist[loop_conf[upd_loop_idx]] <=
                        sim_watch_lp_conf_hist[loop_conf[upd_loop_idx]] + 1;
                end
                if (upd_loop_hit && upd_loop_backward && !update_taken) begin
                    if (loop_count[upd_loop_idx] == loop_limit[upd_loop_idx])
                        sim_watch_lp_exit_limit_match <=
                            sim_watch_lp_exit_limit_match + 1;
                    else
                        sim_watch_lp_exit_limit_update <=
                            sim_watch_lp_exit_limit_update + 1;
                end
                if (sim_trace_looppred_en) begin
                    $display("[LOOPPRED_WATCH_UPD] pc=%016h taken=%b misp=%b back=%b hit=%b idx=%0d tag=%0h count=%0d spec=%0d limit=%0d conf=%0d",
                             update_pc, update_taken, update_mispredict,
                             upd_loop_backward, upd_loop_hit,
                             upd_loop_idx, upd_loop_tag,
                             upd_loop_hit ? loop_count[upd_loop_idx] : 14'd0,
                             upd_loop_hit ? loop_spec_count[upd_loop_idx] : 14'd0,
                             upd_loop_hit ? loop_limit[upd_loop_idx] : 14'd0,
                             upd_loop_hit ? loop_conf[upd_loop_idx] : 2'd0);
                end
            end
        end

        if (sim_bpu_hot_en) begin
            int bpu_pidx;
            int bpu_aidx;
            int bpu_uidx;

            bpu_pidx = sim_bpu_hot_idx(pc);
            if (bpu_pidx >= 0) begin
                sim_bpu_primary_lookup[bpu_pidx] <=
                    sim_bpu_primary_lookup[bpu_pidx] + 1;
                if (pred_taken)
                    sim_bpu_primary_taken[bpu_pidx] <=
                        sim_bpu_primary_taken[bpu_pidx] + 1;
                if (pred_confident)
                    sim_bpu_primary_confident[bpu_pidx] <=
                        sim_bpu_primary_confident[bpu_pidx] + 1;
                if (loop_hit)
                    sim_bpu_primary_loop_hit[bpu_pidx] <=
                        sim_bpu_primary_loop_hit[bpu_pidx] + 1;
                if (loop_override)
                    sim_bpu_primary_loop_ovr[bpu_pidx] <=
                        sim_bpu_primary_loop_ovr[bpu_pidx] + 1;
                if (local_override)
                    sim_bpu_primary_local_ovr[bpu_pidx] <=
                        sim_bpu_primary_local_ovr[bpu_pidx] + 1;
                if (tage_any_hit)
                    sim_bpu_primary_tage_hit[bpu_pidx] <=
                        sim_bpu_primary_tage_hit[bpu_pidx] + 1;
                if (tage_pred_weak)
                    sim_bpu_primary_tage_weak[bpu_pidx] <=
                        sim_bpu_primary_tage_weak[bpu_pidx] + 1;
                if (sc_override)
                    sim_bpu_primary_sc_ovr[bpu_pidx] <=
                        sim_bpu_primary_sc_ovr[bpu_pidx] + 1;
            end
            if (sim_watch_pc_valid && (pc == sim_watch_pc)) begin
                sim_watch_bpu_primary_lookup <=
                    sim_watch_bpu_primary_lookup + 1;
                if (pred_taken)
                    sim_watch_bpu_primary_taken <=
                        sim_watch_bpu_primary_taken + 1;
                if (pred_confident)
                    sim_watch_bpu_primary_confident <=
                        sim_watch_bpu_primary_confident + 1;
                if (loop_hit)
                    sim_watch_bpu_primary_loop_hit <=
                        sim_watch_bpu_primary_loop_hit + 1;
                if (loop_override)
                    sim_watch_bpu_primary_loop_ovr <=
                        sim_watch_bpu_primary_loop_ovr + 1;
                if (local_override)
                    sim_watch_bpu_primary_local_ovr <=
                        sim_watch_bpu_primary_local_ovr + 1;
                if (tage_any_hit)
                    sim_watch_bpu_primary_tage_hit <=
                        sim_watch_bpu_primary_tage_hit + 1;
                if (tage_pred_weak)
                    sim_watch_bpu_primary_tage_weak <=
                        sim_watch_bpu_primary_tage_weak + 1;
                if (sc_override)
                    sim_watch_bpu_primary_sc_ovr <=
                        sim_watch_bpu_primary_sc_ovr + 1;
            end

            bpu_aidx = sim_bpu_hot_idx(aux_pc);
            if (bpu_aidx >= 0) begin
                sim_bpu_aux_lookup[bpu_aidx] <=
                    sim_bpu_aux_lookup[bpu_aidx] + 1;
                if (aux_pred_taken)
                    sim_bpu_aux_taken[bpu_aidx] <=
                        sim_bpu_aux_taken[bpu_aidx] + 1;
                if (aux_pred_confident)
                    sim_bpu_aux_confident[bpu_aidx] <=
                        sim_bpu_aux_confident[bpu_aidx] + 1;
                if (aux_loop_hit)
                    sim_bpu_aux_loop_hit[bpu_aidx] <=
                        sim_bpu_aux_loop_hit[bpu_aidx] + 1;
                if (aux_loop_override)
                    sim_bpu_aux_loop_ovr[bpu_aidx] <=
                        sim_bpu_aux_loop_ovr[bpu_aidx] + 1;
                if (aux_local_override)
                    sim_bpu_aux_local_ovr[bpu_aidx] <=
                        sim_bpu_aux_local_ovr[bpu_aidx] + 1;
                if (aux_tage_any_hit)
                    sim_bpu_aux_tage_hit[bpu_aidx] <=
                        sim_bpu_aux_tage_hit[bpu_aidx] + 1;
                if (aux_tage_pred_weak)
                    sim_bpu_aux_tage_weak[bpu_aidx] <=
                        sim_bpu_aux_tage_weak[bpu_aidx] + 1;
                if (aux_sc_override)
                    sim_bpu_aux_sc_ovr[bpu_aidx] <=
                        sim_bpu_aux_sc_ovr[bpu_aidx] + 1;
            end
            if (sim_watch_pc_valid && (aux_pc == sim_watch_pc)) begin
                sim_watch_bpu_aux_lookup <= sim_watch_bpu_aux_lookup + 1;
                if (aux_pred_taken)
                    sim_watch_bpu_aux_taken <= sim_watch_bpu_aux_taken + 1;
                if (aux_pred_confident)
                    sim_watch_bpu_aux_confident <=
                        sim_watch_bpu_aux_confident + 1;
                if (aux_loop_hit)
                    sim_watch_bpu_aux_loop_hit <=
                        sim_watch_bpu_aux_loop_hit + 1;
                if (aux_loop_override)
                    sim_watch_bpu_aux_loop_ovr <=
                        sim_watch_bpu_aux_loop_ovr + 1;
                if (aux_local_override)
                    sim_watch_bpu_aux_local_ovr <=
                        sim_watch_bpu_aux_local_ovr + 1;
                if (aux_tage_any_hit)
                    sim_watch_bpu_aux_tage_hit <=
                        sim_watch_bpu_aux_tage_hit + 1;
                if (aux_tage_pred_weak)
                    sim_watch_bpu_aux_tage_weak <=
                        sim_watch_bpu_aux_tage_weak + 1;
                if (aux_sc_override)
                    sim_watch_bpu_aux_sc_ovr <= sim_watch_bpu_aux_sc_ovr + 1;
            end

            bpu_uidx = sim_bpu_hot_idx(update_pc);
            if (update_valid && (bpu_uidx >= 0)) begin
                sim_bpu_update[bpu_uidx] <=
                    sim_bpu_update[bpu_uidx] + 1;
                if (update_taken)
                    sim_bpu_update_taken[bpu_uidx] <=
                        sim_bpu_update_taken[bpu_uidx] + 1;
                else
                    sim_bpu_update_not_taken[bpu_uidx] <=
                        sim_bpu_update_not_taken[bpu_uidx] + 1;
                if (update_mispredict)
                    sim_bpu_update_misp[bpu_uidx] <=
                        sim_bpu_update_misp[bpu_uidx] + 1;
                if (upd_loop_hit)
                    sim_bpu_update_loop_hit[bpu_uidx] <=
                        sim_bpu_update_loop_hit[bpu_uidx] + 1;
                if (upd_any_hit) begin
                    sim_bpu_update_tage_hit[bpu_uidx] <=
                        sim_bpu_update_tage_hit[bpu_uidx] + 1;
                    sim_bpu_update_provider[bpu_uidx][upd_provider] <=
                        sim_bpu_update_provider[bpu_uidx][upd_provider] + 1;
                end
            end
            if (update_valid && sim_watch_pc_valid &&
                (update_pc == sim_watch_pc)) begin
                sim_watch_bpu_update <= sim_watch_bpu_update + 1;
                if (update_taken)
                    sim_watch_bpu_update_taken <=
                        sim_watch_bpu_update_taken + 1;
                else
                    sim_watch_bpu_update_not_taken <=
                        sim_watch_bpu_update_not_taken + 1;
                if (update_mispredict)
                    sim_watch_bpu_update_misp <=
                        sim_watch_bpu_update_misp + 1;
                if (upd_loop_hit)
                    sim_watch_bpu_update_loop_hit <=
                        sim_watch_bpu_update_loop_hit + 1;
                if (upd_any_hit) begin
                    sim_watch_bpu_update_tage_hit <=
                        sim_watch_bpu_update_tage_hit + 1;
                    sim_watch_bpu_update_provider[upd_provider] <=
                        sim_watch_bpu_update_provider[upd_provider] + 1;
                end
            end
        end
    end

    final begin
        if (sim_looppred_en) begin
            $display("");
            $display("=== LOOP PREDICTOR HOT-PC SUMMARY ===");
            $display("pc                 p_lkp/hit/ovr/taken  a_lkp/hit/ovr/taken  upd/t/nt/misp/back/hit  exit_match/update  conf0/1/2/3");
            for (int i = 0; i < SIM_LOOPPRED_HOT_PCS; i++) begin
                $display("%016h %0d/%0d/%0d/%0d %0d/%0d/%0d/%0d %0d/%0d/%0d/%0d/%0d/%0d %0d/%0d %0d/%0d/%0d/%0d",
                         sim_looppred_hot_pc(i),
                         sim_lp_primary_lookup[i],
                         sim_lp_primary_hit[i],
                         sim_lp_primary_override[i],
                         sim_lp_primary_pred_taken[i],
                         sim_lp_aux_lookup[i],
                         sim_lp_aux_hit[i],
                         sim_lp_aux_override[i],
                         sim_lp_aux_pred_taken[i],
                         sim_lp_update[i],
                         sim_lp_update_taken[i],
                         sim_lp_update_not_taken[i],
                         sim_lp_update_misp[i],
                         sim_lp_update_backward[i],
                         sim_lp_update_hit[i],
                         sim_lp_exit_limit_match[i],
                         sim_lp_exit_limit_update[i],
                         sim_lp_conf_hist[i][0],
                         sim_lp_conf_hist[i][1],
                         sim_lp_conf_hist[i][2],
                         sim_lp_conf_hist[i][3]);
            end
            if (sim_watch_pc_valid) begin
                $display("watch=%016h %0d/%0d/%0d/%0d %0d/%0d/%0d/%0d %0d/%0d/%0d/%0d/%0d/%0d %0d/%0d %0d/%0d/%0d/%0d",
                         sim_watch_pc,
                         sim_watch_lp_primary_lookup,
                         sim_watch_lp_primary_hit,
                         sim_watch_lp_primary_override,
                         sim_watch_lp_primary_pred_taken,
                         sim_watch_lp_aux_lookup,
                         sim_watch_lp_aux_hit,
                         sim_watch_lp_aux_override,
                         sim_watch_lp_aux_pred_taken,
                         sim_watch_lp_update,
                         sim_watch_lp_update_taken,
                         sim_watch_lp_update_not_taken,
                         sim_watch_lp_update_misp,
                         sim_watch_lp_update_backward,
                         sim_watch_lp_update_hit,
                         sim_watch_lp_exit_limit_match,
                         sim_watch_lp_exit_limit_update,
                         sim_watch_lp_conf_hist[0],
                         sim_watch_lp_conf_hist[1],
                         sim_watch_lp_conf_hist[2],
                         sim_watch_lp_conf_hist[3]);
            end
        end

        if (sim_bpu_hot_en) begin
            $display("");
            $display("=== BPU HOT-PC SUMMARY ===");
            $display("pc                 p(lkp tk cf lp/ovr loc tg wk sc)  a(lkp tk cf lp/ovr loc tg wk sc)  upd(t nt misp lp tg p0/1/2/3)");
            for (int i = 0; i < SIM_BPU_HOT_PCS; i++) begin
                $display("%016h %0d %0d %0d %0d/%0d %0d %0d %0d %0d  %0d %0d %0d %0d/%0d %0d %0d %0d %0d  %0d(%0d %0d %0d %0d %0d %0d/%0d/%0d/%0d)",
                         sim_bpu_hot_pc(i),
                         sim_bpu_primary_lookup[i],
                         sim_bpu_primary_taken[i],
                         sim_bpu_primary_confident[i],
                         sim_bpu_primary_loop_hit[i],
                         sim_bpu_primary_loop_ovr[i],
                         sim_bpu_primary_local_ovr[i],
                         sim_bpu_primary_tage_hit[i],
                         sim_bpu_primary_tage_weak[i],
                         sim_bpu_primary_sc_ovr[i],
                         sim_bpu_aux_lookup[i],
                         sim_bpu_aux_taken[i],
                         sim_bpu_aux_confident[i],
                         sim_bpu_aux_loop_hit[i],
                         sim_bpu_aux_loop_ovr[i],
                         sim_bpu_aux_local_ovr[i],
                         sim_bpu_aux_tage_hit[i],
                         sim_bpu_aux_tage_weak[i],
                         sim_bpu_aux_sc_ovr[i],
                         sim_bpu_update[i],
                         sim_bpu_update_taken[i],
                         sim_bpu_update_not_taken[i],
                         sim_bpu_update_misp[i],
                         sim_bpu_update_loop_hit[i],
                         sim_bpu_update_tage_hit[i],
                         sim_bpu_update_provider[i][0],
                         sim_bpu_update_provider[i][1],
                         sim_bpu_update_provider[i][2],
                         sim_bpu_update_provider[i][3]);
            end
            if (sim_watch_pc_valid) begin
                $display("watch=%016h %0d %0d %0d %0d/%0d %0d %0d %0d %0d  %0d %0d %0d %0d/%0d %0d %0d %0d %0d  %0d(%0d %0d %0d %0d %0d %0d/%0d/%0d/%0d)",
                         sim_watch_pc,
                         sim_watch_bpu_primary_lookup,
                         sim_watch_bpu_primary_taken,
                         sim_watch_bpu_primary_confident,
                         sim_watch_bpu_primary_loop_hit,
                         sim_watch_bpu_primary_loop_ovr,
                         sim_watch_bpu_primary_local_ovr,
                         sim_watch_bpu_primary_tage_hit,
                         sim_watch_bpu_primary_tage_weak,
                         sim_watch_bpu_primary_sc_ovr,
                         sim_watch_bpu_aux_lookup,
                         sim_watch_bpu_aux_taken,
                         sim_watch_bpu_aux_confident,
                         sim_watch_bpu_aux_loop_hit,
                         sim_watch_bpu_aux_loop_ovr,
                         sim_watch_bpu_aux_local_ovr,
                         sim_watch_bpu_aux_tage_hit,
                         sim_watch_bpu_aux_tage_weak,
                         sim_watch_bpu_aux_sc_ovr,
                         sim_watch_bpu_update,
                         sim_watch_bpu_update_taken,
                         sim_watch_bpu_update_not_taken,
                         sim_watch_bpu_update_misp,
                         sim_watch_bpu_update_loop_hit,
                         sim_watch_bpu_update_tage_hit,
                         sim_watch_bpu_update_provider[0],
                         sim_watch_bpu_update_provider[1],
                         sim_watch_bpu_update_provider[2],
                         sim_watch_bpu_update_provider[3]);
            end
        end
    end
`endif

    // Recompute update hashes
    always_comb begin
        upd_base_idx = update_pc[BASE_IDX_BITS+1:2];
        upd_sc_idx   = update_pc[SC_IDX_BITS+1:2] ^ SC_IDX_BITS'(update_ghr[7:0]);
        upd_loop_idx = loop_idx_hash(update_pc);
        upd_loop_tag = update_pc[LOOP_TAG_BITS+1:2];
        upd_loop_backward = (update_target < update_pc);

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
        spec_loop_idx = loop_idx_hash(spec_pc);
        spec_loop_tag = spec_pc[LOOP_TAG_BITS+1:2];
        spec_loop_backward = (spec_target < spec_pc);
        spec_loop_hit = loop_valid[spec_loop_idx] &&
                        (loop_tags[spec_loop_idx] == spec_loop_tag);
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
            // ----- Reset local-history component -----
            for (int i = 0; i < LOCAL_HIST_ENTRIES; i++) begin
                local_hist[i] <= '0;
                local_last_actual[i] <= 1'b0;
                local_last_spec[i] <= 1'b0;
                local_alt_conf[i] <= 2'd0;
                local_bias[i] <= 3'd3;
            end
            for (int i = 0; i < LOCAL_PHT_ENTRIES; i++) begin
                local_pht[i] <= 2'd1; // weakly not-taken
            end
            // ----- Reset loop predictor -----
            for (int i = 0; i < LOOP_PRED_ENTRIES; i++) begin
                loop_valid[i] <= 1'b0;
                loop_tags[i]  <= '0;
                loop_count[i] <= '0;
                loop_spec_count[i] <= '0;
                loop_limit[i] <= '0;
                loop_conf[i]  <= '0;
                loop_bypass_conf[i] <= 2'd0;
                loop_dir[i]   <= 1'b0;
            end
            branch_count_r <= '0;
        end else begin
            if (flush) begin
                for (int i = 0; i < LOOP_PRED_ENTRIES; i++) begin
                    loop_spec_count[i] <= loop_count[i];
                end
            end

            if (update_valid) begin
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
            end else if (update_mispredict) begin
                // Base-only misses must still seed tagged tables; otherwise
                // the predictor never graduates beyond the bimodal table.
                for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                    if (!upd_tage_hit[t]) begin
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
            //  (3b) Local-history update
            // =================================================================
            if (update_taken) begin
                local_pht[upd_local_pht_idx] <=
                    (local_pht[upd_local_pht_idx] == {BASE_CTR_BITS{1'b1}})
                        ? local_pht[upd_local_pht_idx]
                        : local_pht[upd_local_pht_idx] +
                          {{(BASE_CTR_BITS-1){1'b0}}, 1'b1};
            end else begin
                local_pht[upd_local_pht_idx] <=
                    (local_pht[upd_local_pht_idx] == '0)
                        ? local_pht[upd_local_pht_idx]
                        : local_pht[upd_local_pht_idx] -
                          {{(BASE_CTR_BITS-1){1'b0}}, 1'b1};
            end
            local_hist[upd_local_idx] <= update_taken;
            if (upd_local_forward) begin
                if (update_taken) begin
                    local_bias[upd_local_idx] <=
                        (local_bias[upd_local_idx] == {LOCAL_BIAS_BITS{1'b1}})
                            ? local_bias[upd_local_idx]
                            : local_bias[upd_local_idx] +
                              {{(LOCAL_BIAS_BITS-1){1'b0}}, 1'b1};
                end else begin
                    local_bias[upd_local_idx] <=
                        (local_bias[upd_local_idx] == '0)
                            ? local_bias[upd_local_idx]
                            : local_bias[upd_local_idx] -
                              {{(LOCAL_BIAS_BITS-1){1'b0}}, 1'b1};
                end
                if (upd_local_alternates) begin
                    local_alt_conf[upd_local_idx] <=
                        (local_alt_conf[upd_local_idx] == 2'd3)
                            ? local_alt_conf[upd_local_idx]
                            : local_alt_conf[upd_local_idx] + 2'd1;
                end else begin
                    local_alt_conf[upd_local_idx] <=
                        (local_alt_conf[upd_local_idx] == 2'd0)
                            ? local_alt_conf[upd_local_idx]
                            : local_alt_conf[upd_local_idx] - 2'd1;
                end
                local_last_actual[upd_local_idx] <= update_taken;
                local_last_spec[upd_local_idx]   <= update_taken;
            end

            // =================================================================
            //  (4) Loop predictor update
            // =================================================================
            if (upd_loop_hit && upd_loop_backward) begin
                if (update_taken) begin
                    // Branch taken — still in loop, increment count
                    loop_count[upd_loop_idx] <= loop_count[upd_loop_idx] + 14'd1;
                    if (flush)
                        loop_spec_count[upd_loop_idx] <= loop_count[upd_loop_idx] + 14'd1;
                end else begin
                    // Branch not taken — loop exit
                    if (loop_count[upd_loop_idx] == loop_limit[upd_loop_idx]) begin
                        // Correct exit: saturating confidence increment.
                        if (loop_conf[upd_loop_idx] != {LOOP_CONF_BITS{1'b1}}) begin
                            loop_conf[upd_loop_idx] <= loop_conf[upd_loop_idx] +
                                                       {{(LOOP_CONF_BITS-1){1'b0}}, 1'b1};
                        end
                        if (loop_conf[upd_loop_idx] == {LOOP_CONF_BITS{1'b1}}) begin
                            if (update_mispredict) begin
                                loop_bypass_conf[upd_loop_idx] <=
                                    (loop_bypass_conf[upd_loop_idx] == 2'd3)
                                        ? loop_bypass_conf[upd_loop_idx]
                                        : loop_bypass_conf[upd_loop_idx] + 2'd1;
                            end else begin
                                loop_bypass_conf[upd_loop_idx] <=
                                    (loop_bypass_conf[upd_loop_idx] == 2'd0)
                                        ? loop_bypass_conf[upd_loop_idx]
                                        : loop_bypass_conf[upd_loop_idx] - 2'd1;
                            end
                        end
                    end else begin
                        // Wrong limit — update limit, reset confidence
                        loop_limit[upd_loop_idx] <= loop_count[upd_loop_idx];
                        loop_conf[upd_loop_idx]  <= '0;
                        loop_bypass_conf[upd_loop_idx] <= 2'd0;
                    end
                    loop_count[upd_loop_idx] <= '0;
                    loop_spec_count[upd_loop_idx] <= '0;
                    loop_dir[upd_loop_idx]   <= update_taken;
                end
            end else begin
                // No loop entry — allocate only on backward-taken branches.
                if (update_taken && upd_loop_backward) begin
                    loop_valid[upd_loop_idx] <= 1'b1;
                    loop_tags[upd_loop_idx]  <= upd_loop_tag;
                    loop_count[upd_loop_idx] <= 14'd1;
                    loop_spec_count[upd_loop_idx] <= 14'd1;
                    loop_limit[upd_loop_idx] <= '0;
                    loop_conf[upd_loop_idx]  <= '0;
                    loop_bypass_conf[upd_loop_idx] <= 2'd0;
                    loop_dir[upd_loop_idx]   <= 1'b1;
                end
            end
            end // update_valid

            // The local-history predictor is used for forward conditionals.
            // Update the history speculatively so close back-to-back predictions
            // of the same branch do not both consume stale committed history.
            if (!sim_disable_local_pred &&
                spec_update_valid && (spec_target > spec_pc)) begin
                local_hist[spec_local_idx] <= spec_taken;
                local_last_spec[spec_local_idx] <= spec_taken;
            end

            if (!sim_disable_loop_spec_count &&
                !flush &&
                spec_update_valid &&
                spec_loop_hit &&
                spec_loop_backward) begin
                if (spec_taken)
                    loop_spec_count[spec_loop_idx] <=
                        loop_spec_count[spec_loop_idx] + 14'd1;
                else
                    loop_spec_count[spec_loop_idx] <= '0;
            end
        end
    end

endmodule
