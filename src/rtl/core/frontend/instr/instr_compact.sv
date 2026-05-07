/* file: instr_compact.sv
 Description: Compact extracted instruction slots into an IBuffer fetch packet.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module instr_compact
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic                         will_emit_i,
    input  logic                         redirect_i,
    input  logic                         frontend_hold_i,

    input  logic [FTQ_IDX_BITS-1:0]      ftq_idx_i,
    input  logic [FTQ_EPOCH_BITS-1:0]    ftq_epoch_i,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] ftq_alloc_tag_i,
    input  logic                         ftq_owner_complete_i,
    input  ftq_entry_t                   ftq_entry_i,
    input  logic                         ftq_valid_i,

    input  logic [63:LINE_BITS]          ifu_line_addr_i,
    input  logic                         ifu_line_reused_i,

    input  logic                         subgroup_seed_valid_i,
    input  logic [63:0]                  subgroup_seed_parent_pc_i,
    input  logic [63:0]                  subgroup_seed_owner_pc_i,
    input  logic [63:0]                  work_pc_i,

    input  logic                         pd_ctl_found_i,
    input  logic [2:0]                   pd_ctl_slot_i,
    input  logic [2:0]                   pd_ctl_type_i,
    input  logic [63:0]                  pd_ctl_pc_i,
    input  logic [63:0]                  pd_ctl_target_i,

    input  logic [2:0]                   final_count_i,
    input  logic                         slot_valid_i [0:PIPE_WIDTH-1],
    input  logic [31:0]                  raw_insn_i [0:PIPE_WIDTH-1],
    input  logic [31:0]                  decomp_insn_i [0:PIPE_WIDTH-1],
    input  logic                         slot_is_rvc_i [0:PIPE_WIDTH-1],
    input  logic [63:0]                  slot_pc_i [0:PIPE_WIDTH-1],

    input  logic                         bp_branch_found_i,
    input  logic                         bp_taken_i,
    input  logic [2:0]                   bp_branch_slot_i,
    input  logic [63:0]                  bp_target_i,
    input  logic                         subgroup_split_before_ctl_i,

    input  logic [4:0]                   ras_tos_i,
    input  logic [63:0]                  ras_top_i,
    input  logic [GHR_BITS-1:0]          ghr_i,

    output logic                         packet_enq_o,
    output fetch_packet_t                packet_o
);

    logic packet_owner_from_subgroup_c;

    always_comb begin
        packet_owner_from_subgroup_c = ftq_entry_i.pred_from_subgroup;

        // The subgroup seed is cleared as soon as the split request issues, so
        // the eventual packet can no longer rely on the FTQ bit alone. Recover
        // subgroup ownership from the live seed relation at packet build time.
        if (subgroup_seed_valid_i &&
            (work_pc_i == subgroup_seed_parent_pc_i) &&
            pd_ctl_found_i &&
            (pd_ctl_pc_i == subgroup_seed_owner_pc_i)) begin
            packet_owner_from_subgroup_c = 1'b1;
        end
    end

    always_comb begin
        packet_enq_o =
            will_emit_i &&
            !redirect_i &&
            !frontend_hold_i;
        packet_o = '0;

        if (will_emit_i) begin
            packet_o.valid              = 1'b1;
            packet_o.ftq_idx            = ftq_idx_i;
            packet_o.ftq_epoch          = ftq_epoch_i;
            packet_o.ftq_alloc_tag      = ftq_alloc_tag_i;
            packet_o.ftq_owner_complete = ftq_owner_complete_i;
            packet_o.ftq_block_pc       = ftq_entry_i.block_pc;
            packet_o.ftq_start_offset   = ftq_entry_i.start_offset;
            packet_o.ifu_line_addr      = ifu_line_addr_i;
            packet_o.ifu_line_reused    = ifu_line_reused_i;
            packet_o.ftq_bp_lookup_pc   =
                ftq_entry_i.block_pc + 64'(ftq_entry_i.start_offset);
            packet_o.ftq_pred_valid     = ftq_entry_i.pred_ctl_valid;
            packet_o.ftq_pred_taken     = ftq_entry_i.pred_ctl_taken;
            packet_o.ftq_pred_offset    = ftq_entry_i.pred_ctl_offset;
            packet_o.ftq_pred_type      = ftq_entry_i.pred_ctl_type;
            packet_o.ftq_pred_target    = ftq_entry_i.pred_ctl_target;
            packet_o.ftq_pred_from_subgroup =
                packet_owner_from_subgroup_c;
            packet_o.pd_ctl_valid       =
                pd_ctl_found_i && (pd_ctl_slot_i < final_count_i);
            packet_o.pd_ctl_slot        = pd_ctl_slot_i;
            packet_o.pd_ctl_type        = pd_ctl_type_i;
            packet_o.pd_ctl_target      = pd_ctl_target_i;
            packet_o.fetch_count        = final_count_i;

            // Fetch packets carry the request-time repair snapshot owned by
            // the FTQ entry instead of the live frontend state.
            if (ftq_valid_i) begin
                packet_o.fetch_bp_ras_tos = ftq_entry_i.ras_tos_snapshot;
                packet_o.fetch_bp_ras_top = ftq_entry_i.ras_top_snapshot;
                packet_o.fetch_bp_ghr     = ftq_entry_i.ghr_snapshot;
            end else begin
                packet_o.fetch_bp_ras_tos = ras_tos_i;
                packet_o.fetch_bp_ras_top = ras_top_i;
                packet_o.fetch_bp_ghr     = ghr_i;
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (3'(i) < final_count_i && slot_valid_i[i]) begin
                    packet_o.fetch_insn[i] =
                        slot_is_rvc_i[i] ? decomp_insn_i[i] : raw_insn_i[i];
                    packet_o.fetch_pc[i]     = slot_pc_i[i];
                    packet_o.fetch_is_rvc[i] = slot_is_rvc_i[i];

                    if (bp_branch_found_i && bp_taken_i &&
                        !subgroup_split_before_ctl_i &&
                        (3'(i) == bp_branch_slot_i)) begin
                        packet_o.fetch_bp_taken[i]  = 1'b1;
                        packet_o.fetch_bp_target[i] = bp_target_i;
                    end else begin
                        packet_o.fetch_bp_taken[i]  = 1'b0;
                        packet_o.fetch_bp_target[i] = '0;
                    end
                end
            end
        end
    end

endmodule
