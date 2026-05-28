/* file: instr_boundary.sv
 Description: Instruction parcel extraction and cross-line remainder tracking.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module instr_boundary
    import rv64gc_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        redirect_i,
    input  wire        bpu_redirect_i,
    input  wire        stall_i,

    input  wire        work_valid_i,
    input  wire [63:0] work_pc_i,
    input  wire        data_valid_i,
    input  wire [511:0] data_line_i,
    input  wire [2:0]  final_count_i,

    output reg [5:0]  start_offset_o,
    output reg [15:0] raw_hw_o [0:PIPE_WIDTH-1],
    output reg [31:0] raw_insn_o [0:PIPE_WIDTH-1],
    output reg        slot_is_rvc_o [0:PIPE_WIDTH-1],
    output reg        slot_valid_o [0:PIPE_WIDTH-1],
    output reg [63:0] slot_pc_o [0:PIPE_WIDTH-1],
    output reg [2:0]  extract_count_o,
    output reg        straddle_detected_o,
    output reg [63:0] straddle_pc_o,
    output reg        seq_valid_o,
    output reg [63:0] seq_next_pc_o,
    output reg        line_straddle_advance_o,
    output reg        consume_remainder_o,
    output reg        remainder_valid_o
);

    logic        remainder_valid_r;
    logic [15:0] remainder_hw_r;
    logic [63:0] remainder_pc_r;
    logic [15:0] straddle_hw_c;
    logic [2:0]  seq_last_idx_c;

    assign start_offset_o = work_pc_i[5:0];
    assign remainder_valid_o = remainder_valid_r;
    assign seq_last_idx_c = (final_count_i > 3'd0) ? (final_count_i - 3'd1) : 3'd0;
    assign consume_remainder_o =
        remainder_valid_r &&
        work_valid_i &&
        data_valid_i &&
        (start_offset_o == 6'd0) &&
        (extract_count_o > 3'd0);

    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            raw_hw_o[i]      = 16'h0;
            raw_insn_o[i]    = 32'h0000_0013;
            slot_is_rvc_o[i] = 1'b0;
            slot_valid_o[i]  = 1'b0;
            slot_pc_o[i]     = '0;
        end
        extract_count_o     = 3'd0;
        straddle_detected_o = 1'b0;
        straddle_hw_c       = 16'h0;
        straddle_pc_o       = '0;

        if (work_valid_i && data_valid_i) begin
            automatic logic [6:0] byte_pos;
            automatic int slot_idx;
            byte_pos = {1'b0, start_offset_o};
            slot_idx = 0;

            if (remainder_valid_r && byte_pos == 7'd0) begin
                automatic logic [31:0] word32;
                word32[15:0]  = remainder_hw_r;
                word32[23:16] = data_line_i[0 +: 8];
                word32[31:24] = data_line_i[8 +: 8];

                slot_is_rvc_o[0] = 1'b0;
                raw_insn_o[0]    = word32;
                slot_valid_o[0]  = 1'b1;
                slot_pc_o[0]     = remainder_pc_r;
                extract_count_o  = 3'd1;
                byte_pos         = 7'd2;
                slot_idx         = 1;
            end

            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (i >= slot_idx) begin
                    if (byte_pos <= 7'd62) begin
                        automatic logic [15:0] hw;
                        automatic logic [6:0]  bp;
                        bp = byte_pos;
                        hw = {data_line_i[bp*8 +: 8],
                              data_line_i[bp*8 +: 8]};
                        hw[7:0]  = data_line_i[bp*8 +: 8];
                        hw[15:8] = data_line_i[(bp+7'd1)*8 +: 8];

                        raw_hw_o[i]  = hw;
                        slot_pc_o[i] = {work_pc_i[63:6], bp[5:0]};

                        if (hw[1:0] != 2'b11) begin
                            slot_is_rvc_o[i] = 1'b1;
                            raw_insn_o[i]    = {16'h0, hw};
                            slot_valid_o[i]  = 1'b1;
                            extract_count_o  = 3'(i + 1);
                            byte_pos         = byte_pos + 7'd2;
                        end else if (byte_pos <= 7'd60) begin
                            automatic logic [31:0] word32;
                            automatic logic [6:0]  bp2;
                            bp2 = byte_pos;
                            word32[7:0]   = data_line_i[bp2*8 +: 8];
                            word32[15:8]  = data_line_i[(bp2+7'd1)*8 +: 8];
                            word32[23:16] = data_line_i[(bp2+7'd2)*8 +: 8];
                            word32[31:24] = data_line_i[(bp2+7'd3)*8 +: 8];

                            slot_is_rvc_o[i] = 1'b0;
                            raw_insn_o[i]    = word32;
                            slot_valid_o[i]  = 1'b1;
                            extract_count_o  = 3'(i + 1);
                            byte_pos         = byte_pos + 7'd4;
                        end else begin
                            straddle_detected_o = 1'b1;
                            straddle_hw_c       = hw;
                            straddle_pc_o       = {work_pc_i[63:6], bp[5:0]};
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        if (final_count_i > 3'd0) begin
            seq_next_pc_o = slot_pc_o[seq_last_idx_c] +
                (slot_is_rvc_o[seq_last_idx_c] ? 64'd2 : 64'd4);
            seq_valid_o = 1'b1;
        end else if (straddle_detected_o) begin
            seq_next_pc_o = {work_pc_i[63:6] + 58'd1, 6'd0};
            seq_valid_o = 1'b1;
        end else begin
            seq_next_pc_o = work_pc_i;
            seq_valid_o = 1'b0;
        end
    end

    assign line_straddle_advance_o =
        work_valid_i &&
        data_valid_i &&
        straddle_detected_o &&
        (extract_count_o == 3'd0) &&
        seq_valid_o &&
        !redirect_i &&
        !stall_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            remainder_valid_r <= 1'b0;
            remainder_hw_r    <= 16'h0;
            remainder_pc_r    <= '0;
        end else if (redirect_i || bpu_redirect_i) begin
            remainder_valid_r <= 1'b0;
            remainder_hw_r    <= 16'h0;
            remainder_pc_r    <= '0;
        end else if (!stall_i) begin
            if (straddle_detected_o && work_valid_i && data_valid_i) begin
                remainder_valid_r <= 1'b1;
                remainder_hw_r    <= straddle_hw_c;
                remainder_pc_r    <= straddle_pc_o;
            end else if (consume_remainder_o) begin
                remainder_valid_r <= 1'b0;
            end
        end
    end

endmodule
