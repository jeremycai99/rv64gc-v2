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
    input  logic [63:0]  fill_resp_addr, // line-aligned, used to filter stale L2 hit-pipe replays
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

    // Data RAM write data mux (combinational; assigned after sc_install_valid)
    logic [511:0] dr_wdata_mux;

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
                .wdata (dr_wdata_mux)
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
    logic [2:0] plru_victim_ps;
    always_comb begin
        plru_victim_ps = plru_state[s0_index];
        if (!plru_victim_ps[2]) begin
            victim_way = plru_victim_ps[1] ? 2'd0 : 2'd1;
        end else begin
            victim_way = plru_victim_ps[0] ? 2'd2 : 2'd3;
        end
    end

    // PLRU update helper macro: point away from accessed way (inlined below)

    // =========================================================================
    // Miss handling: 2-entry MSHR array (miss-under-miss support)
    //
    // Each MSHR tracks one outstanding miss: addr, victim way, whether the
    // fill request has been sent to L2, and whether the fill data arrived.
    // On a new miss, a free MSHR is allocated.  Fill requests are issued
    // one at a time (L2 accepts one per cycle).  Fill responses are matched
    // against all MSHRs by address.  Completed fills install one per cycle.
    // =========================================================================
    localparam int IC_MSHR_DEPTH = 2;

    logic                ic_mshr_valid    [0:IC_MSHR_DEPTH-1];
    logic [63:0]         ic_mshr_addr     [0:IC_MSHR_DEPTH-1];
    logic [1:0]          ic_mshr_victim   [0:IC_MSHR_DEPTH-1];
    logic                ic_mshr_req_sent [0:IC_MSHR_DEPTH-1];
    logic                ic_mshr_fill_done[0:IC_MSHR_DEPTH-1];
    logic [511:0]        ic_mshr_fill_data[0:IC_MSHR_DEPTH-1];

    // Find a free MSHR for allocation
    logic ic_mshr_free_avail;
    logic ic_mshr_free_idx;
    always_comb begin
        ic_mshr_free_avail = 1'b0;
        ic_mshr_free_idx   = 1'b0;
        for (int m = IC_MSHR_DEPTH-1; m >= 0; m--) begin
            if (!ic_mshr_valid[m]) begin
                ic_mshr_free_avail = 1'b1;
                ic_mshr_free_idx   = m[0];
            end
        end
    end

    // Check if the current request already has an MSHR allocated
    logic ic_mshr_addr_match;
    always_comb begin
        ic_mshr_addr_match = 1'b0;
        for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
            if (ic_mshr_valid[m] &&
                ic_mshr_addr[m][63:LINE_BITS] == req_addr[63:LINE_BITS])
                ic_mshr_addr_match = 1'b1;
        end
    end

    // Find an MSHR that needs the fill request held to L2.
    // Keep asserting fill_req_valid every cycle until the fill arrives
    // (the old FSM held it in ST_WAIT_FILL). The L2 has no req_ready
    // handshake on the icache port, so a single-cycle pulse can be
    // lost if the L2 arbiter is busy with dcache that cycle.
    logic ic_mshr_need_req;
    logic ic_mshr_req_idx;
    always_comb begin
        ic_mshr_need_req = 1'b0;
        ic_mshr_req_idx  = 1'b0;
        for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
            if (ic_mshr_valid[m] && !ic_mshr_fill_done[m] && !ic_mshr_need_req) begin
                ic_mshr_need_req = 1'b1;
                ic_mshr_req_idx  = m[0];
            end
        end
    end

    // Find an MSHR with completed fill (ready to install into cache)
    logic ic_mshr_install_avail;
    logic ic_mshr_install_idx;
    always_comb begin
        ic_mshr_install_avail = 1'b0;
        ic_mshr_install_idx   = 1'b0;
        for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
            if (ic_mshr_valid[m] && ic_mshr_fill_done[m] && !ic_mshr_install_avail) begin
                ic_mshr_install_avail = 1'b1;
                ic_mshr_install_idx   = m[0];
            end
        end
    end

    // Fill request to L2: issue for the first MSHR that needs it
    assign fill_req_valid = ic_mshr_need_req;
    assign fill_req_addr  = {ic_mshr_addr[ic_mshr_req_idx][63:LINE_BITS],
                             {LINE_BITS{1'b0}}};

    // Same-cycle install: when a fill response arrives and matches an MSHR,
    // install immediately (don't wait for fill_done next cycle).
    logic        sc_install_valid;
    logic        sc_install_idx;
    logic [63:0] sc_install_addr;
    logic [1:0]  sc_install_victim;
    always_comb begin
        sc_install_valid  = 1'b0;
        sc_install_idx    = 1'b0;
        sc_install_addr   = '0;
        sc_install_victim = '0;
        if (fill_resp_valid) begin
            for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
                if (ic_mshr_valid[m] && !ic_mshr_fill_done[m] &&
                    fill_resp_addr[63:LINE_BITS] == ic_mshr_addr[m][63:LINE_BITS]) begin
                    sc_install_valid  = 1'b1;
                    sc_install_idx    = m[0];
                    sc_install_addr   = ic_mshr_addr[m];
                    sc_install_victim = ic_mshr_victim[m];
                end
            end
        end
    end

    // Data RAM write data mux (combinational, uses signals declared earlier)
    assign dr_wdata_mux = sc_install_valid   ? fill_resp_data :
                           ic_mshr_install_avail ? ic_mshr_fill_data[ic_mshr_install_idx] : '0;

    // Tag/data RAM write: same-cycle install (priority) or deferred install
    always_comb begin
        tr_we     = 1'b0;
        tr_waddr  = '0;
        tr_wway   = '0;
        tr_wvalid = 1'b0;
        tr_wtag   = '0;

        if (sc_install_valid) begin
            // Install directly from fill response (same cycle)
            tr_we     = 1'b1;
            tr_waddr  = sc_install_addr[INDEX_HI:INDEX_LO];
            tr_wway   = sc_install_victim;
            tr_wvalid = 1'b1;
            tr_wtag   = sc_install_addr[TAG_HI:TAG_LO];
        end else if (ic_mshr_install_avail) begin
            // Deferred install from stored fill data
            tr_we     = 1'b1;
            tr_waddr  = ic_mshr_addr[ic_mshr_install_idx][INDEX_HI:INDEX_LO];
            tr_wway   = ic_mshr_victim[ic_mshr_install_idx];
            tr_wvalid = 1'b1;
            tr_wtag   = ic_mshr_addr[ic_mshr_install_idx][TAG_HI:TAG_LO];
        end
    end

    // MSHR sequential logic: allocate, receive fill, install
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || invalidate_all) begin
            for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
                ic_mshr_valid[m]     <= 1'b0;
                ic_mshr_req_sent[m]  <= 1'b0;
                ic_mshr_fill_done[m] <= 1'b0;
            end
        end else begin
            // 1. Allocate: on miss, grab a free MSHR
            if (req_valid && !cache_hit && !invalidate_all &&
                ic_mshr_free_avail && !ic_mshr_addr_match) begin
                ic_mshr_valid[ic_mshr_free_idx]     <= 1'b1;
                ic_mshr_addr[ic_mshr_free_idx]      <= req_addr;
                ic_mshr_victim[ic_mshr_free_idx]    <= victim_way;
                ic_mshr_req_sent[ic_mshr_free_idx]  <= 1'b0;
                ic_mshr_fill_done[ic_mshr_free_idx] <= 1'b0;
            end

            // 2. Mark fill request as sent
            if (ic_mshr_need_req) begin
                ic_mshr_req_sent[ic_mshr_req_idx] <= 1'b1;
            end

            // 3. Receive fill response: same-cycle install frees the MSHR
            //    immediately.  Otherwise store data for deferred install.
            if (sc_install_valid) begin
                // Same-cycle install: free MSHR now (tag/data RAM written
                // combinationally via tr_we from sc_install_valid)
                ic_mshr_valid[sc_install_idx] <= 1'b0;
            end else if (fill_resp_valid) begin
                // No same-cycle install possible (e.g., another install
                // in progress) — store data for deferred install
                for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
                    if (ic_mshr_valid[m] && ic_mshr_req_sent[m] &&
                        !ic_mshr_fill_done[m] &&
                        fill_resp_addr[63:LINE_BITS] == ic_mshr_addr[m][63:LINE_BITS]) begin
                        ic_mshr_fill_done[m] <= 1'b1;
                        ic_mshr_fill_data[m] <= fill_resp_data;
                    end
                end
            end

            // 4. Deferred install: free the MSHR after writing to tag/data RAM
            if (!sc_install_valid && ic_mshr_install_avail) begin
                ic_mshr_valid[ic_mshr_install_idx] <= 1'b0;
            end
        end
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
        end else if (sc_install_valid || ic_mshr_install_avail) begin
            // Update PLRU for the just-installed fill
            begin
                logic [L1I_SET_BITS-1:0] inst_set;
                logic [1:0] inst_way;
                inst_set = sc_install_valid ? sc_install_addr[INDEX_HI:INDEX_LO]
                                           : ic_mshr_addr[ic_mshr_install_idx][INDEX_HI:INDEX_LO];
                inst_way = sc_install_valid ? sc_install_victim
                                           : ic_mshr_victim[ic_mshr_install_idx];
                case (inst_way)
                    2'd0: plru_state[inst_set] <= {1'b1, 1'b1, plru_state[inst_set][0]};
                    2'd1: plru_state[inst_set] <= {1'b1, 1'b0, plru_state[inst_set][0]};
                    2'd2: plru_state[inst_set] <= {1'b0, plru_state[inst_set][1], 1'b1};
                    2'd3: plru_state[inst_set] <= {1'b0, plru_state[inst_set][1], 1'b0};
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Response outputs (combinational)
    // =========================================================================
    // Priority: 1) cache hit, 2) MSHR fill-forward (just-completed fill
    // whose address matches the current request).
    //
    // Fill-forward from MSHR: when a fill response arrives this cycle AND
    // the current req_addr matches the MSHR being filled, forward the data
    // directly.  Also check MSHRs with fill_done (already received).
    logic mshr_fwd_valid;
    logic [511:0] mshr_fwd_data;
    always_comb begin
        mshr_fwd_valid = 1'b0;
        mshr_fwd_data  = '0;
        // Check for just-arriving fill response matching current request
        if (fill_resp_valid && req_valid) begin
            for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
                if (ic_mshr_valid[m] && ic_mshr_req_sent[m] &&
                    fill_resp_addr[63:LINE_BITS] == req_addr[63:LINE_BITS]) begin
                    mshr_fwd_valid = 1'b1;
                    mshr_fwd_data  = fill_resp_data;
                end
            end
        end
        // Check for already-completed MSHR matching current request
        if (!mshr_fwd_valid && req_valid) begin
            for (int m = 0; m < IC_MSHR_DEPTH; m++) begin
                if (ic_mshr_valid[m] && ic_mshr_fill_done[m] &&
                    ic_mshr_addr[m][63:LINE_BITS] == req_addr[63:LINE_BITS]) begin
                    mshr_fwd_valid = 1'b1;
                    mshr_fwd_data  = ic_mshr_fill_data[m];
                end
            end
        end
    end

    always_comb begin
        resp_valid = 1'b0;
        resp_hit   = 1'b0;
        resp_data  = '0;

        if (req_valid && cache_hit && !invalidate_all) begin
            resp_valid = 1'b1;
            resp_hit   = 1'b1;
            resp_data  = hit_data;
        end else if (mshr_fwd_valid) begin
            resp_valid = 1'b1;
            resp_hit   = 1'b0;
            resp_data  = mshr_fwd_data;
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
