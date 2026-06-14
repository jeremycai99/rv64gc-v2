/* file: dcache.sv
 Description: 64 KB 4-way 2-bank L1 D-Cache with 16-entry MSHR and PLRU.
              Banking: 2 independent read ports (port A: load0/store, port B: load1).
              RAMs are dual-ported (dcache_data_ram / dcache_tag_ram) — bank crossbar
              is implicit in the dual-port structure; no explicit bank-select logic.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0 (stage4: L1D_BANKS 4->2, bank-select implicit in dual-port RAM)
*/
/* verilator lint_off MULTITOP */
module dcache
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    // Load ports (2)
    input  wire [1:0]  load_req_valid,
    input  wire [63:0] load_req_addr [0:1],
    input  wire [1:0]  load_req_size [0:1],
    input  wire [1:0]  load_req_is_unsigned,
    output reg [1:0]  load_resp_valid,
    output reg [63:0] load_resp_data [0:1],
    output reg [1:0]  load_resp_hit,
    output reg [1:0]  load_miss_retry,
    // Store port (1, from CSB)
    input  wire        store_req_valid,
    input  wire [63:0] store_req_addr,
    input  wire [63:0] store_req_data,
    input  wire [7:0]  store_req_byte_mask,
    // PTW-injected store (page-table A/D update).  The PTW reads PTEs through
    // its OWN L2 port, bypassing the L1D, so PTW stores must NOT take the NWA
    // deferred-overlay path (their write-through must reach L2 promptly).
    input  wire        store_req_is_ptw,
    // Next-store peek (no-bubble bypass): looked up in S0 during the cycle the
    // current head is being acknowledged, so back-to-back stores ack 1/cyc.
    input  wire        store_req_next_valid,
    input  wire [63:0] store_req_next_addr,
    input  wire [63:0] store_req_next_data,
    input  wire [7:0]  store_req_next_byte_mask,
    output reg        store_ack,
    // L2 interface (miss handling)
    output reg        l2_req_valid,
    output reg [63:0] l2_req_addr,
    output reg        l2_req_we,           // 1=writeback, 0=fill
    output reg [511:0] l2_req_wdata,       // writeback data
    input  wire        l2_req_ready,
    input  wire        l2_resp_valid,
    input  wire [63:0] l2_resp_addr,
    input  wire [511:0] l2_resp_data,
    // Fill snoop (to LSU for missed-load late response)
    // Fires the cycle a fill is installed into the cache.  The LSU uses
    // this to wake up any pending loads in its miss buffer.
    output reg        fill_snoop_valid,
    output reg [63:0] fill_snoop_addr,
    output reg [511:0] fill_snoop_data,
    // Store write-through drain state, used to hold FENCE.I until older
    // committed stores are instruction-visible in the backing hierarchy.
    output reg        store_wt_busy,
    // D-side hardware prefetch request (Lever A).  A fill-only line request
    // from the LSU stride engine: line-aligned PHYSICAL address.  It runs its
    // own S0/S1 tag probe on RAM port B (only when port B is idle, so it never
    // displaces a demand load1/store lookup), and allocates a free MSHR as the
    // LOWEST-priority alloc arm (demand strict-priority).  It produces NO load
    // response and NO writeback -- the existing fill/install path brings the
    // line into the L1D and frees the MSHR.  Accepted (pf_req_taken) only when
    // the probe slot is granted; the LSU drops the request otherwise.
    // ENABLE=0 => pf_req_valid is tied 0 at the LSU => this whole path is dead.
    input  wire        pf_req_valid,
    input  wire [63:0] pf_req_addr,
    output reg        pf_req_taken,
    // Invalidate
    input  wire        invalidate_all,
    output reg        invalidate_busy
);

    // =========================================================================
    // Address field positions
    //   [5:0]   = byte offset  (LINE_BITS = 6)
    //   [13:6]  = set index    (L1D_SET_BITS = 8)
    //   [63:14] = tag          (L1D_TAG_BITS = 50)
    // =========================================================================
    localparam int OFFSET_HI = LINE_BITS - 1;                        // 5
    localparam int INDEX_LO  = LINE_BITS;                             // 6
    localparam int INDEX_HI  = LINE_BITS + L1D_SET_BITS - 1;         // 13
    localparam int TAG_LO    = LINE_BITS + L1D_SET_BITS;             // 14
    localparam int TAG_HI    = 63;

    // =========================================================================
    // Tag RAM interface signals (port A: load0 / store, port B: load1)
    // =========================================================================
    logic [L1D_SET_BITS-1:0]  tr_raddr;
    logic [L1D_WAYS-1:0]      tr_valid_out;
    logic [L1D_WAYS-1:0]      tr_dirty_out;
    logic [L1D_TAG_BITS-1:0]  tr_tag_out [0:L1D_WAYS-1];

    logic [L1D_SET_BITS-1:0]  tr_raddr2;
    logic [L1D_WAYS-1:0]      tr_valid_out2;
    logic [L1D_WAYS-1:0]      tr_dirty_out2;
    logic [L1D_TAG_BITS-1:0]  tr_tag_out2 [0:L1D_WAYS-1];

    logic                      tr_we;
    logic [L1D_SET_BITS-1:0]   tr_waddr;
    logic [1:0]                tr_wway;
    logic                      tr_wvalid;
    logic                      tr_wdirty;
    logic [L1D_TAG_BITS-1:0]   tr_wtag;

    logic                      tr_dirty_we;

`ifndef SYNTHESIS
    bit     sim_perf_profile;
    integer sim_store_req_cyc;
    integer sim_store_ack_cyc;
    integer sim_store_hit_ack_cyc;
    integer sim_store_fill_ack_cyc;
    integer sim_store_wait_fill_cyc;
    integer sim_store_port_wait_cyc;
    integer sim_store_miss_alloc_cyc;
    integer sim_store_miss_merge_cyc;
    integer sim_store_port_grant_a_cyc;
    integer sim_store_port_grant_b_cyc;
    integer sim_ld_both_s1_cyc;
    integer sim_ld0_miss_new_cyc;
    integer sim_ld1_miss_new_cyc;
    integer sim_ld0_miss_alloc_cyc;
    integer sim_ld1_miss_alloc_cyc;
    integer sim_ld0_miss_merge_cyc;
    integer sim_ld1_miss_merge_cyc;
    integer sim_ld1_new_blocked_by_ld0_alloc_cyc;
    integer sim_ld1_new_blocked_same_line_cyc;
    integer sim_ld1_new_blocked_diff_line_cyc;
    integer sim_ld_new_blocked_no_free_cyc;
    integer sim_store_wt_enq_cyc;
    integer sim_store_wt_deq_cyc;
    integer sim_store_wt_full_cyc;
    integer sim_store_wt_occ_max;
`endif
    logic [L1D_SET_BITS-1:0]   tr_dirty_waddr;
    logic [1:0]                tr_dirty_wway;

    dcache_tag_ram u_tag_ram (
        .clk          (clk),
        .rst_n        (rst_n),
        .raddr        (tr_raddr),
        .valid_out    (tr_valid_out),
        .dirty_out    (tr_dirty_out),
        .tag_out      (tr_tag_out),
        .raddr2       (tr_raddr2),
        .valid_out2   (tr_valid_out2),
        .dirty_out2   (tr_dirty_out2),
        .tag_out2     (tr_tag_out2),
        .we           (tr_we),
        .waddr        (tr_waddr),
        .wway         (tr_wway),
        .wvalid       (tr_wvalid),
        .wdirty       (tr_wdirty),
        .wtag         (tr_wtag),
        .dirty_we     (tr_dirty_we),
        .dirty_waddr  (tr_dirty_waddr),
        .dirty_wway   (tr_dirty_wway),
        .invalidate_all(invalidate_all)
    );

    // =========================================================================
    // Data RAM interface signals (port A: load0 / store, port B: load1)
    // =========================================================================
    logic [L1D_SET_BITS-1:0]  dr_raddr;
    logic [1:0]               dr_rway;
    logic [LINE_SIZE*8-1:0]   dr_rdata;
    logic [LINE_SIZE*8-1:0]   dr_rdata_all [0:L1D_WAYS-1];

    logic [L1D_SET_BITS-1:0]  dr_raddr2;
    logic [LINE_SIZE*8-1:0]   dr_rdata_all2 [0:L1D_WAYS-1];

    logic                     dr_we;
    logic [L1D_SET_BITS-1:0]  dr_waddr;
    logic [1:0]               dr_wway;
    logic [LINE_SIZE*8-1:0]   dr_wdata;

    logic                     dr_bwe;
    logic [L1D_SET_BITS-1:0]  dr_bwaddr;
    logic [1:0]               dr_bwway;
    logic [LINE_SIZE*8-1:0]   dr_bwdata;
    logic [LINE_SIZE-1:0]     dr_bwmask;

    dcache_data_ram u_data_ram (
        .clk        (clk),
        .raddr      (dr_raddr),
        .rway       (dr_rway),
        .rdata      (dr_rdata),
        .rdata_all  (dr_rdata_all),
        .raddr2     (dr_raddr2),
        .rdata_all2 (dr_rdata_all2),
        .we         (dr_we),
        .waddr      (dr_waddr),
        .wway       (dr_wway),
        .wdata      (dr_wdata),
        .bwe        (dr_bwe),
        .bwaddr     (dr_bwaddr),
        .bwway      (dr_bwway),
        .bwdata     (dr_bwdata),
        .bwmask     (dr_bwmask)
    );

    // =========================================================================
    // Pipeline stage registers
    // Dual-ported tag/data RAMs: port A for load0/store, port B for load1.
    // No bank-conflict stall needed — both ports read independently.
    // =========================================================================

    // Stage-0 → Stage-1 pipeline registers for the primary (port 0) load
    logic                    s1_ld0_valid;
    logic [63:0]             s1_ld0_addr;
    logic [1:0]              s1_ld0_size;
    logic                    s1_ld0_unsigned;

    // Stage-0 → Stage-1 pipeline registers for secondary (port 1) load
    logic                    s1_ld1_valid;
    logic [63:0]             s1_ld1_addr;
    logic [1:0]              s1_ld1_size;
    logic                    s1_ld1_unsigned;

    // Stage-0 → Stage-1 for store
    logic                    s1_st_valid;
    logic [63:0]             s1_st_addr;
    logic [63:0]             s1_st_data;
    logic [7:0]              s1_st_byte_mask;
    logic                    s1_st_is_ptw;
    logic                    s1_st_use_port_b;

    // Stage-0 → Stage-1 for the D-prefetch probe (shares RAM port B with load1)
    logic                    s1_pf_valid;
    logic [63:0]             s1_pf_addr;   // line-aligned physical prefetch addr
    logic                    s0_store_lookup_grant_a;
    logic                    s0_store_lookup_grant_b;
    logic                    store_ack_s1;
    logic                    store_ack_matches_head;

    // Store lookup can use either shared read port:
    //   - port A when load0 is idle
    //   - port B when load0 is active but load1 is idle
    // Advance a store into s1 only when it actually won one of the ports;
    // otherwise the tag/data outputs still belong to a load and the store
    // must remain in the CSB.
    // No-bubble bypass: during the cycle the S1 store acknowledges the
    // presented CSB head, the head re-presented on store_req_* is stale (the
    // CSB advances on this edge).  Instead of dropping the S0 lookup (a dead
    // cycle), look up the NEXT store (head+1 peek) so back-to-back stores
    // sustain one ack per cycle.  Gated; 0 = legacy 2-cycle cadence.
    logic        s0_st_bypass;
    logic        s0_store_eff_valid;
    logic [63:0] s0_store_eff_addr;
    logic [63:0] s0_store_eff_data;
    logic [7:0]  s0_store_eff_mask;
    assign s0_st_bypass = STORE_PIPE_NOBUBBLE_ENABLE && store_ack_matches_head &&
                          store_req_next_valid;
    assign s0_store_eff_valid = s0_st_bypass ? 1'b1 : store_req_valid;
    assign s0_store_eff_addr  = s0_st_bypass ? store_req_next_addr
                                             : store_req_addr;
    assign s0_store_eff_data  = s0_st_bypass ? store_req_next_data
                                             : store_req_data;
    assign s0_store_eff_mask  = s0_st_bypass ? store_req_next_byte_mask
                                             : store_req_byte_mask;

    assign s0_store_lookup_grant_a = s0_store_eff_valid && !load_req_valid[0];
    assign s0_store_lookup_grant_b = s0_store_eff_valid && load_req_valid[0]
                                   && !load_req_valid[1];

    // D-prefetch probe grant: port B is free this cycle iff neither load1 nor a
    // port-B store lookup is using it.  The prefetch is the LOWEST priority
    // consumer of port B -- it never displaces a demand lookup.  Gated by the
    // pkg ENABLE (constant-folds the whole path away when 0).
    localparam logic dpf_en = D_PREFETCH_ENABLE;
    logic pf_probe_grant;
    assign pf_probe_grant = dpf_en && pf_req_valid &&
                            !load_req_valid[1] && !s0_store_lookup_grant_b;
    assign pf_req_taken = pf_probe_grant;

    // Tag RAM port A: load port 0 (priority), then store
    always_comb begin
        if (load_req_valid[0])
            tr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
        else if (s0_store_lookup_grant_a)
            tr_raddr = s0_store_eff_addr[INDEX_HI:INDEX_LO];
        else
            tr_raddr = '0;
    end

    // Tag RAM port B: load port 1, store when load1 idle, then prefetch probe.
    assign tr_raddr2 = load_req_valid[1] ? load_req_addr[1][INDEX_HI:INDEX_LO]
                                         : (s0_store_lookup_grant_b
                                            ? s0_store_eff_addr[INDEX_HI:INDEX_LO]
                                            : (pf_probe_grant
                                               ? pf_req_addr[INDEX_HI:INDEX_LO]
                                               : '0));

    // Data RAM port A: load port 0, or store when load0 is idle.
    always_comb begin
        if (load_req_valid[0]) begin
            dr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0;
        end else if (s0_store_lookup_grant_a) begin
            dr_raddr = s0_store_eff_addr[INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0;
        end else begin
            dr_raddr = '0;
            dr_rway  = 2'd0;
        end
    end

    // Data RAM port B: load port 1, store when load1 idle, then prefetch probe.
    // (The prefetch only needs the victim's dirty-line data for a possible
    //  write-back, which dr_rdata_all2 supplies the same as a load1 miss.)
    assign dr_raddr2 = load_req_valid[1] ? load_req_addr[1][INDEX_HI:INDEX_LO]
                                         : (s0_store_lookup_grant_b
                                            ? s0_store_eff_addr[INDEX_HI:INDEX_LO]
                                            : (pf_probe_grant
                                               ? pf_req_addr[INDEX_HI:INDEX_LO]
                                               : '0));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_ld0_valid    <= 1'b0;
            s1_ld0_addr     <= '0;
            s1_ld0_size     <= '0;
            s1_ld0_unsigned <= 1'b0;
            s1_ld1_valid    <= 1'b0;
            s1_ld1_addr     <= '0;
            s1_ld1_size     <= '0;
            s1_ld1_unsigned <= 1'b0;
            s1_st_valid     <= 1'b0;
            s1_st_addr      <= '0;
            s1_st_data      <= '0;
            s1_st_byte_mask <= '0;
            s1_st_is_ptw    <= 1'b0;
            s1_st_use_port_b <= 1'b0;
            s1_pf_valid     <= 1'b0;
            s1_pf_addr      <= '0;
        end else begin
            s1_ld0_valid    <= load_req_valid[0];
            s1_ld0_addr     <= load_req_addr[0];
            s1_ld0_size     <= load_req_size[0];
            s1_ld0_unsigned <= load_req_is_unsigned[0];

            // Prefetch probe S1 register: a granted probe carries its
            // line-aligned address into S1 for tag-port-B hit/victim resolution.
            s1_pf_valid     <= pf_probe_grant;
            s1_pf_addr      <= {pf_req_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};

            // No conflict suppression — port B handles port 1 independently
            s1_ld1_valid    <= load_req_valid[1];
            s1_ld1_addr     <= load_req_addr[1];
            s1_ld1_size     <= load_req_size[1];
            s1_ld1_unsigned <= load_req_is_unsigned[1];

            // store_ack_s1 is generated from the previous cycle's S1 store
            // lookup.  When it acknowledges the current CSB head, the CSB
            // will advance on this edge; do not re-latch that same store into
            // S1 (a duplicate write) — UNLESS the no-bubble bypass redirected
            // this cycle's S0 lookup to the NEXT store (s0_st_bypass), in
            // which case the latched store is the new head, not a duplicate.
            s1_st_valid     <= (s0_store_lookup_grant_a || s0_store_lookup_grant_b) &&
                               (s0_st_bypass || !store_ack_matches_head);
            s1_st_addr      <= s0_store_eff_addr;
            s1_st_data      <= s0_store_eff_data;
            s1_st_byte_mask <= s0_store_eff_mask;
            // The bypass never engages while the PTW is injecting (next_valid
            // is killed externally), so the effective store is PTW iff the
            // presented head is.
            s1_st_is_ptw    <= store_req_is_ptw && !s0_st_bypass;
            s1_st_use_port_b <= s0_store_lookup_grant_b;
        end
    end

    // =========================================================================
    // Stage-1: tag comparison and hit detection
    // =========================================================================
    logic [L1D_SET_BITS-1:0] s1_ld0_index;
    logic [L1D_TAG_BITS-1:0] s1_ld0_tag;
    logic [L1D_SET_BITS-1:0] s1_ld1_index;
    logic [L1D_TAG_BITS-1:0] s1_ld1_tag;
    logic [L1D_SET_BITS-1:0] s1_st_index;
    logic [L1D_TAG_BITS-1:0] s1_st_tag;

    assign s1_ld0_index = s1_ld0_addr[INDEX_HI:INDEX_LO];
    assign s1_ld0_tag   = s1_ld0_addr[TAG_HI:TAG_LO];
    assign s1_ld1_index = s1_ld1_addr[INDEX_HI:INDEX_LO];
    assign s1_ld1_tag   = s1_ld1_addr[TAG_HI:TAG_LO];
    assign s1_st_index  = s1_st_addr[INDEX_HI:INDEX_LO];
    assign s1_st_tag    = s1_st_addr[TAG_HI:TAG_LO];

    // Hit detection for load port 0
    logic [L1D_WAYS-1:0] ld0_way_hit;
    logic                ld0_cache_hit;
    logic [1:0]          ld0_hit_way;

    always_comb begin
        ld0_way_hit   = '0;
        ld0_cache_hit = 1'b0;
        ld0_hit_way   = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (tr_valid_out[w] && (tr_tag_out[w] == s1_ld0_tag)) begin
                ld0_way_hit[w] = 1'b1;
                ld0_cache_hit  = 1'b1;
                ld0_hit_way    = 2'(w);
            end
        end
    end

    // Hit detection for load port 1 (uses tag RAM port B)
    logic [L1D_WAYS-1:0] ld1_way_hit;
    logic                ld1_cache_hit;
    logic [1:0]          ld1_hit_way;

    always_comb begin
        ld1_way_hit   = '0;
        ld1_cache_hit = 1'b0;
        ld1_hit_way   = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (tr_valid_out2[w] && (tr_tag_out2[w] == s1_ld1_tag)) begin
                ld1_way_hit[w] = 1'b1;
                ld1_cache_hit  = 1'b1;
                ld1_hit_way    = 2'(w);
            end
        end
    end

    // Hit detection for store port
    logic [L1D_WAYS-1:0] st_way_hit;
    logic                st_cache_hit;
    logic [1:0]          st_hit_way;
    logic                st_dirty_way [0:L1D_WAYS-1];
    logic [L1D_TAG_BITS-1:0] st_tag_way [0:L1D_WAYS-1];
    logic [LINE_SIZE*8-1:0] st_data_way [0:L1D_WAYS-1];

    always_comb begin
        st_way_hit   = '0;
        st_cache_hit = 1'b0;
        st_hit_way   = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            st_dirty_way[w] = s1_st_use_port_b ? tr_dirty_out2[w]
                                               : tr_dirty_out[w];
            st_tag_way[w]   = s1_st_use_port_b ? tr_tag_out2[w]
                                               : tr_tag_out[w];
            st_data_way[w]  = s1_st_use_port_b ? dr_rdata_all2[w]
                                               : dr_rdata_all[w];
            if ((s1_st_use_port_b ? tr_valid_out2[w] : tr_valid_out[w]) &&
                (st_tag_way[w] == s1_st_tag)) begin
                st_way_hit[w] = 1'b1;
                st_cache_hit  = 1'b1;
                st_hit_way    = 2'(w);
            end
        end
    end

    // Prefetch probe hit detection (port B tag read, line-aligned).  A probe
    // that hits an installed line or whose lookup index is stale (port B was
    // granted to a demand consumer this cycle) is dropped; only a clean
    // resident-miss with a free MSHR allocates.
    logic [L1D_SET_BITS-1:0] s1_pf_index;
    logic [L1D_TAG_BITS-1:0] s1_pf_tag;
    assign s1_pf_index = s1_pf_addr[INDEX_HI:INDEX_LO];
    assign s1_pf_tag   = s1_pf_addr[TAG_HI:TAG_LO];
    logic pf_cache_hit;
    always_comb begin
        pf_cache_hit = 1'b0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (tr_valid_out2[w] && (tr_tag_out2[w] == s1_pf_tag))
                pf_cache_hit = 1'b1;
        end
    end

    // =========================================================================
    // Data mux from RAM output (way selected by hit way)
    // The data RAM was read with the s0 address so its output is available in s1.
    // We read all ways via rdata_all and mux by ld0_hit_way here.
    // =========================================================================
    logic [LINE_SIZE*8-1:0] ld0_line_data;
    assign ld0_line_data = dr_rdata_all[ld0_hit_way];

    // =========================================================================
    // PLRU state (3-bit binary tree per set)
    // =========================================================================
    logic [2:0] plru_state [L1D_SETS];

    // Inline PLRU victim selection from current set state
    logic [1:0] victim_way_s1;
    always_comb begin
        if (!plru_state[s1_ld0_index][2])
            victim_way_s1 = plru_state[s1_ld0_index][1] ? 2'd0 : 2'd1;
        else
            victim_way_s1 = plru_state[s1_ld0_index][0] ? 2'd2 : 2'd3;
    end

    // Load-port-1 miss victim selection uses the secondary load's own set.
    logic [1:0] victim_way_ld1;
    always_comb begin
        if (!plru_state[s1_ld1_index][2])
            victim_way_ld1 = plru_state[s1_ld1_index][1] ? 2'd0 : 2'd1;
        else
            victim_way_ld1 = plru_state[s1_ld1_index][0] ? 2'd2 : 2'd3;
    end

    // Store-miss victim selection uses the store's own set index.
    logic [1:0] victim_way_st;
    always_comb begin
        if (!plru_state[s1_st_index][2])
            victim_way_st = plru_state[s1_st_index][1] ? 2'd0 : 2'd1;
        else
            victim_way_st = plru_state[s1_st_index][0] ? 2'd2 : 2'd3;
    end

    // Prefetch-fill victim selection uses the prefetch line's own set index
    // (port-B tag/data reads supply that set's ways).
    logic [1:0] victim_way_pf;
    always_comb begin
        if (!plru_state[s1_pf_index][2])
            victim_way_pf = plru_state[s1_pf_index][1] ? 2'd0 : 2'd1;
        else
            victim_way_pf = plru_state[s1_pf_index][0] ? 2'd2 : 2'd3;
    end

    // =========================================================================
    // Inline extract_word: combinational word extraction from cache line
    // =========================================================================
    logic [63:0] ld0_extracted, ld1_extracted;

    // Select the cache line from the hit way for each port.
    // Port 1 uses data RAM port B (independent read port).
    logic [LINE_SIZE*8-1:0] ld1_line_data;
    assign ld1_line_data = dr_rdata_all2[ld1_hit_way];

    always_comb begin
        logic [5:0]  byte_off0;
        logic [63:0] raw0;
        byte_off0 = s1_ld0_addr[OFFSET_HI:0];
        raw0 = ld0_line_data[byte_off0*8 +: 64];
        case (s1_ld0_size)
            2'd0: ld0_extracted = s1_ld0_unsigned ? {56'b0, raw0[7:0]}  : {{56{raw0[7]}},  raw0[7:0]};
            2'd1: ld0_extracted = s1_ld0_unsigned ? {48'b0, raw0[15:0]} : {{48{raw0[15]}}, raw0[15:0]};
            2'd2: ld0_extracted = s1_ld0_unsigned ? {32'b0, raw0[31:0]} : {{32{raw0[31]}}, raw0[31:0]};
            default: ld0_extracted = raw0;
        endcase
    end

    always_comb begin
        logic [5:0]  byte_off1;
        logic [63:0] raw1;
        byte_off1 = s1_ld1_addr[OFFSET_HI:0];
        raw1 = ld1_line_data[byte_off1*8 +: 64];
        case (s1_ld1_size)
            2'd0: ld1_extracted = s1_ld1_unsigned ? {56'b0, raw1[7:0]}  : {{56{raw1[7]}},  raw1[7:0]};
            2'd1: ld1_extracted = s1_ld1_unsigned ? {48'b0, raw1[15:0]} : {{48{raw1[15]}}, raw1[15:0]};
            2'd2: ld1_extracted = s1_ld1_unsigned ? {32'b0, raw1[31:0]} : {{32{raw1[31]}}, raw1[31:0]};
            default: ld1_extracted = raw1;
        endcase
    end

    // =========================================================================
    // MSHR (16 entries)
    // =========================================================================
    localparam int MSHR_DEPTH    = L1D_MSHR_DEPTH; // 16
    localparam int MSHR_IDX_BITS = $clog2(MSHR_DEPTH); // 4

    // No-write-allocate (write-validate) enable.  When set, a streaming store
    // miss is NOT held for a read-for-ownership fill: it accumulates a per-line
    // overlay in an MSHR (nwa_pending), is acknowledged immediately (write-
    // around: bytes also go to L2 via the existing write-through queue), and
    // the L1D line is installed clean once the overlay mask covers the full
    // line.  A load/atomic that needs the line, or MSHR pressure, upgrades the
    // entry back to a normal read-for-ownership fill (the fill folds the
    // overlay, so reads are always coherent regardless of WT drain).  ENABLE=0
    // is byte-identical to the legacy write-allocate path.
    localparam logic nwa_en = NO_WRITE_ALLOCATE_ENABLE;

    // L2-fill comb-assert dispatch (dead-cycle fix A).  ENABLE=0 is
    // byte-identical to the legacy registered IDLE->FILL_REQ dispatch.
    localparam logic l2f_comb_en = L2_FILL_COMB_REQ_ENABLE;

    typedef struct packed {
        logic                    valid;
        logic [63:0]             addr;          // line-aligned miss address
        logic                    writeback_pend; // waiting to send WB to L2
        logic                    fill_pend;      // waiting for fill from L2
        logic                    fill_done;      // fill received, ready to install
        logic [511:0]            fill_data;      // data received from L2
        logic                    store_pending;  // store miss waiting on fill
        logic [5:0]              store_byte_off; // byte offset within the line
        logic [63:0]             store_data;     // LSB-aligned store data
        logic [7:0]              store_byte_mask;// valid bytes in store_data
        logic [LINE_SIZE*8-1:0]  store_line_data;// full-line store overlay
        logic [LINE_SIZE-1:0]    store_line_mask;// bytes valid in overlay
        logic                    nwa_pending;    // NWA: deferred no-fill streaming-store line
        logic                    nwa_wt_owed;    // NWA: line owes a full-line write-through at install
        logic [6:0]              nwa_idle_cnt;   // NWA: cycles since alloc; bounds L2 visibility
        logic [1:0]              victim;         // victim way for fill
        logic                    dirty_evict;    // victim was dirty
        logic [511:0]            evict_data;     // dirty line data for writeback
        logic [63:0]             evict_addr;     // dirty line address for writeback
    } mshr_entry_t;

    mshr_entry_t mshr [0:MSHR_DEPTH-1];

    function automatic logic [511:0] merge_store_into_line(
        input logic [511:0] line_data,
        input logic [5:0]   byte_off,
        input logic [63:0]  store_data,
        input logic [7:0]   byte_mask
    );
        logic [511:0] merged;
        int line_byte;
        begin
            merged = line_data;
            for (int b = 0; b < 8; b++) begin
                line_byte = int'(byte_off) + b;
                if (byte_mask[b] && (line_byte < LINE_SIZE))
                    merged[line_byte*8 +: 8] = store_data[b*8 +: 8];
            end
            merge_store_into_line = merged;
        end
    endfunction

    function automatic logic [511:0] merge_store_overlay_into_line(
        input logic [511:0]           line_data,
        input logic [LINE_SIZE*8-1:0] store_line_data,
        input logic [LINE_SIZE-1:0]   store_line_mask
    );
        logic [511:0] merged;
        begin
            merged = line_data;
            for (int b = 0; b < LINE_SIZE; b++) begin
                if (store_line_mask[b])
                    merged[b*8 +: 8] = store_line_data[b*8 +: 8];
            end
            merge_store_overlay_into_line = merged;
        end
    endfunction

    // =========================================================================
    // MSHR lookup: find a matching pending entry
    // =========================================================================
    logic [MSHR_IDX_BITS-1:0] mshr_match_idx;
    logic                     mshr_match_hit;
    logic [63:0]              ld0_line_addr;
    logic [63:0]              ld1_line_addr;
    logic [63:0]              st_line_addr;
    assign ld0_line_addr = {s1_ld0_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign ld1_line_addr = {s1_ld1_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign st_line_addr  = {s1_st_addr[63:LINE_BITS],  {LINE_BITS{1'b0}}};

    always_comb begin
        mshr_match_idx = '0;
        mshr_match_hit = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && (mshr[m].addr == ld0_line_addr)) begin
                mshr_match_hit = 1'b1;
                mshr_match_idx = MSHR_IDX_BITS'(m);
            end
        end
    end

    // MSHR match check for load1 miss.
    logic [MSHR_IDX_BITS-1:0] mshr_ld1_match_idx;
    logic                     mshr_ld1_match_hit;
    always_comb begin
        mshr_ld1_match_idx = '0;
        mshr_ld1_match_hit = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && (mshr[m].addr == ld1_line_addr)) begin
                mshr_ld1_match_hit = 1'b1;
                mshr_ld1_match_idx = MSHR_IDX_BITS'(m);
            end
        end
    end

    // MSHR match check for store miss (write-allocate)
    logic [MSHR_IDX_BITS-1:0] mshr_st_match_idx;
    logic                     mshr_st_match_hit;
    always_comb begin
        mshr_st_match_idx = '0;
        mshr_st_match_hit = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && (mshr[m].addr == st_line_addr)) begin
                mshr_st_match_hit = 1'b1;
                mshr_st_match_idx = MSHR_IDX_BITS'(m);
            end
        end
    end

    // MSHR match check for the prefetch probe (an in-flight miss already
    // covers the line -- the prefetch is redundant, drop it).
    logic [63:0] pf_line_addr;
    assign pf_line_addr = {s1_pf_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};
    logic mshr_pf_match_hit;
    always_comb begin
        mshr_pf_match_hit = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && (mshr[m].addr == pf_line_addr))
                mshr_pf_match_hit = 1'b1;
        end
    end

    // Find a free MSHR slot
    logic [MSHR_IDX_BITS-1:0] mshr_free_idx;
    logic                     mshr_free_avail;
    // MSHR occupancy (for the prefetch reservation gate).  The decisive census
    // hazard is that the high-MLP STREAM rows saturate the L1D MSHR / L2 arb:
    // a prefetch that takes an MSHR there displaces demand fills (measured
    // stream-l2 +4..7%).  Reserve the upper MSHRs for DEMAND: a prefetch may
    // allocate only when occupancy is below DPF_MSHR_RESERVE (lots of free
    // slots).  The bandwidth-bound STREAM rows keep their MSHRs busy with demand
    // => prefetch is refused; the low-MLP kernel/memcpy (mostly-idle MSHRs)
    // prefetch freely.  This is the census's "issue only into a free slot,
    // never steal a demand slot" rule placed where demand+prefetch ACTUALLY
    // contend (the dcache MSHR), not the upstream LSU LMB.
    logic [MSHR_IDX_BITS:0]   mshr_occ;
    logic                     mshr_pf_room;

    always_comb begin
        mshr_free_idx   = '0;
        mshr_free_avail = 1'b0;
        mshr_occ        = '0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (!mshr[m].valid && !mshr_free_avail) begin
                mshr_free_avail = 1'b1;
                mshr_free_idx   = MSHR_IDX_BITS'(m);
            end
            if (mshr[m].valid) mshr_occ = mshr_occ + 1'b1;
        end
    end
    assign mshr_pf_room = mshr_occ < (MSHR_IDX_BITS+1)'(DPF_MSHR_RESERVE);

    // =========================================================================
    // L2 arbitration FSM
    // Priorities: writeback > fill request
    // =========================================================================
    typedef enum logic [1:0] {
        L2_IDLE      = 2'd0,
        L2_WRITEBACK = 2'd1,
        L2_FILL_REQ  = 2'd2,
        L2_FILL_WAIT = 2'd3
    } l2_state_e;

    l2_state_e l2_state_q, l2_state_d;

    // Track which MSHR is being serviced
    logic [MSHR_IDX_BITS-1:0] l2_active_mshr_q, l2_active_mshr_d;
    logic [LINE_SIZE*8-1:0]   st_wt_line_data;
    logic                     st_wt_enq_valid;
    logic                     st_wt_enq_ready;
    logic [63:0]              st_wt_enq_addr;
    logic [LINE_SIZE*8-1:0]   st_wt_enq_data;
    logic                     st_wt_deq_valid;
    logic                     st_wt_deq_fire;
    logic                     st_wt_merge_ready;
    logic                     st_wt_merge_fire;
    logic                     st_wt_push_fire;
    logic                     st_wt_enq_full_line;
    logic                     st_wt_deq_same_line;
    logic [LINE_SIZE*8-1:0]   st_wt_push_data;
    logic [LINE_SIZE-1:0]     st_full_mask;
    logic [LINE_SIZE*8-1:0]   st_full_data;
    logic [5:0]               st_line_off;
    int                       st_line_byte [0:7];
    logic [LINE_SIZE*8-1:0]   fill_done_line_data;
    logic                     fill_done_store_merge;

    localparam int WT_DEPTH      = 4;
    localparam int WT_IDX_BITS   = $clog2(WT_DEPTH);
    localparam int WT_COUNT_BITS = $clog2(WT_DEPTH + 1);

    logic [WT_IDX_BITS-1:0]      wt_tail_prev;
    logic [WT_IDX_BITS-1:0]      wt_head_q;
    logic [WT_IDX_BITS-1:0]      wt_tail_q;
    logic [WT_COUNT_BITS-1:0]    wt_count_q;
    logic [63:0]                 wt_addr_q [0:WT_DEPTH-1];
    logic [LINE_SIZE*8-1:0]      wt_data_q [0:WT_DEPTH-1];

    // NWA forward declarations (driven below; declared here for strict
    // declaration-before-use simulators).
    logic         nwa_wt_room;       // registered WT-queue room (loop-safe)
    logic         nwa_inst_wt_valid; // install-time full-line WT request
    logic [63:0]  nwa_inst_wt_addr;
    logic [511:0] nwa_inst_wt_data;
    assign nwa_wt_room = (wt_count_q < WT_COUNT_BITS'(WT_DEPTH));

    // Find a MSHR entry with pending writeback
    logic [MSHR_IDX_BITS-1:0] wb_mshr_idx;
    logic                     wb_mshr_avail;

    always_comb begin
        wb_mshr_idx   = '0;
        wb_mshr_avail = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && mshr[m].writeback_pend && !wb_mshr_avail) begin
                wb_mshr_avail = 1'b1;
                wb_mshr_idx   = MSHR_IDX_BITS'(m);
            end
        end
    end

    // Find a MSHR entry ready to issue fill request
    logic [MSHR_IDX_BITS-1:0] fill_mshr_idx;
    logic                     fill_mshr_avail;

    always_comb begin
        fill_mshr_idx   = '0;
        fill_mshr_avail = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && mshr[m].fill_pend && !mshr[m].writeback_pend && !fill_mshr_avail) begin
                fill_mshr_avail = 1'b1;
                fill_mshr_idx   = MSHR_IDX_BITS'(m);
            end
        end
    end

    // Guarded fill selection for the L2_FILL_COMB_REQ_ENABLE comb-assert arm:
    // mask entries whose fill response is arriving THIS cycle.  fill_pend is
    // cleared by the registered response handler, so the raw selection above
    // still sees such an entry as pending this cycle; comb-issuing a fill for
    // it would launch a redundant request (the L2 can deliver write-miss
    // responses while this FSM sits in IDLE).  This also covers the just-
    // serviced l2_active_mshr_q entry: by the time the FSM is back in IDLE
    // its fill_pend flop has settled to 0, and in the response cycle itself
    // the address-match term masks it.  The mask is transient (one cycle),
    // so a masked-only situation simply holds IDLE until fill_pend settles —
    // no deadlock, no fallback arm needed.
    logic [MSHR_IDX_BITS-1:0] fill_mshr_idx_g;
    logic                     fill_mshr_avail_g;

    always_comb begin
        fill_mshr_idx_g   = '0;
        fill_mshr_avail_g = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr[m].valid && mshr[m].fill_pend && !mshr[m].writeback_pend &&
                !(l2_resp_valid &&
                  (l2_resp_addr[63:LINE_BITS] == mshr[m].addr[63:LINE_BITS])) &&
                !fill_mshr_avail_g) begin
                fill_mshr_avail_g = 1'b1;
                fill_mshr_idx_g   = MSHR_IDX_BITS'(m);
            end
        end
    end

    // L2 FSM combinational
    always_comb begin
        l2_state_d       = l2_state_q;
        l2_active_mshr_d = l2_active_mshr_q;
        l2_req_valid     = 1'b0;
        l2_req_addr      = '0;
        l2_req_we        = 1'b0;
        l2_req_wdata     = '0;

        case (l2_state_q)
            L2_IDLE: begin
                if (st_wt_deq_valid) begin
                    l2_req_valid = 1'b1;
                    l2_req_we    = 1'b1;
                    l2_req_addr  = wt_addr_q[wt_head_q];
                    l2_req_wdata = wt_data_q[wt_head_q];
                end else if (wb_mshr_avail) begin
                    l2_state_d       = L2_WRITEBACK;
                    l2_active_mshr_d = wb_mshr_idx;
                end else if (l2f_comb_en && fill_mshr_avail_g) begin
                    // L2_FILL_COMB_REQ_ENABLE: assert the fill request directly
                    // from IDLE (same loop-safe comb-assert idiom as the WT
                    // drain arm above), skipping the registered IDLE->FILL_REQ
                    // hop.  Accepted -> straight to FILL_WAIT; not accepted ->
                    // FILL_REQ holds the request as before.
                    l2_req_valid     = 1'b1;
                    l2_req_we        = 1'b0;
                    l2_req_addr      = mshr[fill_mshr_idx_g].addr;
                    l2_active_mshr_d = fill_mshr_idx_g;
                    l2_state_d       = l2_req_ready ? L2_FILL_WAIT : L2_FILL_REQ;
                end else if (!l2f_comb_en && fill_mshr_avail) begin
                    l2_state_d       = L2_FILL_REQ;
                    l2_active_mshr_d = fill_mshr_idx;
                end
            end

            L2_WRITEBACK: begin
                l2_req_valid = 1'b1;
                l2_req_we    = 1'b1;
                l2_req_addr  = mshr[l2_active_mshr_q].evict_addr;
                l2_req_wdata = mshr[l2_active_mshr_q].evict_data;
                if (l2_req_ready) begin
                    l2_state_d = L2_FILL_REQ;
                end
            end

            L2_FILL_REQ: begin
                l2_req_valid = 1'b1;
                l2_req_we    = 1'b0;
                l2_req_addr  = mshr[l2_active_mshr_q].addr;
                if (l2_req_ready) begin
                    l2_state_d = L2_FILL_WAIT;
                end
            end

            L2_FILL_WAIT: begin
                // Wait for fill response matching our address
                if (l2_resp_valid &&
                    (l2_resp_addr[63:LINE_BITS] == mshr[l2_active_mshr_q].addr[63:LINE_BITS])) begin
                    l2_state_d = L2_IDLE;
                end
            end

            default: l2_state_d = L2_IDLE;
        endcase
    end

    assign st_wt_deq_valid = (wt_count_q != '0);
    assign st_wt_deq_fire = (l2_state_q == L2_IDLE) &&
                             st_wt_deq_valid &&
                             l2_req_ready;
    assign wt_tail_prev = wt_tail_q - WT_IDX_BITS'(1);
    assign st_wt_merge_ready =
        (wt_count_q != '0) &&
        !(st_wt_deq_fire && (wt_count_q == WT_COUNT_BITS'(1))) &&
        (wt_addr_q[wt_tail_prev][63:LINE_BITS] ==
         st_wt_enq_addr[63:LINE_BITS]);
    assign st_wt_enq_ready = st_wt_merge_ready ||
                             (wt_count_q < WT_COUNT_BITS'(WT_DEPTH)) ||
                             st_wt_deq_fire;
    assign st_wt_merge_fire = st_wt_enq_valid && st_wt_merge_ready;
    assign st_wt_push_fire  = st_wt_enq_valid && !st_wt_merge_ready;
    assign st_wt_enq_full_line = nwa_inst_wt_valid || fill_done_store_merge;
    assign st_wt_deq_same_line =
        st_wt_deq_fire &&
        (wt_addr_q[wt_head_q][63:LINE_BITS] ==
         st_wt_enq_addr[63:LINE_BITS]);
    assign store_wt_busy = (wt_count_q != '0) || st_wt_enq_valid;

    // =========================================================================
    // Fill install: when a fill_done MSHR entry exists, install into cache
    // (one fill per cycle, arbitrated by lowest MSHR index)
    // =========================================================================
    logic [MSHR_IDX_BITS-1:0] fill_done_idx;
    logic                     fill_done_avail;

    always_comb begin
        fill_done_idx   = '0;
        fill_done_avail = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            // An ex-nwa fill that still owes its full-line write-through may
            // install only when there is WT-queue room (so the install-time WT
            // is never dropped); a normal fill installs unconditionally.
            if (mshr[m].valid && mshr[m].fill_done && !fill_done_avail &&
                (!mshr[m].nwa_wt_owed || nwa_wt_room)) begin
                fill_done_avail = 1'b1;
                fill_done_idx   = MSHR_IDX_BITS'(m);
            end
        end
    end

    // NWA write-validate: a deferred streaming-store MSHR whose overlay now
    // covers the whole line is ready to install clean (no fill).  Must wait for
    // any dirty-victim writeback to drain first (writeback_pend) AND for room in
    // the WT queue (the install enqueues one full-line write-through).  Lowest.
    //
    // MUST be suppressed whenever a fill install is selected this cycle
    // (fill_done_avail): the install mux gives fills priority, so a validate
    // asserting in the same cycle would lose the install port yet still free
    // its MSHR (line vanishes), steal the fill's install-time write-through
    // slot (the ex-nwa fill's folded stores then never reach L2 -> stale line
    // resurrected after a silent clean eviction), and corrupt the fill_snoop
    // mux.  All consumers key off this one signal, so the single guard keeps
    // install / WT / free / snoop / PLRU consistent.
    logic [MSHR_IDX_BITS-1:0] nwa_validate_idx;
    logic                     nwa_validate_avail;
    always_comb begin
        nwa_validate_idx   = '0;
        nwa_validate_avail = 1'b0;
        if (nwa_en && nwa_wt_room && !fill_done_avail) begin
            for (int m = 0; m < MSHR_DEPTH; m++) begin
                if (mshr[m].valid && mshr[m].nwa_pending &&
                    (&mshr[m].store_line_mask) && !mshr[m].writeback_pend &&
                    !nwa_validate_avail) begin
                    nwa_validate_avail = 1'b1;
                    nwa_validate_idx   = MSHR_IDX_BITS'(m);
                end
            end
        end
    end

    // NWA pressure-upgrade: when a new miss needs an MSHR slot but none is
    // free, convert the lowest partial nwa_pending entry back to a normal fill
    // (fetch the rest of the line, fold the overlay) so the pool always drains.
    logic [MSHR_IDX_BITS-1:0] nwa_upgrade_idx;
    logic                     nwa_upgrade_avail;
    always_comb begin
        nwa_upgrade_idx   = '0;
        nwa_upgrade_avail = 1'b0;
        if (nwa_en) begin
            for (int m = 0; m < MSHR_DEPTH; m++) begin
                if (mshr[m].valid && mshr[m].nwa_pending &&
                    !(&mshr[m].store_line_mask) && !nwa_upgrade_avail) begin
                    nwa_upgrade_avail = 1'b1;
                    nwa_upgrade_idx   = MSHR_IDX_BITS'(m);
                end
            end
        end
    end

    // =========================================================================
    // Store byte expansion: compute full-line mask and data from byte mask
    // =========================================================================
    always_comb begin
        st_full_mask = '0;
        st_full_data = '0;
        st_line_off  = s1_st_addr[5:0];
        for (int b = 0; b < 8; b++) begin
            st_line_byte[b] = int'(st_line_off) + b;
            if (s1_st_byte_mask[b]) begin
                if (st_line_byte[b] < LINE_SIZE) begin
                    st_full_mask[st_line_byte[b]] = 1'b1;
                    st_full_data[st_line_byte[b]*8 +: 8] = s1_st_data[b*8 +: 8];
                end
            end
        end
    end

    always_comb begin
        logic [LINE_SIZE*8-1:0] base_line;
        fill_done_line_data = '0;
        fill_done_store_merge = 1'b0;
        if (fill_done_avail) begin
            base_line = mshr[fill_done_idx].store_pending
                ? merge_store_overlay_into_line(
                      mshr[fill_done_idx].fill_data,
                      mshr[fill_done_idx].store_line_data,
                      mshr[fill_done_idx].store_line_mask
                  )
                : mshr[fill_done_idx].fill_data;

            // A store can be looking up the same line in the cycle a fill is
            // installed.  Fill install has RAM-write priority over store-hit,
            // so include those bytes in the installed line instead of acking
            // the store while dropping its data.
            fill_done_store_merge =
                s1_st_valid && !invalidate_all &&
                (st_line_addr[63:LINE_BITS] ==
                 mshr[fill_done_idx].addr[63:LINE_BITS]);

            fill_done_line_data = fill_done_store_merge
                ? merge_store_overlay_into_line(base_line,
                                                st_full_data,
                                                st_full_mask)
                : base_line;
        end
    end

    // NWA install-time write-through: streaming-store lines are NOT written
    // through per store (the cache is write-through but L2 takes only full
    // lines).  Instead one FULL-LINE write-through is enqueued when the line is
    // installed: from the overlay at write-validate, or from the merged fill
    // line when an ex-nwa entry was upgraded to a fill.  Highest WT priority.
    // (Signals forward-declared next to the WT queue.)
    always_comb begin
        nwa_inst_wt_valid = 1'b0;
        nwa_inst_wt_addr  = '0;
        nwa_inst_wt_data  = '0;
        if (nwa_validate_avail) begin
            nwa_inst_wt_valid = 1'b1;
            nwa_inst_wt_addr  = mshr[nwa_validate_idx].addr;
            nwa_inst_wt_data  = mshr[nwa_validate_idx].store_line_data;
        end else if (fill_done_avail && mshr[fill_done_idx].nwa_wt_owed) begin
            nwa_inst_wt_valid = 1'b1;
            nwa_inst_wt_addr  = mshr[fill_done_idx].addr;
            nwa_inst_wt_data  = fill_done_line_data;
        end
    end

    always_comb begin
        st_wt_line_data = st_cache_hit
                        ? merge_store_overlay_into_line(
                              st_data_way[st_hit_way],
                              st_full_data,
                              st_full_mask
                          )
                        : '0;
        st_wt_enq_addr  = nwa_inst_wt_valid
                        ? nwa_inst_wt_addr
                        : (fill_done_store_merge
                           ? mshr[fill_done_idx].addr
                           : st_line_addr);
        st_wt_enq_data  = nwa_inst_wt_valid
                        ? nwa_inst_wt_data
                        : (fill_done_store_merge
                           ? fill_done_line_data
                           : st_wt_line_data);
        st_wt_push_data = st_wt_enq_data;
        if (!st_wt_enq_full_line && st_wt_deq_same_line) begin
            st_wt_push_data =
                merge_store_overlay_into_line(wt_data_q[wt_head_q],
                                              st_full_data,
                                              st_full_mask);
        end
    end

    // =========================================================================
    // Tag / Data RAM write control
    // Priorities: fill_install > store_hit (dirty update)
    // =========================================================================
    always_comb begin
        // Tag RAM write
        tr_we          = 1'b0;
        tr_waddr       = '0;
        tr_wway        = '0;
        tr_wvalid      = 1'b0;
        tr_wdirty      = 1'b0;
        tr_wtag        = '0;
        tr_dirty_we    = 1'b0;
        tr_dirty_waddr = '0;
        tr_dirty_wway  = '0;

        // Data RAM write
        dr_we     = 1'b0;
        dr_waddr  = '0;
        dr_wway   = '0;
        dr_wdata  = '0;
        dr_bwe    = 1'b0;
        dr_bwaddr = '0;
        dr_bwway  = '0;
        dr_bwdata = '0;
        dr_bwmask = '0;

        if (fill_done_avail) begin
            // Install fill into cache as clean. Store bytes merged into a fill
            // are propagated through the write-through queue, so the L1D must
            // not later emit a second dirty-victim writeback for the same line.
            tr_we     = 1'b1;
            tr_waddr  = mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO];
            tr_wway   = mshr[fill_done_idx].victim;
            tr_wvalid = 1'b1;
            tr_wdirty = 1'b0;
            tr_wtag   = mshr[fill_done_idx].addr[TAG_HI:TAG_LO];

            dr_we     = 1'b1;
            dr_waddr  = mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO];
            dr_wway   = mshr[fill_done_idx].victim;
            dr_wdata  = fill_done_line_data;
        end else if (nwa_validate_avail) begin
            // NWA write-validate: the streaming line is fully defined by stores
            // (overlay mask all-ones).  Install it clean from the overlay (no
            // fill); the bytes already reached L2 via the write-through queue,
            // so the L1D copy is clean and no second dirty writeback is owed.
            tr_we     = 1'b1;
            tr_waddr  = mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO];
            tr_wway   = mshr[nwa_validate_idx].victim;
            tr_wvalid = 1'b1;
            tr_wdirty = 1'b0;
            tr_wtag   = mshr[nwa_validate_idx].addr[TAG_HI:TAG_LO];

            dr_we     = 1'b1;
            dr_waddr  = mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO];
            dr_wway   = mshr[nwa_validate_idx].victim;
            dr_wdata  = mshr[nwa_validate_idx].store_line_data;
        end else if (s1_st_valid && st_cache_hit) begin
            // Store hit: byte-enable write. The lower hierarchy is updated via
            // the write-through queue, so the L1D copy remains clean.
            dr_bwe    = 1'b1;
            dr_bwaddr = s1_st_index;
            dr_bwway  = st_hit_way;
            // Expand byte_mask / data to full-line granularity.
            //
            // s1_st_data is LSB-aligned to the store's effective address, so
            // its byte 0 contains the byte that must land at line offset
            // s1_st_addr[5:0].  s1_st_byte_mask[b]==1 means std_data[b*8 +: 8]
            // is valid.  The line byte position is addr[5:0] + b.
            dr_bwmask = st_full_mask;
            dr_bwdata = st_full_data;
        end
    end

    // =========================================================================
    // Store ACK
    // =========================================================================
    // Write-allocate store miss: if the store misses, allocate or merge an
    // MSHR for the line and HOLD the store in the CSB until the line is
    // resident or the fill install merges the current store.  A store miss
    // must never be acknowledged only because its MSHR was allocated, since a
    // later line fill can otherwise overwrite the store data.

    // (Declared here for strict declaration-before-use simulators; assigned
    // in the load-miss section below.)
    logic ld0_new_miss_req;
    logic ld1_new_miss_req;
    logic ld0_miss_alloc_sel;
    logic ld1_miss_alloc_sel;
    logic ld0_miss_merge_req;
    logic ld1_miss_merge_req;
    logic ld1_new_blocked_by_ld0_alloc;
    logic ld1_new_blocked_same_line;
    logic ld1_new_blocked_diff_line;
    logic ld_new_blocked_no_free;

    logic s1_st_can_allocate_mshr;
    assign s1_st_can_allocate_mshr = s1_st_valid && !st_cache_hit &&
                                     !mshr_st_match_hit && mshr_free_avail &&
                                     !invalidate_all &&
                                     !fill_done_avail;

    logic s1_st_waiting_for_fill;
    assign s1_st_waiting_for_fill = s1_st_valid && !st_cache_hit &&
                                    !invalidate_all;

    // NWA write-around: a streaming store miss is acknowledged immediately once
    // it is accepted into a deferred (no-fill) overlay MSHR — either by
    // allocating a fresh nwa entry or merging into an existing one — instead of
    // being held for a read-for-ownership fill.  Its bytes are captured in the
    // MSHR overlay and reach L2 as ONE full-line write-through at install time
    // (nwa_inst_wt), so this ack does NOT itself enqueue a write-through.
    // PTW stores are excluded: the walker reads PTEs through its own L2 port
    // (around the L1D), so a PTW store deferred into an overlay would be
    // invisible to it.  PTW stores take the legacy held-until-fill path.
    // The alloc arm must also verify the store actually WINS the single MSHR
    // alloc slot this cycle (the alloc else-if chain prioritizes load misses);
    // acking without capturing the store would lose it.
    logic nwa_store_accept;
    assign nwa_store_accept =
        nwa_en && s1_st_valid && !s1_st_is_ptw && !st_cache_hit &&
        !invalidate_all && !fill_done_avail &&
        ( (s1_st_can_allocate_mshr &&
           !ld0_miss_alloc_sel && !ld1_miss_alloc_sel) ||
          (mshr_st_match_hit && mshr[mshr_st_match_idx].nwa_pending &&
           !(&mshr[mshr_st_match_idx].store_line_mask)) );

    // A store HIT or a legacy fill-merge produces a per-store full-line
    // write-through (st_wt_enq below); an NWA write-around does not.
    logic store_produces_wt;
    assign store_produces_wt =
        s1_st_valid &&
        (fill_done_store_merge ||
         (!fill_done_avail && !nwa_validate_avail && !invalidate_all && st_cache_hit));

    // Completion is resolved in S1, one cycle after the CSB presents a store
    // on store_req_*.  Only acknowledge the CSB when its current head is still
    // the S1 store being completed; otherwise a completion for the previous
    // store can incorrectly dequeue the next store and drop it before D-cache
    // ever observes it.  A WT-producing store may ack only if it actually wins
    // the single WT enqueue port this cycle (the install-time WT preempts it).
    assign store_ack_s1 =
        (store_produces_wt && st_wt_enq_ready && !nwa_inst_wt_valid) ||
        nwa_store_accept;

    // WT enqueue: install-time full line (priority) or the store's full line.
    // ENABLE=0: nwa_inst_wt_valid=0 -> byte-identical to the legacy path.
    assign st_wt_enq_valid = nwa_inst_wt_valid || (store_produces_wt && st_wt_enq_ready);

    assign store_ack_matches_head =
        store_ack_s1 &&
        store_req_valid &&
        (store_req_addr == s1_st_addr) &&
        (store_req_data == s1_st_data) &&
        (store_req_byte_mask == s1_st_byte_mask);

    assign store_ack = store_ack_matches_head;

    assign ld0_new_miss_req = s1_ld0_valid && !ld0_cache_hit &&
                              !mshr_match_hit && !invalidate_all;
    assign ld1_new_miss_req = s1_ld1_valid && !ld1_cache_hit &&
                              !mshr_ld1_match_hit && !invalidate_all;
    assign ld0_miss_alloc_sel = ld0_new_miss_req && mshr_free_avail;
    assign ld1_miss_alloc_sel = !ld0_miss_alloc_sel && ld1_new_miss_req &&
                                mshr_free_avail;

    // D-prefetch fill alloc: lowest priority for the single MSHR alloc slot.
    // Only when the probed line is a clean resident-miss (no L1D hit, no
    // in-flight MSHR), a slot is free, the MSHR-reserve gate has demand headroom
    // (mshr_pf_room), AND no demand load/store wins the slot this cycle.
    // Drop-on-full / drop-on-demand-contention / MSHR-reserve is the census's
    // mandatory throttle (never displace demand).  NOTE: this protects the
    // low-MLP kernel/memcpy and the boot burst, but does NOT neutralize the
    // bandwidth-bound stream-l2 (+4%) -- its MSHRs drain in 8 cyc so occupancy
    // never trips the gate; an L2-channel-idle throttle was tried and REJECTED
    // (it destroyed memcpy timeliness -- memcpy is also L2-busy yet latency-
    // exposed).  A throughput/rate-aware throttle that distinguishes latency-
    // exposed memcpy from bandwidth-bound stream-l2 is the named follow-up.
    logic pf_new_fill_req;
    logic pf_fill_alloc_sel;
    assign pf_new_fill_req = dpf_en && s1_pf_valid && !pf_cache_hit &&
                             !mshr_pf_match_hit && !invalidate_all;
    assign pf_fill_alloc_sel = pf_new_fill_req && mshr_free_avail && mshr_pf_room &&
                               !ld0_miss_alloc_sel && !ld1_miss_alloc_sel &&
                               !s1_st_can_allocate_mshr;
    assign ld0_miss_merge_req = s1_ld0_valid && !ld0_cache_hit &&
                                mshr_match_hit && !invalidate_all;
    assign ld1_miss_merge_req = s1_ld1_valid && !ld1_cache_hit &&
                                mshr_ld1_match_hit && !invalidate_all;
    assign ld1_new_blocked_by_ld0_alloc = ld0_miss_alloc_sel &&
                                          ld1_new_miss_req;
    assign ld1_new_blocked_same_line = ld1_new_blocked_by_ld0_alloc &&
                                       (ld0_line_addr == ld1_line_addr);
    assign ld1_new_blocked_diff_line = ld1_new_blocked_by_ld0_alloc &&
                                       (ld0_line_addr != ld1_line_addr);
    assign ld_new_blocked_no_free = (ld0_new_miss_req || ld1_new_miss_req) &&
                                    !mshr_free_avail;

    // Notify the LSU when a load miss did not attach to a fill source this
    // cycle.  Port 1 can be retried by the LSU when port 0 consumes the only
    // miss allocation slot; same-line sharing is accepted because port 0's
    // fill will satisfy both LMB entries.
    assign load_miss_retry[0] = ld0_new_miss_req && !ld0_miss_alloc_sel;
    assign load_miss_retry[1] = ld1_new_miss_req &&
                                !ld1_miss_alloc_sel &&
                                !ld1_new_blocked_same_line;

`ifndef SYNTHESIS
    initial sim_perf_profile = $test$plusargs("PERF_PROFILE");

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_store_req_cyc        <= 0;
            sim_store_ack_cyc        <= 0;
            sim_store_hit_ack_cyc    <= 0;
            sim_store_fill_ack_cyc   <= 0;
            sim_store_wait_fill_cyc  <= 0;
            sim_store_port_wait_cyc  <= 0;
            sim_store_miss_alloc_cyc <= 0;
            sim_store_miss_merge_cyc <= 0;
            sim_store_port_grant_a_cyc <= 0;
            sim_store_port_grant_b_cyc <= 0;
            sim_ld_both_s1_cyc <= 0;
            sim_ld0_miss_new_cyc <= 0;
            sim_ld1_miss_new_cyc <= 0;
            sim_ld0_miss_alloc_cyc <= 0;
            sim_ld1_miss_alloc_cyc <= 0;
            sim_ld0_miss_merge_cyc <= 0;
            sim_ld1_miss_merge_cyc <= 0;
            sim_ld1_new_blocked_by_ld0_alloc_cyc <= 0;
            sim_ld1_new_blocked_same_line_cyc <= 0;
            sim_ld1_new_blocked_diff_line_cyc <= 0;
            sim_ld_new_blocked_no_free_cyc <= 0;
            sim_store_wt_enq_cyc <= 0;
            sim_store_wt_deq_cyc <= 0;
            sim_store_wt_full_cyc <= 0;
            sim_store_wt_occ_max <= 0;
        end else if (sim_perf_profile) begin
            if (store_req_valid)
                sim_store_req_cyc <= sim_store_req_cyc + 1;
            if (store_ack)
                sim_store_ack_cyc <= sim_store_ack_cyc + 1;
            if (store_ack && s1_st_valid && st_cache_hit)
                sim_store_hit_ack_cyc <= sim_store_hit_ack_cyc + 1;
            if (store_ack_s1 && fill_done_store_merge)
                sim_store_fill_ack_cyc <= sim_store_fill_ack_cyc + 1;
            if (store_req_valid && !store_ack && s1_st_waiting_for_fill)
                sim_store_wait_fill_cyc <= sim_store_wait_fill_cyc + 1;
            if (store_req_valid && !store_ack &&
                !s1_st_waiting_for_fill && !(store_ack_s1 && fill_done_store_merge) &&
                !s0_store_lookup_grant_a && !s0_store_lookup_grant_b)
                sim_store_port_wait_cyc <= sim_store_port_wait_cyc + 1;
            if (s1_st_can_allocate_mshr)
                sim_store_miss_alloc_cyc <= sim_store_miss_alloc_cyc + 1;
            if (s1_st_valid && !st_cache_hit && mshr_st_match_hit)
                sim_store_miss_merge_cyc <= sim_store_miss_merge_cyc + 1;
            if (s0_store_lookup_grant_a)
                sim_store_port_grant_a_cyc <= sim_store_port_grant_a_cyc + 1;
            if (s0_store_lookup_grant_b)
                sim_store_port_grant_b_cyc <= sim_store_port_grant_b_cyc + 1;
            if (s1_ld0_valid && s1_ld1_valid)
                sim_ld_both_s1_cyc <= sim_ld_both_s1_cyc + 1;
            if (ld0_new_miss_req)
                sim_ld0_miss_new_cyc <= sim_ld0_miss_new_cyc + 1;
            if (ld1_new_miss_req)
                sim_ld1_miss_new_cyc <= sim_ld1_miss_new_cyc + 1;
            if (ld0_miss_alloc_sel)
                sim_ld0_miss_alloc_cyc <= sim_ld0_miss_alloc_cyc + 1;
            if (ld1_miss_alloc_sel)
                sim_ld1_miss_alloc_cyc <= sim_ld1_miss_alloc_cyc + 1;
            if (ld0_miss_merge_req)
                sim_ld0_miss_merge_cyc <= sim_ld0_miss_merge_cyc + 1;
            if (ld1_miss_merge_req)
                sim_ld1_miss_merge_cyc <= sim_ld1_miss_merge_cyc + 1;
            if (ld1_new_blocked_by_ld0_alloc)
                sim_ld1_new_blocked_by_ld0_alloc_cyc <=
                    sim_ld1_new_blocked_by_ld0_alloc_cyc + 1;
            if (ld1_new_blocked_same_line)
                sim_ld1_new_blocked_same_line_cyc <=
                    sim_ld1_new_blocked_same_line_cyc + 1;
            if (ld1_new_blocked_diff_line)
                sim_ld1_new_blocked_diff_line_cyc <=
                    sim_ld1_new_blocked_diff_line_cyc + 1;
            if (ld_new_blocked_no_free)
                sim_ld_new_blocked_no_free_cyc <=
                    sim_ld_new_blocked_no_free_cyc + 1;
            if (st_wt_enq_valid)
                sim_store_wt_enq_cyc <= sim_store_wt_enq_cyc + 1;
            if (st_wt_deq_fire)
                sim_store_wt_deq_cyc <= sim_store_wt_deq_cyc + 1;
            if (!st_wt_enq_ready &&
                (fill_done_store_merge ||
                 (s1_st_valid && !fill_done_avail &&
                  !invalidate_all && st_cache_hit)))
                sim_store_wt_full_cyc <= sim_store_wt_full_cyc + 1;
            if (int'(wt_count_q) > sim_store_wt_occ_max)
                sim_store_wt_occ_max <= int'(wt_count_q);
        end
    end
`endif

    // =========================================================================
    // Fill snoop (for LSU load miss buffer)
    // =========================================================================
    // When a fill is installed this cycle, publish the line address and data
    // to the LSU so it can match it against any pending load misses.  Note
    // that the fill data travels one cycle AHEAD of the cache read-out path:
    // the LSU takes this snoop directly, without going through the cache
    // data RAM.
    // Also snoop NWA write-validate installs so a load/AMO that needs the
    // freshly installed streaming line wakes immediately (else it would miss
    // the fill_done wakeup and stall in the LSU load-miss buffer / AMO FSM).
    assign fill_snoop_valid = fill_done_avail || nwa_validate_avail;
    assign fill_snoop_addr  = fill_done_avail ? mshr[fill_done_idx].addr
                                              : mshr[nwa_validate_idx].addr;
    assign fill_snoop_data  = fill_done_avail ? fill_done_line_data
                                              : mshr[nwa_validate_idx].store_line_data;

    // =========================================================================
    // Load response outputs
    // =========================================================================
    // Tag/data RAMs are synchronous-read and their outputs are already aligned
    // with s1_ld*_valid.  Drive hit responses directly from S1 instead of
    // adding another register stage; LSU metadata uses its _r stage to match.
    always_comb begin
        load_resp_valid[0] = s1_ld0_valid && ld0_cache_hit;
        load_resp_valid[1] = s1_ld1_valid && ld1_cache_hit;
        load_resp_hit[0]   = load_resp_valid[0];
        load_resp_hit[1]   = load_resp_valid[1];
        load_resp_data[0]  = load_resp_valid[0] ? ld0_extracted : '0;
        load_resp_data[1]  = load_resp_valid[1] ? ld1_extracted : '0;
    end

    // =========================================================================
    // PLRU update (sequential)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < L1D_SETS; s++) begin
                plru_state[s] <= 3'd0;
            end
        end else if (invalidate_all) begin
            // No PLRU update during invalidation
        end else begin
            if (s1_ld0_valid && ld0_cache_hit) begin
                case (ld0_hit_way)
                    2'd0: plru_state[s1_ld0_index] <= {1'b1, 1'b1, plru_state[s1_ld0_index][0]};
                    2'd1: plru_state[s1_ld0_index] <= {1'b1, 1'b0, plru_state[s1_ld0_index][0]};
                    2'd2: plru_state[s1_ld0_index] <= {1'b0, plru_state[s1_ld0_index][1], 1'b1};
                    2'd3: plru_state[s1_ld0_index] <= {1'b0, plru_state[s1_ld0_index][1], 1'b0};
                    default: ;
                endcase
            end else if (fill_done_avail) begin
                case (mshr[fill_done_idx].victim)
                    2'd0: plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b1, plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]][0]};
                    2'd1: plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b0, plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]][0]};
                    2'd2: plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]][1], 1'b1};
                    2'd3: plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO]][1], 1'b0};
                    default: ;
                endcase
            // NWA write-validate install: mark the installed way MRU so the
            // freshly streamed line is not immediately re-victimized.
            end else if (nwa_validate_avail) begin
                case (mshr[nwa_validate_idx].victim)
                    2'd0: plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b1, plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]][0]};
                    2'd1: plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b1, 1'b0, plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]][0]};
                    2'd2: plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]][1], 1'b1};
                    2'd3: plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]] <= {1'b0, plru_state[mshr[nwa_validate_idx].addr[INDEX_HI:INDEX_LO]][1], 1'b0};
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // MSHR victim way helpers (combinational, referenced in always_ff below)
    // =========================================================================
    logic [1:0] mshr_ld_vway;
    logic       mshr_ld_dirty_v;
    logic [1:0] mshr_ld1_vway;
    logic       mshr_ld1_dirty_v;
    logic [1:0] mshr_st_vway;
    logic       mshr_st_dirty_v;

    always_comb begin
        mshr_ld_vway    = victim_way_s1;
        mshr_ld_dirty_v = tr_dirty_out[victim_way_s1];
        mshr_ld1_vway    = victim_way_ld1;
        mshr_ld1_dirty_v = tr_dirty_out2[victim_way_ld1];
        mshr_st_vway    = victim_way_st;
        mshr_st_dirty_v = st_dirty_way[victim_way_st];
    end

    // =========================================================================
    // MSHR sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_state_q       <= L2_IDLE;
            l2_active_mshr_q <= '0;
            wt_head_q        <= '0;
            wt_tail_q        <= '0;
            wt_count_q       <= '0;
            for (int w = 0; w < WT_DEPTH; w++) begin
                wt_addr_q[w] <= '0;
                wt_data_q[w] <= '0;
            end
            for (int m = 0; m < MSHR_DEPTH; m++) begin
                mshr[m] <= '0;
            end
        end else begin
            l2_state_q       <= l2_state_d;
            l2_active_mshr_q <= l2_active_mshr_d;

            if (st_wt_merge_fire) begin
                wt_data_q[wt_tail_prev] <=
                    st_wt_enq_full_line
                    ? st_wt_enq_data
                    : merge_store_overlay_into_line(wt_data_q[wt_tail_prev],
                                                    st_full_data,
                                                    st_full_mask);
            end else if (st_wt_push_fire) begin
                wt_addr_q[wt_tail_q] <= st_wt_enq_addr;
                wt_data_q[wt_tail_q] <= st_wt_push_data;
                wt_tail_q <= wt_tail_q + WT_IDX_BITS'(1);
            end
            if (st_wt_deq_fire) begin
                wt_head_q <= wt_head_q + WT_IDX_BITS'(1);
            end
            case ({st_wt_push_fire, st_wt_deq_fire})
                2'b10: wt_count_q <= wt_count_q + WT_COUNT_BITS'(1);
                2'b01: wt_count_q <= wt_count_q - WT_COUNT_BITS'(1);
                default: wt_count_q <= wt_count_q;
            endcase

            // ---- Allocate new MSHR on load miss ----
            if (ld0_miss_alloc_sel) begin
                mshr[mshr_free_idx].valid          <= 1'b1;
                mshr[mshr_free_idx].addr           <= ld0_line_addr;
                mshr[mshr_free_idx].victim         <= mshr_ld_vway;
                mshr[mshr_free_idx].dirty_evict    <= mshr_ld_dirty_v;
                mshr[mshr_free_idx].fill_pend      <= 1'b1;
                mshr[mshr_free_idx].fill_done      <= 1'b0;
                mshr[mshr_free_idx].store_pending  <= 1'b0;
                mshr[mshr_free_idx].store_byte_off <= 6'd0;
                mshr[mshr_free_idx].store_data     <= 64'd0;
                mshr[mshr_free_idx].store_byte_mask<= 8'd0;
                mshr[mshr_free_idx].store_line_data <= '0;
                mshr[mshr_free_idx].store_line_mask <= '0;
                mshr[mshr_free_idx].nwa_pending     <= 1'b0;
                mshr[mshr_free_idx].nwa_wt_owed     <= 1'b0;
                mshr[mshr_free_idx].writeback_pend <= mshr_ld_dirty_v;
                if (mshr_ld_dirty_v) begin
                    // Need to evict dirty line: save its address and data
                    // (pick the victim way's data from the RAM read-all)
                    mshr[mshr_free_idx].evict_data <= dr_rdata_all[mshr_ld_vway];
                    mshr[mshr_free_idx].evict_addr <=
                        {tr_tag_out[mshr_ld_vway], s1_ld0_index, {LINE_BITS{1'b0}}};
                end
            end
            // ---- Allocate new MSHR on load1 miss ----
            else if (ld1_miss_alloc_sel) begin
                mshr[mshr_free_idx].valid          <= 1'b1;
                mshr[mshr_free_idx].addr           <= ld1_line_addr;
                mshr[mshr_free_idx].victim         <= mshr_ld1_vway;
                mshr[mshr_free_idx].dirty_evict    <= mshr_ld1_dirty_v;
                mshr[mshr_free_idx].fill_pend      <= 1'b1;
                mshr[mshr_free_idx].fill_done      <= 1'b0;
                mshr[mshr_free_idx].store_pending  <= 1'b0;
                mshr[mshr_free_idx].store_byte_off <= 6'd0;
                mshr[mshr_free_idx].store_data     <= 64'd0;
                mshr[mshr_free_idx].store_byte_mask<= 8'd0;
                mshr[mshr_free_idx].store_line_data <= '0;
                mshr[mshr_free_idx].store_line_mask <= '0;
                mshr[mshr_free_idx].nwa_pending     <= 1'b0;
                mshr[mshr_free_idx].nwa_wt_owed     <= 1'b0;
                mshr[mshr_free_idx].writeback_pend <= mshr_ld1_dirty_v;
                if (mshr_ld1_dirty_v) begin
                    mshr[mshr_free_idx].evict_data <= dr_rdata_all2[mshr_ld1_vway];
                    mshr[mshr_free_idx].evict_addr <=
                        {tr_tag_out2[mshr_ld1_vway], s1_ld1_index, {LINE_BITS{1'b0}}};
                end
            end
            // ---- Allocate new MSHR on store miss (write-allocate) ----
            // Only if there is no load-miss MSHR allocation this cycle,
            // since we have a single allocation slot.  The tag RAM read
            // on the previous cycle used the store's address (port 0
            // priority selects store when no load is valid), so
            // tr_valid_out / tr_tag_out reflect the store's set.
            else if (s1_st_can_allocate_mshr) begin
                mshr[mshr_free_idx].valid          <= 1'b1;
                mshr[mshr_free_idx].addr           <= st_line_addr;
                mshr[mshr_free_idx].victim         <= mshr_st_vway;
                mshr[mshr_free_idx].dirty_evict    <= mshr_st_dirty_v;
                // NWA: defer the read-for-ownership fill for a streaming store
                // miss (install clean once the overlay covers the line).
                // PTW stores stay on the legacy fill path: the walker reads
                // PTEs around the L1D, so their write-through must not defer.
                mshr[mshr_free_idx].fill_pend      <= (nwa_en && !s1_st_is_ptw) ? 1'b0 : 1'b1;
                mshr[mshr_free_idx].nwa_pending     <= nwa_en && !s1_st_is_ptw;
                mshr[mshr_free_idx].nwa_wt_owed     <= nwa_en && !s1_st_is_ptw;
                mshr[mshr_free_idx].nwa_idle_cnt    <= 7'd0;
                mshr[mshr_free_idx].fill_done      <= 1'b0;
                mshr[mshr_free_idx].store_pending  <= 1'b1;
                mshr[mshr_free_idx].store_byte_off <= s1_st_addr[5:0];
                mshr[mshr_free_idx].store_data     <= s1_st_data;
                mshr[mshr_free_idx].store_byte_mask<= s1_st_byte_mask;
                mshr[mshr_free_idx].store_line_data <= st_full_data;
                mshr[mshr_free_idx].store_line_mask <= st_full_mask;
                mshr[mshr_free_idx].writeback_pend <= mshr_st_dirty_v;
                if (mshr_st_dirty_v) begin
                    mshr[mshr_free_idx].evict_data <= st_data_way[mshr_st_vway];
                    mshr[mshr_free_idx].evict_addr <=
                        {st_tag_way[mshr_st_vway], s1_st_index, {LINE_BITS{1'b0}}};
                end
            end
            // ---- Allocate new MSHR on D-prefetch (lowest priority) ----
            // A fill-only entry: read-for-ownership fill, NO store overlay, NO
            // load waiter.  The existing fill-response / fill-install path
            // brings the line into the L1D and frees the MSHR; no register
            // write occurs because no LMB/LQ entry references it.  Demand
            // strict-priority: pf_fill_alloc_sel is 0 whenever any load/store
            // wins the slot, so this never displaces demand.
            else if (pf_fill_alloc_sel) begin
                mshr[mshr_free_idx].valid          <= 1'b1;
                mshr[mshr_free_idx].addr           <= pf_line_addr;
                mshr[mshr_free_idx].victim         <= victim_way_pf;
                mshr[mshr_free_idx].dirty_evict    <= tr_dirty_out2[victim_way_pf];
                mshr[mshr_free_idx].fill_pend      <= 1'b1;
                mshr[mshr_free_idx].fill_done      <= 1'b0;
                mshr[mshr_free_idx].store_pending  <= 1'b0;
                mshr[mshr_free_idx].store_byte_off <= 6'd0;
                mshr[mshr_free_idx].store_data     <= 64'd0;
                mshr[mshr_free_idx].store_byte_mask<= 8'd0;
                mshr[mshr_free_idx].store_line_data <= '0;
                mshr[mshr_free_idx].store_line_mask <= '0;
                mshr[mshr_free_idx].nwa_pending     <= 1'b0;
                mshr[mshr_free_idx].nwa_wt_owed     <= 1'b0;
                mshr[mshr_free_idx].writeback_pend <= tr_dirty_out2[victim_way_pf];
                if (tr_dirty_out2[victim_way_pf]) begin
                    mshr[mshr_free_idx].evict_data <= dr_rdata_all2[victim_way_pf];
                    mshr[mshr_free_idx].evict_addr <=
                        {tr_tag_out2[victim_way_pf], s1_pf_index, {LINE_BITS{1'b0}}};
                end
            end

            // ---- Merge accepted store miss into an existing line fill ----
            // NWA: do NOT merge into an nwa entry whose overlay is already full
            // (it is about to write-validate-install); hold that store so it
            // retries and hits the freshly installed line next cycle.
            if (s1_st_valid && !st_cache_hit && mshr_st_match_hit &&
                !invalidate_all && !fill_done_avail &&
                !(nwa_en && mshr[mshr_st_match_idx].nwa_pending &&
                  (&mshr[mshr_st_match_idx].store_line_mask))) begin
                mshr[mshr_st_match_idx].store_pending <= 1'b1;
                mshr[mshr_st_match_idx].store_line_mask <=
                    mshr[mshr_st_match_idx].store_line_mask | st_full_mask;
                for (int b = 0; b < LINE_SIZE; b++) begin
                    if (st_full_mask[b]) begin
                        mshr[mshr_st_match_idx].store_line_data[b*8 +: 8] <=
                            st_full_data[b*8 +: 8];
                    end
                end
                // Keep legacy single-store fields coherent for trace/debug.
                mshr[mshr_st_match_idx].store_byte_off  <= s1_st_addr[5:0];
                mshr[mshr_st_match_idx].store_data      <= s1_st_data;
                mshr[mshr_st_match_idx].store_byte_mask <= s1_st_byte_mask;
            end

            // ---- NWA: write-validate install completes -> free the entry ----
            if (nwa_validate_avail) begin
                mshr[nwa_validate_idx].valid       <= 1'b0;
                mshr[nwa_validate_idx].nwa_pending <= 1'b0;
                mshr[nwa_validate_idx].nwa_wt_owed <= 1'b0;
            end

            // ---- NWA load-upgrade: a load that needs a not-yet-complete nwa
            //      line reverts that entry to a normal read-for-ownership fill.
            //      The fill folds the accumulated overlay (store_pending), so
            //      the load observes every prior store regardless of WT drain.
            if (nwa_en && ld0_miss_merge_req &&
                mshr[mshr_match_idx].nwa_pending &&
                !(&mshr[mshr_match_idx].store_line_mask)) begin
                mshr[mshr_match_idx].fill_pend   <= 1'b1;
                mshr[mshr_match_idx].nwa_pending <= 1'b0;
            end
            if (nwa_en && ld1_miss_merge_req &&
                mshr[mshr_ld1_match_idx].nwa_pending &&
                !(&mshr[mshr_ld1_match_idx].store_line_mask)) begin
                mshr[mshr_ld1_match_idx].fill_pend   <= 1'b1;
                mshr[mshr_ld1_match_idx].nwa_pending <= 1'b0;
            end

            // ---- NWA pressure-upgrade: when a new miss cannot allocate an MSHR
            //      (pool exhausted), convert a partial nwa entry to a fill so
            //      the pool always drains (forward-progress guarantee).
            if (nwa_en && nwa_upgrade_avail && !mshr_free_avail &&
                (ld0_new_miss_req || ld1_new_miss_req ||
                 (s1_st_valid && !st_cache_hit && !mshr_st_match_hit &&
                  !invalidate_all))) begin
                mshr[nwa_upgrade_idx].fill_pend   <= 1'b1;
                mshr[nwa_upgrade_idx].nwa_pending <= 1'b0;
            end

            // ---- NWA PTW-store upgrade: a held PTW store whose line sits in
            //      a deferred nwa entry upgrades it to a fill (the fill folds
            //      the overlay, fill_done_store_merge then acks the PTW store
            //      with legacy semantics, and the install-WT makes the line
            //      visible to the walker's L2-side reads).
            if (nwa_en && s1_st_valid && s1_st_is_ptw && !st_cache_hit &&
                mshr_st_match_hit && !invalidate_all &&
                mshr[mshr_st_match_idx].nwa_pending) begin
                mshr[mshr_st_match_idx].fill_pend   <= 1'b1;
                mshr[mshr_st_match_idx].nwa_pending <= 1'b0;
            end

            // ---- NWA idle-timeout upgrade: bound how long a deferred line's
            //      bytes can stay invisible to L2 (the PTW reads PTEs around
            //      the L1D; kernel page-table stores are sparse partial-line
            //      writes whose mask never completes).  Streaming lines fill
            //      their mask in ~8-16 cycles, far below the threshold, so
            //      this never fires for them.  One upgrade per cycle.
            begin : nwa_idle_sweep
                logic nwa_idle_upgraded;
                nwa_idle_upgraded = 1'b0;
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (nwa_en && mshr[m].valid && mshr[m].nwa_pending) begin
                        if (mshr[m].nwa_idle_cnt >= 7'd64 && !nwa_idle_upgraded) begin
                            mshr[m].fill_pend   <= 1'b1;
                            mshr[m].nwa_pending <= 1'b0;
                            nwa_idle_upgraded   = 1'b1;
                        end else begin
                            mshr[m].nwa_idle_cnt <= mshr[m].nwa_idle_cnt + 7'd1;
                        end
                    end
                end
            end

            // ---- Fill response: capture data, mark fill_done ----
            if (l2_resp_valid) begin
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (mshr[m].valid && mshr[m].fill_pend &&
                        (l2_resp_addr[63:LINE_BITS] == mshr[m].addr[63:LINE_BITS])) begin
                        // If a store merges into this MSHR in the same cycle
                        // as the fill response, the nonblocking update to the
                        // overlay is not visible yet.  Fold the current store
                        // bytes into the captured fill data explicitly.
                        if (s1_st_valid && !st_cache_hit && mshr_st_match_hit &&
                            (mshr_st_match_idx == MSHR_IDX_BITS'(m)) &&
                            !invalidate_all) begin
                            mshr[m].fill_data <=
                                merge_store_overlay_into_line(
                                    merge_store_overlay_into_line(
                                        l2_resp_data,
                                        mshr[m].store_line_data,
                                        mshr[m].store_line_mask
                                    ),
                                    st_full_data,
                                    st_full_mask
                                );
                        end else begin
                            mshr[m].fill_data <= mshr[m].store_pending
                                ? merge_store_overlay_into_line(
                                      l2_resp_data,
                                      mshr[m].store_line_data,
                                      mshr[m].store_line_mask
                                  )
                                : l2_resp_data;
                        end
                        mshr[m].fill_pend  <= 1'b0;
                        mshr[m].fill_done  <= 1'b1;
                    end
                end
            end

            // ---- Writeback accepted ----
            if (l2_state_q == L2_WRITEBACK && l2_req_ready) begin
                mshr[l2_active_mshr_q].writeback_pend <= 1'b0;
            end

            // ---- Fill install: clear fill_done, free MSHR ----
            if (fill_done_avail) begin
                mshr[fill_done_idx].fill_done <= 1'b0;
                mshr[fill_done_idx].valid     <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Invalidate busy: single-cycle assertion (tag RAM clears valid bits in 1 cycle)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            invalidate_busy <= 1'b0;
        else
            invalidate_busy <= invalidate_all;
    end

`ifndef SYNTHESIS
    final begin
        if (sim_perf_profile) begin
            $display("D-cache store summary:");
            $display("  req / ack cycles           : %0d / %0d",
                     sim_store_req_cyc, sim_store_ack_cyc);
            $display("  hit_ack / fill_ack         : %0d / %0d",
                     sim_store_hit_ack_cyc, sim_store_fill_ack_cyc);
            $display("  wait_fill / port_wait      : %0d / %0d",
                     sim_store_wait_fill_cyc, sim_store_port_wait_cyc);
            $display("  miss_alloc / miss_merge    : %0d / %0d",
                     sim_store_miss_alloc_cyc, sim_store_miss_merge_cyc);
            $display("  grant_a / grant_b          : %0d / %0d",
                     sim_store_port_grant_a_cyc, sim_store_port_grant_b_cyc);
            $display("  wt_enq / wt_deq / wt_full  : %0d / %0d / %0d",
                     sim_store_wt_enq_cyc, sim_store_wt_deq_cyc,
                     sim_store_wt_full_cyc);
            $display("  wt_occ_max                 : %0d",
                     sim_store_wt_occ_max);
            $display("D-cache load miss allocation summary:");
            $display("  both_loads_s1              : %0d", sim_ld_both_s1_cyc);
            $display("  ld0 new/alloc/merge        : %0d / %0d / %0d",
                     sim_ld0_miss_new_cyc, sim_ld0_miss_alloc_cyc,
                     sim_ld0_miss_merge_cyc);
            $display("  ld1 new/alloc/merge        : %0d / %0d / %0d",
                     sim_ld1_miss_new_cyc, sim_ld1_miss_alloc_cyc,
                     sim_ld1_miss_merge_cyc);
            $display("  ld1 blocked by ld0 alloc   : %0d",
                     sim_ld1_new_blocked_by_ld0_alloc_cyc);
            $display("    same_line / diff_line    : %0d / %0d",
                     sim_ld1_new_blocked_same_line_cyc,
                     sim_ld1_new_blocked_diff_line_cyc);
            $display("  new load miss no free MSHR : %0d",
                     sim_ld_new_blocked_no_free_cyc);
        end
    end
`endif

endmodule
