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
    input  logic        clk,
    input  logic        rst_n,
    // Load ports (2)
    input  logic [1:0]  load_req_valid,
    input  logic [63:0] load_req_addr [0:1],
    input  logic [1:0]  load_req_size [0:1],
    input  logic [1:0]  load_req_is_unsigned,
    output logic [1:0]  load_resp_valid,
    output logic [63:0] load_resp_data [0:1],
    output logic [1:0]  load_resp_hit,
    output logic [1:0]  load_miss_retry,
    // Store port (1, from CSB)
    input  logic        store_req_valid,
    input  logic [63:0] store_req_addr,
    input  logic [63:0] store_req_data,
    input  logic [7:0]  store_req_byte_mask,
    output logic        store_ack,
    // L2 interface (miss handling)
    output logic        l2_req_valid,
    output logic [63:0] l2_req_addr,
    output logic        l2_req_we,           // 1=writeback, 0=fill
    output logic [511:0] l2_req_wdata,       // writeback data
    input  logic        l2_req_ready,
    input  logic        l2_resp_valid,
    input  logic [63:0] l2_resp_addr,
    input  logic [511:0] l2_resp_data,
    // Fill snoop (to LSU for missed-load late response)
    // Fires the cycle a fill is installed into the cache.  The LSU uses
    // this to wake up any pending loads in its miss buffer.
    output logic        fill_snoop_valid,
    output logic [63:0] fill_snoop_addr,
    output logic [511:0] fill_snoop_data,
    // Store write-through drain state, used to hold FENCE.I until older
    // committed stores are instruction-visible in the backing hierarchy.
    output logic        store_wt_busy,
    // Invalidate
    input  logic        invalidate_all,
    output logic        invalidate_busy
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
    logic                    s1_st_use_port_b;
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
    assign s0_store_lookup_grant_a = store_req_valid && !load_req_valid[0];
    assign s0_store_lookup_grant_b = store_req_valid && load_req_valid[0]
                                   && !load_req_valid[1];

    // Tag RAM port A: load port 0 (priority), then store
    always_comb begin
        if (load_req_valid[0])
            tr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
        else if (s0_store_lookup_grant_a)
            tr_raddr = store_req_addr[INDEX_HI:INDEX_LO];
        else
            tr_raddr = '0;
    end

    // Tag RAM port B: load port 1, or store when load1 is idle.
    assign tr_raddr2 = load_req_valid[1] ? load_req_addr[1][INDEX_HI:INDEX_LO]
                                         : (s0_store_lookup_grant_b
                                            ? store_req_addr[INDEX_HI:INDEX_LO]
                                            : '0);

    // Data RAM port A: load port 0, or store when load0 is idle.
    always_comb begin
        if (load_req_valid[0]) begin
            dr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0;
        end else if (s0_store_lookup_grant_a) begin
            dr_raddr = store_req_addr[INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0;
        end else begin
            dr_raddr = '0;
            dr_rway  = 2'd0;
        end
    end

    // Data RAM port B: load port 1, or store when load1 is idle.
    assign dr_raddr2 = load_req_valid[1] ? load_req_addr[1][INDEX_HI:INDEX_LO]
                                         : (s0_store_lookup_grant_b
                                            ? store_req_addr[INDEX_HI:INDEX_LO]
                                            : '0);

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
            s1_st_use_port_b <= 1'b0;
        end else begin
            s1_ld0_valid    <= load_req_valid[0];
            s1_ld0_addr     <= load_req_addr[0];
            s1_ld0_size     <= load_req_size[0];
            s1_ld0_unsigned <= load_req_is_unsigned[0];

            // No conflict suppression — port B handles port 1 independently
            s1_ld1_valid    <= load_req_valid[1];
            s1_ld1_addr     <= load_req_addr[1];
            s1_ld1_size     <= load_req_size[1];
            s1_ld1_unsigned <= load_req_is_unsigned[1];

            // store_ack_s1 is generated from the previous cycle's S1 store
            // lookup.  When it acknowledges the current CSB head, the CSB
            // will advance on this edge; do not re-latch that same store into
            // S1 or the next cycle could perform a duplicate write while the
            // CSB is already presenting the following store.
            s1_st_valid     <= (s0_store_lookup_grant_a || s0_store_lookup_grant_b) &&
                               !store_ack_matches_head;
            s1_st_addr      <= store_req_addr;
            s1_st_data      <= store_req_data;
            s1_st_byte_mask <= store_req_byte_mask;
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

    // Find a free MSHR slot
    logic [MSHR_IDX_BITS-1:0] mshr_free_idx;
    logic                     mshr_free_avail;

    always_comb begin
        mshr_free_idx   = '0;
        mshr_free_avail = 1'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (!mshr[m].valid && !mshr_free_avail) begin
                mshr_free_avail = 1'b1;
                mshr_free_idx   = MSHR_IDX_BITS'(m);
            end
        end
    end

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

    localparam int WT_DEPTH      = 4;
    localparam int WT_IDX_BITS   = $clog2(WT_DEPTH);
    localparam int WT_COUNT_BITS = $clog2(WT_DEPTH + 1);

    logic [WT_IDX_BITS-1:0]      wt_tail_prev;
    logic [WT_IDX_BITS-1:0]      wt_head_q;
    logic [WT_IDX_BITS-1:0]      wt_tail_q;
    logic [WT_COUNT_BITS-1:0]    wt_count_q;
    logic [63:0]                 wt_addr_q [0:WT_DEPTH-1];
    logic [LINE_SIZE*8-1:0]      wt_data_q [0:WT_DEPTH-1];

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
                end else if (fill_mshr_avail) begin
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
            if (mshr[m].valid && mshr[m].fill_done && !fill_done_avail) begin
                fill_done_avail = 1'b1;
                fill_done_idx   = MSHR_IDX_BITS'(m);
            end
        end
    end

    // =========================================================================
    // Store byte expansion: compute full-line mask and data from byte mask
    // =========================================================================
    logic [LINE_SIZE-1:0]   st_full_mask;
    logic [LINE_SIZE*8-1:0] st_full_data;
    logic [5:0]             st_line_off;
    int                     st_line_byte [0:7];
    logic [LINE_SIZE*8-1:0] fill_done_line_data;
    logic                   fill_done_store_merge;

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

    always_comb begin
        st_wt_line_data = st_cache_hit
                        ? merge_store_overlay_into_line(
                              st_data_way[st_hit_way],
                              st_full_data,
                              st_full_mask
                          )
                        : '0;
        st_wt_enq_addr  = fill_done_store_merge
                        ? mshr[fill_done_idx].addr
                        : st_line_addr;
        st_wt_enq_data  = fill_done_store_merge
                        ? fill_done_line_data
                        : st_wt_line_data;
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
            // Install fill into cache (clean, tag update)
            tr_we     = 1'b1;
            tr_waddr  = mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO];
            tr_wway   = mshr[fill_done_idx].victim;
            tr_wvalid = 1'b1;
            tr_wdirty = mshr[fill_done_idx].store_pending;
            tr_wtag   = mshr[fill_done_idx].addr[TAG_HI:TAG_LO];

            dr_we     = 1'b1;
            dr_waddr  = mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO];
            dr_wway   = mshr[fill_done_idx].victim;
            dr_wdata  = fill_done_line_data;
        end else if (s1_st_valid && st_cache_hit) begin
            // Store hit: byte-enable write + dirty bit update
            tr_dirty_we    = 1'b1;
            tr_dirty_waddr = s1_st_index;
            tr_dirty_wway  = st_hit_way;

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

    logic s1_st_can_allocate_mshr;
    assign s1_st_can_allocate_mshr = s1_st_valid && !st_cache_hit &&
                                     !mshr_st_match_hit && mshr_free_avail &&
                                     !invalidate_all &&
                                     !fill_done_avail;

    logic s1_st_waiting_for_fill;
    assign s1_st_waiting_for_fill = s1_st_valid && !st_cache_hit &&
                                    !invalidate_all;

    // Completion is resolved in S1, one cycle after the CSB presents a store
    // on store_req_*.  Only acknowledge the CSB when its current head is still
    // the S1 store being completed; otherwise a completion for the previous
    // store can incorrectly dequeue the next store and drop it before D-cache
    // ever observes it.
    assign store_ack_s1 =
        s1_st_valid &&
        (fill_done_store_merge ||
         (!fill_done_avail && !invalidate_all && st_cache_hit)) &&
        st_wt_enq_ready;
    assign st_wt_enq_valid = store_ack_s1;

    assign store_ack_matches_head =
        store_ack_s1 &&
        store_req_valid &&
        (store_req_addr == s1_st_addr) &&
        (store_req_data == s1_st_data) &&
        (store_req_byte_mask == s1_st_byte_mask);

    assign store_ack = store_ack_matches_head;

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

    assign ld0_new_miss_req = s1_ld0_valid && !ld0_cache_hit &&
                              !mshr_match_hit && !invalidate_all;
    assign ld1_new_miss_req = s1_ld1_valid && !ld1_cache_hit &&
                              !mshr_ld1_match_hit && !invalidate_all;
    assign ld0_miss_alloc_sel = ld0_new_miss_req && mshr_free_avail;
    assign ld1_miss_alloc_sel = !ld0_miss_alloc_sel && ld1_new_miss_req &&
                                mshr_free_avail;
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
    assign fill_snoop_valid = fill_done_avail;
    assign fill_snoop_addr  = mshr[fill_done_idx].addr;
    assign fill_snoop_data  = fill_done_line_data;

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
                wt_data_q[wt_tail_prev] <= st_wt_enq_data;
            end else if (st_wt_push_fire) begin
                wt_addr_q[wt_tail_q] <= st_wt_enq_addr;
                wt_data_q[wt_tail_q] <= st_wt_enq_data;
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
                mshr[mshr_free_idx].fill_pend      <= 1'b1;
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

            // ---- Merge accepted store miss into an existing line fill ----
            if (s1_st_valid && !st_cache_hit && mshr_st_match_hit &&
                !invalidate_all && !fill_done_avail) begin
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
