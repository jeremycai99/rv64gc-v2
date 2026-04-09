/* file: decode.sv
 * Description: 6-wide decode top-level. Instantiates PIPE_WIDTH decode slices,
 *              wires fetch outputs to each slice, and passes through branch
 *              prediction info. Mostly structural wiring.
 * Version: 2.0
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
    // ---------------------------------------------------------------
    decoded_insn_t dec_insn_r [0:PIPE_WIDTH-1];
    logic [2:0]    dec_count_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_count_r <= 3'd0;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                dec_insn_r[j].valid         <= 1'b0;
                dec_insn_r[j].pc            <= 64'd0;
                dec_insn_r[j].insn          <= 32'd0;
                dec_insn_r[j].rs1_arch      <= 5'd0;
                dec_insn_r[j].rs2_arch      <= 5'd0;
                dec_insn_r[j].rd_arch       <= 5'd0;
                dec_insn_r[j].rs1_valid     <= 1'b0;
                dec_insn_r[j].rs2_valid     <= 1'b0;
                dec_insn_r[j].rd_valid      <= 1'b0;
                dec_insn_r[j].imm           <= 64'd0;
                dec_insn_r[j].fu_type       <= FU_ALU;
                dec_insn_r[j].alu_op        <= ALU_ADD;
                dec_insn_r[j].br_op         <= BR_EQ;
                dec_insn_r[j].mul_op        <= MUL_MUL;
                dec_insn_r[j].div_op        <= DIV_DIV;
                dec_insn_r[j].mem_size      <= MEM_BYTE;
                dec_insn_r[j].csr_op        <= CSR_NONE;
                dec_insn_r[j].csr_addr      <= 12'd0;
                dec_insn_r[j].is_branch     <= 1'b0;
                dec_insn_r[j].is_jal        <= 1'b0;
                dec_insn_r[j].is_jalr       <= 1'b0;
                dec_insn_r[j].is_load       <= 1'b0;
                dec_insn_r[j].is_store      <= 1'b0;
                dec_insn_r[j].is_csr        <= 1'b0;
                dec_insn_r[j].is_mul        <= 1'b0;
                dec_insn_r[j].is_div        <= 1'b0;
                dec_insn_r[j].is_w_op       <= 1'b0;
                dec_insn_r[j].is_unsigned   <= 1'b0;
                dec_insn_r[j].use_imm       <= 1'b0;
                dec_insn_r[j].is_fence      <= 1'b0;
                dec_insn_r[j].is_fence_i    <= 1'b0;
                dec_insn_r[j].is_ecall      <= 1'b0;
                dec_insn_r[j].is_ebreak     <= 1'b0;
                dec_insn_r[j].is_mret       <= 1'b0;
                dec_insn_r[j].is_sret       <= 1'b0;
                dec_insn_r[j].is_sfence_vma <= 1'b0;
                dec_insn_r[j].is_wfi        <= 1'b0;
                dec_insn_r[j].is_amo        <= 1'b0;
                dec_insn_r[j].amo_op        <= 5'd0;
                dec_insn_r[j].amo_aq        <= 1'b0;
                dec_insn_r[j].amo_rl        <= 1'b0;
                dec_insn_r[j].is_rvc        <= 1'b0;
                dec_insn_r[j].bp_taken      <= 1'b0;
                dec_insn_r[j].bp_target     <= 64'd0;
                dec_insn_r[j].has_exception <= 1'b0;
                dec_insn_r[j].exc_code      <= 4'd0;
                dec_insn_r[j].is_fused      <= 1'b0;
                dec_insn_r[j].fused_imm     <= 32'd0;
                dec_insn_r[j].fusion_type   <= 3'd0;
            end
        end else if (flush) begin
            dec_count_r <= 3'd0;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                dec_insn_r[j].valid <= 1'b0;
            end
        end else if (!stall) begin
            dec_count_r <= fetch_count;
            for (int j = 0; j < PIPE_WIDTH; j++) begin
                if (j < int'(fetch_count)) begin
                    dec_insn_r[j]           <= slice_out[j];
                    // Override valid and BP info from fetch
                    dec_insn_r[j].valid     <= 1'b1;
                    dec_insn_r[j].bp_taken  <= fetch_bp_taken[j];
                    dec_insn_r[j].bp_target <= fetch_bp_target[j];
                end else begin
                    dec_insn_r[j].valid <= 1'b0;
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
