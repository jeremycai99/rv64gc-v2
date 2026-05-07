/* file: bpu.sv
 Description: Branch prediction unit wrapper for BTB, TAGE, and RAS.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module bpu
    import rv64gc_pkg::*;
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

    logic [63:0] tage_lookup_pc_c;
    logic [63:0] tage_lookup_target_c;

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

endmodule
