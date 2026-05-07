/* file: predecode.sv
 Description: Frontend control-flow predecode for extracted instruction slots.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module predecode
    import rv64gc_pkg::*;
(
    input  logic                         valid_i,
    input  logic [2:0]                   extract_count_i,
    input  logic [31:0]                  raw_insn_i [0:PIPE_WIDTH-1],
    input  logic [31:0]                  decomp_insn_i [0:PIPE_WIDTH-1],
    input  logic                         slot_is_rvc_i [0:PIPE_WIDTH-1],
    input  logic                         slot_valid_i [0:PIPE_WIDTH-1],
    input  logic [63:0]                  slot_pc_i [0:PIPE_WIDTH-1],
    input  logic [4:0]                   ras_tos_i,
    input  logic [63:0]                  ras_pop_addr_i,
    input  logic                         owner_tage_pred_taken_i,

    output logic                         ctl_found_o,
    output logic [2:0]                   ctl_slot_o,
    output logic [2:0]                   ctl_type_o,
    output logic [63:0]                  ctl_pc_o,
    output logic [63:0]                  ctl_target_o,

    output logic                         second_ctl_found_o,
    output logic [2:0]                   second_ctl_slot_o,
    output logic [2:0]                   second_ctl_type_o,
    output logic [63:0]                  second_ctl_pc_o,
    output logic [63:0]                  second_ctl_target_o,

    output logic                         owner_cond_pred_found_o,
    output logic [2:0]                   owner_cond_pred_slot_o,
    output logic [63:0]                  owner_cond_pred_target_o
);

    localparam logic [2:0] BT_COND = 3'd0;
    localparam logic [2:0] BT_JAL  = 3'd1;
    localparam logic [2:0] BT_JALR = 3'd2;
    localparam logic [2:0] BT_CALL = 3'd3;
    localparam logic [2:0] BT_RET  = 3'd4;

    function automatic logic is_link_reg(input logic [4:0] reg_id);
        begin
            is_link_reg = (reg_id == 5'd1) || (reg_id == 5'd5);
        end
    endfunction

    function automatic logic [63:0] imm_b64(input logic [31:0] insn);
        logic [12:0] imm13;
        begin
            imm13 = {insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
            imm_b64 = {{51{imm13[12]}}, imm13};
        end
    endfunction

    function automatic logic [63:0] imm_j64(input logic [31:0] insn);
        logic [20:0] imm21;
        begin
            imm21 = {insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
            imm_j64 = {{43{imm21[20]}}, imm21};
        end
    endfunction

    always_comb begin
        ctl_found_o         = 1'b0;
        ctl_slot_o          = 3'd0;
        ctl_type_o          = BT_COND;
        ctl_pc_o            = '0;
        ctl_target_o        = '0;
        second_ctl_found_o  = 1'b0;
        second_ctl_slot_o   = 3'd0;
        second_ctl_type_o   = BT_COND;
        second_ctl_pc_o     = '0;
        second_ctl_target_o = '0;

        if (valid_i) begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (slot_valid_i[i] && (3'(i) < extract_count_i)) begin
                    automatic logic        ctl_found_i;
                    automatic logic [2:0]  ctl_type_i;
                    automatic logic [63:0] ctl_pc_i;
                    automatic logic [63:0] ctl_target_i;
                    automatic logic [31:0] insn32;
                    automatic logic [6:0]  opcode;
                    automatic logic [2:0]  funct3;
                    automatic logic [4:0]  rd;
                    automatic logic [4:0]  rs1;
                    automatic logic [11:0] imm12;

                    ctl_found_i  = 1'b0;
                    ctl_type_i   = BT_COND;
                    ctl_pc_i     = slot_pc_i[i];
                    ctl_target_i = '0;
                    insn32 = slot_is_rvc_i[i] ? decomp_insn_i[i] : raw_insn_i[i];
                    opcode = insn32[6:0];
                    funct3 = insn32[14:12];
                    rd     = insn32[11:7];
                    rs1    = insn32[19:15];
                    imm12  = insn32[31:20];

                    case (opcode)
                        7'b1100011: begin
                            ctl_found_i  = 1'b1;
                            ctl_type_i   = BT_COND;
                            ctl_target_i = slot_pc_i[i] + imm_b64(insn32);
                        end
                        7'b1101111: begin
                            ctl_found_i  = 1'b1;
                            ctl_type_i   = is_link_reg(rd) ? BT_CALL : BT_JAL;
                            ctl_target_i = slot_pc_i[i] + imm_j64(insn32);
                        end
                        7'b1100111: begin
                            if (funct3 == 3'b000) begin
                                ctl_found_i = 1'b1;
                                if ((rd == 5'd0) && is_link_reg(rs1) &&
                                    (imm12 == 12'd0)) begin
                                    ctl_type_i = BT_RET;
                                    ctl_target_i =
                                        ((ras_tos_i != 5'd0) &&
                                         (ras_pop_addr_i != 64'd0))
                                            ? ras_pop_addr_i
                                            : 64'd0;
                                end else if (is_link_reg(rd)) begin
                                    ctl_type_i   = BT_CALL;
                                    ctl_target_i = 64'd0;
                                end else begin
                                    ctl_type_i   = BT_JALR;
                                    ctl_target_i = 64'd0;
                                end
                            end
                        end
                        default: begin
                        end
                    endcase

                    if (ctl_found_i) begin
                        if (!ctl_found_o) begin
                            ctl_found_o  = 1'b1;
                            ctl_slot_o   = 3'(i);
                            ctl_type_o   = ctl_type_i;
                            ctl_pc_o     = ctl_pc_i;
                            ctl_target_o = ctl_target_i;
                        end else if (!second_ctl_found_o) begin
                            second_ctl_found_o  = 1'b1;
                            second_ctl_slot_o   = 3'(i);
                            second_ctl_type_o   = ctl_type_i;
                            second_ctl_pc_o     = ctl_pc_i;
                            second_ctl_target_o = ctl_target_i;
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        owner_cond_pred_found_o  = 1'b0;
        owner_cond_pred_slot_o   = ctl_slot_o;
        owner_cond_pred_target_o = ctl_target_o;

        if (valid_i &&
            ctl_found_o &&
            (ctl_type_o == BT_COND) &&
            owner_tage_pred_taken_i) begin
            owner_cond_pred_found_o = 1'b1;
        end
    end

endmodule
