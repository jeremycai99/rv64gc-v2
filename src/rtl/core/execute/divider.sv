/* file: divider.sv
 Description: Multi-cycle integer divider (RV64M DIV/REM).
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module divider
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [63:0] operand_a,     // dividend
    input  wire [63:0] operand_b,     // divisor
    input  div_op_e     op,
    input  wire        is_w_op,
    input  wire        flush,         // cancel in-progress divide
    output reg        busy,          // cannot accept new input
    output reg        valid_out,
    output reg [63:0] result
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

    localparam int DIV_BITS_PER_CYCLE = 16;

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

    // Final result negation
    wire [63:0] final_quo = negate_quo_r ? (~quotient_r + 64'd1) : quotient_r;
    wire [63:0] final_rem = negate_rem_r ? (~remainder_r + 64'd1) : remainder_r;

    // W-variant sign extension
    wire [63:0] final_quo_w = {{32{final_quo[31]}}, final_quo[31:0]};
    wire [63:0] final_rem_w = {{32{final_rem[31]}}, final_rem[31:0]};

    // Multiple restoring-division bit steps per cycle.  This preserves the
    // existing multi-cycle contract while reducing DIVW/DIV head stalls in
    // integer benchmark loops.
    logic [63:0] quotient_next;
    logic [63:0] remainder_next;

    // Combinational final-result variants using *_next (last running-iter) values,
    // used when asserting valid_out on the final iteration of ST_RUNNING so we
    // can skip the extra ST_DONE cycle.
    wire [63:0] final_quo_c   = negate_quo_r ? (~quotient_next + 64'd1) : quotient_next;
    wire [63:0] final_rem_c   = negate_rem_r ? (~remainder_next + 64'd1) : remainder_next;
    wire [63:0] final_quo_w_c = {{32{final_quo_c[31]}}, final_quo_c[31:0]};
    wire [63:0] final_rem_w_c = {{32{final_rem_c[31]}}, final_rem_c[31:0]};

    always_comb begin
        quotient_next  = quotient_r;
        remainder_next = remainder_r;

        for (int k = 0; k < DIV_BITS_PER_CYCLE; k++) begin
            logic [5:0]  bit_pos_step;
            logic [63:0] shifted_rem_step;

            bit_pos_step = (is_w_r ? 6'd31 : 6'd63)
                         - (iter_r * 6'(DIV_BITS_PER_CYCLE))
                         - 6'(k);
            shifted_rem_step = {remainder_next[62:0], dividend_r[bit_pos_step]};

            if (shifted_rem_step >= divisor_r) begin
                remainder_next = shifted_rem_step - divisor_r;
                quotient_next[bit_pos_step] = 1'b1;
            end else begin
                remainder_next = shifted_rem_step;
                quotient_next[bit_pos_step] = 1'b0;
            end
        end
    end

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
                        max_iter <= is_w_op
                                  ? 6'(32 / DIV_BITS_PER_CYCLE)
                                  : 6'(64 / DIV_BITS_PER_CYCLE);

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
                    remainder_r <= remainder_next;
                    quotient_r  <= quotient_next;

                    if (iter_r == max_iter - 6'd1) begin
                        // Final iteration: output result combinationally and
                        // skip the extra ST_DONE cycle.  Saves 1 cycle of
                        // latency for every non-special-case division.
                        valid_out <= 1'b1;
                        if (!is_rem_r)
                            result <= is_w_r ? final_quo_w_c : final_quo_c;
                        else
                            result <= is_w_r ? final_rem_w_c : final_rem_c;
                        state_r <= ST_IDLE;
                    end else begin
                        iter_r <= iter_r + 6'd1;
                    end
                end

                // ---------------------------------------------------------
                // Reached only for special cases (div-by-zero, signed
                // overflow) where ST_IDLE transitions directly to ST_DONE.
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
