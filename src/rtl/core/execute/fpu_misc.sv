/* file: fpu_misc.sv
 Description: Phase 5 miscellaneous floating-point operations that do not use
 the future shared FMA or div/sqrt datapaths. Covers sign injection, min/max,
 compares, and class classification with NaN-box aware single-precision reads.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.2
*/

module fpu_misc
    import fpu_pkg::*;
(
    input  wire valid_i,
    input  fpu_misc_op_e op_i,
    input  fp_fmt_e fmt_i,
    input  wire [63:0] rs1_data_i,
    input  wire [63:0] rs2_data_i,
    output logic valid_o,
    output logic [63:0] result_o,
    output fp_status_t status_o
);

    localparam logic [31:0] CANONICAL_NAN_S = 32'h7fc0_0000;
    localparam logic [63:0] CANONICAL_NAN_D = 64'h7ff8_0000_0000_0000;

    // ----------------------------------------------------------------
    // Pre-computed NaN-boxed single-precision views (replaces fp32_view)
    // ----------------------------------------------------------------
    wire [31:0] rs1_s = (&rs1_data_i[63:32]) ? rs1_data_i[31:0] : CANONICAL_NAN_S;
    wire [31:0] rs2_s = (&rs2_data_i[63:32]) ? rs2_data_i[31:0] : CANONICAL_NAN_S;

    // ----------------------------------------------------------------
    // Pre-computed NaN / sNaN flags (replaces fp32_is_nan, fp32_is_snan,
    // fp64_is_nan, fp64_is_snan)
    // ----------------------------------------------------------------
    wire rs1_s_nan  = (&rs1_s[30:23]) && (rs1_s[22:0] != 23'd0);
    wire rs2_s_nan  = (&rs2_s[30:23]) && (rs2_s[22:0] != 23'd0);
    wire rs1_s_snan = (&rs1_s[30:23]) && (rs1_s[22:0] != 23'd0) && !rs1_s[22];
    wire rs2_s_snan = (&rs2_s[30:23]) && (rs2_s[22:0] != 23'd0) && !rs2_s[22];

    wire rs1_d_nan  = (&rs1_data_i[62:52]) && (rs1_data_i[51:0] != 52'd0);
    wire rs2_d_nan  = (&rs2_data_i[62:52]) && (rs2_data_i[51:0] != 52'd0);
    wire rs1_d_snan = (&rs1_data_i[62:52]) && (rs1_data_i[51:0] != 52'd0) && !rs1_data_i[51];
    wire rs2_d_snan = (&rs2_data_i[62:52]) && (rs2_data_i[51:0] != 52'd0) && !rs2_data_i[51];

    // ----------------------------------------------------------------
    // Pre-computed order keys (replaces fp32_order_key, fp64_order_key)
    // ----------------------------------------------------------------
    wire [31:0] rs1_s_order_key = rs1_s[31] ? ~rs1_s : {1'b1, rs1_s[30:0]};
    wire [31:0] rs2_s_order_key = rs2_s[31] ? ~rs2_s : {1'b1, rs2_s[30:0]};

    wire [63:0] rs1_d_order_key = rs1_data_i[63] ? ~rs1_data_i : {1'b1, rs1_data_i[62:0]};
    wire [63:0] rs2_d_order_key = rs2_data_i[63] ? ~rs2_data_i : {1'b1, rs2_data_i[62:0]};

    // ----------------------------------------------------------------
    // Pre-computed class bits (replaces fp32_class_bits, fp64_class_bits)
    // ----------------------------------------------------------------
    logic [9:0] rs1_s_class_bits;

    always_comb begin : fp32_classify
        logic        s_sign;
        logic [7:0]  s_exp;
        logic [22:0] s_frac;

        s_sign = rs1_s[31];
        s_exp  = rs1_s[30:23];
        s_frac = rs1_s[22:0];

        rs1_s_class_bits = 10'd0;
        if ((s_exp == 8'hff) && (s_frac == 23'd0))
            rs1_s_class_bits[s_sign ? 0 : 7] = 1'b1;
        else if ((s_exp == 8'hff) && s_frac[22])
            rs1_s_class_bits[9] = 1'b1;
        else if ((s_exp == 8'hff) && !s_frac[22])
            rs1_s_class_bits[8] = 1'b1;
        else if ((s_exp == 8'd0) && (s_frac == 23'd0))
            rs1_s_class_bits[s_sign ? 3 : 4] = 1'b1;
        else if ((s_exp == 8'd0) && (s_frac != 23'd0))
            rs1_s_class_bits[s_sign ? 2 : 5] = 1'b1;
        else
            rs1_s_class_bits[s_sign ? 1 : 6] = 1'b1;
    end

    logic [9:0] rs1_d_class_bits;

    always_comb begin : fp64_classify
        logic         d_sign;
        logic [10:0]  d_exp;
        logic [51:0]  d_frac;

        d_sign = rs1_data_i[63];
        d_exp  = rs1_data_i[62:52];
        d_frac = rs1_data_i[51:0];

        rs1_d_class_bits = 10'd0;
        if ((d_exp == 11'h7ff) && (d_frac == 52'd0))
            rs1_d_class_bits[d_sign ? 0 : 7] = 1'b1;
        else if ((d_exp == 11'h7ff) && d_frac[51])
            rs1_d_class_bits[9] = 1'b1;
        else if ((d_exp == 11'h7ff) && !d_frac[51])
            rs1_d_class_bits[8] = 1'b1;
        else if ((d_exp == 11'd0) && (d_frac == 52'd0))
            rs1_d_class_bits[d_sign ? 3 : 4] = 1'b1;
        else if ((d_exp == 11'd0) && (d_frac != 52'd0))
            rs1_d_class_bits[d_sign ? 2 : 5] = 1'b1;
        else
            rs1_d_class_bits[d_sign ? 1 : 6] = 1'b1;
    end

    // ----------------------------------------------------------------
    // Main operation mux
    // ----------------------------------------------------------------
    always_comb begin
        valid_o = valid_i;
        result_o = 64'd0;
        status_o = '0;

        if (fmt_i == FP_FMT_S) begin
            logic [31:0] result_s;
            result_s = CANONICAL_NAN_S;

            case (op_i)
                FP_MISC_SGNJ: begin
                    result_s = {rs2_s[31], rs1_s[30:0]};
                end
                FP_MISC_SGNJN: begin
                    result_s = {!rs2_s[31], rs1_s[30:0]};
                end
                FP_MISC_SGNJX: begin
                    result_s = {rs1_s[31] ^ rs2_s[31], rs1_s[30:0]};
                end
                FP_MISC_MIN: begin
                    status_o.nv = rs1_s_snan || rs2_s_snan;
                    if (rs1_s_nan && rs2_s_nan)
                        result_s = CANONICAL_NAN_S;
                    else if (rs1_s_nan)
                        result_s = rs2_s;
                    else if (rs2_s_nan)
                        result_s = rs1_s;
                    else if (rs1_s_order_key <= rs2_s_order_key)
                        result_s = rs1_s;
                    else
                        result_s = rs2_s;
                end
                FP_MISC_MAX: begin
                    status_o.nv = rs1_s_snan || rs2_s_snan;
                    if (rs1_s_nan && rs2_s_nan)
                        result_s = CANONICAL_NAN_S;
                    else if (rs1_s_nan)
                        result_s = rs2_s;
                    else if (rs2_s_nan)
                        result_s = rs1_s;
                    else if (rs1_s_order_key >= rs2_s_order_key)
                        result_s = rs1_s;
                    else
                        result_s = rs2_s;
                end
                FP_MISC_EQ: begin
                    result_o = {63'd0, !(rs1_s_nan || rs2_s_nan) && (rs1_s == rs2_s)};
                    status_o.nv = rs1_s_snan || rs2_s_snan;
                end
                FP_MISC_LT: begin
                    result_o = {63'd0, !(rs1_s_nan || rs2_s_nan) &&
                        (rs1_s_order_key < rs2_s_order_key)};
                    status_o.nv = rs1_s_nan || rs2_s_nan;
                end
                FP_MISC_LE: begin
                    result_o = {63'd0, !(rs1_s_nan || rs2_s_nan) &&
                        (rs1_s_order_key <= rs2_s_order_key)};
                    status_o.nv = rs1_s_nan || rs2_s_nan;
                end
                FP_MISC_CLASS: begin
                    result_o = {54'd0, rs1_s_class_bits};
                end
                default: begin
                    result_s = CANONICAL_NAN_S;
                end
            endcase

            if (!(op_i inside {FP_MISC_EQ, FP_MISC_LT, FP_MISC_LE, FP_MISC_CLASS}))
                result_o = {32'hffff_ffff, result_s};
        end else begin
            logic [63:0] result_d;
            result_d = CANONICAL_NAN_D;

            case (op_i)
                FP_MISC_SGNJ: begin
                    result_d = {rs2_data_i[63], rs1_data_i[62:0]};
                end
                FP_MISC_SGNJN: begin
                    result_d = {!rs2_data_i[63], rs1_data_i[62:0]};
                end
                FP_MISC_SGNJX: begin
                    result_d = {rs1_data_i[63] ^ rs2_data_i[63], rs1_data_i[62:0]};
                end
                FP_MISC_MIN: begin
                    status_o.nv = rs1_d_snan || rs2_d_snan;
                    if (rs1_d_nan && rs2_d_nan)
                        result_d = CANONICAL_NAN_D;
                    else if (rs1_d_nan)
                        result_d = rs2_data_i;
                    else if (rs2_d_nan)
                        result_d = rs1_data_i;
                    else if (rs1_d_order_key <= rs2_d_order_key)
                        result_d = rs1_data_i;
                    else
                        result_d = rs2_data_i;
                end
                FP_MISC_MAX: begin
                    status_o.nv = rs1_d_snan || rs2_d_snan;
                    if (rs1_d_nan && rs2_d_nan)
                        result_d = CANONICAL_NAN_D;
                    else if (rs1_d_nan)
                        result_d = rs2_data_i;
                    else if (rs2_d_nan)
                        result_d = rs1_data_i;
                    else if (rs1_d_order_key >= rs2_d_order_key)
                        result_d = rs1_data_i;
                    else
                        result_d = rs2_data_i;
                end
                FP_MISC_EQ: begin
                    result_o = {63'd0, !(rs1_d_nan || rs2_d_nan) &&
                        (rs1_data_i == rs2_data_i)};
                    status_o.nv = rs1_d_snan || rs2_d_snan;
                end
                FP_MISC_LT: begin
                    result_o = {63'd0, !(rs1_d_nan || rs2_d_nan) &&
                        (rs1_d_order_key < rs2_d_order_key)};
                    status_o.nv = rs1_d_nan || rs2_d_nan;
                end
                FP_MISC_LE: begin
                    result_o = {63'd0, !(rs1_d_nan || rs2_d_nan) &&
                        (rs1_d_order_key <= rs2_d_order_key)};
                    status_o.nv = rs1_d_nan || rs2_d_nan;
                end
                FP_MISC_CLASS: begin
                    result_o = {54'd0, rs1_d_class_bits};
                end
                default: begin
                    result_d = CANONICAL_NAN_D;
                end
            endcase

            if (!(op_i inside {FP_MISC_EQ, FP_MISC_LT, FP_MISC_LE, FP_MISC_CLASS}))
                result_o = result_d;
        end
    end

endmodule
