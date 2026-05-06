/* file: tb_alu.sv
 * Description: Testbench for the v2 ALU.  Exercises every operation with
 *              multiple test vectors including edge cases, W-suffix variants,
 *              and boundary values (0, MAX, MIN, all-ones).
 *              Structured as a clocked state machine for Verilator --no-timing.
 * Version: 2.0
 */

module tb_alu
    import rv64gc_pkg::*;
    import uarch_pkg::*;
();

    // Clock driven from C++ harness
    logic clk;

    // DUT signals
    logic [63:0] operand_a;
    logic [63:0] operand_b;
    alu_op_e     op;
    logic        is_w_op;
    logic        is_unsigned;
    logic [63:0] result;

    // Test tracking
    int pass_count;
    int fail_count;
    int test_num;
    logic [63:0] expected;

    // DUT instantiation
    alu dut (
        .operand_a (operand_a),
        .operand_b (operand_b),
        .op        (op),
        .is_w_op   (is_w_op),
        .is_unsigned(is_unsigned),
        .result    (result)
    );

    // Total number of tests (update if adding/removing cases)
    localparam int NUM_TESTS = 116;

    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;
    end

    // Set inputs combinationally based on test_num
    always @(*) begin
        operand_a = 64'd0;
        operand_b = 64'd0;
        op        = ALU_ADD;
        is_w_op   = 1'b0;
        is_unsigned = 1'b0;
        expected  = 64'd0;

        case (test_num)
            // --- ALU_ADD (64-bit) ---
            0: begin op=ALU_ADD; operand_a=64'd100; operand_b=64'd200; expected=64'd300; end
            1: begin op=ALU_ADD; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd1; expected=64'd0; end
            2: begin op=ALU_ADD; operand_a=64'h00000000_7FFFFFFF; operand_b=64'd1; expected=64'h00000000_80000000; end
            // --- ADDW ---
            3: begin op=ALU_ADD; is_w_op=1; operand_a=64'h00000000_7FFFFFFF; operand_b=64'd1; expected=64'hFFFFFFFF_80000000; end
            4: begin op=ALU_ADD; is_w_op=1; operand_a=64'hDEADBEEF_00000005; operand_b=64'h12345678_00000003; expected=64'h00000000_00000008; end
            // --- ALU_SUB ---
            5: begin op=ALU_SUB; operand_a=64'd300; operand_b=64'd100; expected=64'd200; end
            6: begin op=ALU_SUB; operand_a=64'd0; operand_b=64'd1; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- SUBW ---
            7: begin op=ALU_SUB; is_w_op=1; operand_a=64'h00000000_80000000; operand_b=64'd1; expected=64'h00000000_7FFFFFFF; end
            8: begin op=ALU_SUB; is_w_op=1; operand_a=64'd0; operand_b=64'd1; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- ALU_AND ---
            9:  begin op=ALU_AND; operand_a=64'hFF00FF00_FF00FF00; operand_b=64'h0F0F0F0F_0F0F0F0F; expected=64'h0F000F00_0F000F00; end
            10: begin op=ALU_AND; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'h12345678_9ABCDEF0; expected=64'h12345678_9ABCDEF0; end
            11: begin op=ALU_AND; operand_a=64'd0; operand_b=64'hFFFFFFFF_FFFFFFFF; expected=64'd0; end
            // --- ALU_OR ---
            12: begin op=ALU_OR; operand_a=64'hFF00FF00_00000000; operand_b=64'h00FF00FF_00000000; expected=64'hFFFFFFFF_00000000; end
            13: begin op=ALU_OR; operand_a=64'd0; operand_b=64'd0; expected=64'd0; end
            // --- ALU_XOR ---
            14: begin op=ALU_XOR; operand_a=64'hAAAAAAAA_AAAAAAAA; operand_b=64'h55555555_55555555; expected=64'hFFFFFFFF_FFFFFFFF; end
            15: begin op=ALU_XOR; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'hFFFFFFFF_FFFFFFFF; expected=64'd0; end
            // --- ALU_SLT ---
            16: begin op=ALU_SLT; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd0; expected=64'd1; end
            17: begin op=ALU_SLT; operand_a=64'd5; operand_b=64'd3; expected=64'd0; end
            18: begin op=ALU_SLT; operand_a=64'h80000000_00000000; operand_b=64'h7FFFFFFF_FFFFFFFF; expected=64'd1; end
            // --- ALU_SLTU ---
            19: begin op=ALU_SLTU; operand_a=64'd3; operand_b=64'd5; expected=64'd1; end
            20: begin op=ALU_SLTU; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd0; expected=64'd0; end
            // --- ALU_SLL ---
            21: begin op=ALU_SLL; operand_a=64'd1; operand_b=64'd63; expected=64'h80000000_00000000; end
            22: begin op=ALU_SLL; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd0; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- SLLW ---
            23: begin op=ALU_SLL; is_w_op=1; operand_a=64'd1; operand_b=64'd31; expected=64'hFFFFFFFF_80000000; end
            24: begin op=ALU_SLL; is_w_op=1; operand_a=64'd1; operand_b=64'd15; expected=64'h00000000_00008000; end
            // --- ALU_SRL ---
            25: begin op=ALU_SRL; operand_a=64'h80000000_00000000; operand_b=64'd63; expected=64'd1; end
            // --- SRLW ---
            26: begin op=ALU_SRL; is_w_op=1; operand_a=64'h00000000_80000000; operand_b=64'd31; expected=64'h00000000_00000001; end
            27: begin op=ALU_SRL; is_w_op=1; operand_a=64'hFFFFFFFF_FFFF0000; operand_b=64'd16; expected=64'h00000000_0000FFFF; end
            // --- ALU_SRA ---
            28: begin op=ALU_SRA; operand_a=64'h80000000_00000000; operand_b=64'd63; expected=64'hFFFFFFFF_FFFFFFFF; end
            29: begin op=ALU_SRA; operand_a=64'h40000000_00000000; operand_b=64'd62; expected=64'd1; end
            // --- SRAW ---
            30: begin op=ALU_SRA; is_w_op=1; operand_a=64'h00000000_80000000; operand_b=64'd31; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- ALU_LUI ---
            31: begin op=ALU_LUI; operand_a=64'hDEAD; operand_b=64'h00000000_FFFFF000; expected=64'h00000000_FFFFF000; end
            // --- ALU_PASS2 (AUIPC) ---
            32: begin op=ALU_PASS2; operand_a=64'h80000000; operand_b=64'h1000; expected=64'h80001000; end
            // --- SH1ADD ---
            33: begin op=ALU_SH1ADD; operand_a=64'd10; operand_b=64'd100; expected=64'd120; end
            34: begin op=ALU_SH1ADD; operand_a=64'h80000000_00000001; operand_b=64'd0; expected=64'h00000000_00000002; end
            // --- SH1ADD.UW ---
            35: begin op=ALU_SH1ADD; is_w_op=1; operand_a=64'hFFFFFFFF_80000001; operand_b=64'd0; expected=64'h00000001_00000002; end
            // --- SH2ADD ---
            36: begin op=ALU_SH2ADD; operand_a=64'd10; operand_b=64'd100; expected=64'd140; end
            // --- SH2ADD.UW ---
            37: begin op=ALU_SH2ADD; is_w_op=1; operand_a=64'hFFFFFFFF_00000004; operand_b=64'd0; expected=64'h00000000_00000010; end
            // --- SH3ADD ---
            38: begin op=ALU_SH3ADD; operand_a=64'd10; operand_b=64'd100; expected=64'd180; end
            // --- SH3ADD.UW ---
            39: begin op=ALU_SH3ADD; is_w_op=1; operand_a=64'hFFFFFFFF_00000002; operand_b=64'd0; expected=64'h00000000_00000010; end
            // --- MIN ---
            40: begin op=ALU_MIN; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd5; expected=64'hFFFFFFFF_FFFFFFFF; end
            41: begin op=ALU_MIN; operand_a=64'd10; operand_b=64'd20; expected=64'd10; end
            42: begin op=ALU_MIN; operand_a=64'h80000000_00000000; operand_b=64'h7FFFFFFF_FFFFFFFF; expected=64'h80000000_00000000; end
            // --- MAX ---
            43: begin op=ALU_MAX; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd5; expected=64'd5; end
            44: begin op=ALU_MAX; operand_a=64'd10; operand_b=64'd20; expected=64'd20; end
            45: begin op=ALU_MAX; operand_a=64'h80000000_00000000; operand_b=64'h7FFFFFFF_FFFFFFFF; expected=64'h7FFFFFFF_FFFFFFFF; end
            // --- MINU ---
            46: begin op=ALU_MINU; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd5; expected=64'd5; end
            47: begin op=ALU_MINU; operand_a=64'd0; operand_b=64'd1; expected=64'd0; end
            // --- MAXU ---
            48: begin op=ALU_MAXU; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd5; expected=64'hFFFFFFFF_FFFFFFFF; end
            49: begin op=ALU_MAXU; operand_a=64'd0; operand_b=64'd0; expected=64'd0; end
            // --- CLZ ---
            50: begin op=ALU_CLZ; operand_a=64'd0; expected=64'd64; end
            51: begin op=ALU_CLZ; operand_a=64'h80000000_00000000; expected=64'd0; end
            52: begin op=ALU_CLZ; operand_a=64'h00000000_00000001; expected=64'd63; end
            53: begin op=ALU_CLZ; operand_a=64'h00000000_80000000; expected=64'd32; end
            // --- CLZW ---
            54: begin op=ALU_CLZ; is_w_op=1; operand_a=64'd0; expected=64'd32; end
            55: begin op=ALU_CLZ; is_w_op=1; operand_a=64'hFFFFFFFF_80000000; expected=64'd0; end
            56: begin op=ALU_CLZ; is_w_op=1; operand_a=64'hFFFFFFFF_00000001; expected=64'd31; end
            // --- CTZ ---
            57: begin op=ALU_CTZ; operand_a=64'd0; expected=64'd64; end
            58: begin op=ALU_CTZ; operand_a=64'd1; expected=64'd0; end
            59: begin op=ALU_CTZ; operand_a=64'h80000000_00000000; expected=64'd63; end
            60: begin op=ALU_CTZ; operand_a=64'h00000000_00000100; expected=64'd8; end
            // --- CTZW ---
            61: begin op=ALU_CTZ; is_w_op=1; operand_a=64'd0; expected=64'd32; end
            62: begin op=ALU_CTZ; is_w_op=1; operand_a=64'hFFFFFFFF_80000000; expected=64'd31; end
            // --- CPOP ---
            63: begin op=ALU_CPOP; operand_a=64'd0; expected=64'd0; end
            64: begin op=ALU_CPOP; operand_a=64'hFFFFFFFF_FFFFFFFF; expected=64'd64; end
            65: begin op=ALU_CPOP; operand_a=64'hAAAAAAAA_AAAAAAAA; expected=64'd32; end
            // --- CPOPW ---
            66: begin op=ALU_CPOP; is_w_op=1; operand_a=64'hFFFFFFFF_FFFFFFFF; expected=64'd32; end
            67: begin op=ALU_CPOP; is_w_op=1; operand_a=64'hFFFFFFFF_0000000F; expected=64'd4; end
            // --- ANDN ---
            68: begin op=ALU_ANDN; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'h0F0F0F0F_0F0F0F0F; expected=64'hF0F0F0F0_F0F0F0F0; end
            69: begin op=ALU_ANDN; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'hFFFFFFFF_FFFFFFFF; expected=64'd0; end
            // --- ORN ---
            70: begin op=ALU_ORN; operand_a=64'd0; operand_b=64'd0; expected=64'hFFFFFFFF_FFFFFFFF; end
            71: begin op=ALU_ORN; operand_a=64'hF0F0F0F0_F0F0F0F0; operand_b=64'hFFFFFFFF_FFFFFFFF; expected=64'hF0F0F0F0_F0F0F0F0; end
            // --- XNOR ---
            72: begin op=ALU_XNOR; operand_a=64'hAAAAAAAA_AAAAAAAA; operand_b=64'hAAAAAAAA_AAAAAAAA; expected=64'hFFFFFFFF_FFFFFFFF; end
            73: begin op=ALU_XNOR; operand_a=64'hAAAAAAAA_AAAAAAAA; operand_b=64'h55555555_55555555; expected=64'd0; end
            // --- ROL ---
            74: begin op=ALU_ROL; operand_a=64'h80000000_00000001; operand_b=64'd1; expected=64'h00000000_00000003; end
            75: begin op=ALU_ROL; operand_a=64'hF000000000000000; operand_b=64'd4; expected=64'h000000000000000F; end
            76: begin op=ALU_ROL; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd32; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- ROLW ---
            77: begin op=ALU_ROL; is_w_op=1; operand_a=64'h00000000_80000001; operand_b=64'd1; expected=64'h00000000_00000003; end
            78: begin op=ALU_ROL; is_w_op=1; operand_a=64'h00000000_F0000000; operand_b=64'd4; expected=64'h00000000_0000000F; end
            // --- ROR ---
            79: begin op=ALU_ROR; operand_a=64'h00000000_00000003; operand_b=64'd1; expected=64'h80000000_00000001; end
            80: begin op=ALU_ROR; operand_a=64'd1; operand_b=64'd1; expected=64'h80000000_00000000; end
            // --- RORW ---
            81: begin op=ALU_ROR; is_w_op=1; operand_a=64'h00000000_00000003; operand_b=64'd1; expected=64'hFFFFFFFF_80000001; end
            82: begin op=ALU_ROR; is_w_op=1; operand_a=64'h00000000_00000001; operand_b=64'd1; expected=64'hFFFFFFFF_80000000; end
            // --- SEXTB ---
            83: begin op=ALU_SEXTB; operand_a=64'h00000000_000000FF; expected=64'hFFFFFFFF_FFFFFFFF; end
            84: begin op=ALU_SEXTB; operand_a=64'hDEADBEEF_12345678; expected=64'h00000000_00000078; end
            85: begin op=ALU_SEXTB; operand_a=64'h00000000_00000080; expected=64'hFFFFFFFF_FFFFFF80; end
            // --- SEXTH ---
            86: begin op=ALU_SEXTH; operand_a=64'h00000000_0000FFFF; expected=64'hFFFFFFFF_FFFFFFFF; end
            87: begin op=ALU_SEXTH; operand_a=64'hDEADBEEF_12347FFF; expected=64'h00000000_00007FFF; end
            88: begin op=ALU_SEXTH; operand_a=64'h00000000_00008000; expected=64'hFFFFFFFF_FFFF8000; end
            // --- REV8 ---
            89: begin op=ALU_REV8; operand_a=64'h01020304_05060708; expected=64'h08070605_04030201; end
            90: begin op=ALU_REV8; operand_a=64'hFF000000_00000000; expected=64'h00000000_000000FF; end
            91: begin op=ALU_REV8; operand_a=64'd0; expected=64'd0; end
            // --- ORCB ---
            92: begin op=ALU_ORCB; operand_a=64'h01020000_00000000; expected=64'hFFFF0000_00000000; end
            93: begin op=ALU_ORCB; operand_a=64'd0; expected=64'd0; end
            94: begin op=ALU_ORCB; operand_a=64'hFFFFFFFF_FFFFFFFF; expected=64'hFFFFFFFF_FFFFFFFF; end
            95: begin op=ALU_ORCB; operand_a=64'h00000000_00000001; expected=64'h00000000_000000FF; end
            // --- BSET ---
            96: begin op=ALU_BSET; operand_a=64'd0; operand_b=64'd0; expected=64'd1; end
            97: begin op=ALU_BSET; operand_a=64'd0; operand_b=64'd63; expected=64'h80000000_00000000; end
            98: begin op=ALU_BSET; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd5; expected=64'hFFFFFFFF_FFFFFFFF; end
            // --- BCLR ---
            99:  begin op=ALU_BCLR; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd0; expected=64'hFFFFFFFF_FFFFFFFE; end
            100: begin op=ALU_BCLR; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd63; expected=64'h7FFFFFFF_FFFFFFFF; end
            101: begin op=ALU_BCLR; operand_a=64'd0; operand_b=64'd5; expected=64'd0; end
            // --- BINV ---
            102: begin op=ALU_BINV; operand_a=64'd0; operand_b=64'd0; expected=64'd1; end
            103: begin op=ALU_BINV; operand_a=64'd1; operand_b=64'd0; expected=64'd0; end
            104: begin op=ALU_BINV; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd63; expected=64'h7FFFFFFF_FFFFFFFF; end
            // --- BEXT ---
            105: begin op=ALU_BEXT; operand_a=64'hFFFFFFFF_FFFFFFFF; operand_b=64'd0; expected=64'd1; end
            106: begin op=ALU_BEXT; operand_a=64'hFFFFFFFF_FFFFFFFE; operand_b=64'd0; expected=64'd0; end
            107: begin op=ALU_BEXT; operand_a=64'h80000000_00000000; operand_b=64'd63; expected=64'd1; end
            // --- CZERO_EQZ ---
            108: begin op=ALU_CZERO_EQZ; operand_a=64'hDEADBEEF_12345678; operand_b=64'd0; expected=64'd0; end
            109: begin op=ALU_CZERO_EQZ; operand_a=64'hDEADBEEF_12345678; operand_b=64'd1; expected=64'hDEADBEEF_12345678; end
            // --- CZERO_NEZ ---
            110: begin op=ALU_CZERO_NEZ; operand_a=64'hDEADBEEF_12345678; operand_b=64'd0; expected=64'hDEADBEEF_12345678; end
            111: begin op=ALU_CZERO_NEZ; operand_a=64'hDEADBEEF_12345678; operand_b=64'd1; expected=64'd0; end
            // --- ADD.UW / SLLI.UW ---
            112: begin op=ALU_ADD; is_w_op=1; is_unsigned=1; operand_a=64'hFFFFFFFF_80000000; operand_b=64'd5; expected=64'h00000000_80000005; end
            113: begin op=ALU_ADD; is_w_op=1; is_unsigned=1; operand_a=64'hDEADBEEF_FFFFFFFE; operand_b=64'h00000001_00000005; expected=64'h00000002_00000003; end
            114: begin op=ALU_SLL; is_w_op=1; is_unsigned=1; operand_a=64'hFFFFFFFF_80000001; operand_b=64'd1; expected=64'h00000001_00000002; end
            115: begin op=ALU_SLL; is_w_op=1; is_unsigned=1; operand_a=64'hFFFFFFFF_00000001; operand_b=64'd32; expected=64'h00000001_00000000; end
            default: begin end
        endcase
    end

    // Check on each posedge clk, advance test counter
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (test_num < NUM_TESTS) begin
            if (result === expected) begin
                $display("PASS: test %0d  op=%0d  is_w=%0b  unsigned=%0b  result=0x%016h", test_num, op, is_w_op, is_unsigned, result);
                pass_count = pass_count + 1;
            end else begin
                $error("FAIL: test %0d  op=%0d  is_w=%0b  unsigned=%0b  expected=0x%016h  got=0x%016h",
                       test_num, op, is_w_op, is_unsigned, expected, result);
                fail_count = fail_count + 1;
            end
            test_num = test_num + 1;
        end else if (test_num == NUM_TESTS) begin
            $display("");
            $display("=================================================");
            $display("  ALU Testbench Complete");
            $display("  PASSED: %0d", pass_count);
            $display("  FAILED: %0d", fail_count);
            $display("  TOTAL:  %0d", pass_count + fail_count);
            $display("=================================================");
            if (fail_count > 0)
                $display("*** SOME TESTS FAILED ***");
            else
                $display("*** ALL TESTS PASSED ***");
            test_num = test_num + 1;
            $finish;
        end
    end
    /* verilator lint_on BLKSEQ */

endmodule
