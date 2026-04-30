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
    // Combinational product + result computation (no input register stage).
    // Downstream s1_valid/s2_valid shadow signals are retained so tb probes
    // and the mul_rob_idx_s1/s2 pipeline in core_top continue to work.
    // Latency from valid_in to valid_out is now 1 cycle.
    // =========================================================================
    // Sign extension depends on operation:
    //   MUL/MULH:   signed x signed
    //   MULHU:      unsigned x unsigned
    //   MULHSU:     signed x unsigned
    wire [63:0] ext_a = is_w_op ? {{32{operand_a[31]}}, operand_a[31:0]} : operand_a;
    wire [63:0] ext_b = is_w_op ? {{32{operand_b[31]}}, operand_b[31:0]} : operand_b;

    logic signed [127:0] product_ss;
    logic signed [127:0] product_su;
    logic        [127:0] product_uu;

    assign product_ss = $signed(ext_a) * $signed(ext_b);
    assign product_su = $signed(ext_a) * $signed({1'b0, ext_b});
    assign product_uu = ext_a * ext_b;

    logic [127:0] product_sel;
    always_comb begin
        case (op)
            MUL_MUL:    product_sel = product_ss[127:0];
            MUL_MULH:   product_sel = product_ss[127:0];
            MUL_MULHSU: product_sel = product_su[127:0];
            MUL_MULHU:  product_sel = product_uu;
            default:    product_sel = product_ss[127:0];
        endcase
    end

    logic [63:0] result_sel;
    always_comb begin
        case (op)
            MUL_MUL: begin
                if (is_w_op)
                    result_sel = {{32{product_sel[31]}}, product_sel[31:0]};
                else
                    result_sel = product_sel[63:0];
            end
            MUL_MULH:   result_sel = product_sel[127:64];
            MUL_MULHSU: result_sel = product_sel[127:64];
            MUL_MULHU:  result_sel = product_sel[127:64];
            default:    result_sel = product_sel[63:0];
        endcase
    end

    // Single register stage: latch result and valid.
    logic        s1_valid;
    logic [63:0] s1_result;
    logic        s2_valid;
    logic [63:0] s2_result;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
        end else begin
            s1_valid <= valid_in;
            if (valid_in) begin
                s1_result <= result_sel;
            end
            // s2 is retained for tb/core_top compatibility but is pass-through.
            s2_valid  <= s1_valid;
            s2_result <= s1_result;
        end
    end

    assign valid_out = s1_valid;
    assign result    = s1_result;

endmodule
