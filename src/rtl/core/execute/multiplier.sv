/* file: multiplier.sv
 Description: Pipelined integer multiplier (RV64M MUL/MULH variants).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module multiplier
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  mul_op_e     op,
    input  logic        is_w_op,
    input  logic        flush,         // cancel in-flight operations
    output logic        valid_out,
    output logic [63:0] result
);

    // =========================================================================
    // Stage 1 registers: capture and sign-extend operands
    // =========================================================================
    logic        s1_valid;
    logic [63:0] s1_a, s1_b;
    mul_op_e     s1_op;
    logic        s1_is_w;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= valid_in;
            if (valid_in) begin
                // For W variants, sign-extend the lower 32 bits
                s1_a    <= is_w_op ? {{32{operand_a[31]}}, operand_a[31:0]} : operand_a;
                s1_b    <= is_w_op ? {{32{operand_b[31]}}, operand_b[31:0]} : operand_b;
                s1_op   <= op;
                s1_is_w <= is_w_op;
            end
        end
    end

    // =========================================================================
    // Stage 2: compute 128-bit product
    // =========================================================================
    // Sign extension depends on operation:
    //   MUL/MULH:   signed x signed
    //   MULHU:      unsigned x unsigned
    //   MULHSU:     signed x unsigned
    logic signed [127:0] product_ss;
    logic signed [127:0] product_su;
    logic        [127:0] product_uu;

    assign product_ss = $signed(s1_a) * $signed(s1_b);
    assign product_su = $signed(s1_a) * $signed({1'b0, s1_b});
    assign product_uu = s1_a * s1_b;

    logic        s2_valid;
    logic [127:0] s2_product;
    mul_op_e     s2_op;
    logic        s2_is_w;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                case (s1_op)
                    MUL_MUL:    s2_product <= product_ss[127:0];
                    MUL_MULH:   s2_product <= product_ss[127:0];
                    MUL_MULHSU: s2_product <= product_su[127:0];
                    MUL_MULHU:  s2_product <= product_uu;
                    default:    s2_product <= product_ss[127:0];
                endcase
                s2_op   <= s1_op;
                s2_is_w <= s1_is_w;
            end
        end
    end

    // =========================================================================
    // Stage 3: select upper/lower half, handle W-suffix
    // =========================================================================
    logic [63:0] result_sel;
    always_comb begin
        case (s2_op)
            MUL_MUL: begin
                if (s2_is_w)
                    result_sel = {{32{s2_product[31]}}, s2_product[31:0]};
                else
                    result_sel = s2_product[63:0];
            end
            MUL_MULH:   result_sel = s2_product[127:64];
            MUL_MULHSU: result_sel = s2_product[127:64];
            MUL_MULHU:  result_sel = s2_product[127:64];
            default:    result_sel = s2_product[63:0];
        endcase
    end

    logic        s3_valid;
    logic [63:0] s3_result;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid  <= s2_valid;
            s3_result <= result_sel;
        end
    end

    assign valid_out = s3_valid;
    assign result    = s3_result;

endmodule
