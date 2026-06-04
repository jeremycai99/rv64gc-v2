/* file: ifu_line_fetch.sv
 Description: IFU line request adapter for I-cache and next-line prefetch data.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ifu_line_fetch
    import rv64gc_pkg::*;
    import uarch_pkg::*;
#(
    parameter int ICQ_DEPTH = 4,
    parameter int ICQ_COUNT_BITS = $clog2(ICQ_DEPTH + 1)
)
(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          flush_i,
    input  wire                          redirect_scrub_i,
    input  wire                          fence_i,

    input  wire                          req_valid_i,
    input  wire [63:0]                   req_addr_i,
    input  wire [63:0]                   aux_lookup_addr_i,
    input  wire                          instr_vm_active_i,
    input  wire                          itlb_hit_i,
    input  wire [63:0]                   itlb_pa_i,
    input  wire                          itlb_fault_i,
    input  wire                          itlb_fill_seen_i,    // PTW filled the ITLB (replay trigger)
    output reg                          itlb_lookup_valid_o,
    output reg [63:0]                   itlb_lookup_va_o,
    output reg                          itlb_miss_valid_o,
    output reg [63:0]                   itlb_miss_va_o,
    output reg                          instr_translation_stall_o,
    output reg                          replay_req_valid_o,  // F1: refetch a translation-missed VA after fill
    output reg [63:0]                   replay_req_pc_o,
    input  wire                          f1_valid_i,
    input  wire                          stall_i,
    input  wire                          work_valid_i,
    input  wire                          work_line_valid_i,
    input  wire [63:LINE_BITS]           work_line_addr_i,
    input  wire [FTQ_EPOCH_BITS-1:0]     current_epoch_i,
    input  wire                          ftq_wb_owner_valid_i,
    input  wire [FTQ_IDX_BITS-1:0]       ftq_wb_owner_idx_i,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] ftq_wb_owner_tag_i,
    input  wire                          ftq_next_owner_valid_i,
    input  wire [FTQ_IDX_BITS-1:0]       ftq_next_owner_idx_i,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] ftq_next_owner_tag_i,

    input  wire                          req_owner_valid_i,
    input  wire [FTQ_IDX_BITS-1:0]       req_owner_idx_i,
    input  wire [FTQ_EPOCH_BITS-1:0]     req_owner_epoch_i,
    input  wire [FTQ_ALLOC_TAG_BITS-1:0] req_owner_alloc_tag_i,
    input  ftq_entry_t                    req_owner_entry_i,

    output reg                          icq_deq_valid_o,
    output reg [511:0]                  icq_deq_data_o,
    output reg                          icq_deq_hit_o,
    output reg [63:0]                   icq_deq_pc_o,
    output reg [63:LINE_BITS]           icq_deq_line_addr_o,
    output reg                          icq_deq_ftq_valid_o,
    output reg [FTQ_IDX_BITS-1:0]       icq_deq_ftq_idx_o,
    output reg [FTQ_EPOCH_BITS-1:0]     icq_deq_ftq_epoch_o,
    output reg [FTQ_ALLOC_TAG_BITS-1:0] icq_deq_ftq_alloc_tag_o,
    output ftq_entry_t                    icq_deq_ftq_entry_o,
    output reg                          icq_deq_owner_match_o,
    output reg                          icq_full_o,
    output reg                          icq_empty_o,
    output reg [ICQ_COUNT_BITS-1:0]     icq_count_o,

    output reg                          line_resp_valid_o,
    output reg [511:0]                  line_resp_data_o,
    output reg                          line_resp_hit_o,
    output reg                          data_valid_o,
    output reg [511:0]                  data_line_o,
    output reg [63:LINE_BITS]           data_line_addr_o,
    output reg                          data_line_reused_o,
    output reg                          line_state_valid_o,
    output reg [63:LINE_BITS]           line_state_addr_o,
    output reg [FTQ_EPOCH_BITS-1:0]     line_state_epoch_o,

    output reg                          nlpb_hit_o,
    output reg                          nlpb_aux_hit_o,

    output reg                          icache_fill_req_valid,
    output reg [63:0]                   icache_fill_req_addr,
    input  wire                          icache_fill_req_accepted,
    input  wire                          icache_fill_resp_valid,
    input  wire [63:0]                   icache_fill_resp_addr,
    input  wire [511:0]                  icache_fill_resp_data,
    output reg                          icache_invalidate_busy,

    output reg                          pf_l2_req_valid,
    output reg [63:0]                   pf_l2_req_addr,
    input  wire                          pf_l2_req_ready,
    input  wire                          pf_l2_resp_valid,
    input  wire [63:0]                   pf_l2_resp_addr,
    input  wire [511:0]                  pf_l2_resp_data
);

    logic         ic_resp_valid_comb;
    logic [511:0] ic_resp_data_comb;
    logic         ic_resp_hit_comb;
    logic         nlpb_hit_comb;
    logic [511:0] nlpb_data_comb;
    logic         nlpb_aux_hit_comb;
    logic [511:0] nlpb_aux_data_comb;
    logic         nlpb_resp_valid_r;
    logic [63:0]  nlpb_resp_addr_r;
    logic [511:0] nlpb_resp_data_r;
    logic         nlpb_resp_match_c;
    logic         nlpb_trigger;
    logic [63:0]  nlpb_trigger_addr;
    logic         merged_resp_valid_c;
    logic [511:0] merged_resp_data_c;
    logic         merged_resp_hit_c;
    logic         instr_vm_lookup_c;
    logic         icache_req_valid_c;
    logic [63:0]  icache_req_addr_c;
    logic [63:0]  icache_req_pa_c;
    logic [63:0]  icache_req_va_c;
    logic         icache_req_owner_valid_c;
    logic [FTQ_IDX_BITS-1:0] icache_req_owner_idx_c;
    logic [FTQ_EPOCH_BITS-1:0] icache_req_owner_epoch_c;
    logic [FTQ_ALLOC_TAG_BITS-1:0] icache_req_owner_alloc_tag_c;
    ftq_entry_t   icache_req_owner_entry_c;
    logic [63:0]  ic_req_addr_pipe_r;
    logic         ic_req_ftq_pipe_valid_r;
    logic [FTQ_IDX_BITS-1:0] ic_req_ftq_pipe_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] ic_req_ftq_pipe_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] ic_req_ftq_pipe_alloc_tag_r;
    ftq_entry_t   ic_req_ftq_pipe_entry_r;
    logic         icq_deq_current_owner_match_c;
    logic         icq_deq_next_owner_match_c;
    logic         icq_deq_future_owner_match_c;
    logic         icq_deq_unowned_stale_c;
    logic         icq_deq_prior_owner_line_c;
    logic         icq_line_matches_work_c;
    logic         icq_deq_redirect_stale_c;
    logic         icq_deq_stale_c;
    logic         icq_future_capture_c;
    logic         icq_future_overflow_drop_c;
    logic         icq_deq_ready_c;
    logic         redirect_scrub_r;
    logic         line_state_valid_r;
    logic [63:LINE_BITS] line_state_addr_r;
    logic [511:0] line_state_data_r;
    logic [FTQ_EPOCH_BITS-1:0] line_state_epoch_r;
    logic         line_state_match_c;
    logic         line_state_use_c;
    logic         future_line_valid_r;
    logic [511:0] future_line_data_r;
    logic         future_line_hit_r;
    logic [63:0]  future_line_pc_r;
    logic [FTQ_IDX_BITS-1:0] future_line_ftq_idx_r;
    logic [FTQ_EPOCH_BITS-1:0] future_line_ftq_epoch_r;
    logic [FTQ_ALLOC_TAG_BITS-1:0] future_line_ftq_alloc_tag_r;
    ftq_entry_t   future_line_ftq_entry_r;
    logic         future_line_match_c;
    logic         line_resp_from_future_c;
    logic         line_resp_from_icq_c;
    logic [511:0] line_resp_data_c;
    logic         line_resp_hit_c;
    logic [63:LINE_BITS] line_resp_addr_c;

    // VIPT: the ITLB is looked up every cycle a paged fetch is presented; the PA is
    // used combinationally (itlb_pa_i) the same cycle, so no vm_req capture/serialization.
    assign instr_vm_lookup_c =
        instr_vm_active_i && f1_valid_i && !flush_i;
    assign itlb_lookup_valid_o = instr_vm_lookup_c;
    assign itlb_lookup_va_o    = req_addr_i;
    assign itlb_miss_valid_o   = instr_vm_lookup_c && !itlb_hit_i && !itlb_fault_i;
    assign itlb_miss_va_o      = req_addr_i;

    // F1 stage: registered snapshot of the F0 paged lookup. The translation-miss DECISION
    // reads this registered bundle, not the live ITLB result, so it cannot feed back to the
    // F0 same-cycle ITLB VA -> the combinational loop is broken by pipeline structure.
    // ITLB lookup + icache index/PA below stay on the LIVE F0 signals (VIPT preserved).
    logic        f1b_valid_r;
    logic [63:0] f1b_pc_r;
    logic        f1b_itlb_hit_r;
    logic        f1b_itlb_fault_r;
    // F1 miss: last cycle's paged lookup missed and was not a fault. Drives replay (Task 2),
    // NOT an F0 hold. instr_translation_stall_o keeps this name so the existing fe_stall_xlate
    // perf counter measures REAL misses (the VIPT discriminator: ~= itlb_misses, not lookups).
    wire f1_xlate_miss_c = f1b_valid_r && !f1b_itlb_hit_r && !f1b_itlb_fault_r;
    assign instr_translation_stall_o = f1_xlate_miss_c;

    // Redirect-on-miss replay: F0 advances past a missed VA without re-fetching it, so on an
    // F1 translation miss we hold the missed PC until the PTW fills the ITLB, then request a
    // redirect back to it (the existing redirect+epoch path discards the wrongly-advanced
    // fetches). The replay request is a REGISTERED pulse -> no combinational loop.
    logic        replay_pending_r;
    logic [63:0] replay_pc_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            replay_pending_r <= 1'b0;
            replay_pc_r      <= '0;
        end else if (flush_i) begin
            replay_pending_r <= 1'b0;   // a real redirect/flush supersedes a pending replay
        end else begin
            if (f1_xlate_miss_c && !replay_pending_r) begin
                replay_pending_r <= 1'b1;
                replay_pc_r      <= f1b_pc_r;        // the VA that missed
            end else if (replay_pending_r && itlb_fill_seen_i) begin
                replay_pending_r <= 1'b0;            // fill arrived -> replay fires this cycle
            end
        end
    end
    assign replay_req_valid_o = replay_pending_r && itlb_fill_seen_i;
    assign replay_req_pc_o    = replay_pc_r;

    assign icache_req_valid_c =
        req_valid_i &&
        !flush_i &&
        (!instr_vm_active_i || (itlb_hit_i && !itlb_fault_i));
    assign icache_req_addr_c = req_addr_i;   // VA index (VA[11:6]==PA[11:6] within page offset)
    assign icache_req_pa_c   = instr_vm_active_i ? itlb_pa_i : req_addr_i;
    assign icache_req_va_c   = req_addr_i;
    assign icache_req_owner_valid_c     = req_owner_valid_i;
    assign icache_req_owner_idx_c       = req_owner_idx_i;
    assign icache_req_owner_epoch_c     = req_owner_epoch_i;
    assign icache_req_owner_alloc_tag_c = req_owner_alloc_tag_i;
    assign icache_req_owner_entry_c     = req_owner_entry_i;

    assign nlpb_trigger      =
        !instr_vm_active_i && ic_resp_valid_comb && ic_resp_hit_comb;
    assign nlpb_trigger_addr = {req_addr_i[63:6], 6'b0};
    assign nlpb_resp_match_c =
        nlpb_resp_valid_r &&
        work_line_valid_i &&
        (nlpb_resp_addr_r[63:LINE_BITS] == work_line_addr_i);
    assign merged_resp_valid_c = ic_resp_valid_comb || nlpb_resp_match_c;
    assign merged_resp_data_c  =
        ic_resp_valid_comb ? ic_resp_data_comb : nlpb_resp_data_r;
    assign merged_resp_hit_c   = ic_resp_hit_comb || nlpb_resp_match_c;
    assign nlpb_hit_o        = nlpb_hit_comb;
    assign nlpb_aux_hit_o    = nlpb_aux_hit_comb;
    assign icq_line_matches_work_c =
        icq_deq_valid_o &&
        work_line_valid_i &&
        (icq_deq_line_addr_o == work_line_addr_i);
    assign icq_deq_current_owner_match_c =
        icq_deq_valid_o &&
        icq_deq_ftq_valid_o &&
        ftq_wb_owner_valid_i &&
        (icq_deq_ftq_idx_o == ftq_wb_owner_idx_i) &&
        (icq_deq_ftq_epoch_o == current_epoch_i) &&
        (icq_deq_ftq_alloc_tag_o == ftq_wb_owner_tag_i);
    assign icq_deq_next_owner_match_c =
        icq_deq_valid_o &&
        icq_deq_ftq_valid_o &&
        ftq_next_owner_valid_i &&
        (icq_deq_ftq_idx_o == ftq_next_owner_idx_i) &&
        (icq_deq_ftq_epoch_o == current_epoch_i) &&
        (icq_deq_ftq_alloc_tag_o == ftq_next_owner_tag_i);
    assign icq_deq_owner_match_o = icq_deq_current_owner_match_c;
    assign icq_deq_future_owner_match_c =
        icq_deq_current_owner_match_c ||
        icq_deq_next_owner_match_c;
    assign icq_deq_unowned_stale_c =
        icq_deq_valid_o &&
        icq_deq_ftq_valid_o &&
        ftq_wb_owner_valid_i &&
        !icq_deq_current_owner_match_c &&
        !icq_deq_next_owner_match_c;
    assign icq_deq_prior_owner_line_c =
        icq_deq_current_owner_match_c &&
        work_line_valid_i &&
        (icq_deq_line_addr_o < work_line_addr_i);
    assign icq_deq_redirect_stale_c =
        redirect_scrub_r &&
        icq_deq_current_owner_match_c &&
        work_line_valid_i &&
        !icq_line_matches_work_c;
    assign icq_deq_stale_c =
        icq_deq_valid_o &&
        (!icq_deq_ftq_valid_o ||
         (icq_deq_ftq_epoch_o != current_epoch_i) ||
         icq_deq_unowned_stale_c ||
         icq_deq_prior_owner_line_c ||
         icq_deq_redirect_stale_c);
    assign icq_future_capture_c =
        icq_deq_valid_o &&
        !icq_line_matches_work_c &&
        !icq_deq_stale_c &&
        icq_deq_future_owner_match_c &&
        !future_line_valid_r;
    assign icq_future_overflow_drop_c =
        icq_deq_valid_o &&
        !icq_line_matches_work_c &&
        !icq_deq_stale_c &&
        icq_deq_future_owner_match_c &&
        future_line_valid_r;
    assign icq_deq_ready_c =
        icq_line_matches_work_c ||
        icq_deq_stale_c ||
        icq_future_capture_c ||
        icq_future_overflow_drop_c;
    assign future_line_match_c =
        future_line_valid_r &&
        work_line_valid_i &&
        (future_line_pc_r[63:LINE_BITS] == work_line_addr_i) &&
        ftq_wb_owner_valid_i &&
        (future_line_ftq_idx_r == ftq_wb_owner_idx_i) &&
        (future_line_ftq_epoch_r == current_epoch_i) &&
        (future_line_ftq_alloc_tag_r == ftq_wb_owner_tag_i);
    assign line_resp_from_future_c = future_line_match_c;
    assign line_resp_from_icq_c =
        icq_deq_valid_o &&
        icq_line_matches_work_c &&
        !icq_deq_stale_c;
    assign line_resp_valid_o =
        line_resp_from_future_c ||
        line_resp_from_icq_c;
    assign line_resp_data_c =
        line_resp_from_future_c ? future_line_data_r : icq_deq_data_o;
    assign line_resp_hit_c =
        line_resp_from_future_c ? future_line_hit_r : icq_deq_hit_o;
    assign line_resp_addr_c =
        line_resp_from_future_c
            ? future_line_pc_r[63:LINE_BITS]
            : icq_deq_line_addr_o;
    assign line_resp_data_o = line_resp_data_c;
    assign line_resp_hit_o  = line_resp_hit_c;
    assign line_state_match_c =
        line_state_valid_r &&
        work_line_valid_i &&
        (line_state_addr_r == work_line_addr_i) &&
        (line_state_epoch_r == current_epoch_i);
    assign line_state_use_c = line_state_match_c && !line_resp_valid_o;
    assign data_valid_o =
        line_state_use_c || line_resp_valid_o;
    assign data_line_o =
        line_state_use_c ? line_state_data_r : line_resp_data_o;
    assign data_line_addr_o =
        line_state_use_c ? line_state_addr_r : line_resp_addr_c;
    assign data_line_reused_o = line_state_use_c;
    assign line_state_valid_o = line_state_valid_r;
    assign line_state_addr_o  = line_state_addr_r;
    assign line_state_epoch_o = line_state_epoch_r;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid      (icache_req_valid_c),
        .req_addr       (icache_req_addr_c),
        .req_pa         (icache_req_pa_c),
        .resp_valid     (ic_resp_valid_comb),
        .resp_data      (ic_resp_data_comb),
        .resp_hit       (ic_resp_hit_comb),
        .fill_req_valid (icache_fill_req_valid),
        .fill_req_addr  (icache_fill_req_addr),
        .fill_req_accepted(icache_fill_req_accepted),
        .fill_resp_valid(icache_fill_resp_valid),
        .fill_resp_addr (icache_fill_resp_addr),
        .fill_resp_data (icache_fill_resp_data),
        .invalidate_all (fence_i),
        .invalidate_busy(icache_invalidate_busy)
    );

    next_line_prefetch_buffer u_nlpb (
        .clk             (clk),
        .rst_n           (rst_n),
        .lookup_valid    (f1_valid_i && !stall_i && !instr_vm_active_i),
        .lookup_addr     (req_addr_i),
        .hit             (nlpb_hit_comb),
        .hit_data        (nlpb_data_comb),
        .aux_lookup_valid(f1_valid_i && !stall_i && !instr_vm_active_i),
        .aux_lookup_addr (aux_lookup_addr_i),
        .aux_hit         (nlpb_aux_hit_comb),
        .aux_hit_data    (nlpb_aux_data_comb),
        .trigger_valid   (nlpb_trigger),
        .trigger_addr    (nlpb_trigger_addr),
        .flush           (flush_i),
        .fence_i         (fence_i),
        .pf_req_valid    (pf_l2_req_valid),
        .pf_req_addr     (pf_l2_req_addr),
        .pf_req_ready    (pf_l2_req_ready),
        .pf_resp_valid   (pf_l2_resp_valid),
        .pf_resp_addr    (pf_l2_resp_addr),
        .pf_resp_data    (pf_l2_resp_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
            redirect_scrub_r            <= 1'b0;
            f1b_valid_r                 <= 1'b0;
            f1b_pc_r                    <= '0;
            f1b_itlb_hit_r              <= 1'b0;
            f1b_itlb_fault_r            <= 1'b0;
            ic_req_addr_pipe_r          <= '0;
            ic_req_ftq_pipe_valid_r     <= 1'b0;
            ic_req_ftq_pipe_idx_r       <= '0;
            ic_req_ftq_pipe_epoch_r     <= '0;
            ic_req_ftq_pipe_alloc_tag_r <= '0;
            ic_req_ftq_pipe_entry_r     <= '0;
            line_state_valid_r          <= 1'b0;
            line_state_addr_r           <= '0;
            line_state_data_r           <= '0;
            line_state_epoch_r          <= '0;
            future_line_valid_r         <= 1'b0;
            future_line_data_r          <= '0;
            future_line_hit_r           <= 1'b0;
            future_line_pc_r            <= '0;
            future_line_ftq_idx_r       <= '0;
            future_line_ftq_epoch_r     <= '0;
            future_line_ftq_alloc_tag_r <= '0;
            future_line_ftq_entry_r     <= '0;
        end else if (flush_i) begin
            nlpb_resp_valid_r <= 1'b0;
            nlpb_resp_addr_r  <= '0;
            nlpb_resp_data_r  <= '0;
            redirect_scrub_r <= 1'b0;
            f1b_valid_r       <= 1'b0;
            ic_req_ftq_pipe_valid_r <= 1'b0;
            line_state_valid_r <= 1'b0;
            line_state_addr_r  <= '0;
            line_state_data_r  <= '0;
            line_state_epoch_r <= '0;
            future_line_valid_r         <= 1'b0;
            future_line_data_r          <= '0;
            future_line_hit_r           <= 1'b0;
            future_line_pc_r            <= '0;
            future_line_ftq_idx_r       <= '0;
            future_line_ftq_epoch_r     <= '0;
            future_line_ftq_alloc_tag_r <= '0;
            future_line_ftq_entry_r     <= '0;
        end else begin
            // Capture the F0 paged lookup for next-cycle F1 decision (coherent with the
            // ic_req_*_pipe_r owner snapshot below — same cycle, same fetch).
            // Gate on req_valid_i (= ic_req_valid = f1_valid_r && !fe_stall_c): only a REAL
            // issued fetch counts. Without this, a frozen f1_pc_r under stall keeps
            // re-presenting a not-yet-filled VA as a "miss" every stall cycle, so
            // f1_xlate_miss_c sticks high (counter reads ~lookups, not ~misses) and a
            // spurious replay could be armed. Registered req_valid_i -> loop stays broken.
            f1b_valid_r      <= instr_vm_active_i && f1_valid_i && !flush_i && req_valid_i;
            f1b_pc_r         <= req_addr_i;
            f1b_itlb_hit_r   <= itlb_hit_i;
            f1b_itlb_fault_r <= itlb_fault_i;
            if (redirect_scrub_i)
                redirect_scrub_r <= 1'b1;
            else if (line_resp_valid_o)
                redirect_scrub_r <= 1'b0;

            nlpb_resp_valid_r <=
                f1_valid_i && !stall_i && !instr_vm_active_i && nlpb_hit_comb;
            nlpb_resp_addr_r  <= {req_addr_i[63:LINE_BITS], {LINE_BITS{1'b0}}};
            nlpb_resp_data_r  <= nlpb_data_comb;
            if (icache_req_valid_c) begin
                ic_req_addr_pipe_r <= icache_req_va_c;
                ic_req_ftq_pipe_valid_r <= icache_req_owner_valid_c;
                if (icache_req_owner_valid_c) begin
                    ic_req_ftq_pipe_idx_r       <= icache_req_owner_idx_c;
                    ic_req_ftq_pipe_epoch_r     <= icache_req_owner_epoch_c;
                    ic_req_ftq_pipe_alloc_tag_r <= icache_req_owner_alloc_tag_c;
                    ic_req_ftq_pipe_entry_r     <= icache_req_owner_entry_c;
                end else begin
                    ic_req_ftq_pipe_idx_r       <= '0;
                    ic_req_ftq_pipe_epoch_r     <= '0;
                    ic_req_ftq_pipe_alloc_tag_r <= '0;
                    ic_req_ftq_pipe_entry_r     <= '0;
                end
            end else begin
                ic_req_ftq_pipe_valid_r <= 1'b0;
            end
            if (fence_i) begin
                line_state_valid_r <= 1'b0;
                line_state_addr_r  <= '0;
                line_state_data_r  <= '0;
                line_state_epoch_r <= '0;
                future_line_valid_r         <= 1'b0;
                future_line_data_r          <= '0;
                future_line_hit_r           <= 1'b0;
                future_line_pc_r            <= '0;
                future_line_ftq_idx_r       <= '0;
                future_line_ftq_epoch_r     <= '0;
                future_line_ftq_alloc_tag_r <= '0;
                future_line_ftq_entry_r     <= '0;
            end else if (work_valid_i && line_resp_valid_o) begin
                line_state_valid_r <= 1'b1;
                line_state_addr_r  <= line_resp_addr_c;
                line_state_data_r  <= line_resp_data_o;
                line_state_epoch_r <= current_epoch_i;
            end

            if (!fence_i) begin
                if (line_resp_from_future_c) begin
                    future_line_valid_r         <= 1'b0;
                    future_line_data_r          <= '0;
                    future_line_hit_r           <= 1'b0;
                    future_line_pc_r            <= '0;
                    future_line_ftq_idx_r       <= '0;
                    future_line_ftq_epoch_r     <= '0;
                    future_line_ftq_alloc_tag_r <= '0;
                    future_line_ftq_entry_r     <= '0;
                end else if (icq_future_capture_c) begin
                    future_line_valid_r         <= 1'b1;
                    future_line_data_r          <= icq_deq_data_o;
                    future_line_hit_r           <= icq_deq_hit_o;
                    future_line_pc_r            <= icq_deq_pc_o;
                    future_line_ftq_idx_r       <= icq_deq_ftq_idx_o;
                    future_line_ftq_epoch_r     <= icq_deq_ftq_epoch_o;
                    future_line_ftq_alloc_tag_r <= icq_deq_ftq_alloc_tag_o;
                    future_line_ftq_entry_r     <= icq_deq_ftq_entry_o;
                end
            end
        end
    end

    icache_resp_queue #(.DEPTH(ICQ_DEPTH)) u_icache_resp_queue (
        .clk                 (clk),
        .rst_n               (rst_n),
        .flush               (flush_i),
        .resp_valid_i        (merged_resp_valid_c),
        .resp_data_i         (merged_resp_data_c),
        .resp_hit_i          (merged_resp_hit_c),
        .resp_pc_i           (ic_req_addr_pipe_r),
        .resp_ftq_valid_i    (ic_req_ftq_pipe_valid_r),
        .resp_ftq_idx_i      (ic_req_ftq_pipe_idx_r),
        .resp_ftq_epoch_i    (ic_req_ftq_pipe_epoch_r),
        .resp_ftq_alloc_tag_i(ic_req_ftq_pipe_alloc_tag_r),
        .resp_ftq_entry_i    (ic_req_ftq_pipe_entry_r),
        .deq_ready_i         (icq_deq_ready_c),
        .deq_valid_o         (icq_deq_valid_o),
        .deq_data_o          (icq_deq_data_o),
        .deq_hit_o           (icq_deq_hit_o),
        .deq_pc_o            (icq_deq_pc_o),
        .deq_line_addr_o     (icq_deq_line_addr_o),
        .deq_ftq_valid_o     (icq_deq_ftq_valid_o),
        .deq_ftq_idx_o       (icq_deq_ftq_idx_o),
        .deq_ftq_epoch_o     (icq_deq_ftq_epoch_o),
        .deq_ftq_alloc_tag_o (icq_deq_ftq_alloc_tag_o),
        .deq_ftq_entry_o     (icq_deq_ftq_entry_o),
        .full                (icq_full_o),
        .empty               (icq_empty_o),
        .count               (icq_count_o)
    );

endmodule
