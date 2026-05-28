/* file: rvc_expander.sv
 Description: Multi-slot wrapper around the RVC decompressor.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module rvc_expander
    import rv64gc_pkg::*;
(
    input  wire [15:0] raw_hw_i [0:PIPE_WIDTH-1],
    output logic [31:0] decomp_out_o [0:PIPE_WIDTH-1],
    output logic        decomp_is_rvc_o [0:PIPE_WIDTH-1],
    output logic        decomp_illegal_o [0:PIPE_WIDTH-1]
);

    genvar gi;
    generate
        for (gi = 0; gi < PIPE_WIDTH; gi++) begin : gen_rvc_decomp
            rvc_decompress u_rvc_decomp (
                .insn_in (raw_hw_i[gi]),
                .insn_out(decomp_out_o[gi]),
                .is_rvc  (decomp_is_rvc_o[gi]),
                .illegal (decomp_illegal_o[gi])
            );
        end
    endgenerate

endmodule
