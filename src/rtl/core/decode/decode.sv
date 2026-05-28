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
    input  wire clk,
    input  wire rst_n,

    // Input from fetch (raw instruction bytes, already decompressed or 32-bit)
    input  wire [2:0]                      fetch_count,     // how many instructions fetched (0..6)
    input  wire [31:0]                     fetch_insn   [0:PIPE_WIDTH-1],
    input  wire [63:0]                     fetch_pc     [0:PIPE_WIDTH-1],
    input  wire [PIPE_WIDTH-1:0]           fetch_is_rvc,
    input  wire [PIPE_WIDTH-1:0]           fetch_bp_taken,
    input  wire [63:0]                     fetch_bp_target [0:PIPE_WIDTH-1],
    input  wire                            fetch_bp_owner_valid,
    input  wire [2:0]                      fetch_bp_owner_slot,
    input  wire                            fetch_bp_owner_from_subgroup,
    input  wire [63:0]                     fetch_bp_lookup_pc,
    input  wire [4:0]                      fetch_bp_ras_tos,
    input  wire [63:0]                     fetch_bp_ras_top,
    input  wire [GHR_BITS-1:0]             fetch_bp_ghr,

    // Output to fusion detector (or directly to rename if no fusion)
    output decoded_insn_t                   dec_insn [0:PIPE_WIDTH-1],
    output logic [2:0]                      dec_count,

    // Stall from downstream
    input  wire                            stall,
    // Flush
    input  wire                            flush
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
                    dec_tmp[j].bp_owner  =
                        fetch_bp_owner_valid && (3'(j) == fetch_bp_owner_slot);
                    dec_tmp[j].bp_from_subgroup =
                        fetch_bp_owner_from_subgroup &&
                        fetch_bp_owner_valid &&
                        (3'(j) == fetch_bp_owner_slot);
                    // Carry the real owner-branch PC when this slot owns the
                    // prediction. The legacy packet-start lookup PC is kept
                    // only for non-owner slots, where commit will ignore it.
                    if (fetch_bp_owner_valid && (3'(j) == fetch_bp_owner_slot))
                        dec_tmp[j].bp_lookup_pc = fetch_pc[j];
                    else
                        dec_tmp[j].bp_lookup_pc = fetch_bp_lookup_pc;
                    dec_tmp[j].bp_ras_tos = fetch_bp_ras_tos;
                    dec_tmp[j].bp_ras_top = fetch_bp_ras_top;
                    dec_tmp[j].bp_ghr    = fetch_bp_ghr;
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
