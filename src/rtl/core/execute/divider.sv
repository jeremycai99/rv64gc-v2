/* file: divider.sv
 * Description: Iterative 64-bit integer divider. Radix-2 restoring division.
 *              Takes 64 cycles for 64-bit ops, 32 for W variants.
 *              Supports DIV, DIVU, REM, REMU and W variants.
 *              Handles division by zero and signed overflow per RISC-V spec.
 *              State machine: IDLE -> RUNNING (1 bit/cycle) -> DONE.
 *              On flush, returns immediately to IDLE.
 * Version: 2.0
 */

module divider
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [63:0] operand_a,     // dividend
    input  logic [63:0] operand_b,     // divisor
    input  div_op_e     op,
    input  logic        is_w_op,
    input  logic        flush,         // cancel in-progress divide
    output logic        busy,          // cannot accept new input
    output logic        valid_out,
    output logic [63:0] result
);

    // =========================================================================
    // State machine
    // =========================================================================
    typedef enum logic [1:0] {
        ST_IDLE    = 2'd0,
        ST_RUNNING = 2'd1,
        ST_DONE    = 2'd2
    } state_e;

    state_e state_r;

    logic [5:0]  iter_r;
    logic [5:0]  max_iter;

    logic [63:0] dividend_r;
    logic [63:0] divisor_r;
    logic [63:0] quotient_r;
    logic [63:0] remainder_r;
    logic        negate_quo_r;
    logic        negate_rem_r;
    logic        is_rem_r;       // 1 = remainder op, 0 = division op
    logic        is_w_r;
    logic        special_case_r; // div-by-zero or signed overflow
    logic [63:0] special_result_r;

    assign busy = (state_r != ST_IDLE);

    // =========================================================================
    // Input preprocessing
    // =========================================================================
    wire is_signed_op = (op == DIV_DIV) || (op == DIV_REM);
    wire is_rem_op    = (op == DIV_REM) || (op == DIV_REMU);

    // Sign-extend or zero-extend lower 32 bits for W variants
    wire [63:0] in_a = is_w_op ?
        {{32{operand_a[31] & is_signed_op}}, operand_a[31:0]} : operand_a;
    wire [63:0] in_b = is_w_op ?
        {{32{operand_b[31] & is_signed_op}}, operand_b[31:0]} : operand_b;

    // =========================================================================
    // Compute-state helpers (hoisted for clarity)
    // =========================================================================
    wire [5:0]  bit_pos    = is_w_r ? (6'd31 - iter_r) : (6'd63 - iter_r);
    wire [63:0] shifted_rem = {remainder_r[62:0], dividend_r[bit_pos]};

    // Final result negation
    wire [63:0] final_quo = negate_quo_r ? (~quotient_r + 64'd1) : quotient_r;
    wire [63:0] final_rem = negate_rem_r ? (~remainder_r + 64'd1) : remainder_r;

    // W-variant sign extension
    wire [63:0] final_quo_w = {{32{final_quo[31]}}, final_quo[31:0]};
    wire [63:0] final_rem_w = {{32{final_rem[31]}}, final_rem[31:0]};

    // =========================================================================
    // Main state machine
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            state_r   <= ST_IDLE;
            valid_out <= 1'b0;
        end else begin
            valid_out <= 1'b0;

            case (state_r)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (valid_in) begin
                        is_rem_r <= is_rem_op;
                        is_w_r   <= is_w_op;
                        max_iter <= is_w_op ? 6'd32 : 6'd64;

                        // Division by zero
                        if (in_b == 64'd0) begin
                            special_case_r   <= 1'b1;
                            special_result_r <= is_rem_op ? in_a : 64'hFFFF_FFFF_FFFF_FFFF;
                            state_r          <= ST_DONE;

                        // Signed overflow (64-bit): most negative / -1
                        end else if (is_signed_op && !is_w_op &&
                                     in_a == 64'h8000_0000_0000_0000 &&
                                     in_b == 64'hFFFF_FFFF_FFFF_FFFF) begin
                            special_case_r   <= 1'b1;
                            special_result_r <= is_rem_op ? 64'd0 : 64'h8000_0000_0000_0000;
                            state_r          <= ST_DONE;

                        // Signed overflow (W-variant): 0x80000000 / -1
                        end else if (is_signed_op && is_w_op &&
                                     in_a[31:0] == 32'h8000_0000 &&
                                     in_b[31:0] == 32'hFFFF_FFFF) begin
                            special_case_r   <= 1'b1;
                            special_result_r <= is_rem_op ? 64'd0 : {{32{1'b1}}, 32'h8000_0000};
                            state_r          <= ST_DONE;

                        // Normal division -- take absolute values for signed ops
                        end else begin
                            special_case_r <= 1'b0;
                            negate_quo_r   <= is_signed_op && (in_a[63] ^ in_b[63]);
                            negate_rem_r   <= is_signed_op && in_a[63];
                            dividend_r     <= (is_signed_op && in_a[63]) ? (~in_a + 64'd1) : in_a;
                            divisor_r      <= (is_signed_op && in_b[63]) ? (~in_b + 64'd1) : in_b;
                            quotient_r     <= 64'd0;
                            remainder_r    <= 64'd0;
                            iter_r         <= 6'd0;
                            state_r        <= ST_RUNNING;
                        end
                    end
                end

                // ---------------------------------------------------------
                ST_RUNNING: begin
                    if (shifted_rem >= divisor_r) begin
                        remainder_r         <= shifted_rem - divisor_r;
                        quotient_r[bit_pos] <= 1'b1;
                    end else begin
                        remainder_r         <= shifted_rem;
                        quotient_r[bit_pos] <= 1'b0;
                    end

                    if (iter_r == max_iter - 6'd1)
                        state_r <= ST_DONE;
                    iter_r <= iter_r + 6'd1;
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    valid_out <= 1'b1;

                    if (special_case_r)
                        result <= is_w_r ? {{32{special_result_r[31]}}, special_result_r[31:0]}
                                         : special_result_r;
                    else if (!is_rem_r)
                        result <= is_w_r ? final_quo_w : final_quo;
                    else
                        result <= is_w_r ? final_rem_w : final_rem;

                    state_r <= ST_IDLE;
                end

                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
