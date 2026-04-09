/* file: alu.sv
 * Description: 64-bit ALU for the v2 OoO core.  Purely combinational,
 *              1-cycle latency.  Supports all RV64I base ALU operations
 *              plus Zba (address generation), Zbb (bit manipulation),
 *              Zbs (single-bit), and Zicond (conditional) extensions.
 *              W-suffix variants operate on the lower 32 bits and
 *              sign-extend the result to 64 bits.
 * Version: 2.0
 */

module alu
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic [63:0] operand_a,   // rs1 value or PC
    input  logic [63:0] operand_b,   // rs2 value or immediate
    input  alu_op_e     op,
    input  logic        is_w_op,     // 1 = 32-bit W suffix operation
    output logic [63:0] result
);

    // =========================================================================
    // Shift amount: 6 bits for 64-bit, 5 bits for 32-bit W ops
    // =========================================================================
    logic [5:0] shamt;
    assign shamt = is_w_op ? {1'b0, operand_b[4:0]} : operand_b[5:0];

    // =========================================================================
    // 32-bit operands for W-suffix operations
    // =========================================================================
    logic [31:0] a32, b32;
    assign a32 = operand_a[31:0];
    assign b32 = operand_b[31:0];

    // =========================================================================
    // Base integer 32-bit intermediate results
    // =========================================================================
    logic [31:0] add32, sub32, sll32, srl32, sra32;
    assign add32 = a32 + b32;
    assign sub32 = a32 - b32;
    assign sll32 = a32 << shamt[4:0];
    assign srl32 = a32 >> shamt[4:0];
    assign sra32 = $signed(a32) >>> shamt[4:0];

    // 64-bit arithmetic right shift (explicit signed intermediate)
    logic signed [63:0] sra64_in;
    logic [63:0] sra64_out;
    assign sra64_in  = $signed(operand_a);
    assign sra64_out = sra64_in >>> shamt;

    // Sign-extend 32 -> 64
    wire [63:0] sext_add32 = {{32{add32[31]}}, add32};
    wire [63:0] sext_sub32 = {{32{sub32[31]}}, sub32};
    wire [63:0] sext_sll32 = {{32{sll32[31]}}, sll32};
    wire [63:0] sext_srl32 = {{32{srl32[31]}}, srl32};
    wire [63:0] sext_sra32 = {{32{sra32[31]}}, sra32};

    // =========================================================================
    // Zba: address generation helpers
    // For W variants (add.uw, sh*add.uw): zero-extend rs1[31:0] before shift
    // =========================================================================
    logic [63:0] zba_src;
    assign zba_src = is_w_op ? {32'b0, a32} : operand_a;

    logic [63:0] sh1add_res, sh2add_res, sh3add_res;
    assign sh1add_res = (zba_src << 1) + operand_b;
    assign sh2add_res = (zba_src << 2) + operand_b;
    assign sh3add_res = (zba_src << 3) + operand_b;

    // =========================================================================
    // Zbb: CLZ / CTZ / CPOP helpers
    // =========================================================================
    logic [6:0] clz_result, ctz_result, cpop_result;

    // CLZ - count leading zeros
    always_comb begin
        if (is_w_op) begin
            clz_result = 7'd32;
            for (int i = 31; i >= 0; i--) begin
                if (operand_a[i]) begin
                    clz_result = 7'(31 - i);
                    break;
                end
            end
        end else begin
            clz_result = 7'd64;
            for (int i = 63; i >= 0; i--) begin
                if (operand_a[i]) begin
                    clz_result = 7'(63 - i);
                    break;
                end
            end
        end
    end

    // CTZ - count trailing zeros
    always_comb begin
        if (is_w_op) begin
            ctz_result = 7'd32;
            for (int i = 0; i < 32; i++) begin
                if (operand_a[i]) begin
                    ctz_result = 7'(i);
                    break;
                end
            end
        end else begin
            ctz_result = 7'd64;
            for (int i = 0; i < 64; i++) begin
                if (operand_a[i]) begin
                    ctz_result = 7'(i);
                    break;
                end
            end
        end
    end

    // CPOP - population count
    always_comb begin
        cpop_result = 7'd0;
        if (is_w_op) begin
            for (int i = 0; i < 32; i++) begin
                cpop_result = cpop_result + {6'b0, operand_a[i]};
            end
        end else begin
            for (int i = 0; i < 64; i++) begin
                cpop_result = cpop_result + {6'b0, operand_a[i]};
            end
        end
    end

    // =========================================================================
    // Zbb: rotate helpers
    // =========================================================================
    logic [63:0] rol64, ror64;
    logic [31:0] rol32, ror32;

    // Complementary shift amounts (need wider arithmetic to avoid overflow)
    logic [5:0] rshamt64, lshamt64;
    logic [4:0] rshamt32, lshamt32;
    assign rshamt64 = (6'd0 - shamt);         // equivalent to (64 - shamt) mod 64
    assign lshamt64 = (6'd0 - shamt);
    assign rshamt32 = (5'd0 - shamt[4:0]);    // equivalent to (32 - shamt) mod 32
    assign lshamt32 = (5'd0 - shamt[4:0]);

    assign rol64 = (operand_a << shamt) | (operand_a >> rshamt64);
    assign ror64 = (operand_a >> shamt) | (operand_a << lshamt64);
    assign rol32 = (a32 << shamt[4:0]) | (a32 >> rshamt32);
    assign ror32 = (a32 >> shamt[4:0]) | (a32 << lshamt32);

    // =========================================================================
    // Zbb: REV8 and ORC.B helpers
    // =========================================================================
    logic [63:0] rev8_result;
    assign rev8_result = {operand_a[7:0],   operand_a[15:8],
                          operand_a[23:16],  operand_a[31:24],
                          operand_a[39:32],  operand_a[47:40],
                          operand_a[55:48],  operand_a[63:56]};

    logic [63:0] orcb_result;
    assign orcb_result = {{8{|operand_a[63:56]}}, {8{|operand_a[55:48]}},
                          {8{|operand_a[47:40]}}, {8{|operand_a[39:32]}},
                          {8{|operand_a[31:24]}}, {8{|operand_a[23:16]}},
                          {8{|operand_a[15:8]}},  {8{|operand_a[7:0]}}};

    // =========================================================================
    // Zbs: single-bit helpers
    // =========================================================================
    logic [63:0] bit_mask;
    assign bit_mask = 64'd1 << shamt;

    // =========================================================================
    // Main ALU operation mux
    // =========================================================================
    logic [63:0] full_result;

    always_comb begin
        full_result = 64'd0;

        case (op)
            // -----------------------------------------------------------------
            // Base RV64I
            // -----------------------------------------------------------------
            ALU_ADD: begin
                full_result = is_w_op ? sext_add32
                                      : (operand_a + operand_b);
            end

            ALU_SUB: begin
                full_result = is_w_op ? sext_sub32
                                      : (operand_a - operand_b);
            end

            ALU_AND:  full_result = operand_a & operand_b;
            ALU_OR:   full_result = operand_a | operand_b;
            ALU_XOR:  full_result = operand_a ^ operand_b;

            ALU_SLT:  full_result = {63'd0, $signed(operand_a) < $signed(operand_b)};
            ALU_SLTU: full_result = {63'd0, operand_a < operand_b};

            ALU_SLL: begin
                full_result = is_w_op ? sext_sll32
                                      : (operand_a << shamt);
            end

            ALU_SRL: begin
                full_result = is_w_op ? sext_srl32
                                      : (operand_a >> shamt);
            end

            ALU_SRA: begin
                full_result = is_w_op ? sext_sra32 : sra64_out;
            end

            ALU_LUI:   full_result = operand_b;
            ALU_PASS2: full_result = operand_a + operand_b;

            // -----------------------------------------------------------------
            // Zba - Address Generation
            // -----------------------------------------------------------------
            ALU_SH1ADD: full_result = sh1add_res;
            ALU_SH2ADD: full_result = sh2add_res;
            ALU_SH3ADD: full_result = sh3add_res;

            // -----------------------------------------------------------------
            // Zbb - Min / Max
            // -----------------------------------------------------------------
            ALU_MIN:  full_result = ($signed(operand_a) < $signed(operand_b))
                                    ? operand_a : operand_b;
            ALU_MAX:  full_result = ($signed(operand_a) >= $signed(operand_b))
                                    ? operand_a : operand_b;
            ALU_MINU: full_result = (operand_a < operand_b)
                                    ? operand_a : operand_b;
            ALU_MAXU: full_result = (operand_a >= operand_b)
                                    ? operand_a : operand_b;

            // -----------------------------------------------------------------
            // Zbb - Count
            // -----------------------------------------------------------------
            ALU_CLZ:  full_result = {57'd0, clz_result};
            ALU_CTZ:  full_result = {57'd0, ctz_result};
            ALU_CPOP: full_result = {57'd0, cpop_result};

            // -----------------------------------------------------------------
            // Zbb - Bitwise with inversion
            // -----------------------------------------------------------------
            ALU_ANDN: full_result = operand_a & ~operand_b;
            ALU_ORN:  full_result = operand_a | ~operand_b;
            ALU_XNOR: full_result = ~(operand_a ^ operand_b);

            // -----------------------------------------------------------------
            // Zbb - Rotate
            // -----------------------------------------------------------------
            ALU_ROL: begin
                full_result = is_w_op ? {{32{rol32[31]}}, rol32} : rol64;
            end

            ALU_ROR: begin
                full_result = is_w_op ? {{32{ror32[31]}}, ror32} : ror64;
            end

            // -----------------------------------------------------------------
            // Zbb - Sign extend / byte ops
            // -----------------------------------------------------------------
            ALU_SEXTB: full_result = {{56{operand_a[7]}},  operand_a[7:0]};
            ALU_SEXTH: full_result = {{48{operand_a[15]}}, operand_a[15:0]};
            ALU_REV8:  full_result = rev8_result;
            ALU_ORCB:  full_result = orcb_result;

            // -----------------------------------------------------------------
            // Zbs - Single-bit
            // -----------------------------------------------------------------
            ALU_BSET: full_result = operand_a | bit_mask;
            ALU_BCLR: full_result = operand_a & ~bit_mask;
            ALU_BINV: full_result = operand_a ^ bit_mask;
            ALU_BEXT: full_result = {63'd0, operand_a[shamt]};

            // -----------------------------------------------------------------
            // Zicond - Conditional zero
            // -----------------------------------------------------------------
            ALU_CZERO_EQZ: full_result = (operand_b == 64'd0) ? 64'd0 : operand_a;
            ALU_CZERO_NEZ: full_result = (operand_b != 64'd0) ? 64'd0 : operand_a;

            default: full_result = 64'd0;
        endcase
    end

    assign result = full_result;

endmodule
