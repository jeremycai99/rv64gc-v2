/* file: decode.sv
 Description: Six-wide decode wrapper combining decode slices and fusion.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module decode
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Input from fetch (raw instruction bytes, already decompressed or 32-bit)
    input  logic [2:0]                      fetch_count,     // how many instructions fetched (0..6)
    input  logic [31:0]                     fetch_insn   [0:PIPE_WIDTH-1],
    input  logic [63:0]                     fetch_pc     [0:PIPE_WIDTH-1],
    input  logic [PIPE_WIDTH-1:0]           fetch_is_rvc,
    input  logic [PIPE_WIDTH-1:0]           fetch_bp_taken,
    input  logic [63:0]                     fetch_bp_target [0:PIPE_WIDTH-1],

    // Output to fusion detector (or directly to rename if no fusion)
    output decoded_insn_t                   dec_insn [0:PIPE_WIDTH-1],
    output logic [2:0]                      dec_count,

    // Stall from downstream
    input  logic                            stall,
    // Flush
    input  logic                            flush
);

    // ---------------------------------------------------------------
    // Decode slice outputs (combinational)
    // ---------------------------------------------------------------
    decoded_insn_t slice_out [0:PIPE_WIDTH-1];

    // ---------------------------------------------------------------
    // Instantiate PIPE_WIDTH decode slices
    // ---------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < PIPE_WIDTH; i++) begin : gen_decode_slices
            decode_slice u_decode_slice (
                .insn    (fetch_insn[i]),
                .pc      (fetch_pc[i]),
                .is_rvc  (fetch_is_rvc[i]),
                .decoded (slice_out[i])
            );
        end
    endgenerate

    // ---------------------------------------------------------------
    // Pipeline register (fetch -> decode output)
    // Stored as flat bit-vectors to avoid Verilator packed-struct
    // array misalignment that corrupts narrow fields like alu_op.
    // ---------------------------------------------------------------
    localparam int DI_W = $bits(decoded_insn_t);
    logic [DI_W-1:0] dec_insn_flat_r [0:PIPE_WIDTH-1];
    logic [2:0]      dec_count_r;

    // Reconstruct struct from flat storage for output
    decoded_insn_t dec_insn_r [0:PIPE_WIDTH-1];

    // Per-slot temporary for pipeline register update (formerly automatic)
    decoded_insn_t dec_tmp [0:PIPE_WIDTH-1];
    always_comb begin
        for (int j = 0; j < PIPE_WIDTH; j++) begin
            dec_insn_r[j] = decoded_insn_t'(dec_insn_flat_r[j]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_count_r <= 3'd0;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                dec_insn_flat_r[j] <= '0;
            end
        end else if (flush) begin
            dec_count_r <= 3'd0;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                // Clear just the valid bit (MSB of the struct)
                dec_insn_flat_r[j][DI_W-1] <= 1'b0;
            end
        end else if (!stall) begin
            dec_count_r <= fetch_count;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                if (j < int'(fetch_count)) begin
                    dec_tmp[j]           = slice_out[j];
                    dec_tmp[j].valid     = 1'b1;
                    dec_tmp[j].bp_taken  = fetch_bp_taken[j];
                    dec_tmp[j].bp_target = fetch_bp_target[j];
                    dec_insn_flat_r[j] <= DI_W'(dec_tmp[j]);
                end else begin
                    // Clear valid bit only
                    dec_insn_flat_r[j][DI_W-1] <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Output assignment
    // ---------------------------------------------------------------
    always_comb begin
        for (int j = 0; j < PIPE_WIDTH; j++) begin
            dec_insn[j] = dec_insn_r[j];
        end
        dec_count = dec_count_r;
    end

endmodule
