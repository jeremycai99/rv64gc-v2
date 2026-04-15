/* file: next_line_prefetch_buffer.sv
 Description: 2-entry next-line prefetch buffer for the instruction fetch
              pipeline.  When the icache delivers a line, this module
              requests the next sequential line from L2.  A combinational
              lookup lets F2 consume prefetched data without waiting for
              icache SRAM latency, breaking the 2-cycle fetch cadence.
 Author: Jeremy Cai
 Date: Apr. 13, 2026
 Version: 1.0
*/
module next_line_prefetch_buffer
    import rv64gc_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    // Lookup port (from fetch_unit, combinational — same cycle as icache)
    input  logic         lookup_valid,
    input  logic [63:0]  lookup_addr,
    output logic         hit,
    output logic [511:0] hit_data,

    // Prefetch trigger (icache delivered a line this cycle)
    input  logic         trigger_valid,
    input  logic [63:0]  trigger_addr,   // line-aligned address that was just delivered

    // Invalidation
    input  logic         flush,          // redirect: cancel in-flight prefetch
    input  logic         fence_i,        // FENCE.I: clear all entries

    // L2 prefetch request
    output logic         pf_req_valid,
    output logic [63:0]  pf_req_addr,
    input  logic         pf_req_ready,

    // L2 prefetch response
    input  logic         pf_resp_valid,
    input  logic [63:0]  pf_resp_addr,
    input  logic [511:0] pf_resp_data
);

    // =========================================================================
    // Buffer storage (4 entries, flip-flop based)
    // =========================================================================
    localparam int NUM_ENTRIES = 4;
    localparam int TAG_HI = 63;
    localparam int TAG_LO = LINE_BITS;  // 6 for 64-byte lines

    logic                buf_valid [0:NUM_ENTRIES-1];
    logic [TAG_HI:TAG_LO] buf_tag [0:NUM_ENTRIES-1];
    logic [511:0]        buf_data  [0:NUM_ENTRIES-1];

    logic [1:0]          replace_ptr;  // round-robin victim (2-bit for 4 entries)

    // =========================================================================
    // Combinational lookup
    // =========================================================================
    logic [TAG_HI:TAG_LO] lookup_tag;
    assign lookup_tag = lookup_addr[TAG_HI:TAG_LO];

    logic [NUM_ENTRIES-1:0] entry_match;
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++)
            entry_match[i] = buf_valid[i] && (buf_tag[i] == lookup_tag);
    end

    assign hit = lookup_valid && (|entry_match);

    // Priority mux: lowest matching entry wins
    always_comb begin
        hit_data = '0;
        for (int i = NUM_ENTRIES-1; i >= 0; i--)
            if (entry_match[i]) hit_data = buf_data[i];
    end

    // =========================================================================
    // Prefetch FSM
    // =========================================================================
    typedef enum logic [1:0] {
        PF_IDLE = 2'd0,
        PF_REQ  = 2'd1,
        PF_WAIT = 2'd2
    } pf_state_e;

    pf_state_e pf_state_r;
    logic [63:0] pf_addr_r;  // line-aligned address being prefetched

    // Next-line address from trigger
    logic [63:0] next_line_addr;
    assign next_line_addr = {trigger_addr[TAG_HI:TAG_LO] + 1'b1,
                             {TAG_LO{1'b0}}};

    // Check if next line is already in the buffer
    logic [TAG_HI:TAG_LO] next_line_tag;
    assign next_line_tag = next_line_addr[TAG_HI:TAG_LO];

    logic next_already_buffered;
    assign next_already_buffered =
        (buf_valid[0] && buf_tag[0] == next_line_tag) ||
        (buf_valid[1] && buf_tag[1] == next_line_tag);

    // Prefetch request output (active only in PF_REQ)
    assign pf_req_valid = (pf_state_r == PF_REQ);
    assign pf_req_addr  = pf_addr_r;

    // =========================================================================
    // Sequential logic: FSM + buffer management
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_state_r  <= PF_IDLE;
            pf_addr_r   <= '0;
            replace_ptr <= 2'd0;
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                buf_valid[i] <= 1'b0;
                buf_tag[i]   <= '0;
                buf_data[i]  <= '0;
            end
        end else if (fence_i) begin
            // FENCE.I: invalidate all entries and cancel prefetch
            pf_state_r <= PF_IDLE;
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                buf_valid[i] <= 1'b0;
            end
        end else begin
            case (pf_state_r)
                PF_IDLE: begin
                    if (trigger_valid && !next_already_buffered && !flush) begin
                        pf_addr_r  <= next_line_addr;
                        pf_state_r <= PF_REQ;
                    end
                end

                PF_REQ: begin
                    if (flush) begin
                        pf_state_r <= PF_IDLE;
                    end else if (pf_req_ready) begin
                        pf_state_r <= PF_WAIT;
                    end
                end

                PF_WAIT: begin
                    if (flush) begin
                        // Cancel: go idle, discard the eventual response
                        pf_state_r <= PF_IDLE;
                    end else if (pf_resp_valid &&
                                 pf_resp_addr[TAG_HI:TAG_LO] == pf_addr_r[TAG_HI:TAG_LO]) begin
                        // Install into buffer
                        buf_valid[replace_ptr] <= 1'b1;
                        buf_tag[replace_ptr]   <= pf_addr_r[TAG_HI:TAG_LO];
                        buf_data[replace_ptr]  <= pf_resp_data;
                        replace_ptr            <= replace_ptr + 2'd1;
                        pf_state_r             <= PF_IDLE;
                    end
                end

                default: pf_state_r <= PF_IDLE;
            endcase

            // Invalidate a buffer entry when the icache installs the same
            // line (the icache is authoritative; stale NLPB data must go).
            if (trigger_valid) begin
                for (int i = 0; i < NUM_ENTRIES; i++) begin
                    if (buf_valid[i] &&
                        buf_tag[i] == trigger_addr[TAG_HI:TAG_LO]) begin
                        buf_valid[i] <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
