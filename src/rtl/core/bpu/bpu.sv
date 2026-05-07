/* file: bpu.sv
 Description: Branch prediction unit wrapper for BTB, TAGE, and RAS.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module bpu
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    flush_i,

    input  logic [63:0]             lookup_pc_i,
    input  logic [63:0]             lookup_block_pc_i,
    input  logic [63:0]             aux_lookup_pc_i,

    output logic                    btb_hit_o,
    output logic [63:0]             btb_target_o,
    output logic [2:0]              btb_type_o,
    output logic [5:0]              btb_offset_o,
    output logic                    btb_alt_hit_o,
    output logic [63:0]             btb_alt_target_o,
    output logic [2:0]              btb_alt_type_o,
    output logic [5:0]              btb_alt_offset_o,

    output logic                    aux_btb_hit_o,
    output logic [63:0]             aux_btb_target_o,
    output logic [2:0]              aux_btb_type_o,
    output logic [5:0]              aux_btb_offset_o,
    output logic                    aux_btb_alt_hit_o,
    output logic [63:0]             aux_btb_alt_target_o,
    output logic [2:0]              aux_btb_alt_type_o,
    output logic [5:0]              aux_btb_alt_offset_o,

    output logic                    tage_pred_taken_o,
    output logic                    tage_pred_confident_o,
    input  logic [63:0]             aux_tage_pc_i,
    input  logic [63:0]             aux_tage_target_i,
    input  logic [GHR_BITS-1:0]     aux_tage_ghr_i,
    output logic                    aux_tage_pred_taken_o,
    output logic                    aux_tage_pred_confident_o,

    input  logic                    btb_update_valid_i,
    input  logic [63:0]             btb_update_pc_i,
    input  logic [63:0]             btb_update_target_i,
    input  logic [2:0]              btb_update_type_i,

    input  logic                    tage_update_valid_i,
    input  logic [63:0]             tage_update_pc_i,
    input  logic [63:0]             tage_update_target_i,
    input  logic                    tage_update_taken_i,
    input  logic                    tage_update_mispredict_i,
    input  logic [GHR_BITS-1:0]     tage_update_ghr_i,

    input  logic                    tage_spec_update_valid_i,
    input  logic                    tage_spec_taken_i,
    input  logic [63:0]             tage_spec_pc_i,
    input  logic [63:0]             tage_spec_target_i,
    input  logic                    ghr_restore_valid_i,
    input  logic [GHR_BITS-1:0]     ghr_restore_val_i,
    output logic [GHR_BITS-1:0]     ghr_o,

    input  logic                    subgroup_seed_hit_i,
    input  logic                    subgroup_seed_pred_valid_i,
    input  logic                    subgroup_seed_pred_taken_i,
    input  logic [5:0]              subgroup_seed_pred_offset_i,
    input  logic [2:0]              subgroup_seed_pred_type_i,
    input  logic [63:0]             subgroup_seed_pred_target_i,
    output ftq_entry_t              req_ftq_entry_o,
    output logic                    aux_pred_ctl_valid_o,
    output logic                    aux_pred_ctl_taken_o,
    output logic [5:0]              aux_pred_ctl_offset_o,
    output logic [2:0]              aux_pred_ctl_type_o,
    output logic [63:0]             aux_pred_ctl_target_o,

    input  logic                    ras_push_valid_i,
    input  logic [63:0]             ras_push_addr_i,
    input  logic                    ras_pop_valid_i,
    output logic [63:0]             ras_pop_addr_o,
    output logic [4:0]              ras_tos_o,
    input  logic                    ras_restore_valid_i,
    input  logic [4:0]              ras_restore_tos_i,
    input  logic                    ras_restore_top_valid_i,
    input  logic [63:0]             ras_restore_top_addr_i
);

    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;

    logic [63:0] tage_lookup_pc_c;
    logic [63:0] tage_lookup_target_c;
    logic        req_pred_ctl_valid_c;
    logic        req_pred_ctl_taken_c;
    logic [5:0]  req_pred_ctl_offset_c;
    logic [2:0]  req_pred_ctl_type_c;
    logic [63:0] req_pred_ctl_target_c;
    logic [63:0] aux_pred_branch_pc_c;

    assign tage_lookup_pc_c =
        (btb_hit_o && (btb_type_o == BT_COND))
            ? {lookup_block_pc_i[63:LINE_BITS], btb_offset_o}
            : lookup_pc_i;
    assign tage_lookup_target_c =
        (btb_hit_o && (btb_type_o == BT_COND)) ? btb_target_o : 64'd0;

    btb u_btb (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .lookup_pc              (lookup_pc_i),
        .hit                    (btb_hit_o),
        .target                 (btb_target_o),
        .branch_type            (btb_type_o),
        .branch_offset          (btb_offset_o),
        .alt_hit                (btb_alt_hit_o),
        .alt_target             (btb_alt_target_o),
        .alt_branch_type        (btb_alt_type_o),
        .alt_branch_offset      (btb_alt_offset_o),
        .aux_lookup_pc          (aux_lookup_pc_i),
        .aux_hit                (aux_btb_hit_o),
        .aux_target             (aux_btb_target_o),
        .aux_branch_type        (aux_btb_type_o),
        .aux_branch_offset      (aux_btb_offset_o),
        .aux_alt_hit            (aux_btb_alt_hit_o),
        .aux_alt_target         (aux_btb_alt_target_o),
        .aux_alt_branch_type    (aux_btb_alt_type_o),
        .aux_alt_branch_offset  (aux_btb_alt_offset_o),
        .update_valid           (btb_update_valid_i),
        .update_pc              (btb_update_pc_i),
        .update_target          (btb_update_target_i),
        .update_type            (btb_update_type_i),
        .flush                  (1'b0)
    );

    tage_sc_l u_tage_sc_l (
        .clk                (clk),
        .rst_n              (rst_n),
        .pc                 (tage_lookup_pc_c),
        .target             (tage_lookup_target_c),
        .pred_taken         (tage_pred_taken_o),
        .pred_confident     (tage_pred_confident_o),
        .aux_pc             (aux_tage_pc_i),
        .aux_target         (aux_tage_target_i),
        .aux_ghr            (aux_tage_ghr_i),
        .aux_pred_taken     (aux_tage_pred_taken_o),
        .aux_pred_confident (aux_tage_pred_confident_o),
        .update_valid       (tage_update_valid_i),
        .update_pc          (tage_update_pc_i),
        .update_target      (tage_update_target_i),
        .update_taken       (tage_update_taken_i),
        .update_mispredict  (tage_update_mispredict_i),
        .update_ghr         (tage_update_ghr_i),
        .spec_update_valid  (tage_spec_update_valid_i),
        .spec_taken         (tage_spec_taken_i),
        .spec_pc            (tage_spec_pc_i),
        .spec_target        (tage_spec_target_i),
        .ghr_restore_valid  (ghr_restore_valid_i),
        .ghr_restore_val    (ghr_restore_val_i),
        .ghr_out            (ghr_o),
        .flush              (flush_i)
    );

    ras u_ras (
        .clk                (clk),
        .rst_n              (rst_n),
        .push_valid         (ras_push_valid_i),
        .push_addr          (ras_push_addr_i),
        .pop_valid          (ras_pop_valid_i),
        .pop_addr           (ras_pop_addr_o),
        .tos                (ras_tos_o),
        .restore_valid      (ras_restore_valid_i),
        .restore_tos        (ras_restore_tos_i),
        .restore_top_valid  (ras_restore_top_valid_i),
        .restore_top_addr   (ras_restore_top_addr_i)
    );

    always_comb begin
        req_pred_ctl_valid_c  = 1'b0;
        req_pred_ctl_taken_c  = 1'b0;
        req_pred_ctl_offset_c = 6'd0;
        req_pred_ctl_type_c   = BT_COND;
        req_pred_ctl_target_c = 64'd0;

        if (btb_hit_o) begin
            req_pred_ctl_valid_c  = 1'b1;
            req_pred_ctl_offset_c = btb_offset_o;
            req_pred_ctl_type_c   = btb_type_o;

            case (btb_type_o)
                BT_COND: begin
                    req_pred_ctl_target_c = btb_target_o;
                    req_pred_ctl_taken_c  = tage_pred_taken_o;
                end
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    req_pred_ctl_target_c = btb_target_o;
                    req_pred_ctl_taken_c  = 1'b1;
                end
                BT_RET: begin
                    if ((ras_tos_o != 5'd0) && (ras_pop_addr_o != 64'd0)) begin
                        req_pred_ctl_target_c = ras_pop_addr_o;
                        req_pred_ctl_taken_c  = 1'b1;
                    end
                end
                default: begin
                    req_pred_ctl_valid_c = 1'b0;
                end
            endcase
        end
    end

    assign aux_pred_branch_pc_c =
        {aux_lookup_pc_i[63:LINE_BITS], aux_btb_offset_o};

    always_comb begin
        aux_pred_ctl_valid_o  = 1'b0;
        aux_pred_ctl_taken_o  = 1'b0;
        aux_pred_ctl_offset_o = 6'd0;
        aux_pred_ctl_type_o   = BT_COND;
        aux_pred_ctl_target_o = 64'd0;

        if (aux_btb_hit_o) begin
            aux_pred_ctl_valid_o  = 1'b1;
            aux_pred_ctl_offset_o = aux_btb_offset_o;
            aux_pred_ctl_type_o   = aux_btb_type_o;

            case (aux_btb_type_o)
                BT_COND: begin
                    aux_pred_ctl_target_o = aux_btb_target_o;
                    aux_pred_ctl_taken_o =
                        (aux_btb_target_o < aux_pred_branch_pc_c);
                end
                BT_JAL,
                BT_JALR,
                BT_CALL: begin
                    aux_pred_ctl_target_o = aux_btb_target_o;
                    aux_pred_ctl_taken_o  = 1'b1;
                end
                BT_RET: begin
                    if ((ras_tos_o != 5'd0) && (ras_pop_addr_o != 64'd0)) begin
                        aux_pred_ctl_target_o = ras_pop_addr_o;
                        aux_pred_ctl_taken_o  = 1'b1;
                    end
                end
                default: begin
                    aux_pred_ctl_valid_o = 1'b0;
                end
            endcase
        end
    end

    always_comb begin
        req_ftq_entry_o = '0;
        req_ftq_entry_o.block_pc       = lookup_block_pc_i;
        req_ftq_entry_o.start_offset   = lookup_pc_i[5:0];
        req_ftq_entry_o.fallthrough_pc = lookup_block_pc_i + 64'(LINE_SIZE);

        if (subgroup_seed_hit_i) begin
            req_ftq_entry_o.pred_ctl_valid     = subgroup_seed_pred_valid_i;
            req_ftq_entry_o.pred_ctl_taken     = subgroup_seed_pred_taken_i;
            req_ftq_entry_o.pred_ctl_offset    = subgroup_seed_pred_offset_i;
            req_ftq_entry_o.pred_ctl_type      = subgroup_seed_pred_type_i;
            req_ftq_entry_o.pred_ctl_target    = subgroup_seed_pred_target_i;
            req_ftq_entry_o.pred_from_subgroup = 1'b1;
        end else begin
            req_ftq_entry_o.pred_ctl_valid     = req_pred_ctl_valid_c;
            req_ftq_entry_o.pred_ctl_taken     = req_pred_ctl_taken_c;
            req_ftq_entry_o.pred_ctl_offset    = req_pred_ctl_offset_c;
            req_ftq_entry_o.pred_ctl_type      = req_pred_ctl_type_c;
            req_ftq_entry_o.pred_ctl_target    = req_pred_ctl_target_c;
            req_ftq_entry_o.pred_from_subgroup = 1'b0;
        end

        req_ftq_entry_o.btb_hit          = btb_hit_o;
        req_ftq_entry_o.btb_offset       = btb_offset_o;
        req_ftq_entry_o.btb_type         = btb_type_o;
        req_ftq_entry_o.btb_target       = btb_target_o;
        req_ftq_entry_o.btb_alt_hit      = btb_alt_hit_o;
        req_ftq_entry_o.btb_alt_offset   = btb_alt_offset_o;
        req_ftq_entry_o.btb_alt_type     = btb_alt_type_o;
        req_ftq_entry_o.btb_alt_target   = btb_alt_target_o;
        req_ftq_entry_o.tage_taken       = tage_pred_taken_o;
        req_ftq_entry_o.tage_confident   = tage_pred_confident_o;
        req_ftq_entry_o.ras_tos_snapshot = ras_tos_o;
        req_ftq_entry_o.ras_top_snapshot = ras_pop_addr_o;
        req_ftq_entry_o.ghr_snapshot     = ghr_o;
    end

endmodule
