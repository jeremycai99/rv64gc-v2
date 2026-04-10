/* file: icache.sv
 Description: 32 kB 4-way L1 I-Cache with PLRU and FENCE.I support.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module icache
    import rv64gc_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,
    // Fetch request (from fetch unit)
    input  logic         req_valid,
    input  logic [63:0]  req_addr,
    // Fetch response (to fetch unit)
    output logic         resp_valid,
    output logic [511:0] resp_data,    // full 64-byte cache line
    output logic         resp_hit,
    // Fill from L2 (miss handling)
    output logic         fill_req_valid,
    output logic [63:0]  fill_req_addr,  // line-aligned
    input  logic         fill_resp_valid,
    input  logic [511:0] fill_resp_data,
    // Invalidate (FENCE.I)
    input  logic         invalidate_all,
    output logic         invalidate_busy
);

    // =========================================================================
    // Address field widths (from rv64gc_pkg)
    //   addr[5:0]               = byte offset  (LINE_BITS  = 6)
    //   addr[12:6]              = set index    (L1I_SET_BITS = 7)
    //   addr[63:13]             = tag          (L1I_TAG_BITS = 51)
    // =========================================================================
    localparam int OFFSET_LO  = 0;
    localparam int OFFSET_HI  = LINE_BITS - 1;           // 5
    localparam int INDEX_LO   = LINE_BITS;                // 6
    localparam int INDEX_HI   = LINE_BITS + L1I_SET_BITS - 1; // 12
    localparam int TAG_LO     = LINE_BITS + L1I_SET_BITS; // 13
    localparam int TAG_HI     = 63;                       // 63

    // =========================================================================
    // Stage-1 registers (clocked from incoming request)
    // =========================================================================
    logic                    s1_valid;
    logic [63:0]             s1_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_addr  <= '0;
        end else begin
            s1_valid <= req_valid;
            s1_addr  <= req_addr;
        end
    end

    // =========================================================================
    // Address decode for stage-1 (combinational from registered values)
    // =========================================================================
    logic [L1I_SET_BITS-1:0] s1_index;
    logic [L1I_TAG_BITS-1:0] s1_tag;

    assign s1_index = s1_addr[INDEX_HI:INDEX_LO];
    assign s1_tag   = s1_addr[TAG_HI:TAG_LO];

    // =========================================================================
    // Tag RAM interface
    // =========================================================================
    // Read port driven by the incoming (stage-0) address for 1-cycle latency
    logic [L1I_SET_BITS-1:0]  tr_raddr;
    logic [L1I_WAYS-1:0]      tr_valid_out;
    logic [L1I_TAG_BITS-1:0]  tr_tag_out [0:L1I_WAYS-1];

    // Write port driven by fill FSM
    logic                      tr_we;
    logic [L1I_SET_BITS-1:0]   tr_waddr;
    logic [1:0]                tr_wway;
    logic                      tr_wvalid;
    logic [L1I_TAG_BITS-1:0]   tr_wtag;
    logic                      tr_invalidate;

    assign tr_raddr     = req_addr[INDEX_HI:INDEX_LO];
    assign tr_invalidate = invalidate_all;

    icache_tag_ram u_tag_ram (
        .clk           (clk),
        .raddr         (tr_raddr),
        .valid_out     (tr_valid_out),
        .tag_out       (tr_tag_out),
        .we            (tr_we),
        .waddr         (tr_waddr),
        .wway          (tr_wway),
        .wvalid        (tr_wvalid),
        .wtag          (tr_wtag),
        .invalidate_all(tr_invalidate)
    );

    // =========================================================================
    // Data RAM interface
    // =========================================================================
    // On a hit the data RAM is read in parallel with tag comparison.
    // We must read all 4 ways and mux in stage-1; alternatively, read one way
    // selected by the hit.  For simplicity (and because SV lint prefers it),
    // we do a 4-way read and mux combinationally.
    //
    // We instantiate 4 single-way data RAMs.
    // =========================================================================
    logic [511:0] dr_rdata [0:L1I_WAYS-1];

    // Generate one data RAM per way
    genvar gw;
    generate
        for (gw = 0; gw < L1I_WAYS; gw++) begin : gen_data_ram
            // Per-way write enable – only the victim way is written on fill
            logic dr_we_w;
            assign dr_we_w = tr_we && (tr_wway == 2'(gw));

            icache_data_ram u_data_ram (
                .clk   (clk),
                .raddr (req_addr[INDEX_HI:INDEX_LO]),
                .rway  (2'd0),          // dummy – we read whole way bank
                .rdata (dr_rdata[gw]),
                .we    (dr_we_w),
                .waddr (tr_waddr),
                .wway  (2'd0),          // dummy
                .wdata (fill_resp_data)
            );
        end
    endgenerate

    // =========================================================================
    // Hit detection (combinational from stage-0 request address)
    // With async tag/data RAMs, the tag outputs are for req_addr (stage-0).
    // Hit comparison therefore uses req_addr tag, not s1 registered tag.
    // =========================================================================
    logic [L1I_TAG_BITS-1:0] s0_tag;
    assign s0_tag = req_addr[TAG_HI:TAG_LO];

    logic [L1I_WAYS-1:0] way_hit;
    logic                cache_hit;
    logic [1:0]          hit_way;

    always_comb begin
        way_hit   = '0;
        cache_hit = 1'b0;
        hit_way   = 2'd0;
        for (int w = 0; w < L1I_WAYS; w++) begin
            if (tr_valid_out[w] && (tr_tag_out[w] == s0_tag)) begin
                way_hit[w] = 1'b1;
                cache_hit  = 1'b1;
                hit_way    = 2'(w);
            end
        end
    end

    // =========================================================================
    // Data mux
    // =========================================================================
    logic [511:0] hit_data;
    assign hit_data = dr_rdata[hit_way];

    // =========================================================================
    // PLRU state (3-bit binary tree per set)
    //   Bit [2] = root:          0 → go left (ways 0/1), 1 → go right (ways 2/3)
    //   Bit [1] = left subtree:  0 → way 0,              1 → way 1
    //   Bit [0] = right subtree: 0 → way 2,              1 → way 3
    // =========================================================================
    logic [2:0] plru_state [L1I_SETS];

    // Victim way derived combinationally from PLRU state of current request set
    logic [L1I_SET_BITS-1:0] s0_index;
    assign s0_index = req_addr[INDEX_HI:INDEX_LO];

    logic [1:0] victim_way;
    always_comb begin
        automatic logic [2:0] ps = plru_state[s0_index];
        if (!ps[2]) begin
            victim_way = ps[1] ? 2'd0 : 2'd1;
        end else begin
            victim_way = ps[0] ? 2'd2 : 2'd3;
        end
    end

    // PLRU update helper macro: point away from accessed way (inlined below)

    // =========================================================================
    // Miss FSM
    // =========================================================================
    typedef enum logic [0:0] {
        ST_IDLE      = 1'b0,
        ST_WAIT_FILL = 1'b1
    } fsm_state_e;

    fsm_state_e state_q, state_d;

    // Latch the miss address and victim
    logic [63:0] miss_addr_q;
    logic [1:0]  miss_way_q;

    // Fill write-back controls driven from FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= ST_IDLE;
            miss_addr_q <= '0;
            miss_way_q  <= '0;
        end else begin
            state_q <= state_d;
            if (state_q == ST_IDLE && req_valid && !cache_hit && !invalidate_all) begin
                miss_addr_q <= req_addr;
                miss_way_q  <= victim_way;
            end
        end
    end

    // FSM combinational
    always_comb begin
        state_d        = state_q;
        tr_we          = 1'b0;
        tr_waddr       = '0;
        tr_wway        = '0;
        tr_wvalid      = 1'b0;
        tr_wtag        = '0;
        fill_req_valid = 1'b0;
        fill_req_addr  = '0;

        case (state_q)
            ST_IDLE: begin
                if (req_valid && !cache_hit && !invalidate_all) begin
                    // Issue fill request immediately
                    fill_req_valid = 1'b1;
                    fill_req_addr  = {req_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};
                    state_d        = ST_WAIT_FILL;
                end
            end

            ST_WAIT_FILL: begin
                // Hold fill request until acknowledged
                fill_req_valid = 1'b1;
                fill_req_addr  = {miss_addr_q[63:LINE_BITS], {LINE_BITS{1'b0}}};

                if (fill_resp_valid) begin
                    // Write tag RAM
                    tr_we     = 1'b1;
                    tr_waddr  = miss_addr_q[INDEX_HI:INDEX_LO];
                    tr_wway   = miss_way_q;
                    tr_wvalid = 1'b1;
                    tr_wtag   = miss_addr_q[TAG_HI:TAG_LO];
                    state_d   = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // =========================================================================
    // PLRU update (sequential)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < L1I_SETS; s++) begin
                plru_state[s] <= 3'd0;
            end
        end else if (invalidate_all) begin
            // No PLRU update during invalidation
        end else if (req_valid && cache_hit) begin
            case (hit_way)
                2'd0: plru_state[s0_index] <= {1'b1, 1'b1, plru_state[s0_index][0]};
                2'd1: plru_state[s0_index] <= {1'b1, 1'b0, plru_state[s0_index][0]};
                2'd2: plru_state[s0_index] <= {1'b0, plru_state[s0_index][1], 1'b1};
                2'd3: plru_state[s0_index] <= {1'b0, plru_state[s0_index][1], 1'b0};
                default: ;
            endcase
        end else if (state_q == ST_WAIT_FILL && fill_resp_valid) begin
            case (miss_way_q)
                2'd0: plru_state[miss_addr_q[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b1, plru_state[miss_addr_q[INDEX_HI:INDEX_LO]][0]};
                2'd1: plru_state[miss_addr_q[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b0, plru_state[miss_addr_q[INDEX_HI:INDEX_LO]][0]};
                2'd2: plru_state[miss_addr_q[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[miss_addr_q[INDEX_HI:INDEX_LO]][1], 1'b1};
                2'd3: plru_state[miss_addr_q[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[miss_addr_q[INDEX_HI:INDEX_LO]][1], 1'b0};
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Response outputs (combinational, using s1 registered address)
    // =========================================================================
    // Tag and data RAMs now use async reads, so their outputs correspond
    // to the current cycle's raddr (= previous cycle's req_addr, registered
    // in s1_addr). The hit detection uses s1_tag vs tr_tag_out, and
    // hit_data = dr_rdata[hit_way]. All are available in the same cycle
    // as s1_valid, giving 1-cycle hit latency from request.
    //
    // Fill-path forwarding: when a miss is in flight and the fill response
    // arrives, we can return the filled line directly — but ONLY if the
    // current req_addr still matches the line being filled.  If a redirect
    // has moved the fetch unit to a different line, the fill data is for
    // the OLD request and must not be presented as the response for the
    // new request (that would corrupt the instruction stream).
    logic fill_addr_matches;
    assign fill_addr_matches =
        (req_addr[63:LINE_BITS] == miss_addr_q[63:LINE_BITS]);

    always_comb begin
        resp_valid = 1'b0;
        resp_hit   = 1'b0;
        resp_data  = '0;

        if (req_valid && cache_hit && !invalidate_all) begin
            resp_valid = 1'b1;
            resp_hit   = 1'b1;
            resp_data  = hit_data;
        end else if (state_q == ST_WAIT_FILL && fill_resp_valid &&
                     req_valid && fill_addr_matches) begin
            resp_valid = 1'b1;
            resp_hit   = 1'b0;
            resp_data  = fill_resp_data;
        end
    end

    // =========================================================================
    // Invalidation busy: asserted while any invalidation is in progress.
    // Because invalidate_all clears all valid bits in a single cycle inside
    // the tag RAM, we only need to be busy for 1 cycle.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            invalidate_busy <= 1'b0;
        else
            invalidate_busy <= invalidate_all;
    end

endmodule
