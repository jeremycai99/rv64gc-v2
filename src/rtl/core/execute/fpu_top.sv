/* file: fpu_top.sv
 Description: Floating-point execution wrapper with selectable legacy misc/FMV
 path or FPnew-backed smoke path. FMV remains in-house; FPnew is used for the
 broader RV64F/D operation set being integrated for the Linux-smoke phase.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.2
*/

module fpu_top
    import rv64gc_pkg::*;
    import fpu_pkg::*;
(
    input  wire clk_i,
    input  wire rst_ni,
    input  wire flush_i,
    input  wire valid_i,
    input  wire use_fpnew_i,
    input  fpu_pipe_e pipe_i,
    input  fpu_op_e op_i,
    input  wire op_mod_i,
    input  fpu_misc_op_e misc_op_i,
    input  fmv_op_e fmv_op_i,
    input  fp_fmt_e src_fmt_i,
    input  fp_fmt_e dst_fmt_i,
    input  fp_int_fmt_e int_fmt_i,
    input  fp_rm_e rm_i,
    input  wire [63:0] rs1_data_i,
    input  wire [63:0] rs2_data_i,
    input  wire [63:0] rs3_data_i,
    input  wire [ROB_IDX_BITS-1:0] rob_idx_i,
    input  wire [PHYS_REG_BITS-1:0] pdst_i,
    output logic ready_o,
    output logic out_valid_o,
    output logic [ROB_IDX_BITS-1:0] out_rob_idx_o,
    output logic [PHYS_REG_BITS-1:0] out_pdst_o,
    output logic [63:0] out_data_o,
    output fp_status_t out_status_o,
    output logic unsupported_o
);

    logic fmv_valid;
    logic [63:0] fmv_int_result;
    logic [63:0] fmv_fp_result;
    logic misc_valid;
    logic [63:0] misc_result;
    fp_status_t misc_status;
    logic fpnew_ready;
    logic fpnew_out_valid;
    logic [ROB_IDX_BITS-1:0] fpnew_out_rob_idx;
    logic [PHYS_REG_BITS-1:0] fpnew_out_pdst;
    logic [63:0] fpnew_out_data;
    fp_status_t fpnew_out_status;
    logic fpnew_unsupported;

    fmv_unit u_fmv (
        .valid_i(valid_i && (pipe_i == FPU_PIPE_FMV)),
        .op_i(fmv_op_i),
        .int_data_i(rs1_data_i),
        .fp_data_i(rs1_data_i),
        .valid_o(fmv_valid),
        .int_result_o(fmv_int_result),
        .fp_result_o(fmv_fp_result)
    );

    fpu_misc u_fpu_misc (
        .valid_i(valid_i && !use_fpnew_i && (pipe_i == FPU_PIPE_MISC)),
        .op_i(misc_op_i),
        .fmt_i(src_fmt_i),
        .rs1_data_i(rs1_data_i),
        .rs2_data_i(rs2_data_i),
        .valid_o(misc_valid),
        .result_o(misc_result),
        .status_o(misc_status)
    );

    fpu_fpnew_wrapper u_fpnew_wrapper (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .valid_i(valid_i && use_fpnew_i && (pipe_i != FPU_PIPE_FMV)),
        .op_i(op_i),
        .op_mod_i(op_mod_i),
        .misc_op_i(misc_op_i),
        .src_fmt_i(src_fmt_i),
        .dst_fmt_i(dst_fmt_i),
        .int_fmt_i(int_fmt_i),
        .rm_i(rm_i),
        .rs1_data_i(rs1_data_i),
        .rs2_data_i(rs2_data_i),
        .rs3_data_i(rs3_data_i),
        .rob_idx_i(rob_idx_i),
        .pdst_i(pdst_i),
        .ready_o(fpnew_ready),
        .out_valid_o(fpnew_out_valid),
        .out_rob_idx_o(fpnew_out_rob_idx),
        .out_pdst_o(fpnew_out_pdst),
        .out_data_o(fpnew_out_data),
        .out_status_o(fpnew_out_status),
        .unsupported_o(fpnew_unsupported)
    );

    always_comb begin
        ready_o = 1'b0;
        unsupported_o = valid_i;
        out_valid_o = 1'b0;
        out_rob_idx_o = rob_idx_i;
        out_pdst_o = pdst_i;
        out_data_o = 64'd0;
        out_status_o = '0;

        if (pipe_i == FPU_PIPE_FMV) begin
            ready_o = 1'b1;
            unsupported_o = 1'b0;
            out_valid_o = fmv_valid;
            out_data_o = (fmv_op_i == FMV_X_FROM_W ||
                fmv_op_i == FMV_X_FROM_D) ? fmv_int_result : fmv_fp_result;
        end else if (use_fpnew_i) begin
            ready_o = fpnew_ready;
            unsupported_o = fpnew_unsupported;
            out_valid_o = fpnew_out_valid;
            out_rob_idx_o = fpnew_out_rob_idx;
            out_pdst_o = fpnew_out_pdst;
            out_data_o = fpnew_out_data;
            out_status_o = fpnew_out_status;
        end else if (pipe_i == FPU_PIPE_MISC) begin
            ready_o = 1'b1;
            unsupported_o = 1'b0;
            out_valid_o = misc_valid;
            out_data_o = misc_result;
            out_status_o = misc_status;
        end
    end

endmodule
