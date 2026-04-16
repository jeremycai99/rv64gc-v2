/* file: tb_bru.sv
 * Description: Testbench for the v2 BRU. Exercises every branch type
 *              (BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL, JALR), fused
 *              compare-and-branch for each fusion_type, and mispredict
 *              detection (correct prediction, wrong direction, wrong target).
 *              Structured as a clocked state machine for Verilator --no-timing.
 * Version: 2.0
 */

module tb_bru
    import rv64gc_pkg::*;
    import uarch_pkg::*;
();

    // Clock driven from C++ harness
    logic clk;

    // DUT signals
    logic [63:0] operand_a;
    logic [63:0] operand_b;
    logic [63:0] pc;
    logic [63:0] imm;
    br_op_e      op;
    logic        is_fused;
    logic [2:0]  fusion_type;
    logic        bp_taken;
    logic [63:0] bp_target;
    logic [63:0] result;
    logic        taken;
    logic [63:0] target;
    logic        mispredict;

    // Test tracking
    int pass_count;
    int fail_count;
    int test_num;
    logic        exp_taken;
    logic [63:0] exp_target;
    logic [63:0] exp_result;
    logic        exp_mispredict;

    // DUT instantiation
    bru dut (
        .operand_a   (operand_a),
        .operand_b   (operand_b),
        .pc          (pc),
        .imm         (imm),
        .op          (op),
        .is_fused    (is_fused),
        .fusion_type (fusion_type),
        .bp_taken    (bp_taken),
        .bp_target   (bp_target),
        .result      (result),
        .taken       (taken),
        .target      (target),
        .mispredict  (mispredict)
    );

    localparam int NUM_TESTS = 42;

    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;
    end

    // Set inputs combinationally based on test_num
    always @(*) begin
        // Defaults
        operand_a   = 64'd0;
        operand_b   = 64'd0;
        pc          = 64'h8000_0000;
        imm         = 64'd16;
        op          = BR_EQ;
        is_fused    = 1'b0;
        fusion_type = 3'd0;
        bp_taken    = 1'b0;
        bp_target   = 64'd0;
        exp_taken   = 1'b0;
        exp_target  = 64'h8000_0010;  // pc + 16
        exp_result  = 64'h8000_0004;  // pc + 4
        exp_mispredict = 1'b0;

        case (test_num)
            // =================================================================
            // BEQ tests
            // =================================================================
            // 0: BEQ taken (equal values)
            0: begin
                op = BR_EQ; operand_a = 64'd42; operand_b = 64'd42;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 1: BEQ not taken (different values)
            1: begin
                op = BR_EQ; operand_a = 64'd42; operand_b = 64'd43;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 2: BEQ with zero values, taken
            2: begin
                op = BR_EQ; operand_a = 64'd0; operand_b = 64'd0;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // BNE tests
            // =================================================================
            // 3: BNE taken (different values)
            3: begin
                op = BR_NE; operand_a = 64'd1; operand_b = 64'd2;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 4: BNE not taken (equal values)
            4: begin
                op = BR_NE; operand_a = 64'd5; operand_b = 64'd5;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // BLT tests (signed)
            // =================================================================
            // 5: BLT taken (-1 < 0)
            5: begin
                op = BR_LT; operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd0;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 6: BLT not taken (0 >= -1)
            6: begin
                op = BR_LT; operand_a = 64'd0; operand_b = 64'hFFFFFFFF_FFFFFFFF;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 7: BLT edge: most negative < most positive
            7: begin
                op = BR_LT;
                operand_a = 64'h80000000_00000000;
                operand_b = 64'h7FFFFFFF_FFFFFFFF;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 8: BLT not taken (equal)
            8: begin
                op = BR_LT; operand_a = 64'd10; operand_b = 64'd10;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // BGE tests (signed)
            // =================================================================
            // 9: BGE taken (equal)
            9: begin
                op = BR_GE; operand_a = 64'd10; operand_b = 64'd10;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 10: BGE taken (greater)
            10: begin
                op = BR_GE; operand_a = 64'd5; operand_b = 64'hFFFFFFFF_FFFFFFFF;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 11: BGE not taken (less)
            11: begin
                op = BR_GE;
                operand_a = 64'h80000000_00000000;
                operand_b = 64'h7FFFFFFF_FFFFFFFF;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // BLTU tests (unsigned)
            // =================================================================
            // 12: BLTU taken (3 < 5)
            12: begin
                op = BR_LTU; operand_a = 64'd3; operand_b = 64'd5;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 13: BLTU not taken (0xFFFF... is largest unsigned)
            13: begin
                op = BR_LTU;
                operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd0;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 14: BLTU taken (0 < 1)
            14: begin
                op = BR_LTU; operand_a = 64'd0; operand_b = 64'd1;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // BGEU tests (unsigned)
            // =================================================================
            // 15: BGEU taken (equal)
            15: begin
                op = BR_GEU; operand_a = 64'd100; operand_b = 64'd100;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 16: BGEU taken (larger unsigned)
            16: begin
                op = BR_GEU;
                operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd0;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 17: BGEU not taken
            17: begin
                op = BR_GEU; operand_a = 64'd0; operand_b = 64'd1;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // JAL tests
            // =================================================================
            // 18: JAL always taken, target = PC + imm
            18: begin
                op = BR_JAL; pc = 64'h8000_1000; imm = 64'd256;
                exp_taken = 1'b1; exp_target = 64'h8000_1100;
                exp_result = 64'h8000_1004;
                bp_taken = 1'b1; bp_target = 64'h8000_1100;
                exp_mispredict = 1'b0;
            end
            // 19: JAL with negative offset
            19: begin
                op = BR_JAL; pc = 64'h8000_1000;
                imm = 64'hFFFFFFFF_FFFFFF00;  // -256
                exp_taken = 1'b1; exp_target = 64'h8000_0F00;
                exp_result = 64'h8000_1004;
                bp_taken = 1'b1; bp_target = 64'h8000_0F00;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // JALR tests
            // =================================================================
            // 20: JALR target = (rs1 + imm) & ~1
            20: begin
                op = BR_JALR; pc = 64'h8000_2000;
                operand_a = 64'h8000_3000; imm = 64'd100;
                exp_taken = 1'b1;
                exp_target = 64'h8000_3064;  // 0x8000_3000 + 100 = 0x8000_3064
                exp_result = 64'h8000_2004;
                bp_taken = 1'b1; bp_target = 64'h8000_3064;
                exp_mispredict = 1'b0;
            end
            // 21: JALR with alignment mask (clear bit 0)
            21: begin
                op = BR_JALR; pc = 64'h8000_2000;
                operand_a = 64'h8000_3001; imm = 64'd0;
                exp_taken = 1'b1;
                exp_target = 64'h8000_3000;  // bit 0 cleared
                exp_result = 64'h8000_2004;
                bp_taken = 1'b1; bp_target = 64'h8000_3000;
                exp_mispredict = 1'b0;
            end
            // 22: JALR odd sum -> clear bit 0
            22: begin
                op = BR_JALR; pc = 64'h8000_0000;
                operand_a = 64'd100; imm = 64'd3;
                exp_taken = 1'b1;
                exp_target = 64'd102;   // (100+3)&~1 = 103&~1 = 102
                exp_result = 64'h8000_0004;
                bp_taken = 1'b1; bp_target = 64'd102;
                exp_mispredict = 1'b0;
            end

            // =================================================================
            // Mispredict detection tests
            // =================================================================
            // 23: Correct prediction (taken, correct target)
            23: begin
                op = BR_EQ; operand_a = 64'd7; operand_b = 64'd7;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b0;
            end
            // 24: Mispredict: wrong direction (predicted taken, actually not taken)
            24: begin
                op = BR_EQ; operand_a = 64'd7; operand_b = 64'd8;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_0010;
                exp_mispredict = 1'b1;
            end
            // 25: Mispredict: wrong direction (predicted not taken, actually taken)
            25: begin
                op = BR_EQ; operand_a = 64'd7; operand_b = 64'd7;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b1;
            end
            // 26: Mispredict: right direction but wrong target
            26: begin
                op = BR_EQ; operand_a = 64'd7; operand_b = 64'd7;
                exp_taken = 1'b1; exp_target = 64'h8000_0010;
                bp_taken = 1'b1; bp_target = 64'h8000_DEAD;  // wrong target
                exp_mispredict = 1'b1;
            end
            // 27: No mispredict on not-taken (target doesn't matter)
            27: begin
                op = BR_EQ; operand_a = 64'd1; operand_b = 64'd2;
                exp_taken = 1'b0; exp_target = 64'h8000_0010;
                bp_taken = 1'b0; bp_target = 64'hDEAD_BEEF;  // target irrelevant when not taken
                exp_mispredict = 1'b0;
            end
            // 28: JAL mispredict (wrong target predicted)
            28: begin
                op = BR_JAL; pc = 64'h8000_0000; imm = 64'd100;
                exp_taken = 1'b1; exp_target = 64'h8000_0064;
                exp_result = 64'h8000_0004;
                bp_taken = 1'b1; bp_target = 64'h8000_0000;  // wrong target
                exp_mispredict = 1'b1;
            end

            // =================================================================
            // Fused compare-and-branch tests
            // =================================================================
            // 29: fusion_type=0: SLT+BNE -> branch if rs1 < rs2 (signed), taken
            29: begin
                is_fused = 1'b1; fusion_type = 3'd0;
                operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd5;  // -1 < 5
                imm = 64'd32; pc = 64'h8000_0000;
                exp_taken = 1'b1; exp_target = 64'h8000_0020;
                bp_taken = 1'b1; bp_target = 64'h8000_0020;
                exp_mispredict = 1'b0;
            end
            // 30: fusion_type=0: SLT+BNE -> not taken (5 >= 3)
            30: begin
                is_fused = 1'b1; fusion_type = 3'd0;
                operand_a = 64'd5; operand_b = 64'd3;
                imm = 64'd32; pc = 64'h8000_0000;
                exp_taken = 1'b0; exp_target = 64'h8000_0020;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 31: fusion_type=1: SLTU+BNE -> branch if rs1 < rs2 (unsigned), taken
            31: begin
                is_fused = 1'b1; fusion_type = 3'd1;
                operand_a = 64'd3; operand_b = 64'd5;
                imm = 64'd8; pc = 64'h8000_0100;
                exp_taken = 1'b1; exp_target = 64'h8000_0108;
                bp_taken = 1'b1; bp_target = 64'h8000_0108;
                exp_mispredict = 1'b0;
            end
            // 32: fusion_type=1: SLTU+BNE -> not taken (large unsigned >= small)
            32: begin
                is_fused = 1'b1; fusion_type = 3'd1;
                operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd5;
                imm = 64'd8; pc = 64'h8000_0100;
                exp_taken = 1'b0; exp_target = 64'h8000_0108;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 33: fusion_type=2: SLT+BEQ -> branch if rs1 >= rs2 (signed), taken
            33: begin
                is_fused = 1'b1; fusion_type = 3'd2;
                operand_a = 64'd10; operand_b = 64'd5;  // 10 >= 5
                imm = 64'd12; pc = 64'h8000_0200;
                exp_taken = 1'b1; exp_target = 64'h8000_020C;
                bp_taken = 1'b1; bp_target = 64'h8000_020C;
                exp_mispredict = 1'b0;
            end
            // 34: fusion_type=2: SLT+BEQ -> not taken (rs1 < rs2)
            34: begin
                is_fused = 1'b1; fusion_type = 3'd2;
                operand_a = 64'd3; operand_b = 64'd10;  // 3 < 10
                imm = 64'd12; pc = 64'h8000_0200;
                exp_taken = 1'b0; exp_target = 64'h8000_020C;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 35: fusion_type=3: SLTU+BEQ -> branch if rs1 >= rs2 (unsigned), taken
            35: begin
                is_fused = 1'b1; fusion_type = 3'd3;
                operand_a = 64'hFFFFFFFF_FFFFFFFF; operand_b = 64'd5;  // max >= 5
                imm = 64'd20; pc = 64'h8000_0300;
                exp_taken = 1'b1; exp_target = 64'h8000_0314;
                bp_taken = 1'b1; bp_target = 64'h8000_0314;
                exp_mispredict = 1'b0;
            end
            // 36: fusion_type=3: SLTU+BEQ -> not taken (0 < 1)
            36: begin
                is_fused = 1'b1; fusion_type = 3'd3;
                operand_a = 64'd0; operand_b = 64'd1;
                imm = 64'd20; pc = 64'h8000_0300;
                exp_taken = 1'b0; exp_target = 64'h8000_0314;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 37: fusion_type=4: SLTI+BNE -> branch if rs1 < imm (signed), taken
            37: begin
                is_fused = 1'b1; fusion_type = 3'd4;
                operand_a = 64'hFFFFFFFF_FFFFFFFF;  // -1
                imm = 64'd0;  // imm=0, -1 < 0
                pc = 64'h8000_0400;
                exp_taken = 1'b1; exp_target = 64'h8000_0400;
                bp_taken = 1'b1; bp_target = 64'h8000_0400;
                exp_mispredict = 1'b0;
            end
            // 38: fusion_type=4: SLTI+BNE -> not taken (5 >= 3)
            38: begin
                is_fused = 1'b1; fusion_type = 3'd4;
                operand_a = 64'd5;
                imm = 64'd3;  // 5 >= 3
                pc = 64'h8000_0400;
                exp_taken = 1'b0; exp_target = 64'h8000_0403;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 39: fusion_type=5: SLTIU+BNE -> branch if rs1 < imm (unsigned), taken
            39: begin
                is_fused = 1'b1; fusion_type = 3'd5;
                operand_a = 64'd3;
                imm = 64'd10;  // 3 < 10
                pc = 64'h8000_0500;
                exp_taken = 1'b1; exp_target = 64'h8000_050A;
                bp_taken = 1'b1; bp_target = 64'h8000_050A;
                exp_mispredict = 1'b0;
            end
            // 40: fusion_type=5: SLTIU+BNE -> not taken (10 >= 3)
            40: begin
                is_fused = 1'b1; fusion_type = 3'd5;
                operand_a = 64'd10;
                imm = 64'd3;  // 10 >= 3
                pc = 64'h8000_0500;
                exp_taken = 1'b0; exp_target = 64'h8000_0503;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b0;
            end
            // 41: Fused mispredict: predicted not taken but actually taken
            41: begin
                is_fused = 1'b1; fusion_type = 3'd0;
                operand_a = 64'd1; operand_b = 64'd100;  // 1 < 100 signed
                imm = 64'd64; pc = 64'h8000_0000;
                exp_taken = 1'b1; exp_target = 64'h8000_0040;
                bp_taken = 1'b0; bp_target = 64'd0;
                exp_mispredict = 1'b1;
            end

            default: begin end
        endcase
    end

    // Check on each posedge clk, advance test counter
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (test_num < NUM_TESTS) begin
            if (taken === exp_taken &&
                mispredict === exp_mispredict &&
                target === exp_target) begin
                // For JAL/JALR, also check result (link address)
                if ((op == BR_JAL || op == BR_JALR) && !is_fused) begin
                    if (result === exp_result) begin
                        $display("PASS: test %0d  op=%0d  fused=%0b  ft=%0d  taken=%0b  target=0x%016h  result=0x%016h",
                                 test_num, op, is_fused, fusion_type, taken, target, result);
                        pass_count = pass_count + 1;
                    end else begin
                        $error("FAIL: test %0d  op=%0d  fused=%0b  ft=%0d  exp_result=0x%016h  got_result=0x%016h",
                               test_num, op, is_fused, fusion_type, exp_result, result);
                        fail_count = fail_count + 1;
                    end
                end else begin
                    $display("PASS: test %0d  op=%0d  fused=%0b  ft=%0d  taken=%0b  target=0x%016h  mispred=%0b",
                             test_num, op, is_fused, fusion_type, taken, target, mispredict);
                    pass_count = pass_count + 1;
                end
            end else begin
                $error("FAIL: test %0d  op=%0d  fused=%0b  ft=%0d",
                       test_num, op, is_fused, fusion_type);
                if (taken !== exp_taken)
                    $error("  taken: expected=%0b got=%0b", exp_taken, taken);
                if (target !== exp_target)
                    $error("  target: expected=0x%016h got=0x%016h", exp_target, target);
                if (mispredict !== exp_mispredict)
                    $error("  mispredict: expected=%0b got=%0b", exp_mispredict, mispredict);
                fail_count = fail_count + 1;
            end
            test_num = test_num + 1;
        end else if (test_num == NUM_TESTS) begin
            $display("");
            $display("=================================================");
            $display("  BRU Testbench Complete");
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
