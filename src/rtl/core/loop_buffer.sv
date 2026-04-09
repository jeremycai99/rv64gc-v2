/* file: loop_buffer.sv
 Description: Loop stream detector and buffer for small hot loops.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef LOOP_BUFFER_SV
`define LOOP_BUFFER_SV

module loop_buffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // Input from decode (capture phase)
    input  decoded_insn_t dec_insn [0:PIPE_WIDTH-1],
    input  logic [2:0]    dec_count,
    input  logic          backward_branch_taken,  // BPU detected backward taken branch

    // Output to rename (playback phase)
    output decoded_insn_t lb_insn [0:PIPE_WIDTH-1],
    output logic [2:0]    lb_count,
    output logic          active,      // 1 = playing back from loop buffer

    // Invalidate (on mispredict, loop exit, or any flush)
    input  logic          invalidate,

    // Stall from rename
    input  logic          stall
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int DEPTH    = LOOP_BUF_DEPTH;   // 64
    localparam int IDX_BITS = $clog2(DEPTH);    // 6

    // =========================================================================
    // State encoding
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE      = 2'd0,
        CAPTURING = 2'd1,
        PLAYING   = 2'd2
    } lb_state_e;

    lb_state_e state_r, state_next;

    // =========================================================================
    // Storage
    // =========================================================================
    decoded_insn_t buf_r [0:DEPTH-1];

    // Capture write pointer (free-running 6-bit index into buf_r)
    logic [IDX_BITS-1:0] wr_ptr_r;

    // Index within buf_r where the current loop body starts
    logic [IDX_BITS-1:0] loop_start_r;

    // Number of entries in the captured loop body (0..DEPTH)
    logic [IDX_BITS:0]   body_len_r;

    // Playback: offset within body (0..body_len_r-1)
    logic [IDX_BITS:0]   rd_ptr_r;

    // =========================================================================
    // Combinational helpers (module-scope to avoid latch warnings)
    // =========================================================================
    logic [IDX_BITS:0]   pb_remaining;  // entries left in this pass
    logic [IDX_BITS:0]   pb_avail;      // entries to emit this cycle

    always_comb begin
        pb_remaining = body_len_r - rd_ptr_r;
        if (pb_remaining > (IDX_BITS+1)'(PIPE_WIDTH))
            pb_avail = (IDX_BITS+1)'(PIPE_WIDTH);
        else
            pb_avail = pb_remaining;
    end

    // Captured body length (combinational, computed at back-edge)
    logic [IDX_BITS:0] cap_len;
    always_comb begin
        if (wr_ptr_r >= loop_start_r)
            cap_len = {1'b0, wr_ptr_r} - {1'b0, loop_start_r};
        else
            cap_len = (IDX_BITS+1)'(DEPTH);  // wrapped: treat as overflow
    end

    // =========================================================================
    // State register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_r <= IDLE;
        else
            state_r <= state_next;
    end

    // =========================================================================
    // Next-state logic
    // =========================================================================
    always_comb begin
        state_next = state_r;
        case (state_r)
            IDLE: begin
                if (backward_branch_taken && !invalidate)
                    state_next = CAPTURING;
            end
            CAPTURING: begin
                if (invalidate) begin
                    state_next = IDLE;
                end else if (backward_branch_taken) begin
                    // Second back-edge: body complete.
                    // Only play back if it fits within LOOP_BUF_DEPTH.
                    if (cap_len > '0 && cap_len < (IDX_BITS+1)'(DEPTH))
                        state_next = PLAYING;
                    else
                        state_next = IDLE;
                end
            end
            PLAYING: begin
                if (invalidate)
                    state_next = IDLE;
            end
            default: state_next = IDLE;
        endcase
    end

    // =========================================================================
    // Capture logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_r     <= '0;
            loop_start_r <= '0;
            body_len_r   <= '0;
        end else begin
            case (state_r)
                IDLE: begin
                    if (backward_branch_taken && !invalidate) begin
                        loop_start_r <= wr_ptr_r;
                        body_len_r   <= '0;
                    end
                end
                CAPTURING: begin
                    if (invalidate) begin
                        wr_ptr_r   <= '0;
                        body_len_r <= '0;
                    end else if (backward_branch_taken) begin
                        // Lock body length at second back-edge
                        body_len_r <= cap_len;
                    end else begin
                        // Absorb dec_count instructions this cycle
                        for (int i = 0; i < PIPE_WIDTH; i++) begin
                            if (i < int'(dec_count)) begin
                                buf_r[wr_ptr_r + IDX_BITS'(i)] <= dec_insn[i];
                            end
                        end
                        wr_ptr_r <= wr_ptr_r + IDX_BITS'(dec_count);
                    end
                end
                PLAYING: begin
                    if (invalidate) begin
                        wr_ptr_r   <= '0;
                        body_len_r <= '0;
                    end
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Playback read pointer
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_r <= '0;
        end else begin
            if (state_r != PLAYING || invalidate) begin
                rd_ptr_r <= '0;
            end else if (!stall) begin
                if (rd_ptr_r + pb_avail >= body_len_r)
                    rd_ptr_r <= '0;
                else
                    rd_ptr_r <= rd_ptr_r + pb_avail;
            end
        end
    end

    // =========================================================================
    // Output logic (combinational, no local variables)
    // =========================================================================
    always_comb begin
        active   = (state_r == PLAYING);
        lb_count = 3'd0;

        for (int i = 0; i < PIPE_WIDTH; i++)
            lb_insn[i] = '0;

        if (state_r == PLAYING && !invalidate) begin
            lb_count = pb_avail[2:0];
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if ((IDX_BITS+1)'(i) < pb_avail) begin
                    lb_insn[i] = buf_r[loop_start_r +
                                       IDX_BITS'(rd_ptr_r[IDX_BITS-1:0]) +
                                       IDX_BITS'(i)];
                end
            end
        end
    end

endmodule

`endif  // LOOP_BUFFER_SV
