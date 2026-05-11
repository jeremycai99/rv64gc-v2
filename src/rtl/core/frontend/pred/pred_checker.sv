/* file: pred_checker.sv
 Description: Frontend predicted-control validation and packet-cut decisions.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module pred_checker
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         valid_i,
    input  logic                         will_emit_i,
    input  logic                         redirect_i,
    input  logic                         stall_i,
    input  logic                         seed_clear_i,
    input  logic                         seed_consume_i,
    input  logic [63:0]                  req_pc_i,
    input  logic [63:0]                  seq_next_pc_i,
    input  logic [63:0]                  work_pc_i,

    input  logic [2:0]                   extract_count_i,
    input  logic                         slot_valid_i [0:PIPE_WIDTH-1],
    input  logic                         slot_is_rvc_i [0:PIPE_WIDTH-1],
    input  logic [63:0]                  slot_pc_i [0:PIPE_WIDTH-1],

    input  logic                         ftq_valid_i,
    input  ftq_entry_t                   ftq_entry_i,

    input  logic                         btb_hit_i,
    input  logic [63:0]                  btb_target_i,
    input  logic [2:0]                   btb_type_i,
    input  logic [5:0]                   btb_offset_i,
    input  logic                         btb_alt_hit_i,
    input  logic [63:0]                  btb_alt_target_i,
    input  logic [2:0]                   btb_alt_type_i,
    input  logic [5:0]                   btb_alt_offset_i,
    input  logic                         tage_taken_i,

    input  logic [4:0]                   ras_tos_i,
    input  logic [63:0]                  ras_pop_addr_i,

    input  logic                         pd_ctl_found_i,
    input  logic [2:0]                   pd_ctl_slot_i,
    input  logic [2:0]                   pd_ctl_type_i,
    input  logic [63:0]                  pd_ctl_pc_i,
    input  logic [63:0]                  pd_ctl_target_i,

    input  logic                         second_ctl_found_i,
    input  logic [2:0]                   second_ctl_slot_i,
    input  logic [2:0]                   second_ctl_type_i,
    input  logic [63:0]                  second_ctl_pc_i,
    input  logic [63:0]                  second_ctl_target_i,
    input  logic                         owner_cond_pred_found_i,

    input  logic                         seq_valid_i,
    input  logic                         consume_remainder_i,
    input  logic                         redirect_without_owner_successor_i,
    input  logic                         straddle_detected_i,

    output logic                         ftq_pred_ctl_valid_o,
    output logic                         ftq_pred_ctl_slot_match_o,
    output logic                         ftq_pred_ctl_taken_o,
    output logic [2:0]                   ftq_pred_ctl_slot_o,
    output logic [2:0]                   ftq_pred_ctl_type_o,
    output logic [63:0]                  ftq_pred_ctl_target_o,
    output logic                         pd_pred_mismatch_o,

    output logic                         bp_branch_found_o,
    output logic                         bp_taken_o,
    output logic [2:0]                   bp_branch_slot_o,
    output logic [2:0]                   bp_type_o,
    output logic [63:0]                  bp_target_o,

    output logic                         subgroup_split_before_ctl_o,
    output logic                         subgroup_split_seed_o,
    output logic [2:0]                   subgroup_split_slot_o,
    output logic [2:0]                   subgroup_split_type_o,
    output logic [63:0]                  subgroup_split_pc_o,
    output logic [63:0]                  subgroup_split_target_o,
    output logic                         subgroup_seed_load_o,
    output logic                         subgroup_seed_pred_taken_o,
    output logic                         subgroup_seed_hit_o,
    output logic                         subgroup_seed_valid_o,
    output logic [63:0]                  subgroup_seed_pc_o,
    output logic [63:0]                  subgroup_seed_parent_pc_o,
    output logic [63:0]                  subgroup_seed_owner_pc_o,
    output logic                         subgroup_seed_pred_valid_o,
    output logic                         subgroup_seed_pred_taken_state_o,
    output logic [5:0]                   subgroup_seed_pred_offset_o,
    output logic [2:0]                   subgroup_seed_pred_type_o,
    output logic [63:0]                  subgroup_seed_pred_target_o,

    output logic [2:0]                   final_count_o,
    output logic                         same_owner_continue_o,
    output logic                         owner_complete_o,
    output logic                         successor_req_valid_o,
    output logic [63:0]                  successor_req_pc_o,
    output logic                         req_redirect_o,
    output logic                         bpu_redirect_o,
    output logic [63:0]                  bpu_target_o,

    output logic                         ras_push_valid_o,
    output logic [63:0]                  ras_push_addr_o,
    output logic                         ras_pop_valid_o,
    output logic                         tage_spec_update_valid_o,
    output logic                         tage_spec_taken_o,
    output logic                         tage_loop_spec_update_valid_o,
    output logic                         tage_loop_spec_taken_o
);

    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;
    localparam logic SUBGROUP_SPLIT_SECOND_CTL_EN = 1'b1;
    localparam logic SUBGROUP_SPLIT_ANY_SECOND_CTL_EN = 1'b1;
    localparam logic SUBGROUP_SPLIT_OWNER_COND_EN = 1'b1;
    localparam logic SUBGROUP_SPLIT_SLOT3_FTQ_TAKEN_ONLY_EN = 1'b0;

    logic        second_ctl_backward_cond_c;
    logic        btb_pred_found_c;
    logic        btb_slot_matched_c;
    logic [2:0]  btb_branch_slot_c;
    logic [63:0] btb_target_addr_c;
    logic        btb_taken_c;
    logic [2:0]  btb_truncated_count_c;
    logic [2:0]  btb_pred_type_c;
    logic        btb_alt_pred_found_c;
    logic        btb_alt_slot_matched_c;
    logic [2:0]  btb_alt_branch_slot_c;
    logic [63:0] btb_alt_target_addr_c;
    logic [2:0]  btb_alt_truncated_count_c;
    logic        static_jal_found_c;
    logic [2:0]  static_jal_slot_c;
    logic [63:0] static_jal_target_c;
    logic [2:0]  static_jal_type_c;
    logic        static_ret_found_c;
    logic [2:0]  static_ret_slot_c;
    logic [63:0] static_ret_target_c;
    logic        static_ctl_found_c;
    logic [2:0]  static_ctl_slot_c;
    logic [63:0] static_ctl_target_c;
    logic [2:0]  static_ctl_type_c;
    logic [2:0]  bp_truncated_count_c;
    logic        consume_remainder_terminal_c;

    always_comb begin
        ftq_pred_ctl_valid_o      = 1'b0;
        ftq_pred_ctl_slot_match_o = 1'b0;
        ftq_pred_ctl_taken_o      = 1'b0;
        ftq_pred_ctl_slot_o       = 3'd0;
        ftq_pred_ctl_type_o       = BT_COND;
        ftq_pred_ctl_target_o     = '0;

        if (ftq_valid_i && ftq_entry_i.pred_ctl_valid) begin
            ftq_pred_ctl_valid_o  = 1'b1;
            ftq_pred_ctl_taken_o  = ftq_entry_i.pred_ctl_taken;
            ftq_pred_ctl_type_o   = ftq_entry_i.pred_ctl_type;
            ftq_pred_ctl_target_o = ftq_entry_i.pred_ctl_target;

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_valid_i[i] &&
                    (slot_pc_i[i][5:0] == ftq_entry_i.pred_ctl_offset)) begin
                    ftq_pred_ctl_slot_match_o = 1'b1;
                    ftq_pred_ctl_slot_o       = 3'(i);
                end
            end

            if (!ftq_pred_ctl_slot_match_o) begin
                ftq_pred_ctl_valid_o  = 1'b0;
                ftq_pred_ctl_taken_o  = 1'b0;
                ftq_pred_ctl_target_o = '0;
            end
        end
    end

    always_comb begin
        pd_pred_mismatch_o = 1'b0;

        if (pd_ctl_found_i != ftq_pred_ctl_valid_o) begin
            pd_pred_mismatch_o = 1'b1;
        end else if (pd_ctl_found_i && ftq_pred_ctl_valid_o) begin
            if ((pd_ctl_slot_i != ftq_pred_ctl_slot_o) ||
                (pd_ctl_type_i != ftq_pred_ctl_type_o)) begin
                pd_pred_mismatch_o = 1'b1;
            end else begin
                case (pd_ctl_type_i)
                    BT_COND,
                    BT_JAL,
                    BT_RET: begin
                        if (pd_ctl_target_i != ftq_pred_ctl_target_o)
                            pd_pred_mismatch_o = 1'b1;
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    assign second_ctl_backward_cond_c =
        second_ctl_found_i &&
        (second_ctl_type_i == BT_COND) &&
        (second_ctl_target_i != 64'd0) &&
        (second_ctl_target_i < second_ctl_pc_i);

    always_comb begin
        btb_pred_found_c      = 1'b0;
        btb_slot_matched_c    = 1'b0;
        btb_branch_slot_c     = 3'd0;
        btb_target_addr_c     = '0;
        btb_taken_c           = 1'b0;
        btb_truncated_count_c = extract_count_i;
        btb_pred_type_c       = BT_COND;
        btb_alt_pred_found_c   = 1'b0;
        btb_alt_slot_matched_c = 1'b0;
        btb_alt_branch_slot_c  = 3'd0;
        btb_alt_target_addr_c  = '0;
        btb_alt_truncated_count_c = extract_count_i;

        if (valid_i && btb_hit_i) begin
            case (btb_type_i)
                BT_COND: begin
                    if (tage_taken_i) begin
                        btb_pred_found_c  = 1'b1;
                        btb_taken_c       = 1'b1;
                        btb_target_addr_c = btb_target_i;
                        btb_pred_type_c   = BT_COND;
                    end
                end
                BT_JAL: begin
                    btb_pred_found_c  = 1'b1;
                    btb_taken_c       = 1'b1;
                    btb_target_addr_c = btb_target_i;
                    btb_pred_type_c   = BT_JAL;
                end
                BT_JALR: begin
                    btb_pred_found_c  = 1'b1;
                    btb_taken_c       = 1'b1;
                    btb_target_addr_c = btb_target_i;
                    btb_pred_type_c   = BT_JALR;
                end
                BT_CALL: begin
                    btb_pred_found_c  = 1'b1;
                    btb_taken_c       = 1'b1;
                    btb_target_addr_c = btb_target_i;
                    btb_pred_type_c   = BT_CALL;
                end
                BT_RET: begin
                    if ((ras_tos_i != 5'd0) && (ras_pop_addr_i != 64'd0)) begin
                        btb_pred_found_c  = 1'b1;
                        btb_taken_c       = 1'b1;
                        btb_target_addr_c = ras_pop_addr_i;
                        btb_pred_type_c   = BT_RET;
                    end
                end
                default: begin
                    btb_pred_found_c = 1'b0;
                end
            endcase

            if (btb_pred_found_c && btb_taken_c) begin
                btb_truncated_count_c = extract_count_i;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (slot_valid_i[i] &&
                        (slot_pc_i[i][5:0] == btb_offset_i)) begin
                        btb_branch_slot_c     = 3'(i);
                        btb_truncated_count_c = 3'(i + 1);
                        btb_slot_matched_c    = 1'b1;
                    end
                end

                if (!btb_slot_matched_c) begin
                    btb_pred_found_c = 1'b0;
                    btb_taken_c      = 1'b0;
                end
            end
        end

        if (valid_i && btb_alt_hit_i) begin
            case (btb_alt_type_i)
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    btb_alt_pred_found_c = 1'b1;
                    btb_alt_target_addr_c = btb_alt_target_i;
                end
                BT_RET: begin
                    if ((ras_tos_i != 5'd0) && (ras_pop_addr_i != 64'd0)) begin
                        btb_alt_pred_found_c = 1'b1;
                        btb_alt_target_addr_c = ras_pop_addr_i;
                    end
                end
                default: begin
                    btb_alt_pred_found_c = 1'b0;
                end
            endcase

            if (btb_alt_pred_found_c) begin
                btb_alt_truncated_count_c = extract_count_i;

                for (int i = 0; i < PIPE_WIDTH; i++) begin
                    if (slot_valid_i[i] &&
                        (slot_pc_i[i][5:0] == btb_alt_offset_i)) begin
                        btb_alt_branch_slot_c     = 3'(i);
                        btb_alt_truncated_count_c = 3'(i + 1);
                        btb_alt_slot_matched_c    = 1'b1;
                    end
                end

                if (!btb_alt_slot_matched_c) begin
                    btb_alt_pred_found_c = 1'b0;
                end
            end
        end

        if ((!btb_pred_found_c || !btb_taken_c) &&
            btb_alt_pred_found_c) begin
            btb_pred_found_c      = 1'b1;
            btb_taken_c           = 1'b1;
            btb_branch_slot_c     = btb_alt_branch_slot_c;
            btb_target_addr_c     = btb_alt_target_addr_c;
            btb_truncated_count_c = btb_alt_truncated_count_c;
            btb_pred_type_c       = btb_alt_type_i;
        end
    end

    always_comb begin
        static_jal_found_c  = 1'b0;
        static_jal_slot_c   = 3'd0;
        static_jal_target_c = '0;
        static_jal_type_c   = BT_JAL;

        if (valid_i &&
            pd_ctl_found_i &&
            ((pd_ctl_type_i == BT_JAL) ||
             (pd_ctl_type_i == BT_CALL)) &&
            (pd_ctl_target_i != 64'd0)) begin
            static_jal_found_c  = 1'b1;
            static_jal_slot_c   = pd_ctl_slot_i;
            static_jal_target_c = pd_ctl_target_i;
            static_jal_type_c   = pd_ctl_type_i;
        end
    end

    always_comb begin
        static_ret_found_c  = 1'b0;
        static_ret_slot_c   = 3'd0;
        static_ret_target_c = '0;

        if (valid_i &&
            pd_ctl_found_i &&
            (pd_ctl_type_i == BT_RET) &&
            (pd_ctl_target_i != 64'd0)) begin
            static_ret_found_c  = 1'b1;
            static_ret_slot_c   = pd_ctl_slot_i;
            static_ret_target_c = pd_ctl_target_i;
        end
    end

    always_comb begin
        static_ctl_found_c  = 1'b0;
        static_ctl_slot_c   = 3'd0;
        static_ctl_target_c = '0;
        static_ctl_type_c   = BT_JAL;

        if (static_jal_found_c) begin
            static_ctl_found_c  = 1'b1;
            static_ctl_slot_c   = static_jal_slot_c;
            static_ctl_target_c = static_jal_target_c;
            static_ctl_type_c   = static_jal_type_c;
        end

        if (static_ret_found_c &&
            (!static_ctl_found_c ||
             (static_ret_slot_c < static_ctl_slot_c))) begin
            static_ctl_found_c  = 1'b1;
            static_ctl_slot_c   = static_ret_slot_c;
            static_ctl_target_c = static_ret_target_c;
            static_ctl_type_c   = BT_RET;
        end
    end

    always_comb begin
        bp_branch_found_o    = 1'b0;
        bp_branch_slot_o     = 3'd0;
        bp_target_o          = '0;
        bp_taken_o           = 1'b0;
        bp_truncated_count_c = extract_count_i;
        bp_type_o            = BT_COND;

        if (btb_pred_found_c && btb_taken_c) begin
            bp_branch_found_o    = 1'b1;
            bp_branch_slot_o     = btb_branch_slot_c;
            bp_target_o          = btb_target_addr_c;
            bp_taken_o           = 1'b1;
            bp_truncated_count_c = btb_truncated_count_c;
            bp_type_o            = btb_pred_type_c;
        end

        // A subgroup FTQ entry can carry the owning conditional's prediction
        // even before the BTB has a matching entry. Use it only when current
        // predecode confirms the same live branch.
        if (ftq_pred_ctl_valid_o &&
            ftq_pred_ctl_taken_o &&
            (ftq_pred_ctl_type_o == BT_COND) &&
            pd_ctl_found_i &&
            (pd_ctl_type_i == BT_COND) &&
            (pd_ctl_slot_i == ftq_pred_ctl_slot_o) &&
            (pd_ctl_target_i == ftq_pred_ctl_target_o) &&
            (!bp_branch_found_o ||
             (ftq_pred_ctl_slot_o < bp_branch_slot_o))) begin
            bp_branch_found_o    = 1'b1;
            bp_branch_slot_o     = ftq_pred_ctl_slot_o;
            bp_target_o          = ftq_pred_ctl_target_o;
            bp_taken_o           = 1'b1;
            bp_truncated_count_c = 3'(ftq_pred_ctl_slot_o + 1);
            bp_type_o            = BT_COND;
        end

        if (static_ctl_found_c &&
            (!bp_branch_found_o ||
             (static_ctl_slot_c < bp_branch_slot_o))) begin
            bp_branch_found_o    = 1'b1;
            bp_branch_slot_o     = static_ctl_slot_c;
            bp_target_o          = static_ctl_target_c;
            bp_taken_o           = 1'b1;
            bp_truncated_count_c = 3'(static_ctl_slot_c + 1);
            bp_type_o            = static_ctl_type_c;
        end
    end

    always_comb begin
        subgroup_split_before_ctl_o = 1'b0;
        subgroup_split_seed_o       = 1'b1;
        subgroup_split_slot_o       = pd_ctl_slot_i;
        subgroup_split_type_o       = pd_ctl_type_i;
        subgroup_split_pc_o         = pd_ctl_pc_i;
        subgroup_split_target_o     = pd_ctl_target_i;

        // If the earliest conditional is not predicted taken, do not carry a
        // later control-flow instruction as an unpredicted passenger.
        if (SUBGROUP_SPLIT_SECOND_CTL_EN &&
            valid_i &&
            pd_ctl_found_i &&
            second_ctl_found_i &&
            (pd_ctl_type_i == BT_COND) &&
            !(bp_branch_found_o && bp_taken_o &&
              (bp_branch_slot_o <= second_ctl_slot_i)) &&
            (SUBGROUP_SPLIT_ANY_SECOND_CTL_EN ||
             (pd_ctl_slot_i == 3'd0) ||
             second_ctl_backward_cond_c)) begin
            subgroup_split_before_ctl_o = 1'b1;
            subgroup_split_seed_o       = 1'b0;
            subgroup_split_slot_o       = second_ctl_slot_i;
            subgroup_split_type_o       = second_ctl_type_i;
            subgroup_split_pc_o         = second_ctl_pc_i;
            subgroup_split_target_o     = second_ctl_target_i;

        // Split before a later owner conditional so the next request can be
        // branch-owned.
        end else if (SUBGROUP_SPLIT_OWNER_COND_EN &&
            valid_i &&
            pd_ctl_found_i &&
            (pd_ctl_type_i == BT_COND) &&
            (pd_ctl_slot_i != 3'd0)) begin
            if (pd_ctl_slot_i == 3'd1) begin
                if (!(bp_branch_found_o &&
                      bp_taken_o &&
                      (bp_type_o == BT_COND) &&
                      (bp_branch_slot_o == pd_ctl_slot_i)) &&
                    (owner_cond_pred_found_i ||
                     ((pd_ctl_target_i != 64'd0) &&
                      (pd_ctl_target_i < pd_ctl_pc_i)))) begin
                    subgroup_split_before_ctl_o = 1'b1;
                end
            end else if ((pd_ctl_slot_i == 3'd3) &&
                         ftq_pred_ctl_valid_o &&
                         (ftq_pred_ctl_type_o == BT_COND) &&
                         (!SUBGROUP_SPLIT_SLOT3_FTQ_TAKEN_ONLY_EN ||
                          ftq_pred_ctl_taken_o) &&
                         (ftq_pred_ctl_slot_o == pd_ctl_slot_i)) begin
                if (!(bp_branch_found_o &&
                      bp_taken_o &&
                      (bp_type_o == BT_COND) &&
                      (bp_branch_slot_o == pd_ctl_slot_i))) begin
                    subgroup_split_before_ctl_o = 1'b1;
                end
            end else if (owner_cond_pred_found_i) begin
                if (!ftq_pred_ctl_valid_o ||
                    (pd_ctl_slot_i < ftq_pred_ctl_slot_o) ||
                    pd_pred_mismatch_o) begin
                    subgroup_split_before_ctl_o = 1'b1;
                end
            end
        end
    end

    always_comb begin
        if (subgroup_split_before_ctl_o) begin
            final_count_o = subgroup_split_slot_o;
        end else if (bp_branch_found_o && bp_taken_o) begin
            final_count_o = bp_truncated_count_c;
        end else begin
            final_count_o = extract_count_i;
        end
    end

    // A straight-line continuation within the current cache line remains part
    // of the same fetch-block owner. Allocate a new FTQ owner only at a real
    // ownership boundary: control transfer, explicit subgroup split, line end,
    // or straddle handling.
    assign same_owner_continue_o =
        valid_i &&
        seq_valid_i &&
        (final_count_o > 3'd0) &&
        !straddle_detected_i &&
        !pd_ctl_found_i &&
        !subgroup_split_before_ctl_o &&
        !(bp_branch_found_o && bp_taken_o) &&
        (seq_next_pc_i[63:LINE_BITS] == work_pc_i[63:LINE_BITS]);

    assign subgroup_seed_load_o =
        valid_i &&
        will_emit_i &&
        !redirect_i &&
        subgroup_split_before_ctl_o &&
        subgroup_split_seed_o &&
        (subgroup_split_type_o == BT_COND) &&
        seq_valid_i;

    assign subgroup_seed_pred_taken_o =
        (ftq_pred_ctl_valid_o &&
         (ftq_pred_ctl_slot_o == subgroup_split_slot_o) &&
         (ftq_pred_ctl_type_o == subgroup_split_type_o))
            ? ftq_pred_ctl_taken_o
            : (((subgroup_split_slot_o == pd_ctl_slot_i) &&
                (subgroup_split_pc_o == pd_ctl_pc_i) &&
                (subgroup_split_target_o == pd_ctl_target_i))
                   ? owner_cond_pred_found_i
                   : 1'b0);

    assign subgroup_seed_hit_o =
        subgroup_seed_valid_o &&
        (req_pc_i == subgroup_seed_pc_o);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            subgroup_seed_valid_o            <= 1'b0;
            subgroup_seed_pc_o               <= '0;
            subgroup_seed_parent_pc_o        <= '0;
            subgroup_seed_owner_pc_o         <= '0;
            subgroup_seed_pred_valid_o       <= 1'b0;
            subgroup_seed_pred_taken_state_o <= 1'b0;
            subgroup_seed_pred_offset_o      <= '0;
            subgroup_seed_pred_type_o        <= '0;
            subgroup_seed_pred_target_o      <= '0;
        end else if (seed_clear_i) begin
            subgroup_seed_valid_o            <= 1'b0;
            subgroup_seed_pc_o               <= '0;
            subgroup_seed_parent_pc_o        <= '0;
            subgroup_seed_owner_pc_o         <= '0;
            subgroup_seed_pred_valid_o       <= 1'b0;
            subgroup_seed_pred_taken_state_o <= 1'b0;
            subgroup_seed_pred_offset_o      <= '0;
            subgroup_seed_pred_type_o        <= '0;
            subgroup_seed_pred_target_o      <= '0;
        end else if (subgroup_seed_load_o) begin
            subgroup_seed_valid_o            <= 1'b1;
            subgroup_seed_pc_o               <= seq_next_pc_i;
            subgroup_seed_parent_pc_o        <= work_pc_i;
            subgroup_seed_owner_pc_o         <= subgroup_split_pc_o;
            subgroup_seed_pred_valid_o       <= 1'b1;
            subgroup_seed_pred_taken_state_o <= subgroup_seed_pred_taken_o;
            subgroup_seed_pred_offset_o      <= subgroup_split_pc_o[5:0];
            subgroup_seed_pred_type_o        <= subgroup_split_type_o;
            subgroup_seed_pred_target_o      <= subgroup_split_target_o;
        end else if (seed_consume_i && subgroup_seed_hit_o) begin
            subgroup_seed_valid_o     <= 1'b0;
            subgroup_seed_parent_pc_o <= '0;
            subgroup_seed_owner_pc_o  <= '0;
        end
    end

    assign consume_remainder_terminal_c =
        consume_remainder_i &&
        bp_branch_found_o &&
        bp_taken_o &&
        !subgroup_split_before_ctl_o;
    assign owner_complete_o =
        (!consume_remainder_i || consume_remainder_terminal_c) &&
        !redirect_without_owner_successor_i &&
        !same_owner_continue_o &&
        (!straddle_detected_i ||
         (bp_branch_found_o && bp_taken_o && !subgroup_split_before_ctl_o));
    assign successor_req_valid_o =
        valid_i &&
        will_emit_i &&
        seq_valid_i &&
        owner_complete_o &&
        !req_redirect_o &&
        !redirect_i;
    assign successor_req_pc_o =
        subgroup_split_before_ctl_o ? subgroup_split_pc_o : seq_next_pc_i;

    assign req_redirect_o =
        will_emit_i &&
        bp_branch_found_o && bp_taken_o &&
        !subgroup_split_before_ctl_o &&
        !redirect_i;
    assign bpu_redirect_o = req_redirect_o && !stall_i;
    assign bpu_target_o = bp_target_o;

    always_comb begin
        ras_push_valid_o = 1'b0;
        ras_push_addr_o  = '0;
        ras_pop_valid_o  = 1'b0;

        if (will_emit_i &&
            bp_branch_found_o && bp_taken_o &&
            !subgroup_split_before_ctl_o &&
            !stall_i && !redirect_i) begin
            if (bp_type_o == BT_CALL) begin
                ras_push_valid_o = 1'b1;
                ras_push_addr_o  = slot_pc_i[bp_branch_slot_o]
                    + (slot_is_rvc_i[bp_branch_slot_o] ? 64'd2 : 64'd4);
            end else if (bp_type_o == BT_RET) begin
                ras_pop_valid_o = 1'b1;
            end
        end
    end

    always_comb begin
        tage_spec_update_valid_o      = 1'b0;
        tage_spec_taken_o             = 1'b0;
        tage_loop_spec_update_valid_o = 1'b0;
        tage_loop_spec_taken_o        = 1'b0;

        if (valid_i &&
            will_emit_i &&
            pd_ctl_found_i &&
            (pd_ctl_type_i == BT_COND) &&
            (pd_ctl_slot_i < final_count_o) &&
            !stall_i && !redirect_i) begin
            tage_spec_update_valid_o = 1'b1;
            tage_spec_taken_o        =
                bp_branch_found_o && bp_taken_o &&
                (bp_type_o == BT_COND) &&
                (bp_branch_slot_o == pd_ctl_slot_i);
        end

        if (valid_i &&
            will_emit_i &&
            pd_ctl_found_i &&
            (pd_ctl_type_i == BT_COND) &&
            ftq_pred_ctl_valid_o &&
            ftq_pred_ctl_slot_match_o &&
            (ftq_pred_ctl_type_o == BT_COND) &&
            (ftq_pred_ctl_slot_o == pd_ctl_slot_i) &&
            !stall_i && !redirect_i) begin
            tage_loop_spec_update_valid_o = 1'b1;
            tage_loop_spec_taken_o        = ftq_pred_ctl_taken_o;
        end
    end

endmodule
