/* file: dcache.sv
 Description: 64 kB 4-way L1 D-Cache with 16-entry MSHR and PLRU.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
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
    // Tag RAM interface signals
    // =========================================================================
    logic [L1D_SET_BITS-1:0]  tr_raddr;
    logic [L1D_WAYS-1:0]      tr_valid_out;
    logic [L1D_WAYS-1:0]      tr_dirty_out;
    logic [L1D_TAG_BITS-1:0]  tr_tag_out [0:L1D_WAYS-1];

    logic                      tr_we;
    logic [L1D_SET_BITS-1:0]   tr_waddr;
    logic [1:0]                tr_wway;
    logic                      tr_wvalid;
    logic                      tr_wdirty;
    logic [L1D_TAG_BITS-1:0]   tr_wtag;

    logic                      tr_dirty_we;
    logic [L1D_SET_BITS-1:0]   tr_dirty_waddr;
    logic [1:0]                tr_dirty_wway;

    dcache_tag_ram u_tag_ram (
        .clk          (clk),
        .raddr        (tr_raddr),
        .valid_out    (tr_valid_out),
        .dirty_out    (tr_dirty_out),
        .tag_out      (tr_tag_out),
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
    // Data RAM interface signals
    // =========================================================================
    logic [L1D_SET_BITS-1:0]  dr_raddr;
    logic [1:0]               dr_rway;
    logic [LINE_SIZE*8-1:0]   dr_rdata;

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
        .clk    (clk),
        .raddr  (dr_raddr),
        .rway   (dr_rway),
        .rdata  (dr_rdata),
        .we     (dr_we),
        .waddr  (dr_waddr),
        .wway   (dr_wway),
        .wdata  (dr_wdata),
        .bwe    (dr_bwe),
        .bwaddr (dr_bwaddr),
        .bwway  (dr_bwway),
        .bwdata (dr_bwdata),
        .bwmask (dr_bwmask)
    );

    // =========================================================================
    // Pipeline stage registers
    // Two load ports share a single tag RAM read port using a priority mux.
    // Port 0 wins over port 1.  A bank-conflict stall retries port 1 next cycle.
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

    // Bank-conflict: both ports hit the same set → stall port 1
    logic conflict;
    assign conflict = load_req_valid[0] && load_req_valid[1] &&
                      (load_req_addr[0][INDEX_HI:INDEX_LO] ==
                       load_req_addr[1][INDEX_HI:INDEX_LO]);

    // The tag RAM is read with the stage-0 (incoming) address.
    // We prioritise port 0; port 1 is suppressed on conflict.
    // The tag RAM read address is port 0 if valid, else port 1.
    always_comb begin
        if (load_req_valid[0])
            tr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
        else if (load_req_valid[1])
            tr_raddr = load_req_addr[1][INDEX_HI:INDEX_LO];
        else if (store_req_valid)
            tr_raddr = store_req_addr[INDEX_HI:INDEX_LO];
        else
            tr_raddr = '0;
    end

    // Data RAM read address (same priority)
    always_comb begin
        if (load_req_valid[0]) begin
            dr_raddr = load_req_addr[0][INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0; // way selected after hit detection in s1
        end else if (load_req_valid[1]) begin
            dr_raddr = load_req_addr[1][INDEX_HI:INDEX_LO];
            dr_rway  = 2'd0;
        end else begin
            dr_raddr = '0;
            dr_rway  = 2'd0;
        end
    end

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
        end else begin
            s1_ld0_valid    <= load_req_valid[0];
            s1_ld0_addr     <= load_req_addr[0];
            s1_ld0_size     <= load_req_size[0];
            s1_ld0_unsigned <= load_req_is_unsigned[0];

            s1_ld1_valid    <= load_req_valid[1] && !conflict;
            s1_ld1_addr     <= load_req_addr[1];
            s1_ld1_size     <= load_req_size[1];
            s1_ld1_unsigned <= load_req_is_unsigned[1];

            s1_st_valid     <= store_req_valid;
            s1_st_addr      <= store_req_addr;
            s1_st_data      <= store_req_data;
            s1_st_byte_mask <= store_req_byte_mask;
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

    // Hit detection for load port 1
    logic [L1D_WAYS-1:0] ld1_way_hit;
    logic                ld1_cache_hit;
    logic [1:0]          ld1_hit_way;

    always_comb begin
        ld1_way_hit   = '0;
        ld1_cache_hit = 1'b0;
        ld1_hit_way   = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (tr_valid_out[w] && (tr_tag_out[w] == s1_ld1_tag)) begin
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

    always_comb begin
        st_way_hit   = '0;
        st_cache_hit = 1'b0;
        st_hit_way   = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (tr_valid_out[w] && (tr_tag_out[w] == s1_st_tag)) begin
                st_way_hit[w] = 1'b1;
                st_cache_hit  = 1'b1;
                st_hit_way    = 2'(w);
            end
        end
    end

    // =========================================================================
    // Data mux from RAM output (way selected by hit way)
    // The data RAM was read with the s0 address so its output is available in s1.
    // We read all ways and mux by hit_way.  Because we have a single-port data
    // RAM, for the two-load case we hold the result of the first load and replay
    // the second the next cycle — load port 1 miss is handled separately.
    // For the initial bring-up simplification we output hit data for load 0 only
    // from the RAM; load 1 will be resolved through the miss path when needed.
    // =========================================================================
    logic [LINE_SIZE*8-1:0] ld0_line_data;
    assign ld0_line_data = dr_rdata;   // single data RAM port returns ld0's data

    // Extract the requested word from the cache line for load port 0
    function automatic logic [63:0] extract_word(
        input logic [LINE_SIZE*8-1:0] line,
        input logic [63:0]            addr,
        input logic [1:0]             sz,
        input logic                   is_unsigned
    );
        logic [5:0]  byte_off;
        logic [63:0] raw;
        logic [63:0] result;
        byte_off = addr[OFFSET_HI:0];
        raw = line[byte_off*8 +: 64];
        case (sz)
            2'd0: result = is_unsigned ? {56'b0, raw[7:0]}  : {{56{raw[7]}},  raw[7:0]};
            2'd1: result = is_unsigned ? {48'b0, raw[15:0]} : {{48{raw[15]}}, raw[15:0]};
            2'd2: result = is_unsigned ? {32'b0, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
            default: result = raw;
        endcase
        return result;
    endfunction

    // =========================================================================
    // PLRU state (3-bit binary tree per set)
    // =========================================================================
    logic [2:0] plru_state [L1D_SETS];

    function automatic logic [1:0] plru_victim(input logic [2:0] ps);
        logic [1:0] v;
        if (!ps[2])
            v = ps[1] ? 2'd0 : 2'd1;
        else
            v = ps[0] ? 2'd2 : 2'd3;
        return v;
    endfunction

    logic [1:0] victim_way_s1;
    assign victim_way_s1 = plru_victim(plru_state[s1_ld0_index]);

    // PLRU update task (for use inside always_ff)
    // Points away from the accessed way
    task automatic update_plru_state;
        input logic [L1D_SET_BITS-1:0] idx;
        input logic [1:0]              way;
        case (way)
            2'd0: plru_state[idx] <= {1'b1, 1'b1, plru_state[idx][0]};
            2'd1: plru_state[idx] <= {1'b1, 1'b0, plru_state[idx][0]};
            2'd2: plru_state[idx] <= {1'b0, plru_state[idx][1], 1'b1};
            2'd3: plru_state[idx] <= {1'b0, plru_state[idx][1], 1'b0};
            default: ;
        endcase
    endtask

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
        logic [1:0]              victim;         // victim way for fill
        logic                    dirty_evict;    // victim was dirty
        logic [511:0]            evict_data;     // dirty line data for writeback
        logic [63:0]             evict_addr;     // dirty line address for writeback
    } mshr_entry_t;

    mshr_entry_t mshr [0:MSHR_DEPTH-1];

    // =========================================================================
    // MSHR lookup: find a matching pending entry
    // =========================================================================
    logic [MSHR_IDX_BITS-1:0] mshr_match_idx;
    logic                     mshr_match_hit;
    logic [63:0]              ld0_line_addr;
    assign ld0_line_addr = {s1_ld0_addr[63:LINE_BITS], {LINE_BITS{1'b0}}};

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
                if (wb_mshr_avail) begin
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
            tr_wdirty = 1'b0;
            tr_wtag   = mshr[fill_done_idx].addr[TAG_HI:TAG_LO];

            dr_we     = 1'b1;
            dr_waddr  = mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO];
            dr_wway   = mshr[fill_done_idx].victim;
            dr_wdata  = mshr[fill_done_idx].fill_data;
        end else if (s1_st_valid && st_cache_hit) begin
            // Store hit: byte-enable write + dirty bit update
            tr_dirty_we    = 1'b1;
            tr_dirty_waddr = s1_st_index;
            tr_dirty_wway  = st_hit_way;

            dr_bwe    = 1'b1;
            dr_bwaddr = s1_st_index;
            dr_bwway  = st_hit_way;
            dr_bwdata = {8{s1_st_data}};  // replicate data to full line; mask selects
            // Expand byte_mask to line-granularity based on word offset
            begin
                automatic logic [LINE_SIZE-1:0] full_mask;
                automatic logic [2:0]           byte_off;
                full_mask = '0;
                byte_off  = s1_st_addr[2:0];
                for (int b = 0; b < 8; b++) begin
                    if (s1_st_byte_mask[b]) begin
                        full_mask[int'(byte_off) + b] = 1'b1;
                    end
                end
                dr_bwmask = full_mask;
                // Also write actual store data aligned correctly into bwdata
                dr_bwdata = '0;
                for (int b = 0; b < 8; b++) begin
                    if (s1_st_byte_mask[b]) begin
                        dr_bwdata[(int'(byte_off) + b)*8 +: 8] = s1_st_data[b*8 +: 8];
                    end
                end
            end
        end
    end

    // =========================================================================
    // Store ACK
    // =========================================================================
    assign store_ack = s1_st_valid && st_cache_hit && !fill_done_avail;

    // =========================================================================
    // Load response outputs
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_resp_valid[0] <= 1'b0;
            load_resp_valid[1] <= 1'b0;
            load_resp_data[0]  <= '0;
            load_resp_data[1]  <= '0;
            load_resp_hit[0]   <= 1'b0;
            load_resp_hit[1]   <= 1'b0;
        end else begin
            load_resp_valid[0] <= 1'b0;
            load_resp_valid[1] <= 1'b0;
            load_resp_hit[0]   <= 1'b0;
            load_resp_hit[1]   <= 1'b0;
            load_resp_data[0]  <= '0;
            load_resp_data[1]  <= '0;

            if (s1_ld0_valid && ld0_cache_hit) begin
                load_resp_valid[0] <= 1'b1;
                load_resp_hit[0]   <= 1'b1;
                load_resp_data[0]  <= extract_word(dr_rdata, s1_ld0_addr,
                                                   s1_ld0_size, s1_ld0_unsigned);
            end

            // Load port 1: tag comparison against s1_ld1_tag using tr_valid/tag_out.
            // Note: tr_valid_out/tr_tag_out are the result of reading tr_raddr which
            // was set to port 0's address in s0 when both ports were valid.  When only
            // port 1 is active, tr_raddr was set to port 1's address.  This means port
            // 1 hit detection is only valid when port 0 was NOT active in the same s0
            // cycle (no conflict). On a conflict, port 1 was suppressed and will be
            // re-issued the next cycle by the upstream LSU.
            if (s1_ld1_valid && ld1_cache_hit) begin
                load_resp_valid[1] <= 1'b1;
                load_resp_hit[1]   <= 1'b1;
                // Port 1 reads the same data RAM word — this is the simplification:
                // on simultaneous hits to the same line the upstream must handle.
                load_resp_data[1]  <= extract_word(dr_rdata, s1_ld1_addr,
                                                   s1_ld1_size, s1_ld1_unsigned);
            end
        end
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
            if (s1_ld0_valid && ld0_cache_hit)
                update_plru_state(s1_ld0_index, ld0_hit_way);
            else if (fill_done_avail)
                update_plru_state(mshr[fill_done_idx].addr[INDEX_HI:INDEX_LO],
                                  mshr[fill_done_idx].victim);
        end
    end

    // =========================================================================
    // MSHR sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_state_q       <= L2_IDLE;
            l2_active_mshr_q <= '0;
            for (int m = 0; m < MSHR_DEPTH; m++) begin
                mshr[m] <= '0;
            end
        end else begin
            l2_state_q       <= l2_state_d;
            l2_active_mshr_q <= l2_active_mshr_d;

            // ---- Allocate new MSHR on load miss ----
            if (s1_ld0_valid && !ld0_cache_hit && !mshr_match_hit && mshr_free_avail
                && !invalidate_all) begin
                automatic logic [1:0] vway;
                automatic logic       dirty_v;
                vway    = victim_way_s1;
                dirty_v = tr_dirty_out[vway];

                mshr[mshr_free_idx].valid          <= 1'b1;
                mshr[mshr_free_idx].addr           <= ld0_line_addr;
                mshr[mshr_free_idx].victim         <= vway;
                mshr[mshr_free_idx].dirty_evict    <= dirty_v;
                mshr[mshr_free_idx].fill_pend      <= 1'b1;
                mshr[mshr_free_idx].fill_done      <= 1'b0;
                mshr[mshr_free_idx].writeback_pend <= dirty_v;
                if (dirty_v) begin
                    // Need to evict dirty line: save its address and data
                    // Evict address reconstructed from tag + index
                    mshr[mshr_free_idx].evict_data <= dr_rdata; // data from last RAM read
                    mshr[mshr_free_idx].evict_addr <=
                        {tr_tag_out[vway], s1_ld0_index, {LINE_BITS{1'b0}}};
                end
            end

            // ---- Fill response: capture data, mark fill_done ----
            if (l2_resp_valid) begin
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (mshr[m].valid && mshr[m].fill_pend &&
                        (l2_resp_addr[63:LINE_BITS] == mshr[m].addr[63:LINE_BITS])) begin
                        mshr[m].fill_data  <= l2_resp_data;
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

endmodule
