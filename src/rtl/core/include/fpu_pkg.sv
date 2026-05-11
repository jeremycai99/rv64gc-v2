/* file: fpu_pkg.sv
 Description: Shared Phase 5 floating-point types and op encodings.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.1
*/

`ifndef FPU_PKG_SV
`define FPU_PKG_SV
package fpu_pkg;

    typedef enum logic [1:0] {
        FP_FMT_S = 2'd0,
        FP_FMT_D = 2'd1
    } fp_fmt_e;

    typedef enum logic [2:0] {
        FP_RM_RNE = 3'd0,
        FP_RM_RTZ = 3'd1,
        FP_RM_RDN = 3'd2,
        FP_RM_RUP = 3'd3,
        FP_RM_RMM = 3'd4,
        FP_RM_DYN = 3'd7
    } fp_rm_e;

    typedef struct packed {
        logic nv;
        logic dz;
        logic of;
        logic uf;
        logic nx;
    } fp_status_t;

    typedef enum logic [2:0] {
        FPU_PIPE_MISC = 3'd0,
        FPU_PIPE_FMA = 3'd1,
        FPU_PIPE_DIVSQRT = 3'd2,
        FPU_PIPE_FMV = 3'd3,
        FPU_PIPE_CONV = 3'd4
    } fpu_pipe_e;

    typedef enum logic [1:0] {
        FP_INT_FMT_8 = 2'd0,
        FP_INT_FMT_16 = 2'd1,
        FP_INT_FMT_32 = 2'd2,
        FP_INT_FMT_64 = 2'd3
    } fp_int_fmt_e;

    typedef enum logic [3:0] {
        FPU_OP_NONE = 4'd0,
        FPU_OP_ADD = 4'd1,
        FPU_OP_MUL = 4'd2,
        FPU_OP_DIV = 4'd3,
        FPU_OP_SQRT = 4'd4,
        FPU_OP_SGNJ = 4'd5,
        FPU_OP_MINMAX = 4'd6,
        FPU_OP_CMP = 4'd7,
        FPU_OP_CLASSIFY = 4'd8,
        FPU_OP_F2F = 4'd9,
        FPU_OP_F2I = 4'd10,
        FPU_OP_I2F = 4'd11,
        FPU_OP_FMADD = 4'd12,
        FPU_OP_FNMSUB = 4'd13
    } fpu_op_e;

    typedef enum logic [3:0] {
        FP_MISC_SGNJ = 4'd0,
        FP_MISC_SGNJN = 4'd1,
        FP_MISC_SGNJX = 4'd2,
        FP_MISC_MIN = 4'd3,
        FP_MISC_MAX = 4'd4,
        FP_MISC_EQ = 4'd5,
        FP_MISC_LT = 4'd6,
        FP_MISC_LE = 4'd7,
        FP_MISC_CLASS = 4'd8
    } fpu_misc_op_e;

    typedef enum logic [1:0] {
        FMV_W_FROM_X = 2'd0,
        FMV_X_FROM_W = 2'd1,
        FMV_D_FROM_X = 2'd2,
        FMV_X_FROM_D = 2'd3
    } fmv_op_e;

endpackage
`endif
