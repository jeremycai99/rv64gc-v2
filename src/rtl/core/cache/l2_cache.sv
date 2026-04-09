/* file: l2_cache.sv
 * Description: 2 MB, 8-way set-associative L2 Cache.
 *              4096 sets, 64-byte cache lines, PLRU replacement.
 *              32 MSHRs for outstanding misses to main memory.
 *              8-cycle hit latency (shift-register pipeline).
 *              Arbitrates between D-cache and I-cache fill requests
 *              (D-cache has priority).  Dirty-line writeback before fill.
 *              FENCE.I: flush all dirty lines to memory, then invalidate.
 * Version: 2.0
 */
module l2_cache
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // D-cache port (fill requests and writebacks)
    input  logic        dcache_req_valid,
    input  logic [63:0] dcache_req_addr,
    input  logic        dcache_req_we,        // 1=writeback from D$, 0=fill request
    input  logic [511:0] dcache_req_wdata,    // writeback data
    output logic        dcache_req_ready,     // can accept request
    output logic        dcache_resp_valid,
    output logic [63:0] dcache_resp_addr,
    output logic [511:0] dcache_resp_data,

    // I-cache port (fill requests only — I$ is read-only)
    input  logic        icache_req_valid,
    input  logic [63:0] icache_req_addr,
    output logic        icache_req_ready,
    output logic        icache_resp_valid,
    output logic [63:0] icache_resp_addr,
    output logic [511:0] icache_resp_data,

    // Main memory interface (sim_memory / external)
    output logic        mem_req_valid,
    output logic [63:0] mem_req_addr,
    output logic        mem_req_we,
    output logic [511:0] mem_req_wdata,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [511:0] mem_resp_data,

    // Invalidate (FENCE.I — flush dirty lines, invalidate all)
    input  logic        invalidate_all,
    output logic        invalidate_busy
);

    // =========================================================================
    // Address field positions
    //   [5:0]   = byte offset  (LINE_BITS  = 6)
    //   [17:6]  = set index    (L2_SET_BITS = 12)
    //   [63:18] = tag          (L2_TAG_BITS = 46)
    // =========================================================================
    localparam int OFFSET_HI  = LINE_BITS - 1;                  // 5
    localparam int INDEX_LO   = LINE_BITS;                       // 6
    localparam int INDEX_HI   = LINE_BITS + L2_SET_BITS - 1;    // 17
    localparam int TAG_LO     = LINE_BITS + L2_SET_BITS;         // 18
    localparam int TAG_HI     = 63;

    // =========================================================================
    // Tag + dirty + valid arrays
    //   Implemented as flat arrays (no separate sub-module for initial bringup)
    // =========================================================================
    logic [L2_TAG_BITS-1:0] tag_ram  [0:L2_SETS-1][0:L2_WAYS-1];
    logic                   valid_ram[0:L2_SETS-1][0:L2_WAYS-1];
    logic                   dirty_ram[0:L2_SETS-1][0:L2_WAYS-1];

    // Data SRAM (unpacked by set then way)
    logic [511:0]           data_ram [0:L2_SETS-1][0:L2_WAYS-1];

    // PLRU state: one bit per way-1 per set (7 bits for 8-way)
    logic [L2_WAYS-2:0]     plru_state[0:L2_SETS-1];

    // =========================================================================
    // MSHR definitions
    // =========================================================================
    typedef enum logic [1:0] {
        MSHR_IDLE     = 2'd0,
        MSHR_PENDING  = 2'd1,   // waiting to issue mem request
        MSHR_WAIT_MEM = 2'd2    // mem request issued, waiting for response
    } mshr_state_e;

    typedef struct packed {
        logic           valid;
        logic [63:0]    addr;
        logic           is_dcache;   // 1 = D-cache source, 0 = I-cache source
        mshr_state_e    state;
    } mshr_entry_t;

    mshr_entry_t mshr [0:L2_MSHR_DEPTH-1];

    // =========================================================================
    // Hit-latency pipeline (8 stages)
    //   Each stage carries: valid, addr, data, is_dcache flag
    // =========================================================================
    typedef struct packed {
        logic           valid;
        logic [63:0]    addr;
        logic [511:0]   data;
        logic           is_dcache;
    } pipe_entry_t;

    pipe_entry_t hit_pipe [0:L2_HIT_LATENCY-1];

    // =========================================================================
    // Invalidate (FENCE.I) state machine
    // =========================================================================
    typedef enum logic [1:0] {
        INV_IDLE      = 2'd0,
        INV_FLUSH     = 2'd1,   // write back dirty lines
        INV_INVAL     = 2'd2,   // clear valid bits
        INV_WAIT_MEM  = 2'd3    // waiting for mem ack on a dirty writeback
    } inv_state_e;

    inv_state_e             inv_state;
    logic [L2_SET_BITS-1:0] inv_set;
    logic [2:0]             inv_way;  // 3 bits for 8 ways
    logic [63:0]            inv_wb_addr;
    logic [511:0]           inv_wb_data;
    logic                   inv_wb_pending;

    // =========================================================================
    // Internal signals
    // =========================================================================

    // Arbitrated request
    logic           arb_valid;
    logic [63:0]    arb_addr;
    logic           arb_we;
    logic [511:0]   arb_wdata;
    logic           arb_is_dcache;

    // Tag-lookup results (combinational)
    logic [L2_SET_BITS-1:0] lookup_set;
    logic [L2_TAG_BITS-1:0] lookup_tag;
    logic                   hit_any;
    logic [2:0]             hit_way;
    logic [511:0]           hit_data;

    // MSHR full / address-match checks
    logic mshr_full;
    logic mshr_addr_match;   // same address already tracked

    // Free MSHR slot
    logic [4:0]  mshr_free_idx;
    logic        mshr_has_free;

    // MSHR to issue to memory
    logic [4:0]  mshr_issue_idx;
    logic        mshr_has_issue;

    // Memory response routing
    logic [4:0]  mshr_resp_idx;
    logic        mshr_resp_found;

    // PLRU helpers
    logic [2:0] plru_victim;

    // Eviction / fill helpers
    logic need_evict;         // victim is dirty, must write back first
    logic [2:0] victim_way;

    // =========================================================================
    // PLRU tree: standard binary tree for 8-way (7 bits)
    //   Bit [0]     : left=0..3 vs right=4..7
    //   Bit [1]     : left=0..1 vs right=2..3
    //   Bit [2]     : left=4..5 vs right=6..7
    //   Bit [3]     : way 0 vs 1
    //   Bit [4]     : way 2 vs 3
    //   Bit [5]     : way 4 vs 5
    //   Bit [6]     : way 6 vs 7
    // Victim is the LRU leaf.
    // =========================================================================
    function automatic logic [2:0] plru_get_victim(input logic [6:0] state);
        logic top, mid_l, mid_r, bot;
        logic [2:0] v;
        top   = state[0];
        if (!top) begin
            mid_l = state[1];
            if (!mid_l) begin
                bot = state[3];
                v = bot ? 3'd1 : 3'd0;
            end else begin
                bot = state[4];
                v = bot ? 3'd3 : 3'd2;
            end
        end else begin
            mid_r = state[2];
            if (!mid_r) begin
                bot = state[5];
                v = bot ? 3'd5 : 3'd4;
            end else begin
                bot = state[6];
                v = bot ? 3'd7 : 3'd6;
            end
        end
        return v;
    endfunction

    function automatic logic [6:0] plru_update(
        input logic [6:0] state,
        input logic [2:0] way
    );
        logic [6:0] ns;
        ns = state;
        // Update root: point away from used half
        ns[0] = ~way[2];
        // Update mid level
        if (!way[2]) begin
            ns[1] = ~way[1];
            // Update leaf level for left half
            if (!way[1])
                ns[3] = ~way[0];
            else
                ns[4] = ~way[0];
        end else begin
            ns[2] = ~way[1];
            // Update leaf level for right half
            if (!way[1])
                ns[5] = ~way[0];
            else
                ns[6] = ~way[0];
        end
        return ns;
    endfunction

    // =========================================================================
    // Combinational: address decode
    // =========================================================================
    assign lookup_set = arb_addr[INDEX_HI:INDEX_LO];
    assign lookup_tag = arb_addr[TAG_HI:TAG_LO];

    // =========================================================================
    // Combinational: hit detection
    // =========================================================================
    always_comb begin
        hit_any  = 1'b0;
        hit_way  = 3'd0;
        hit_data = '0;
        for (int w = 0; w < L2_WAYS; w++) begin
            if (valid_ram[lookup_set][w] &&
                (tag_ram[lookup_set][w] == lookup_tag)) begin
                hit_any  = 1'b1;
                hit_way  = 3'(w);
                hit_data = data_ram[lookup_set][w];
            end
        end
    end

    // =========================================================================
    // Combinational: PLRU victim for this set
    // =========================================================================
    always_comb begin
        plru_victim = plru_get_victim(plru_state[lookup_set]);
        victim_way  = plru_victim;
        need_evict  = valid_ram[lookup_set][victim_way] &&
                      dirty_ram[lookup_set][victim_way];
    end

    // =========================================================================
    // Combinational: MSHR free/full/match
    // =========================================================================
    always_comb begin
        mshr_full       = 1'b1;
        mshr_has_free   = 1'b0;
        mshr_free_idx   = 5'd0;
        mshr_addr_match = 1'b0;
        for (int i = 0; i < L2_MSHR_DEPTH; i++) begin
            if (!mshr[i].valid) begin
                if (!mshr_has_free) begin
                    mshr_has_free = 1'b1;
                    mshr_free_idx = 5'(i);
                end
                mshr_full = 1'b0;
            end else begin
                // Check if same cache-line address already outstanding
                if (mshr[i].addr[63:LINE_BITS] == arb_addr[63:LINE_BITS])
                    mshr_addr_match = 1'b1;
            end
        end
    end

    // =========================================================================
    // Combinational: pick an MSHR to issue to memory (PENDING -> WAIT_MEM)
    // =========================================================================
    always_comb begin
        mshr_has_issue  = 1'b0;
        mshr_issue_idx  = 5'd0;
        for (int i = 0; i < L2_MSHR_DEPTH; i++) begin
            if (mshr[i].valid && (mshr[i].state == MSHR_PENDING) &&
                !mshr_has_issue) begin
                mshr_has_issue = 1'b1;
                mshr_issue_idx = 5'(i);
            end
        end
    end

    // =========================================================================
    // Combinational: match memory response to MSHR entry
    // =========================================================================
    always_comb begin
        mshr_resp_found = 1'b0;
        mshr_resp_idx   = 5'd0;
        for (int i = 0; i < L2_MSHR_DEPTH; i++) begin
            if (mshr[i].valid && (mshr[i].state == MSHR_WAIT_MEM) &&
                !mshr_resp_found) begin
                mshr_resp_found = 1'b1;
                mshr_resp_idx   = 5'(i);
            end
        end
    end

    // =========================================================================
    // Arbitration: D-cache has priority, but blocked when invalidation running
    // =========================================================================
    always_comb begin
        arb_valid     = 1'b0;
        arb_addr      = '0;
        arb_we        = 1'b0;
        arb_wdata     = '0;
        arb_is_dcache = 1'b0;

        if (inv_state == INV_IDLE) begin
            if (dcache_req_valid) begin
                arb_valid     = 1'b1;
                arb_addr      = dcache_req_addr;
                arb_we        = dcache_req_we;
                arb_wdata     = dcache_req_wdata;
                arb_is_dcache = 1'b1;
            end else if (icache_req_valid) begin
                arb_valid     = 1'b1;
                arb_addr      = icache_req_addr;
                arb_we        = 1'b0;
                arb_wdata     = '0;
                arb_is_dcache = 1'b0;
            end
        end
    end

    // =========================================================================
    // Ready signals: accept when not full / no duplicate / not invalidating
    // =========================================================================
    always_comb begin
        dcache_req_ready = (inv_state == INV_IDLE) && !mshr_full;
        icache_req_ready = (inv_state == INV_IDLE) && !mshr_full &&
                           !dcache_req_valid;
    end

    // =========================================================================
    // Invalidate busy
    // =========================================================================
    assign invalidate_busy = (inv_state != INV_IDLE);

    // =========================================================================
    // Hit pipeline shift register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < L2_HIT_LATENCY; s++) begin
                hit_pipe[s].valid     <= 1'b0;
                hit_pipe[s].addr      <= '0;
                hit_pipe[s].data      <= '0;
                hit_pipe[s].is_dcache <= 1'b0;
            end
        end else begin
            // Stage 0: insert a hit on a fill request (read hit)
            // A write (writeback from D$) goes directly to data_ram — no resp needed
            hit_pipe[0].valid     <= arb_valid && hit_any && !arb_we;
            hit_pipe[0].addr      <= arb_addr;
            hit_pipe[0].data      <= hit_data;
            hit_pipe[0].is_dcache <= arb_is_dcache;
            // Stages 1..7: propagate
            for (int s = 1; s < L2_HIT_LATENCY; s++) begin
                hit_pipe[s] <= hit_pipe[s-1];
            end
        end
    end

    // =========================================================================
    // Hit response outputs (end of 8-stage pipe)
    // =========================================================================
    assign dcache_resp_valid = hit_pipe[L2_HIT_LATENCY-1].valid &&
                               hit_pipe[L2_HIT_LATENCY-1].is_dcache;
    assign dcache_resp_addr  = hit_pipe[L2_HIT_LATENCY-1].addr;
    assign dcache_resp_data  = hit_pipe[L2_HIT_LATENCY-1].data;

    assign icache_resp_valid = hit_pipe[L2_HIT_LATENCY-1].valid &&
                               !hit_pipe[L2_HIT_LATENCY-1].is_dcache;
    assign icache_resp_addr  = hit_pipe[L2_HIT_LATENCY-1].addr;
    assign icache_resp_data  = hit_pipe[L2_HIT_LATENCY-1].data;

    // =========================================================================
    // Memory request mux: MSHR issue vs invalidation writeback
    // =========================================================================
    always_comb begin
        mem_req_valid  = 1'b0;
        mem_req_addr   = '0;
        mem_req_we     = 1'b0;
        mem_req_wdata  = '0;

        if (inv_wb_pending) begin
            // Invalidation-triggered dirty writeback
            mem_req_valid = 1'b1;
            mem_req_addr  = inv_wb_addr;
            mem_req_we    = 1'b1;
            mem_req_wdata = inv_wb_data;
        end else if (mshr_has_issue) begin
            // MSHR fill or writeback request
            mem_req_valid = 1'b1;
            mem_req_addr  = mshr[mshr_issue_idx].addr;
            mem_req_we    = 1'b0;   // MSHRs only track fill (read) requests
            mem_req_wdata = '0;
        end
    end

    // =========================================================================
    // Main sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear all valid/dirty bits; leave data don't-care
            for (int s = 0; s < L2_SETS; s++) begin
                for (int w = 0; w < L2_WAYS; w++) begin
                    valid_ram[s][w] <= 1'b0;
                    dirty_ram[s][w] <= 1'b0;
                    tag_ram[s][w]   <= '0;
                end
                plru_state[s] <= '0;
            end
            // Clear MSHRs
            for (int i = 0; i < L2_MSHR_DEPTH; i++) begin
                mshr[i].valid     <= 1'b0;
                mshr[i].addr      <= '0;
                mshr[i].is_dcache <= 1'b0;
                mshr[i].state     <= MSHR_IDLE;
            end
            inv_state      <= INV_IDLE;
            inv_set        <= '0;
            inv_way        <= 3'd0;
            inv_wb_addr    <= '0;
            inv_wb_data    <= '0;
            inv_wb_pending <= 1'b0;
        end else begin

            // ------------------------------------------------------------------
            // 1. Handle incoming arbitrated request
            // ------------------------------------------------------------------
            if (arb_valid) begin
                if (hit_any) begin
                    // ---- HIT ----
                    if (arb_we) begin
                        // D-cache writeback: update data and mark dirty
                        data_ram[lookup_set][hit_way] <= arb_wdata;
                        dirty_ram[lookup_set][hit_way] <= 1'b1;
                    end
                    // Update PLRU on every access
                    plru_state[lookup_set] <=
                        plru_update(plru_state[lookup_set], hit_way);
                end else begin
                    // ---- MISS ----
                    // Only allocate MSHR for fill requests (not writebacks)
                    // For writebacks on a miss: just allocate as a write-through
                    // (write directly to MSHR-less path; handle inline)
                    if (!mshr_addr_match) begin
                        if (arb_we) begin
                            // D-cache dirty writeback, line not in L2:
                            // allocate a victim, evict if dirty, install wb data
                            if (!need_evict) begin
                                data_ram[lookup_set][victim_way]  <= arb_wdata;
                                tag_ram[lookup_set][victim_way]   <= lookup_tag;
                                valid_ram[lookup_set][victim_way] <= 1'b1;
                                dirty_ram[lookup_set][victim_way] <= 1'b1;
                                plru_state[lookup_set] <=
                                    plru_update(plru_state[lookup_set], victim_way);
                            end
                            // If need_evict: writeback handling below via
                            // eviction path (simplified: skip for bringup,
                            // the MSHR path covers read misses).
                        end else begin
                            // Fill request miss: allocate MSHR
                            if (mshr_has_free) begin
                                mshr[mshr_free_idx].valid     <= 1'b1;
                                mshr[mshr_free_idx].addr      <= arb_addr;
                                mshr[mshr_free_idx].is_dcache <= arb_is_dcache;
                                mshr[mshr_free_idx].state     <= MSHR_PENDING;
                            end
                        end
                    end
                end
            end

            // ------------------------------------------------------------------
            // 2. Advance MSHR: issue pending request to memory
            // ------------------------------------------------------------------
            if (mshr_has_issue && mem_req_ready && !inv_wb_pending) begin
                mshr[mshr_issue_idx].state <= MSHR_WAIT_MEM;
            end

            // ------------------------------------------------------------------
            // 3. Handle memory response: fill L2, send resp via MSHR pipe
            //    (response is returned immediately, not through hit_pipe)
            // ------------------------------------------------------------------
            if (mem_resp_valid && mshr_resp_found && !inv_wb_pending) begin
                // Determine set/tag from MSHR address
                begin
                    logic [L2_SET_BITS-1:0] fill_set;
                    logic [L2_TAG_BITS-1:0] fill_tag;
                    logic [2:0]             fill_victim;
                    logic [6:0]             fill_plru_ns;

                    fill_set    = mshr[mshr_resp_idx].addr[INDEX_HI:INDEX_LO];
                    fill_tag    = mshr[mshr_resp_idx].addr[TAG_HI:TAG_LO];
                    fill_victim = plru_get_victim(plru_state[fill_set]);

                    // Writeback dirty victim before installing fill data
                    // (simplified: queue writeback only if dirty — for
                    //  bringup we mark it clean and overwrite; a full impl
                    //  would use a write buffer)
                    if (valid_ram[fill_set][fill_victim] &&
                        dirty_ram[fill_set][fill_victim]) begin
                        // Flush victim to memory via inv_wb path (reuse)
                        inv_wb_addr    <= {tag_ram[fill_set][fill_victim],
                                           fill_set,
                                           {LINE_BITS{1'b0}}};
                        inv_wb_data    <= data_ram[fill_set][fill_victim];
                        inv_wb_pending <= 1'b1;
                        // Invalidate the victim slot now so re-fill can proceed
                        valid_ram[fill_set][fill_victim] <= 1'b0;
                        dirty_ram[fill_set][fill_victim] <= 1'b0;
                    end

                    // Install fill data
                    data_ram[fill_set][fill_victim]  <= mem_resp_data;
                    tag_ram[fill_set][fill_victim]   <= fill_tag;
                    valid_ram[fill_set][fill_victim] <= 1'b1;
                    dirty_ram[fill_set][fill_victim] <= 1'b0;

                    fill_plru_ns = plru_update(plru_state[fill_set], fill_victim);
                    plru_state[fill_set] <= fill_plru_ns;

                    // Deliver response through a single-cycle bypass
                    // (insert directly into the last pipe stage so it arrives
                    //  next cycle — simplification for bringup)
                    hit_pipe[L2_HIT_LATENCY-1].valid     <= 1'b1;
                    hit_pipe[L2_HIT_LATENCY-1].addr      <= mshr[mshr_resp_idx].addr;
                    hit_pipe[L2_HIT_LATENCY-1].data      <= mem_resp_data;
                    hit_pipe[L2_HIT_LATENCY-1].is_dcache <= mshr[mshr_resp_idx].is_dcache;

                    // Deallocate MSHR
                    mshr[mshr_resp_idx].valid <= 1'b0;
                    mshr[mshr_resp_idx].state <= MSHR_IDLE;
                end
            end

            // ------------------------------------------------------------------
            // 4. Clear inv_wb_pending when memory accepts the writeback
            // ------------------------------------------------------------------
            if (inv_wb_pending && mem_req_ready) begin
                inv_wb_pending <= 1'b0;
            end

            // ------------------------------------------------------------------
            // 5. FENCE.I invalidation state machine
            // ------------------------------------------------------------------
            case (inv_state)
                INV_IDLE: begin
                    if (invalidate_all) begin
                        inv_state <= INV_FLUSH;
                        inv_set   <= '0;
                        inv_way   <= 3'd0;
                    end
                end

                INV_FLUSH: begin
                    // Walk all sets and ways, write back dirty lines
                    if (dirty_ram[inv_set][inv_way] &&
                        valid_ram[inv_set][inv_way]) begin
                        // Queue a writeback
                        inv_wb_addr    <= {tag_ram[inv_set][inv_way],
                                           inv_set,
                                           {LINE_BITS{1'b0}}};
                        inv_wb_data    <= data_ram[inv_set][inv_way];
                        inv_wb_pending <= 1'b1;
                        dirty_ram[inv_set][inv_way] <= 1'b0;
                        inv_state <= INV_WAIT_MEM;
                    end else begin
                        // Advance to next way/set
                        if (inv_way == 3'(L2_WAYS - 1)) begin
                            inv_way <= 3'd0;
                            if (inv_set == L2_SET_BITS'(L2_SETS - 1)) begin
                                inv_set   <= '0;
                                inv_state <= INV_INVAL;
                            end else begin
                                inv_set <= inv_set + 1'b1;
                            end
                        end else begin
                            inv_way <= inv_way + 1'b1;
                        end
                    end
                end

                INV_WAIT_MEM: begin
                    // Wait for the pending writeback to be accepted
                    if (!inv_wb_pending) begin
                        // Resume flush scan
                        if (inv_way == 3'(L2_WAYS - 1)) begin
                            inv_way <= 3'd0;
                            if (inv_set == L2_SET_BITS'(L2_SETS - 1)) begin
                                inv_set   <= '0;
                                inv_state <= INV_INVAL;
                            end else begin
                                inv_set   <= inv_set + 1'b1;
                                inv_state <= INV_FLUSH;
                            end
                        end else begin
                            inv_way   <= inv_way + 1'b1;
                            inv_state <= INV_FLUSH;
                        end
                    end
                end

                INV_INVAL: begin
                    // Clear all valid bits in one sweep
                    for (int s = 0; s < L2_SETS; s++) begin
                        for (int w = 0; w < L2_WAYS; w++) begin
                            valid_ram[s][w] <= 1'b0;
                            dirty_ram[s][w] <= 1'b0;
                        end
                    end
                    inv_state <= INV_IDLE;
                end

                default: inv_state <= INV_IDLE;
            endcase

        end // else rst_n
    end // always_ff

endmodule
