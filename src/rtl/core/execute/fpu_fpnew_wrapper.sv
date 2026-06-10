/* file: fpu_fpnew_wrapper.sv
 Description: FPnew-backed floating-point execution wrapper for the active
 smoke/bring-up path. This slice now covers the full FPnew-backed RV64G
 arithmetic set used by the current Phase 5 milestone, including FMA and
 div/sqrt, while preserving architectural tags and `fflags` accumulation.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.1
*/

module fpu_fpnew_wrapper
    import rv64gc_pkg::*;
    import fpu_pkg::*;
(
    input  wire clk_i,
    input  wire rst_ni,
    input  wire flush_i,
    input  wire valid_i,
    input  fpu_op_e op_i,
    input  wire op_mod_i,
    input  fpu_misc_op_e misc_op_i,
    input  fp_fmt_e src_fmt_i,
    input  fp_fmt_e dst_fmt_i,
    input  fp_int_fmt_e int_fmt_i,
    input  fp_rm_e rm_i,
    input  wire [63:0] rs1_data_i,
    input  wire [63:0] rs2_data_i,
    input  wire [63:0] rs3_data_i,
    input  wire [ROB_IDX_BITS-1:0] rob_idx_i,
    input  wire [PHYS_REG_BITS-1:0] pdst_i,
    output reg ready_o,
    output reg out_valid_o,
    output reg [ROB_IDX_BITS-1:0] out_rob_idx_o,
    output reg [PHYS_REG_BITS-1:0] out_pdst_o,
    output reg [63:0] out_data_o,
    output fp_status_t out_status_o,
    output reg unsupported_o
);
    typedef struct packed {
        logic [ROB_IDX_BITS-1:0] rob_idx;
        logic [PHYS_REG_BITS-1:0] pdst;
    } fpnew_tag_t;

    fpnew_pkg::fp_format_e mapped_src_fmt;
    always_comb begin
        case (src_fmt_i)
            FP_FMT_S: mapped_src_fmt = fpnew_pkg::FP32;
            default:   mapped_src_fmt = fpnew_pkg::FP64;
        endcase
    end

    fpnew_pkg::fp_format_e mapped_dst_fmt;
    always_comb begin
        case (dst_fmt_i)
            FP_FMT_S: mapped_dst_fmt = fpnew_pkg::FP32;
            default:   mapped_dst_fmt = fpnew_pkg::FP64;
        endcase
    end

    fpnew_pkg::int_format_e mapped_int_fmt;
    always_comb begin
        case (int_fmt_i)
            FP_INT_FMT_32: mapped_int_fmt = fpnew_pkg::INT32;
            default:        mapped_int_fmt = fpnew_pkg::INT64;
        endcase
    end

    fpnew_pkg::roundmode_e mapped_rm;
    always_comb begin
        case (rm_i)
            FP_RM_RNE: mapped_rm = fpnew_pkg::RNE;
            FP_RM_RTZ: mapped_rm = fpnew_pkg::RTZ;
            FP_RM_RDN: mapped_rm = fpnew_pkg::RDN;
            FP_RM_RUP: mapped_rm = fpnew_pkg::RUP;
            FP_RM_RMM: mapped_rm = fpnew_pkg::RMM;
            default:    mapped_rm = fpnew_pkg::DYN;
        endcase
    end

    logic rm_valid;
    fpnew_pkg::operation_e fpnew_op;
    logic fpnew_op_mod;
    fpnew_pkg::roundmode_e fpnew_rm;
    fpnew_pkg::fp_format_e fpnew_src_fmt;
    fpnew_pkg::fp_format_e fpnew_dst_fmt;
    fpnew_pkg::int_format_e fpnew_int_fmt;
    logic [2:0][63:0] fpnew_operands;
    logic fpnew_issue_valid;
    logic fpnew_in_ready;
    logic fpnew_out_valid;
    logic [63:0] fpnew_result;
    fpnew_pkg::status_t fpnew_status;
    fpnew_tag_t fpnew_tag_out;
    logic fpnew_busy;
    logic fpnew_unsupported;
    localparam fpnew_pkg::fpu_implementation_t FPNEW_SMOKE_IMPL = '{
        PipeRegs: '{default: 0},
        UnitTypes: '{
            '{default: fpnew_pkg::PARALLEL}, // ADDMUL
            '{default: fpnew_pkg::MERGED},   // DIVSQRT
            '{default: fpnew_pkg::PARALLEL}, // NONCOMP
            '{default: fpnew_pkg::MERGED}    // CONV
        },
        PipeConfig: fpnew_pkg::BEFORE
    };

    always_comb begin
        rm_valid = (rm_i == FP_RM_RNE) || (rm_i == FP_RM_RTZ) ||
            (rm_i == FP_RM_RDN) || (rm_i == FP_RM_RUP) || (rm_i == FP_RM_RMM);
        fpnew_op = fpnew_pkg::ADD;
        fpnew_op_mod = op_mod_i;
        fpnew_rm = mapped_rm;
        fpnew_src_fmt = mapped_src_fmt;
        fpnew_dst_fmt = mapped_dst_fmt;
        fpnew_int_fmt = mapped_int_fmt;
        fpnew_operands[0] = rs1_data_i;
        fpnew_operands[1] = rs2_data_i;
        fpnew_operands[2] = rs3_data_i;
        fpnew_unsupported = 1'b0;

        case (op_i)
            FPU_OP_ADD: begin
                fpnew_op = fpnew_pkg::ADD;
                fpnew_operands[0] = 64'd0;
                fpnew_operands[1] = rs1_data_i;
                fpnew_operands[2] = rs2_data_i;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_FMADD: begin
                fpnew_op = fpnew_pkg::FMADD;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_FNMSUB: begin
                fpnew_op = fpnew_pkg::FNMSUB;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_MUL: begin
                fpnew_op = fpnew_pkg::MUL;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_DIV: begin
                fpnew_op = fpnew_pkg::DIV;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_SQRT: begin
                fpnew_op = fpnew_pkg::SQRT;
                fpnew_operands[1] = 64'd0;
                fpnew_operands[2] = 64'd0;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_SGNJ: begin
                fpnew_op = fpnew_pkg::SGNJ;
                case (misc_op_i)
                    FP_MISC_SGNJ:  fpnew_rm = fpnew_pkg::RNE;
                    FP_MISC_SGNJN: fpnew_rm = fpnew_pkg::RTZ;
                    FP_MISC_SGNJX: fpnew_rm = fpnew_pkg::RDN;
                    default: fpnew_unsupported = 1'b1;
                endcase
            end
            FPU_OP_MINMAX: begin
                fpnew_op = fpnew_pkg::MINMAX;
                case (misc_op_i)
                    FP_MISC_MIN: fpnew_rm = fpnew_pkg::RNE;
                    FP_MISC_MAX: fpnew_rm = fpnew_pkg::RTZ;
                    default: fpnew_unsupported = 1'b1;
                endcase
            end
            FPU_OP_CMP: begin
                fpnew_op = fpnew_pkg::CMP;
                case (misc_op_i)
                    FP_MISC_EQ: fpnew_rm = fpnew_pkg::RDN;
                    FP_MISC_LT: fpnew_rm = fpnew_pkg::RTZ;
                    FP_MISC_LE: fpnew_rm = fpnew_pkg::RNE;
                    default: fpnew_unsupported = 1'b1;
                endcase
            end
            FPU_OP_CLASSIFY: begin
                fpnew_op = fpnew_pkg::CLASSIFY;
                fpnew_rm = fpnew_pkg::RNE;
                fpnew_operands[1] = 64'd0;
                fpnew_operands[2] = 64'd0;
            end
            FPU_OP_F2F: begin
                fpnew_op = fpnew_pkg::F2F;
                fpnew_operands[1] = 64'd0;
                fpnew_operands[2] = 64'd0;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_F2I: begin
                fpnew_op = fpnew_pkg::F2I;
                fpnew_operands[1] = 64'd0;
                fpnew_operands[2] = 64'd0;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            FPU_OP_I2F: begin
                fpnew_op = fpnew_pkg::I2F;
                fpnew_operands[1] = 64'd0;
                fpnew_operands[2] = 64'd0;
                if (!rm_valid)
                    fpnew_unsupported = 1'b1;
            end
            default: begin
                fpnew_unsupported = 1'b1;
            end
        endcase
    end

    assign fpnew_issue_valid = valid_i && !fpnew_unsupported;

    fpnew_top #(
        .Features(fpnew_pkg::RV64D),
        .Implementation(FPNEW_SMOKE_IMPL),
        .DivSqrtSel(fpnew_pkg::PULP),
        .TagType(fpnew_tag_t)
    ) u_fpnew (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .operands_i(fpnew_operands),
        .rnd_mode_i(fpnew_rm),
        .op_i(fpnew_op),
        .op_mod_i(fpnew_op_mod),
        .src_fmt_i(fpnew_src_fmt),
        .dst_fmt_i(fpnew_dst_fmt),
        .int_fmt_i(fpnew_int_fmt),
        .vectorial_op_i(1'b0),
        .tag_i('{rob_idx: rob_idx_i, pdst: pdst_i}),
        .simd_mask_i(1'b1),
        .in_valid_i(fpnew_issue_valid),
        .in_ready_o(fpnew_in_ready),
        .flush_i(flush_i),
        .result_o(fpnew_result),
        .status_o(fpnew_status),
        .tag_o(fpnew_tag_out),
        .out_valid_o(fpnew_out_valid),
        .out_ready_i(1'b1),
        .busy_o(fpnew_busy),
        .early_valid_o()
    );

    always_comb begin
        // An FPnew completion drains UNCONDITIONALLY this cycle (out_ready_i
        // is tied high below), so it must always be visible upstream.  Do NOT
        // mask out_valid with the request-side unsupported decode: that
        // decode describes the op sitting in the REQUEST register (possibly
        // stale), not the op completing inside FPnew.  Masking it dropped
        // late multi-cycle results (fdiv/fsqrt) on the floor, permanently
        // wedging the ROB on their rob_idx.  When a completion and an
        // unsupported-request retire collide on the single output slot, the
        // completion wins and the unsupported retire is deferred one cycle
        // (ready_o=0 holds the request register).
        ready_o = fpnew_unsupported ? !fpnew_out_valid : fpnew_in_ready;
        unsupported_o = valid_i && fpnew_unsupported && !fpnew_out_valid;
        out_valid_o = fpnew_out_valid;
        out_rob_idx_o = fpnew_tag_out.rob_idx;
        out_pdst_o = fpnew_tag_out.pdst;
        out_data_o = fpnew_result;
        out_status_o.nv = fpnew_status.NV;
        out_status_o.dz = fpnew_status.DZ;
        out_status_o.of = fpnew_status.OF;
        out_status_o.uf = fpnew_status.UF;
        out_status_o.nx = fpnew_status.NX;
    end

    wire unused_busy = ^fpnew_busy;

endmodule
