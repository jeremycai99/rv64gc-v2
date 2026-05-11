/* file: fmv_unit.sv
 Description: Bit-preserving integer <-> floating-point move unit for Phase 5.
 Handles NaN-boxing on 32-bit moves into the 64-bit FP register file.
 Author: Jeremy Cai
 Date: Mar. 28, 2026
 Version: 0.1
*/

module fmv_unit
    import fpu_pkg::*;
(
    input  logic valid_i,
    input  fmv_op_e op_i,
    input  logic [63:0] int_data_i,
    input  logic [63:0] fp_data_i,
    output logic valid_o,
    output logic [63:0] int_result_o,
    output logic [63:0] fp_result_o
);

    always_comb begin
        valid_o = valid_i;
        int_result_o = 64'd0;
        fp_result_o = 64'd0;

        case (op_i)
            FMV_W_FROM_X: begin
                fp_result_o = {32'hffff_ffff, int_data_i[31:0]};
            end
            FMV_X_FROM_W: begin
                int_result_o = {{32{fp_data_i[31]}}, fp_data_i[31:0]};
            end
            FMV_D_FROM_X: begin
                fp_result_o = int_data_i;
            end
            FMV_X_FROM_D: begin
                int_result_o = fp_data_i;
            end
            default: begin
                int_result_o = 64'd0;
                fp_result_o = 64'd0;
            end
        endcase
    end

endmodule
