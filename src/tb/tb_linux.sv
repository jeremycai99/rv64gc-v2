/* file: tb_linux.sv
 Description: Linux platform simulation top for rv64gc-v2.
 Author: Jeremy Cai
 Date: May 10, 2026
 Version: 1.0
*/
`timescale 1ns/1ps

module tb_linux;
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;

    logic clk;
    logic rst_n;

    logic        mem_req_valid;
    logic [63:0] mem_req_addr;
    logic        mem_req_we;
    logic [511:0] mem_req_wdata;
    logic        mem_req_ready;
    logic        mem_resp_valid;
    logic [511:0] mem_resp_data;

    logic        data_mmio_req_valid;
    logic        data_mmio_req_we;
    logic [63:0] data_mmio_req_addr;
    logic [63:0] data_mmio_req_wdata;
    logic [7:0]  data_mmio_req_wmask;
    logic [1:0]  data_mmio_req_size;
    logic        data_mmio_req_ready;
    logic        data_mmio_resp_valid;
    logic [63:0] data_mmio_resp_data;

    logic [63:0] time_val;
    logic        mtip;
    logic        msip;
    logic        meip;
    logic        stip;
    logic        ssip;
    logic        seip;
    logic        uart_tx_valid;
    logic [7:0]  uart_tx_data;

    logic [63:0] perf_mcycle;
    logic [63:0] perf_minstret;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat (40) @(posedge clk);
        rst_n = 1'b1;
    end

    rv64gc_core_top u_core (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .mem_req_valid               (mem_req_valid),
        .mem_req_addr                (mem_req_addr),
        .mem_req_we                  (mem_req_we),
        .mem_req_wdata               (mem_req_wdata),
        .mem_req_ready               (mem_req_ready),
        .mem_resp_valid              (mem_resp_valid),
        .mem_resp_data               (mem_resp_data),
        .data_mmio_req_valid         (data_mmio_req_valid),
        .data_mmio_req_we            (data_mmio_req_we),
        .data_mmio_req_addr          (data_mmio_req_addr),
        .data_mmio_req_wdata         (data_mmio_req_wdata),
        .data_mmio_req_wmask         (data_mmio_req_wmask),
        .data_mmio_req_size          (data_mmio_req_size),
        .data_mmio_req_ready         (data_mmio_req_ready),
        .data_mmio_resp_valid        (data_mmio_resp_valid),
        .data_mmio_resp_data         (data_mmio_resp_data),
        .mtip                        (mtip),
        .msip                        (msip),
        .meip                        (meip),
        .stip                        (stip),
        .ssip                        (ssip),
        .seip                        (seip),
        .time_val                    (time_val),
        .backend_admission_throttle_enable(1'b0),
        .perf_mcycle                 (perf_mcycle),
        .perf_minstret               (perf_minstret)
    );

    sim_memory #(
        .MEM_SIZE_BYTES(128 * 1024 * 1024)
    ) u_mem (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_req_valid  (mem_req_valid),
        .mem_req_addr   (mem_req_addr),
        .mem_req_we     (mem_req_we),
        .mem_req_wdata  (mem_req_wdata),
        .mem_req_ready  (mem_req_ready),
        .mem_resp_valid (mem_resp_valid),
        .mem_resp_data  (mem_resp_data)
    );

    mmio_platform u_mmio (
        .clk             (clk),
        .rst_n           (rst_n),
        .req_valid_i     (data_mmio_req_valid),
        .req_we_i        (data_mmio_req_we),
        .req_addr_i      (data_mmio_req_addr),
        .req_wdata_i     (data_mmio_req_wdata),
        .req_wmask_i     (data_mmio_req_wmask),
        .req_size_i      (data_mmio_req_size),
        .req_ready_o     (data_mmio_req_ready),
        .resp_valid_o    (data_mmio_resp_valid),
        .resp_data_o     (data_mmio_resp_data),
        .time_val_o      (time_val),
        .mtip_o          (mtip),
        .msip_o          (msip),
        .meip_o          (meip),
        .stip_o          (stip),
        .ssip_o          (ssip),
        .seip_o          (seip),
        .uart_tx_valid_o (uart_tx_valid),
        .uart_tx_data_o  (uart_tx_data)
    );

    integer sim_cycle;
    integer max_cycles;
    integer uart_log_fd;
    integer uart_stdout_en;
    integer smoke_check_en;
    integer smoke_idx;
    integer uart_fail_stop_en;
    integer uart_fail_delay_cycles;
    logic   uart_fail_pending_r;
    integer uart_fail_cycle_r;
    integer uart_fail_panic_idx;
    integer uart_fail_oops_idx;
    integer uart_fail_bug_idx;
    integer linux_trace_mmio_en;
    integer mmio_req_count;
    integer mmio_uart_rd_count;
    integer mmio_uart_wr_count;
    logic [63:0] last_commit_pc;
    logic [63:0] last_commit_cycle;
    integer last_commit_count;
    // Wedge-dump (sim-only, +WEDGE_DUMP): when commit stalls for a long window,
    // dump the LSU atomic-serialization state so we can see which amo_serial_block
    // term is stuck (the root of the LR/AMO-at-head boot deadlock).
    logic        wedge_dump_en;
    logic        wedge_dumped;
    logic [63:0] wedge_prev_minstret;
    logic [63:0] wedge_last_change_cyc;
    integer      wedge_dump_thresh;
    initial begin
        wedge_dump_en = $test$plusargs("WEDGE_DUMP");
        wedge_dumped  = 1'b0;
        wedge_prev_minstret = 64'd0;
        wedge_last_change_cyc = 64'd0;
        wedge_dump_thresh = 300000;
        void'($value$plusargs("WEDGE_DUMP_THRESH=%d", wedge_dump_thresh));
    end
    localparam int LINUX_TRACE_RING_DEPTH = 32;
    integer linux_commit_ring_wr;
    integer linux_commit_ring_count;
    logic [63:0] linux_commit_ring_cycle [0:LINUX_TRACE_RING_DEPTH-1];
    logic [63:0] linux_commit_ring_pc [0:LINUX_TRACE_RING_DEPTH-1];
    logic [2:0]  linux_commit_ring_slot [0:LINUX_TRACE_RING_DEPTH-1];
    logic [2:0]  linux_commit_ring_group_count [0:LINUX_TRACE_RING_DEPTH-1];
    integer linux_bru_ring_wr;
    integer linux_bru_ring_count;
    logic [63:0] linux_bru_ring_cycle [0:LINUX_TRACE_RING_DEPTH-1];
    logic [63:0] linux_bru_ring_pc [0:LINUX_TRACE_RING_DEPTH-1];
    logic [63:0] linux_bru_ring_bp_target [0:LINUX_TRACE_RING_DEPTH-1];
    logic [63:0] linux_bru_ring_target [0:LINUX_TRACE_RING_DEPTH-1];
    logic [ROB_IDX_BITS-1:0] linux_bru_ring_rob [0:LINUX_TRACE_RING_DEPTH-1];
    logic [2:0]  linux_bru_ring_port [0:LINUX_TRACE_RING_DEPTH-1];
    logic [2:0]  linux_bru_ring_op [0:LINUX_TRACE_RING_DEPTH-1];
    logic        linux_bru_ring_bp_taken [0:LINUX_TRACE_RING_DEPTH-1];
    logic        linux_bru_ring_taken [0:LINUX_TRACE_RING_DEPTH-1];
    logic        linux_bru_ring_misp [0:LINUX_TRACE_RING_DEPTH-1];
    integer linux_trace_load_pc_en;
    integer linux_stop_on_trace_load_pc_en;
    integer linux_trace_load_range_en;
    integer linux_stop_on_trace_load_range_en;
    logic [63:0] linux_trace_load_pc;
    integer linux_stop_sideband_tval_en;
    logic [63:0] linux_stop_sideband_tval;
    integer linux_stop_trap_pc_en;
    integer linux_stop_trap_tval_en;
    logic [63:0] linux_stop_trap_pc;
    logic [63:0] linux_stop_trap_tval;
    integer linux_trace_line_en;
    logic [63:0] linux_trace_line;
    integer linux_trace_pa_line_en;
    logic [63:0] linux_trace_pa_line;
    integer linux_trace_preempt_pa_en;
    logic [63:0] linux_trace_preempt_pa;
    integer linux_trace_preempt_va_en;
    logic [63:0] linux_trace_preempt_va;
    integer linux_trace_l2_en;
    integer linux_trace_trap_en;
    integer linux_trace_fault_only_en;
    integer linux_trace_fe_en;
    integer linux_trace_amo_en;
    integer linux_stop_lost_load_owner_en;
    integer linux_lost_load_owner_limit;
    integer linux_lost_load_owner_count [0:LQ_DEPTH-1];
    integer linux_trace_commit_range_en;
    integer linux_trace_regs_en;
    integer linux_trace_sscratch_en;
    integer linux_stop_on_sscratch_nonzero_en;
    integer linux_stop_on_bad_kernel_sscratch_en;
    integer linux_stop_on_low_ifetch_fault_en;
    integer linux_stop_on_low_vm_fetch_en;
    integer linux_stop_on_timer_boundary_en;
    logic   linux_timer_boundary_seen_r;
    integer linux_stop_store_pc_en;
    integer linux_stop_store_data_above_en;
    logic [63:0] linux_stop_store_pc;
    logic [63:0] linux_stop_store_data_above;
    integer linux_stop_commit_rd_en;
    integer linux_stop_commit_data_above_en;
    logic [4:0] linux_stop_commit_rd;
    logic [63:0] linux_stop_commit_data_above;
    integer linux_stop_commit_pc_en;
    logic [63:0] linux_stop_commit_pc;
    integer linux_trace_pipe_en;
    integer linux_trace_bru_en;
    integer linux_trace_mmu_en;
    integer linux_trace_clear_bss_en;
    integer linux_trace_clear_bss_monitor_en;
    integer linux_trace_cycle_window_en;
    integer linux_stop_on_no_commit_en;
    integer linux_no_commit_limit;
    // Early-kernel panic visibility probe (see probe block below).
    integer linux_panic_probe_en;
    integer linux_stop_on_panic_en;
    integer linux_trace_printk_en;
    logic [63:0] linux_panic_pc;
    logic [63:0] linux_die_pc;
    logic [63:0] linux_warn_pc;
    logic [63:0] linux_printk_pc;
    integer linux_trace_cycle_lo;
    integer linux_trace_cycle_hi;
    logic [63:0] boot_hartid;
    logic [63:0] boot_dtb_addr;
    logic [63:0] linux_trace_commit_lo;
    logic [63:0] linux_trace_commit_hi;
    integer status_en;
    integer status_interval;
    integer perf_profile_en;
    logic [63:0] mem_read_addr_r;
    logic        mem_read_pending_r;
    logic        clear_bss_post_flush_pending;
    logic        clear_bss_a3_commit_seen_r;
    logic [63:0] clear_bss_last_commit_a3_r;
    logic        clear_bss_a3_issue_seen_r;
    logic [63:0] clear_bss_last_issue_a3_r;
    logic        clear_bss_exit_branch_seen_r;
    string uart_log_path;
    string smoke_pattern;
    string uart_fail_panic_pattern;
    string uart_fail_oops_pattern;
    string uart_fail_bug_pattern;

    localparam int TRACE_LOAD_TRACK = 8;
    localparam int LOAD_OWNER_HIST_DEPTH = 2048;
    localparam logic [63:0] OPENSBI_TEXT_LO = 64'h0000_0000_8000_0000;
    localparam logic [63:0] OPENSBI_TEXT_HI = 64'h0000_0000_8006_0000;
    logic                    trace_load_valid [0:TRACE_LOAD_TRACK-1];
    logic [ROB_IDX_BITS-1:0] trace_load_rob [0:TRACE_LOAD_TRACK-1];
    logic [PHYS_REG_BITS-1:0] trace_load_pdst [0:TRACE_LOAD_TRACK-1];
    logic [63:0]             trace_load_pc [0:TRACE_LOAD_TRACK-1];
    logic [63:0]             trace_load_addr [0:TRACE_LOAD_TRACK-1];
    integer                  linux_owner_hist_en;
    integer                  linux_owner_hist_wr;
    integer                  linux_owner_hist_count;
    logic [7:0]              linux_owner_hist_event [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [1:0]              linux_owner_hist_port [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [63:0]             linux_owner_hist_cycle [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [63:0]             linux_owner_hist_pc [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [ROB_IDX_BITS-1:0] linux_owner_hist_rob [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [LQ_IDX_BITS-1:0]  linux_owner_hist_lq [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [63:0]             linux_owner_hist_addr [0:LOAD_OWNER_HIST_DEPTH-1];
    logic [63:0]             linux_owner_hist_flags [0:LOAD_OWNER_HIST_DEPTH-1];
    integer                  linux_owner_hist_load_pc_en;
    logic [63:0]             linux_owner_hist_load_pc;
    integer                  linux_hist_dump_pos;
    integer                  linux_hist_dump_idx;
    integer                  linux_owner_hist_pa_line_en;
    logic [63:0]             linux_owner_hist_pa_line;
    wire                     linux_trace_cycle_on;
    wire                     linux_trace_any_line_en;

    assign linux_trace_cycle_on =
        (linux_trace_cycle_window_en == 0) ||
        ((sim_cycle >= linux_trace_cycle_lo) &&
         (sim_cycle <= linux_trace_cycle_hi));
    assign linux_trace_any_line_en =
        (linux_trace_line_en != 0) || (linux_trace_pa_line_en != 0);

    function automatic logic linux_trace_line_match(input logic [63:0] addr);
        linux_trace_line_match =
            ((linux_trace_line_en != 0) &&
             ({addr[63:6], 6'd0} == linux_trace_line)) ||
            ((linux_trace_pa_line_en != 0) &&
             ({addr[63:6], 6'd0} == linux_trace_pa_line));
    endfunction

    function automatic logic linux_trace_preempt_match(input logic [63:0] addr);
        linux_trace_preempt_match =
            ((linux_trace_preempt_pa_en != 0) &&
             (addr == linux_trace_preempt_pa)) ||
            ((linux_trace_preempt_va_en != 0) &&
             (addr == linux_trace_preempt_va));
    endfunction

    function automatic logic linux_owner_hist_pc_match(input logic [63:0] pc);
        linux_owner_hist_pc_match =
            ((linux_trace_load_pc_en != 0) && (pc == linux_trace_load_pc)) ||
            ((linux_owner_hist_load_pc_en != 0) &&
             (pc == linux_owner_hist_load_pc));
    endfunction

    function automatic logic linux_owner_hist_addr_match(input logic [63:0] addr);
        linux_owner_hist_addr_match =
            ((linux_trace_any_line_en != 0) && linux_trace_line_match(addr)) ||
            ((linux_owner_hist_pa_line_en != 0) &&
             ({addr[63:6], 6'd0} == linux_owner_hist_pa_line));
    endfunction

    task automatic linux_owner_hist_record(
        input logic [7:0]              event_i,
        input logic [1:0]              port_i,
        input logic [63:0]             pc_i,
        input logic [ROB_IDX_BITS-1:0] rob_i,
        input logic [LQ_IDX_BITS-1:0]  lq_i,
        input logic [63:0]             addr_i,
        input logic [63:0]             flags_i
    );
        begin
            linux_owner_hist_event[linux_owner_hist_wr] = event_i;
            linux_owner_hist_port[linux_owner_hist_wr]  = port_i;
            linux_owner_hist_cycle[linux_owner_hist_wr] = 64'(sim_cycle);
            linux_owner_hist_pc[linux_owner_hist_wr]    = pc_i;
            linux_owner_hist_rob[linux_owner_hist_wr]   = rob_i;
            linux_owner_hist_lq[linux_owner_hist_wr]    = lq_i;
            linux_owner_hist_addr[linux_owner_hist_wr]  = addr_i;
            linux_owner_hist_flags[linux_owner_hist_wr] = flags_i;
            linux_owner_hist_wr = (linux_owner_hist_wr + 1) %
                                  LOAD_OWNER_HIST_DEPTH;
            if (linux_owner_hist_count < LOAD_OWNER_HIST_DEPTH)
                linux_owner_hist_count = linux_owner_hist_count + 1;
        end
    endtask

    task automatic linux_dump_load_owner_history(
        input int                      target_lq,
        input logic [ROB_IDX_BITS-1:0] target_rob,
        input logic [63:0]             target_addr
    );
        integer hist_pos;
        integer hist_idx;
        logic   target_line_match;
        begin
            if (linux_owner_hist_en != 0) begin
                $display("[LINUX_LOAD_OWNER_HISTORY] count=%0d wr=%0d target_lq=%0d target_rob=%0d target_addr=%016h",
                         linux_owner_hist_count, linux_owner_hist_wr,
                         target_lq, target_rob, target_addr);
                for (hist_pos = 0; hist_pos < linux_owner_hist_count;
                     hist_pos = hist_pos + 1) begin
                    hist_idx = (linux_owner_hist_wr + LOAD_OWNER_HIST_DEPTH -
                                linux_owner_hist_count + hist_pos) %
                               LOAD_OWNER_HIST_DEPTH;
                    target_line_match =
                        ({linux_owner_hist_addr[hist_idx][63:6], 6'd0} ==
                         {target_addr[63:6], 6'd0});
                    if ((linux_owner_hist_lq[hist_idx] == LQ_IDX_BITS'(target_lq)) ||
                        (linux_owner_hist_rob[hist_idx] == target_rob) ||
                        target_line_match) begin
                        $display("[LINUX_LOAD_OWNER_HIST] cyc=%0d ev=%0d p%0d pc=%016h rob=%0d lq=%0d addr=%016h flags=%016h line=%0b",
                                 linux_owner_hist_cycle[hist_idx],
                                 linux_owner_hist_event[hist_idx],
                                 linux_owner_hist_port[hist_idx],
                                 linux_owner_hist_pc[hist_idx],
                                 linux_owner_hist_rob[hist_idx],
                                 linux_owner_hist_lq[hist_idx],
                                 linux_owner_hist_addr[hist_idx],
                                 linux_owner_hist_flags[hist_idx],
                                 target_line_match);
                    end
                end
            end
        end
    endtask

    task linux_dump_stall_debug;
        begin
            $display("[LINUX_DEBUG_LSU] lq_head=%0d lq_tail=%0d lq_count=%0d lq_full=%0b lmb_any=%0b p0_retry=%0b p1_retry=%0b p0_miss_retry=%0b p1_miss_retry=%0b p0_miss=%0b p1_miss=%0b p0_fill_hit=%0b p1_fill_hit=%0b lmb_match=%0b lmb_ready=%0b lmb_wb_free=%0b",
                     u_core.u_lsu.u_load_queue.head_r,
                     u_core.u_lsu.u_load_queue.tail_r,
                     u_core.u_lsu.u_load_queue.count_r,
                     u_core.lq_full,
                     u_core.u_lsu.lmb_any_valid,
                     u_core.u_lsu.p0_retry_valid_r,
                     u_core.u_lsu.p1_retry_valid_r,
                     u_core.u_lsu.p0_miss_retry_req,
                     u_core.u_lsu.p1_miss_retry_req,
                     u_core.u_lsu.p0_miss_detect,
                     u_core.u_lsu.p1_miss_detect,
                     u_core.u_lsu.p0_miss_fill_hit,
                     u_core.u_lsu.p1_miss_fill_hit,
                     u_core.u_lsu.lmb_any_match,
                     u_core.u_lsu.lmb_ready_any,
                     u_core.u_lsu.lmb_wb_port_free);
            $display("[LINUX_DEBUG_LOAD_PIPE] issue=%b r=%b rr=%b p0_pc=%016h p0_addr=%016h p0_lq=%0d p0_rob=%0d p1_pc=%016h p1_addr=%016h p1_lq=%0d p1_rob=%0d resp_v=%b resp_hit=%b miss_retry=%b wb_v=%b wb_rob=%0d/%0d wb_pdst=%0d/%0d",
                     u_core.u_lsu.load_issue_valid,
                     u_core.u_lsu.load_issue_valid_r,
                     u_core.u_lsu.load_issue_valid_rr,
                     u_core.u_lsu.load_issue_data_r[0].pc,
                     u_core.u_lsu.load_eff_addr_r[0],
                     u_core.u_lsu.load_issue_data_r[0].lq_idx,
                     u_core.u_lsu.load_issue_data_r[0].rob_idx,
                     u_core.u_lsu.load_issue_data_r[1].pc,
                     u_core.u_lsu.load_eff_addr_r[1],
                     u_core.u_lsu.load_issue_data_r[1].lq_idx,
                     u_core.u_lsu.load_issue_data_r[1].rob_idx,
                     u_core.dc_load_resp_valid,
                     u_core.dc_load_resp_hit,
                     u_core.u_lsu.dcache_load_miss_retry,
                     u_core.lsu_load_wb_valid,
                     u_core.lsu_load_wb_rob_idx[0],
                     u_core.lsu_load_wb_rob_idx[1],
                     u_core.lsu_load_wb_pdst[0],
                     u_core.lsu_load_wb_pdst[1]);
            $display("[LINUX_DEBUG_LOAD_HOLD] p0_dcache=%0b lq=%0d rob=%0d p1_dcache=%0b lq=%0d rob=%0d p1_misalign=%0b lq=%0d rob=%0d p0_fwd=%0b lq=%0d rob=%0d p1_fwd=%0b lq=%0d rob=%0d",
                     u_core.u_lsu.p0_dcache_hold_valid_r,
                     u_core.u_lsu.p0_dcache_hold_lq_idx_r,
                     u_core.u_lsu.p0_dcache_hold_rob_idx_r,
                     u_core.u_lsu.p1_dcache_hold_valid_r,
                     u_core.u_lsu.p1_dcache_hold_lq_idx_r,
                     u_core.u_lsu.p1_dcache_hold_rob_idx_r,
                     u_core.u_lsu.p1_misalign_hold_valid_r,
                     u_core.u_lsu.p1_misalign_hold_lq_idx_r,
                     u_core.u_lsu.p1_misalign_hold_rob_idx_r,
                     u_core.u_lsu.fwd_hold_valid_r,
                     u_core.u_lsu.fwd_hold_lq_idx_r,
                     u_core.u_lsu.fwd_hold_rob_idx_r,
                     u_core.u_lsu.p1_fwd_hold_valid_r,
                     u_core.u_lsu.p1_fwd_hold_lq_idx_r,
                     u_core.u_lsu.p1_fwd_hold_rob_idx_r);
            $display("[LINUX_DEBUG_AMO] wait=%0b wb=%0b store=%0b committed=%0b lq=%0d rob=%0d addr=%016h op=%0d",
                     u_core.u_lsu.amo_wait_load_r,
                     u_core.u_lsu.amo_wb_valid_r,
                     u_core.u_lsu.amo_store_valid_r,
                     u_core.u_lsu.amo_store_committed_r,
                     u_core.u_lsu.amo_data_r.lq_idx,
                     u_core.u_lsu.amo_data_r.rob_idx,
                     u_core.u_lsu.amo_addr_r,
                     u_core.u_lsu.amo_data_r.amo_op);
            $display("[LINUX_DEBUG_DCACHE] l2_state=%0d active=%0d req=%0b we=%0b req_addr=%016h ready=%0b resp=%0b resp_addr=%016h fill=%0b fill_addr=%016h free=%0b free_idx=%0d fill_avail=%0b fill_idx=%0d done_avail=%0b done_idx=%0d wb_avail=%0b wb_idx=%0d wt_count=%0d wt_deq=%0b",
                     u_core.u_dcache.l2_state_q,
                     u_core.u_dcache.l2_active_mshr_q,
                     u_core.dc_l2_req_valid,
                     u_core.dc_l2_req_we,
                     u_core.dc_l2_req_addr,
                     u_core.dc_l2_req_ready,
                     u_core.dc_l2_resp_valid,
                     u_core.dc_l2_resp_addr,
                     u_core.dc_fill_snoop_valid,
                     u_core.dc_fill_snoop_addr,
                     u_core.u_dcache.mshr_free_avail,
                     u_core.u_dcache.mshr_free_idx,
                     u_core.u_dcache.fill_mshr_avail,
                     u_core.u_dcache.fill_mshr_idx,
                     u_core.u_dcache.fill_done_avail,
                     u_core.u_dcache.fill_done_idx,
                     u_core.u_dcache.wb_mshr_avail,
                     u_core.u_dcache.wb_mshr_idx,
                     u_core.u_dcache.wt_count_q,
                     u_core.u_dcache.st_wt_deq_valid);
            for (int lqi = 0; lqi < LQ_DEPTH; lqi++) begin
                if (u_core.u_lsu.u_load_queue.queue[lqi].valid) begin
                    $display("[LINUX_DEBUG_LQ] idx=%0d head=%0b rob=%0d valid=%0b addr_v=%0b exec=%0b result=%0b addr=%016h size=%0d data=%016h",
                             lqi,
                             (lqi == u_core.u_lsu.u_load_queue.head_r),
                             u_core.u_lsu.u_load_queue.queue[lqi].rob_idx,
                             u_core.u_lsu.u_load_queue.queue[lqi].valid,
                             u_core.u_lsu.u_load_queue.queue[lqi].addr_valid,
                             u_core.u_lsu.u_load_queue.queue[lqi].executed,
                             u_core.u_lsu.u_load_queue.queue[lqi].has_result,
                             u_core.u_lsu.u_load_queue.queue[lqi].addr,
                             u_core.u_lsu.u_load_queue.queue[lqi].size,
                             u_core.u_lsu.u_load_queue.queue[lqi].data);
                end
            end
            for (int lmbi = 0; lmbi < 32; lmbi++) begin
                if (u_core.u_lsu.lmb[lmbi].valid) begin
                    $display("[LINUX_DEBUG_LMB] idx=%0d ready=%0b line=%016h off=%0d size=%0d rob=%0d pdst=%0d lq=%0d data=%016h",
                             lmbi,
                             u_core.u_lsu.lmb[lmbi].ready,
                             u_core.u_lsu.lmb[lmbi].line_addr,
                             u_core.u_lsu.lmb[lmbi].byte_offset,
                             u_core.u_lsu.lmb[lmbi].size,
                             u_core.u_lsu.lmb[lmbi].rob_idx,
                             u_core.u_lsu.lmb[lmbi].pdst,
                             u_core.u_lsu.lmb[lmbi].lq_idx,
                             u_core.u_lsu.lmb[lmbi].data);
                end
            end
            for (int mi = 0; mi < 16; mi++) begin
                if (u_core.u_dcache.mshr[mi].valid) begin
                    $display("[LINUX_DEBUG_MSHR] idx=%0d addr=%016h wb=%0b fill_pend=%0b fill_done=%0b store=%0b victim=%0d dirty=%0b evict=%016h",
                             mi,
                             u_core.u_dcache.mshr[mi].addr,
                             u_core.u_dcache.mshr[mi].writeback_pend,
                             u_core.u_dcache.mshr[mi].fill_pend,
                             u_core.u_dcache.mshr[mi].fill_done,
                             u_core.u_dcache.mshr[mi].store_pending,
                             u_core.u_dcache.mshr[mi].victim,
                             u_core.u_dcache.mshr[mi].dirty_evict,
                             u_core.u_dcache.mshr[mi].evict_addr);
                end
            end
        end
    endtask

    function automatic logic linux_lq_entry_has_owner(input int lq_idx);
        linux_lq_entry_has_owner = 1'b0;

        for (int lp = 0; lp < 2; lp++) begin
            if (u_core.u_lsu.load_issue_valid_r[lp] &&
                (u_core.u_lsu.load_issue_data_r[lp].lq_idx == LQ_IDX_BITS'(lq_idx)))
                linux_lq_entry_has_owner = 1'b1;
            if (u_core.u_lsu.load_issue_valid_rr[lp] &&
                (u_core.u_lsu.load_issue_data_rr[lp].lq_idx == LQ_IDX_BITS'(lq_idx)))
                linux_lq_entry_has_owner = 1'b1;
            if (u_core.u_lsu.load_wb_valid[lp] &&
                u_core.u_lsu.lq_result_valid_sel[lp] &&
                (u_core.u_lsu.lq_result_idx_sel[lp] == LQ_IDX_BITS'(lq_idx)))
                linux_lq_entry_has_owner = 1'b1;
            if (u_core.u_lsu.lq_result_valid[lp] &&
                (u_core.u_lsu.lq_result_idx[lp] == LQ_IDX_BITS'(lq_idx)))
                linux_lq_entry_has_owner = 1'b1;
        end

        if (u_core.u_lsu.p0_retry_valid_r &&
            (u_core.u_lsu.p0_retry_data_r.lq_idx == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.p1_retry_valid_r &&
            (u_core.u_lsu.p1_retry_data_r.lq_idx == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;

        if (u_core.u_lsu.fwd_hold_valid_r &&
            (u_core.u_lsu.fwd_hold_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.p0_dcache_hold_valid_r &&
            (u_core.u_lsu.p0_dcache_hold_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.p1_dcache_hold_valid_r &&
            (u_core.u_lsu.p1_dcache_hold_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.p1_fwd_hold_valid_r &&
            (u_core.u_lsu.p1_fwd_hold_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.p1_misalign_hold_valid_r &&
            (u_core.u_lsu.p1_misalign_hold_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;

        if (u_core.u_lsu.split_load_busy &&
            (u_core.u_lsu.split_load_data_r.lq_idx == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.mmio_resp_hold_valid_r &&
            (u_core.u_lsu.mmio_resp_load_data_r.lq_idx == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.amo_wb_valid_r &&
            (u_core.u_lsu.amo_wb_lq_idx_r == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;
        if (u_core.u_lsu.amo_wait_load_r &&
            (u_core.u_lsu.amo_data_r.lq_idx == LQ_IDX_BITS'(lq_idx)))
            linux_lq_entry_has_owner = 1'b1;

        for (int li = 0; li < 32; li++) begin
            if (u_core.u_lsu.lmb[li].valid &&
                (u_core.u_lsu.lmb[li].lq_idx == LQ_IDX_BITS'(lq_idx)))
                linux_lq_entry_has_owner = 1'b1;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int li = 0; li < LQ_DEPTH; li++) begin
                linux_lost_load_owner_count[li] <= 0;
            end
        end else if (linux_stop_lost_load_owner_en != 0) begin
            for (int li = 0; li < LQ_DEPTH; li++) begin
                if (u_core.u_lsu.u_load_queue.queue[li].valid &&
                    u_core.u_lsu.u_load_queue.queue[li].executed &&
                    !u_core.u_lsu.u_load_queue.queue[li].has_result &&
                    !linux_lq_entry_has_owner(li)) begin
                    linux_lost_load_owner_count[li] <=
                        linux_lost_load_owner_count[li] + 1;
                    if (linux_lost_load_owner_count[li] >=
                        linux_lost_load_owner_limit) begin
                        $display("[LINUX_STOP_LOST_LOAD_OWNER] cyc=%0d lq=%0d rob=%0d addr=%016h size=%0d pc0=%016h pc1=%016h lq_head=%0d lq_tail=%0d lq_count=%0d",
                                 sim_cycle,
                                 li,
                                 u_core.u_lsu.u_load_queue.queue[li].rob_idx,
                                 u_core.u_lsu.u_load_queue.queue[li].addr,
                                 u_core.u_lsu.u_load_queue.queue[li].size,
                                 u_core.rob_head_pc[0],
                                 u_core.rob_head_pc[1],
                                 u_core.u_lsu.u_load_queue.head_r,
                                 u_core.u_lsu.u_load_queue.tail_r,
                                 u_core.u_lsu.u_load_queue.count_r);
                        linux_dump_stall_debug();
                        linux_dump_load_owner_history(
                            li,
                            u_core.u_lsu.u_load_queue.queue[li].rob_idx,
                            u_core.u_lsu.u_load_queue.queue[li].addr);
                        $finish;
                    end
                end else begin
                    linux_lost_load_owner_count[li] <= 0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Early-kernel panic visibility probe (sim-only).
    //
    // WHY: under Verilator the S-mode kernel panics BEFORE earlycon
    // registration, so the panic message only reaches the in-RAM printk
    // log_buf and the UART stays silent; the boot then spins forever in
    // panic()'s mdelay blink loop (udelay PCs ffffffff80bba8xx and the
    // jal-udelay loop at ffffffff80bbb70e..718).  This looks like a "udelay
    // / time stall" from the outside but is really a silent early panic.
    //
    // This probe makes the failure visible: when the commit stream retires
    // the entry PC of panic()/die()/__warn() (and optionally _printk()),
    // dump the format-string argument directly from backdoor sim memory.
    // Format strings live in kernel .rodata, which is loaded from the boot
    // image and never written, so reading u_mem.mem (bypassing the cache
    // hierarchy) is safe and exact.
    //
    // VA -> mem index: with nokaslr the kernel image VA base
    // 0xffffffff_80000000 maps to load PA 0x80200000 (OpenSBI "Domain0 Next
    // Address"), and sim_memory is indexed by PA - 0x8000_0000, so
    //   idx = va - 64'hffffffff_80000000 + 64'h0020_0000.
    // Entry PCs come from the fw_payload vmlinux System.map and can be
    // overridden via +LINUX_PANIC_PC/+LINUX_DIE_PC/+LINUX_WARN_PC/
    // +LINUX_PRINTK_PC for a different payload.
    // -------------------------------------------------------------------------
    function automatic string linux_kva_string(input logic [63:0] va);
        logic [63:0] idx;
        logic [7:0]  b;
        string s;
        s = "";
        if ((va >= 64'hffff_ffff_8000_0000) &&
            (va <  64'hffff_ffff_8800_0000)) begin
            idx = va - 64'hffff_ffff_8000_0000 + 64'h0020_0000;
            for (int k = 0; k < 256; k++) begin
                if ((idx + 64'(k)) >= 64'(128 * 1024 * 1024))
                    break;
                b = u_mem.mem[int'(idx) + k];
                if (b == 8'h00)
                    break;
                if ((b >= 8'h20) && (b < 8'h7f))
                    s = {s, $sformatf("%c", b)};
                else if (b == 8'h0a)
                    s = {s, "\\n"};
                else
                    s = {s, "."};
            end
        end
        return s;
    endfunction

    always @(posedge clk) begin
        if (rst_n && (linux_panic_probe_en != 0) &&
            (u_core.commit_count != 0)) begin
            for (int ci = 0; ci < PIPE_WIDTH; ci++) begin
                if (ci < int'(u_core.commit_count)) begin
                    if ((u_core.rob_head_pc[ci] == linux_panic_pc) ||
                        (u_core.rob_head_pc[ci] == linux_die_pc) ||
                        (u_core.rob_head_pc[ci] == linux_warn_pc)) begin
                        $display("[LINUX_PANIC_PROBE] cyc=%0d pc=%016h ra=%016h a0=%016h a1=%016h a2=%016h priv=%0d satp=%016h",
                                 sim_cycle,
                                 u_core.rob_head_pc[ci],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[1]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[12]],
                                 u_core.csr_priv_mode,
                                 u_core.csr_satp);
                        $display("[LINUX_PANIC_PROBE] a0_str='%s' a1_str='%s'",
                                 linux_kva_string(
                                     u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]]),
                                 linux_kva_string(
                                     u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]]));
                        if (linux_stop_on_panic_en != 0) begin
                            $display("[LINUX_PANIC_PROBE] +LINUX_STOP_ON_PANIC set; stopping at cyc=%0d",
                                     sim_cycle);
                            $finish;
                        end
                    end else if ((linux_trace_printk_en != 0) &&
                                 (u_core.rob_head_pc[ci] == linux_printk_pc)) begin
                        $display("[LINUX_PRINTK] cyc=%0d a0=%016h fmt='%s' a1=%016h a1_str='%s'",
                                 sim_cycle,
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                                 linux_kva_string(
                                     u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]]),
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                                 linux_kva_string(
                                     u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]]));
                    end
                end
            end
        end
    end

    initial begin
        max_cycles = 100000;
        uart_log_fd = 0;
        uart_stdout_en = 1;
        smoke_check_en = 0;
        uart_fail_stop_en = 1;
        uart_fail_delay_cycles = 0;
        linux_trace_mmio_en = 0;
        linux_trace_load_pc_en = 0;
        linux_stop_on_trace_load_pc_en = 0;
        linux_trace_load_range_en = 0;
        linux_stop_on_trace_load_range_en = 0;
        linux_trace_load_pc = 64'd0;
        linux_stop_sideband_tval_en = 0;
        linux_stop_sideband_tval = 64'd0;
        linux_stop_trap_pc_en = 0;
        linux_stop_trap_tval_en = 0;
        linux_stop_trap_pc = 64'd0;
        linux_stop_trap_tval = 64'd0;
        linux_trace_line_en = 0;
        linux_trace_line = 64'd0;
        linux_trace_pa_line_en = 0;
        linux_trace_pa_line = 64'd0;
        linux_trace_preempt_pa_en = 0;
        linux_trace_preempt_pa = 64'd0;
        linux_trace_preempt_va_en = 0;
        linux_trace_preempt_va = 64'd0;
        linux_trace_l2_en = 0;
        linux_trace_trap_en = 0;
        linux_trace_fault_only_en = 0;
        linux_trace_fe_en = 0;
        linux_trace_amo_en = 0;
        linux_owner_hist_en = 0;
        linux_owner_hist_load_pc_en = 0;
        linux_owner_hist_load_pc = 64'd0;
        linux_owner_hist_pa_line_en = 0;
        linux_owner_hist_pa_line = 64'd0;
        linux_stop_lost_load_owner_en = 0;
        linux_lost_load_owner_limit = 256;
        linux_trace_commit_range_en = 0;
        linux_trace_regs_en = 0;
        linux_trace_sscratch_en = 0;
        linux_stop_on_sscratch_nonzero_en = 0;
        linux_stop_on_bad_kernel_sscratch_en = 0;
        linux_stop_on_low_ifetch_fault_en = 0;
        linux_stop_on_low_vm_fetch_en = 0;
        linux_stop_on_timer_boundary_en = 0;
        linux_stop_store_pc_en = 0;
        linux_stop_store_data_above_en = 0;
        linux_stop_store_pc = 64'd0;
        linux_stop_store_data_above = 64'd0;
        linux_stop_commit_rd_en = 0;
        linux_stop_commit_data_above_en = 0;
        linux_stop_commit_rd = 5'd0;
        linux_stop_commit_data_above = 64'd0;
        linux_stop_commit_pc_en = 0;
        linux_stop_commit_pc = 64'd0;
        linux_trace_pipe_en = 0;
        linux_trace_bru_en = 0;
        linux_trace_mmu_en = 0;
        linux_trace_clear_bss_en = 0;
        linux_trace_clear_bss_monitor_en = 0;
        linux_trace_cycle_window_en = 0;
        linux_stop_on_no_commit_en = 0;
        linux_no_commit_limit = 100000;
        linux_trace_cycle_lo = 0;
        linux_trace_cycle_hi = 2147483647;
        boot_hartid = 64'd0;
        boot_dtb_addr = 64'd0;
        linux_trace_commit_lo = 64'd0;
        linux_trace_commit_hi = 64'hffff_ffff_ffff_ffff;
        status_en = 0;
        status_interval = 1000000;
        uart_log_path = "";
        smoke_pattern = "RV64GC-V2 STAGE3 UART OK";
        uart_fail_panic_pattern = "Kernel panic";
        uart_fail_oops_pattern = "Oops";
        uart_fail_bug_pattern = "BUG:";

        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        void'($value$plusargs("STATUS_INTERVAL=%d", status_interval));
        void'($value$plusargs("LINUX_UART_FAIL_DELAY=%d", uart_fail_delay_cycles));
        void'($value$plusargs("UART_STDOUT=%d", uart_stdout_en));
        if ($value$plusargs("UART_LOGFILE=%s", uart_log_path)) begin
            uart_log_fd = $fopen(uart_log_path, "w");
        end
        status_en = $test$plusargs("STATUS") ? 1 : 0;
        perf_profile_en = $test$plusargs("PERF_PROFILE") ? 1 : 0;
        if ($value$plusargs("UART_PASS_PATTERN=%s", smoke_pattern)) begin
            for (int pi = 0; pi < smoke_pattern.len(); pi++) begin
                if (smoke_pattern.getc(pi) == 8'h5f)
                    smoke_pattern.putc(pi, 8'h20);
            end
            smoke_check_en = 1;
        end else begin
            smoke_check_en = $test$plusargs("UART_SMOKE_CHECK") ? 1 : 0;
        end
        if ($test$plusargs("LINUX_KEEP_RUNNING_AFTER_UART_FAILURE"))
            uart_fail_stop_en = 0;
        linux_trace_mmio_en = $test$plusargs("LINUX_TRACE_MMIO") ? 1 : 0;
        if ($value$plusargs("LINUX_TRACE_LOAD_PC=%h", linux_trace_load_pc))
            linux_trace_load_pc_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_TRACE_LOAD_PC"))
            linux_stop_on_trace_load_pc_en = 1;
        if ($test$plusargs("LINUX_TRACE_LOAD_RANGE"))
            linux_trace_load_range_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_TRACE_LOAD_RANGE"))
            linux_stop_on_trace_load_range_en = 1;
        if ($value$plusargs("LINUX_STOP_SIDEBAND_TVAL=%h", linux_stop_sideband_tval))
            linux_stop_sideband_tval_en = 1;
        if ($value$plusargs("LINUX_STOP_TRAP_PC=%h", linux_stop_trap_pc))
            linux_stop_trap_pc_en = 1;
        if ($value$plusargs("LINUX_STOP_TRAP_TVAL=%h", linux_stop_trap_tval))
            linux_stop_trap_tval_en = 1;
        if ($value$plusargs("LINUX_TRACE_LINE=%h", linux_trace_line)) begin
            linux_trace_line_en = 1;
            linux_trace_line[5:0] = 6'd0;
        end
        if ($value$plusargs("LINUX_TRACE_PA_LINE=%h", linux_trace_pa_line)) begin
            linux_trace_pa_line_en = 1;
            linux_trace_pa_line[5:0] = 6'd0;
        end
        if ($value$plusargs("LINUX_TRACE_PREEMPT_PA=%h", linux_trace_preempt_pa))
            linux_trace_preempt_pa_en = 1;
        if ($value$plusargs("LINUX_TRACE_PREEMPT_VA=%h", linux_trace_preempt_va))
            linux_trace_preempt_va_en = 1;
        if ($test$plusargs("LINUX_TRACE_L2"))
            linux_trace_l2_en = 1;
        if ($test$plusargs("LINUX_TRACE_TRAP"))
            linux_trace_trap_en = 1;
        if ($test$plusargs("LINUX_TRACE_FAULT_ONLY"))
            linux_trace_fault_only_en = 1;
        if ($test$plusargs("LINUX_TRACE_FE"))
            linux_trace_fe_en = 1;
        if ($test$plusargs("LINUX_TRACE_AMO"))
            linux_trace_amo_en = 1;
        if ($test$plusargs("LINUX_TRACE_LOAD_OWNER_HISTORY"))
            linux_owner_hist_en = 1;
        if ($value$plusargs("LINUX_OWNER_HIST_LOAD_PC=%h",
                            linux_owner_hist_load_pc))
            linux_owner_hist_load_pc_en = 1;
        if ($value$plusargs("LINUX_OWNER_HIST_PA_LINE=%h",
                            linux_owner_hist_pa_line)) begin
            linux_owner_hist_pa_line_en = 1;
            linux_owner_hist_pa_line[5:0] = 6'd0;
        end
        if ($test$plusargs("LINUX_STOP_ON_LOST_LOAD_OWNER"))
            linux_stop_lost_load_owner_en = 1;
        void'($value$plusargs("LINUX_LOST_LOAD_OWNER_LIMIT=%d",
                              linux_lost_load_owner_limit));
        if ($test$plusargs("LINUX_TRACE_REGS"))
            linux_trace_regs_en = 1;
        if ($test$plusargs("LINUX_TRACE_SSCRATCH"))
            linux_trace_sscratch_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_SSCRATCH_NONZERO"))
            linux_stop_on_sscratch_nonzero_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_BAD_KERNEL_SSCRATCH"))
            linux_stop_on_bad_kernel_sscratch_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_LOW_IFETCH_FAULT"))
            linux_stop_on_low_ifetch_fault_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_LOW_VM_FETCH"))
            linux_stop_on_low_vm_fetch_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_TIMER_BOUNDARY"))
            linux_stop_on_timer_boundary_en = 1;
        if ($value$plusargs("LINUX_STOP_STORE_PC=%h", linux_stop_store_pc))
            linux_stop_store_pc_en = 1;
        if ($value$plusargs("LINUX_STOP_STORE_DATA_ABOVE=%h", linux_stop_store_data_above))
            linux_stop_store_data_above_en = 1;
        if ($value$plusargs("LINUX_STOP_COMMIT_RD=%d", linux_stop_commit_rd))
            linux_stop_commit_rd_en = 1;
        if ($value$plusargs("LINUX_STOP_COMMIT_DATA_ABOVE=%h", linux_stop_commit_data_above))
            linux_stop_commit_data_above_en = 1;
        if ($value$plusargs("LINUX_STOP_COMMIT_PC=%h", linux_stop_commit_pc))
            linux_stop_commit_pc_en = 1;
        if ($test$plusargs("LINUX_TRACE_PIPE"))
            linux_trace_pipe_en = 1;
        if ($test$plusargs("LINUX_TRACE_BRU"))
            linux_trace_bru_en = 1;
        if ($test$plusargs("LINUX_TRACE_MMU"))
            linux_trace_mmu_en = 1;
        if ($test$plusargs("LINUX_TRACE_CLEAR_BSS"))
            linux_trace_clear_bss_en = 1;
        if ($test$plusargs("LINUX_TRACE_CLEAR_BSS_MONITOR"))
            linux_trace_clear_bss_monitor_en = 1;
        if ($value$plusargs("LINUX_TRACE_COMMIT_LO=%h", linux_trace_commit_lo))
            linux_trace_commit_range_en = 1;
        void'($value$plusargs("LINUX_TRACE_COMMIT_HI=%h", linux_trace_commit_hi));
        if ($value$plusargs("LINUX_TRACE_CYCLE_LO=%d", linux_trace_cycle_lo))
            linux_trace_cycle_window_en = 1;
        if ($value$plusargs("LINUX_TRACE_CYCLE_HI=%d", linux_trace_cycle_hi))
            linux_trace_cycle_window_en = 1;
        if ($test$plusargs("LINUX_STOP_ON_NO_COMMIT"))
            linux_stop_on_no_commit_en = 1;
        void'($value$plusargs("LINUX_NO_COMMIT_LIMIT=%d", linux_no_commit_limit));
        // Panic probe: ON by default (only fires on panic/die/__warn commits).
        // PCs are the fw_payload kernel's System.map entry points; override
        // via plusargs when the payload changes.
        linux_panic_probe_en  = 1;
        linux_stop_on_panic_en = $test$plusargs("LINUX_STOP_ON_PANIC") ? 1 : 0;
        linux_trace_printk_en  = $test$plusargs("LINUX_TRACE_PRINTK") ? 1 : 0;
        if ($test$plusargs("LINUX_NO_PANIC_PROBE"))
            linux_panic_probe_en = 0;
        linux_panic_pc  = 64'hffff_ffff_80bb_b490;  // T panic
        linux_die_pc    = 64'hffff_ffff_8000_4852;  // T die
        linux_warn_pc   = 64'hffff_ffff_80bb_b722;  // T __warn
        linux_printk_pc = 64'hffff_ffff_80bb_c096;  // T _printk
        void'($value$plusargs("LINUX_PANIC_PC=%h", linux_panic_pc));
        void'($value$plusargs("LINUX_DIE_PC=%h", linux_die_pc));
        void'($value$plusargs("LINUX_WARN_PC=%h", linux_warn_pc));
        void'($value$plusargs("LINUX_PRINTK_PC=%h", linux_printk_pc));
        void'($value$plusargs("BOOT_HARTID=%h", boot_hartid));
        void'($value$plusargs("DTB_ADDR=%h", boot_dtb_addr));
    end

    // Simulation platform boot contract for OpenSBI/Linux:
    // a0 is hartid and a1 is the flattened device tree pointer. The core RTL
    // remains an ASIC-style reset target; this block only models the prior
    // boot stage that would enter the core with ABI registers already seeded.
    initial begin
        #1;
        u_core.u_int_prf.regfile_copy0[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy1[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy2[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy3[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy4[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy5[10] = boot_hartid;
        u_core.u_int_prf.regfile_copy0[11] = boot_dtb_addr;
        u_core.u_int_prf.regfile_copy1[11] = boot_dtb_addr;
        u_core.u_int_prf.regfile_copy2[11] = boot_dtb_addr;
        u_core.u_int_prf.regfile_copy3[11] = boot_dtb_addr;
        u_core.u_int_prf.regfile_copy4[11] = boot_dtb_addr;
        u_core.u_int_prf.regfile_copy5[11] = boot_dtb_addr;
    end

    final begin
        if (uart_log_fd != 0)
            $fclose(uart_log_fd);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            linux_owner_hist_wr = 0;
            linux_owner_hist_count = 0;
            for (int hi = 0; hi < LOAD_OWNER_HIST_DEPTH; hi++) begin
                linux_owner_hist_event[hi] = 8'd0;
                linux_owner_hist_port[hi]  = 2'd0;
                linux_owner_hist_cycle[hi] = 64'd0;
                linux_owner_hist_pc[hi]    = 64'd0;
                linux_owner_hist_rob[hi]   = '0;
                linux_owner_hist_lq[hi]    = '0;
                linux_owner_hist_addr[hi]  = 64'd0;
                linux_owner_hist_flags[hi] = 64'd0;
            end
        end else if (linux_owner_hist_en != 0) begin
            for (int li = 0; li < 2; li++) begin
                if (u_core.iq_load_issue_candidate_valid[li] &&
                    u_core.lsu_load_issue_suppress_raw[li] &&
                    (linux_owner_hist_pc_match(u_core.iq_load_issue_data[li].pc) ||
                     linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr[li]))) begin
                    linux_owner_hist_record(
                        8'd1,
                        2'(li),
                        u_core.iq_load_issue_data[li].pc,
                        u_core.iq_load_issue_data[li].rob_idx,
                        u_core.iq_load_issue_data[li].lq_idx,
                        u_core.u_lsu.load_eff_addr[li],
                        {
                            53'd0,
                            u_core.flush_out.valid,
                            u_core.u_lsu.amo_busy,
                            ((li == 0) ? u_core.u_lsu.p0_partial_fwd_wait
                                       : u_core.u_lsu.p1_partial_fwd_wait),
                            ((li == 0) ? u_core.u_lsu.p0_sq_order_wait_block
                                       : u_core.u_lsu.p1_sq_order_wait_block),
                            u_core.u_lsu.load_addr_mmio[li],
                            u_core.u_lsu.load_cross_line[li],
                            u_core.u_lsu.load_addr_misaligned[li],
                            u_core.mem_fence_load_issue_suppress[li],
                            u_core.vm_serial_load_issue_suppress[li],
                            u_core.lsu_load_issue_suppress_raw[li],
                            u_core.iq_load_issue_candidate_valid[li]
                        });
                end

                if (u_core.u_lsu.load_issue_valid[li] &&
                    (linux_owner_hist_pc_match(u_core.u_lsu.load_issue_data[li].pc) ||
                     linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr[li]))) begin
                    linux_owner_hist_record(
                        8'd2,
                        2'(li),
                        u_core.u_lsu.load_issue_data[li].pc,
                        u_core.u_lsu.load_issue_data[li].rob_idx,
                        u_core.u_lsu.load_issue_data[li].lq_idx,
                        u_core.u_lsu.load_eff_addr[li],
                        {
                            53'd0,
                            u_core.flush_out.valid,
                            ((li == 0) ? u_core.u_lsu.p0_lmb_retry_req
                                       : u_core.u_lsu.p1_lmb_retry_req),
                            ((li == 0) ? u_core.u_lsu.lmb_free_avail
                                       : u_core.u_lsu.lmb_p1_alloc_avail),
                            u_core.dc_load_miss_retry[li],
                            u_core.dc_load_resp_hit[li],
                            u_core.dc_load_resp_valid[li],
                            ((li == 0) ? u_core.u_lsu.p0_miss_detect
                                       : u_core.u_lsu.p1_miss_detect),
                            u_core.dc_load_req_valid[li],
                            u_core.u_lsu.load_addr_mmio[li],
                            u_core.u_lsu.load_cross_line[li],
                            u_core.u_lsu.load_addr_misaligned[li]
                        });
                end

                if (u_core.dc_load_req_valid[li] &&
                    linux_owner_hist_addr_match(u_core.dc_load_req_addr[li])) begin
                    if ((li == 0) && u_core.u_lsu.split_load_req_valid) begin
                        linux_owner_hist_record(
                            8'd3,
                            2'(li),
                            u_core.u_lsu.split_load_data_r.pc,
                            u_core.u_lsu.split_load_data_r.rob_idx,
                            u_core.u_lsu.split_load_data_r.lq_idx,
                            u_core.dc_load_req_addr[li],
                            {
                                56'd0,
                                u_core.flush_out.valid,
                                u_core.u_lsu.split_load_req_valid,
                                u_core.u_lsu.p0_retry_fire,
                                u_core.dc_load_miss_retry[li],
                                u_core.dc_load_resp_hit[li],
                                u_core.dc_load_resp_valid[li],
                                u_core.dc_load_req_valid[li]
                            });
                    end else if ((li == 0) && u_core.u_lsu.p0_retry_fire) begin
                        linux_owner_hist_record(
                            8'd3,
                            2'(li),
                            u_core.u_lsu.p0_retry_data_r.pc,
                            u_core.u_lsu.p0_retry_data_r.rob_idx,
                            u_core.u_lsu.p0_retry_data_r.lq_idx,
                            u_core.dc_load_req_addr[li],
                            {
                                56'd0,
                                u_core.flush_out.valid,
                                u_core.u_lsu.split_load_req_valid,
                                u_core.u_lsu.p0_retry_fire,
                                u_core.dc_load_miss_retry[li],
                                u_core.dc_load_resp_hit[li],
                                u_core.dc_load_resp_valid[li],
                                u_core.dc_load_req_valid[li]
                            });
                    end else if (li == 0) begin
                        linux_owner_hist_record(
                            8'd3,
                            2'(li),
                            u_core.u_lsu.load_issue_data[0].pc,
                            u_core.u_lsu.load_issue_data[0].rob_idx,
                            u_core.u_lsu.load_issue_data[0].lq_idx,
                            u_core.dc_load_req_addr[li],
                            {
                                56'd0,
                                u_core.flush_out.valid,
                                u_core.u_lsu.split_load_req_valid,
                                u_core.u_lsu.p0_retry_fire,
                                u_core.dc_load_miss_retry[li],
                                u_core.dc_load_resp_hit[li],
                                u_core.dc_load_resp_valid[li],
                                u_core.dc_load_req_valid[li]
                            });
                    end else begin
                        linux_owner_hist_record(
                            8'd3,
                            2'(li),
                            u_core.u_lsu.p1_eff_data.pc,
                            u_core.u_lsu.p1_eff_data.rob_idx,
                            u_core.u_lsu.p1_eff_data.lq_idx,
                            u_core.dc_load_req_addr[li],
                            {
                                56'd0,
                                u_core.flush_out.valid,
                                u_core.u_lsu.p1_retry_valid_r,
                                u_core.u_lsu.dcache_conflict,
                                u_core.dc_load_miss_retry[li],
                                u_core.dc_load_resp_hit[li],
                                u_core.dc_load_resp_valid[li],
                                u_core.dc_load_req_valid[li]
                            });
                    end
                end
            end

            if (u_core.u_lsu.lq_exec_valid &&
                (linux_owner_hist_pc_match(u_core.u_lsu.load_issue_data[0].pc) ||
                 linux_owner_hist_addr_match(u_core.u_lsu.lq_exec_addr))) begin
                linux_owner_hist_record(
                    8'd18,
                    2'd0,
                    u_core.u_lsu.load_issue_data[0].pc,
                    u_core.u_lsu.lq_exec_rob_idx,
                    u_core.u_lsu.lq_exec_idx,
                    u_core.u_lsu.lq_exec_addr,
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.p0_partial_fwd_wait,
                     u_core.u_lsu.p0_fwd_hit,
                     u_core.u_lsu.dcache_load_req_valid[0]});
            end

            if (u_core.u_lsu.lq_exec1_valid &&
                (linux_owner_hist_pc_match(u_core.u_lsu.p1_eff_data.pc) ||
                 linux_owner_hist_addr_match(u_core.u_lsu.lq_exec1_addr))) begin
                linux_owner_hist_record(
                    8'd18,
                    2'd1,
                    u_core.u_lsu.p1_eff_data.pc,
                    u_core.u_lsu.lq_exec1_rob_idx,
                    u_core.u_lsu.lq_exec1_idx,
                    u_core.u_lsu.lq_exec1_addr,
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.p1_partial_fwd_wait,
                     u_core.u_lsu.p1_any_fwd_hit,
                     u_core.u_lsu.dcache_load_req_valid[1]});
            end

            if (u_core.u_lsu.p0_miss_detect &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[0])) begin
                linux_owner_hist_record(
                    8'd4,
                    2'd0,
                    u_core.u_lsu.load_issue_data_r[0].pc,
                    u_core.u_lsu.load_issue_data_r[0].rob_idx,
                    u_core.u_lsu.load_issue_data_r[0].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[0],
                    {
                        58'd0,
                        u_core.flush_out.valid,
                        u_core.u_lsu.load_pipe_flush_keep[0],
                        u_core.u_lsu.p0_miss_fill_hit,
                        u_core.u_lsu.p0_lmb_retry_req,
                        u_core.u_lsu.lmb_free_avail,
                        u_core.dc_load_miss_retry[0]
                    });
            end
            if (u_core.u_lsu.p1_miss_detect &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[1])) begin
                linux_owner_hist_record(
                    8'd5,
                    2'd1,
                    u_core.u_lsu.load_issue_data_r[1].pc,
                    u_core.u_lsu.load_issue_data_r[1].rob_idx,
                    u_core.u_lsu.load_issue_data_r[1].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[1],
                    {
                        58'd0,
                        u_core.flush_out.valid,
                        u_core.u_lsu.load_pipe_flush_keep[1],
                        u_core.u_lsu.p1_miss_fill_hit,
                        u_core.u_lsu.p1_lmb_retry_req,
                        u_core.u_lsu.lmb_p1_alloc_avail,
                        u_core.dc_load_miss_retry[1]
                    });
            end
            if (u_core.u_lsu.p0_miss_retry_req &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[0])) begin
                linux_owner_hist_record(
                    8'd16,
                    2'd0,
                    u_core.u_lsu.load_issue_data_r[0].pc,
                    u_core.u_lsu.load_issue_data_r[0].rob_idx,
                    u_core.u_lsu.load_issue_data_r[0].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[0],
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.dc_load_miss_retry[0],
                     u_core.u_lsu.p0_lmb_retry_req,
                     u_core.u_lsu.lmb_free_avail});
            end
            if (u_core.u_lsu.p1_miss_retry_req &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[1])) begin
                linux_owner_hist_record(
                    8'd17,
                    2'd1,
                    u_core.u_lsu.load_issue_data_r[1].pc,
                    u_core.u_lsu.load_issue_data_r[1].rob_idx,
                    u_core.u_lsu.load_issue_data_r[1].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[1],
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.dc_load_miss_retry[1],
                     u_core.u_lsu.p1_lmb_retry_req,
                     u_core.u_lsu.lmb_p1_alloc_avail});
            end
            if (u_core.u_lsu.lmb_any_match &&
                linux_owner_hist_addr_match(
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].line_addr)) begin
                linux_owner_hist_record(
                    8'd6,
                    2'd0,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].pc,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].rob_idx,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].lq_idx,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].line_addr,
                    {61'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.lmb_ready_any,
                     u_core.u_lsu.lmb_wb_port_free});
            end
            if (u_core.u_lsu.lmb_ready_any &&
                linux_owner_hist_addr_match(
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].line_addr)) begin
                linux_owner_hist_record(
                    8'd7,
                    2'd0,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].pc,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].rob_idx,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].lq_idx,
                    u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].line_addr,
                    {61'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.lmb_any_match,
                     u_core.u_lsu.lmb_wb_port_free});
            end
            for (int wi = 0; wi < 2; wi++) begin
                if (u_core.u_lsu.lq_result_valid[wi] &&
                    linux_owner_hist_addr_match(
                        u_core.u_lsu.u_load_queue.queue[
                            u_core.u_lsu.lq_result_idx[wi]].addr)) begin
                    linux_owner_hist_record(
                        8'd8,
                        2'(wi),
                        64'd0,
                        u_core.u_lsu.lq_result_rob_idx[wi],
                        u_core.u_lsu.lq_result_idx[wi],
                        u_core.u_lsu.u_load_queue.queue[
                            u_core.u_lsu.lq_result_idx[wi]].addr,
                        {62'd0,
                         u_core.u_lsu.u_load_queue.queue[
                            u_core.u_lsu.lq_result_idx[wi]].valid,
                         (u_core.u_lsu.u_load_queue.queue[
                            u_core.u_lsu.lq_result_idx[wi]].rob_idx ==
                          u_core.u_lsu.lq_result_rob_idx[wi])});
                end
            end
            if (u_core.dc_fill_snoop_valid &&
                linux_owner_hist_addr_match(u_core.dc_fill_snoop_addr)) begin
                linux_owner_hist_record(
                    8'd9,
                    2'd0,
                    64'd0,
                    '0,
                    '0,
                    u_core.dc_fill_snoop_addr,
                    64'd0);
            end
            if (u_core.u_lsu.p0_dcache_hit_valid &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[0])) begin
                linux_owner_hist_record(
                    8'd10,
                    2'd0,
                    u_core.u_lsu.load_issue_data_r[0].pc,
                    u_core.u_lsu.load_issue_data_r[0].rob_idx,
                    u_core.u_lsu.load_issue_data_r[0].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[0],
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.p0_dcache_hit_blocked,
                     u_core.u_lsu.p0_dcache_hold_valid_r,
                     u_core.u_lsu.amo_wb_valid_r});
            end
            if (u_core.u_lsu.p1_dcache_hit_valid &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[1])) begin
                linux_owner_hist_record(
                    8'd11,
                    2'd1,
                    u_core.u_lsu.load_issue_data_r[1].pc,
                    u_core.u_lsu.load_issue_data_r[1].rob_idx,
                    u_core.u_lsu.load_issue_data_r[1].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[1],
                    {60'd0,
                     u_core.flush_out.valid,
                     u_core.u_lsu.p1_dcache_hit_blocked,
                     u_core.u_lsu.p1_dcache_hold_valid_r,
                     u_core.u_lsu.p1_misalign_hold_valid_r});
            end
            if (u_core.u_lsu.p0_dcache_hit_blocked &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[0])) begin
                linux_owner_hist_record(
                    8'd12,
                    2'd0,
                    u_core.u_lsu.load_issue_data_r[0].pc,
                    u_core.u_lsu.load_issue_data_r[0].rob_idx,
                    u_core.u_lsu.load_issue_data_r[0].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[0],
                    {62'd0,
                     u_core.u_lsu.amo_wb_valid_r,
                     u_core.u_lsu.p0_dcache_hold_valid_r});
            end
            if (u_core.u_lsu.p1_dcache_hit_blocked &&
                linux_owner_hist_addr_match(u_core.u_lsu.load_eff_addr_r[1])) begin
                linux_owner_hist_record(
                    8'd13,
                    2'd1,
                    u_core.u_lsu.load_issue_data_r[1].pc,
                    u_core.u_lsu.load_issue_data_r[1].rob_idx,
                    u_core.u_lsu.load_issue_data_r[1].lq_idx,
                    u_core.u_lsu.load_eff_addr_r[1],
                    {62'd0,
                     u_core.u_lsu.p1_dcache_hold_valid_r,
                     u_core.u_lsu.p1_misalign_hold_valid_r});
            end
            if (u_core.u_lsu.fwd_hold_valid_r &&
                linux_owner_hist_addr_match(u_core.u_lsu.u_load_queue.queue[
                    u_core.u_lsu.fwd_hold_lq_idx_r].addr)) begin
                linux_owner_hist_record(
                    8'd14,
                    2'd0,
                    64'd0,
                    u_core.u_lsu.fwd_hold_rob_idx_r,
                    u_core.u_lsu.fwd_hold_lq_idx_r,
                    u_core.u_lsu.u_load_queue.queue[
                        u_core.u_lsu.fwd_hold_lq_idx_r].addr,
                    {63'd0,
                     u_core.u_lsu.fwd_hold_is_exc_r});
            end
            if (u_core.u_lsu.p1_fwd_hold_valid_r &&
                linux_owner_hist_addr_match(u_core.u_lsu.u_load_queue.queue[
                    u_core.u_lsu.p1_fwd_hold_lq_idx_r].addr)) begin
                linux_owner_hist_record(
                    8'd15,
                    2'd1,
                    64'd0,
                    u_core.u_lsu.p1_fwd_hold_rob_idx_r,
                    u_core.u_lsu.p1_fwd_hold_lq_idx_r,
                    u_core.u_lsu.u_load_queue.queue[
                        u_core.u_lsu.p1_fwd_hold_lq_idx_r].addr,
                    64'd0);
            end
        end
    end

    // ---- Wedge detector + LSU atomic-serialization dump -------------------
    always_ff @(posedge clk) begin
        if (rst_n && wedge_dump_en && !wedge_dumped) begin
            if (perf_minstret != wedge_prev_minstret) begin
                wedge_prev_minstret   <= perf_minstret;
                wedge_last_change_cyc <= sim_cycle;
            end else if ((sim_cycle - wedge_last_change_cyc) >= wedge_dump_thresh
                         && sim_cycle > wedge_dump_thresh) begin
                wedge_dumped <= 1'b1;
                $display("[WEDGE] cyc=%0d minstret=%0d stalled_for=%0d priv=%0d satp=%016h rob_head=%0d rob_tail=%0d rob_free=%0d last_commit_pc=%016h",
                         sim_cycle, perf_minstret, sim_cycle - wedge_last_change_cyc,
                         u_core.csr_priv_mode, u_core.csr_satp,
                         u_core.rob_head_idx, u_core.rob_tail_idx, u_core.rob_free_count,
                         last_commit_pc);
                $display("[WEDGE-SERIAL] amo_serial_block=%b | amo_busy=%b csb_deq=%b lmb_any=%b p0_dch=%b p1_dch=%b liv_r=%b liv_rr=%b p0_retry=%b p1_retry=%b p0_mretry=%b p1_mretry=%b fwd_hold=%b p1_fwd_hold=%b",
                         u_core.u_lsu.amo_serial_block,
                         u_core.u_lsu.amo_busy, u_core.u_lsu.csb_deq_valid,
                         u_core.u_lsu.lmb_any_valid,
                         u_core.u_lsu.p0_dcache_hold_valid_r, u_core.u_lsu.p1_dcache_hold_valid_r,
                         u_core.u_lsu.load_issue_valid_r, u_core.u_lsu.load_issue_valid_rr,
                         u_core.u_lsu.p0_retry_valid_r, u_core.u_lsu.p1_retry_valid_r,
                         u_core.u_lsu.p0_miss_retry_req, u_core.u_lsu.p1_miss_retry_req,
                         u_core.u_lsu.fwd_hold_valid_r, u_core.u_lsu.p1_fwd_hold_valid_r);
                $display("[WEDGE-AMO] amo_wait_load_r=%b amo_store_valid_r=%b amo_wb_valid_r=%b amo_forward_block=%b load_issue_suppress=%b%b",
                         u_core.u_lsu.amo_wait_load_r, u_core.u_lsu.amo_store_valid_r,
                         u_core.u_lsu.amo_wb_valid_r, u_core.u_lsu.amo_forward_block,
                         u_core.u_lsu.load_issue_suppress[1], u_core.u_lsu.load_issue_suppress[0]);
                $finish;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sim_cycle <= 0;
            smoke_idx <= 0;
            mmio_req_count <= 0;
            mmio_uart_rd_count <= 0;
            mmio_uart_wr_count <= 0;
            last_commit_pc <= 64'd0;
            last_commit_cycle <= 64'd0;
            last_commit_count <= 0;
            uart_fail_pending_r <= 1'b0;
            uart_fail_cycle_r <= 0;
            linux_commit_ring_wr <= 0;
            linux_commit_ring_count <= 0;
            linux_bru_ring_wr <= 0;
            linux_bru_ring_count <= 0;
            mem_read_addr_r <= 64'd0;
            mem_read_pending_r <= 1'b0;
            clear_bss_post_flush_pending <= 1'b0;
            clear_bss_a3_commit_seen_r <= 1'b0;
            clear_bss_last_commit_a3_r <= 64'd0;
            clear_bss_a3_issue_seen_r <= 1'b0;
            clear_bss_last_issue_a3_r <= 64'd0;
            clear_bss_exit_branch_seen_r <= 1'b0;
            linux_timer_boundary_seen_r <= 1'b0;
            for (int ti = 0; ti < TRACE_LOAD_TRACK; ti++) begin
                trace_load_valid[ti] <= 1'b0;
                trace_load_rob[ti] <= '0;
                trace_load_pdst[ti] <= '0;
                trace_load_pc[ti] <= 64'd0;
                trace_load_addr[ti] <= 64'd0;
            end
            for (int ri = 0; ri < LINUX_TRACE_RING_DEPTH; ri++) begin
                linux_commit_ring_cycle[ri] <= 64'd0;
                linux_commit_ring_pc[ri] <= 64'd0;
                linux_commit_ring_slot[ri] <= 3'd0;
                linux_commit_ring_group_count[ri] <= 3'd0;
                linux_bru_ring_cycle[ri] <= 64'd0;
                linux_bru_ring_pc[ri] <= 64'd0;
                linux_bru_ring_bp_target[ri] <= 64'd0;
                linux_bru_ring_target[ri] <= 64'd0;
                linux_bru_ring_rob[ri] <= '0;
                linux_bru_ring_port[ri] <= 3'd0;
                linux_bru_ring_op[ri] <= 3'd0;
                linux_bru_ring_bp_taken[ri] <= 1'b0;
                linux_bru_ring_taken[ri] <= 1'b0;
                linux_bru_ring_misp[ri] <= 1'b0;
            end
        end else begin
            sim_cycle <= sim_cycle + 1;

            if (linux_stop_on_low_ifetch_fault_en != 0) begin
                if (u_core.instr_vm_active &&
                    (u_core.frontend_fetch_priv_r != PRIV_M) &&
                    (((u_core.itlb_lookup_valid &&
                       u_core.itlb_fault &&
                       (u_core.itlb_lookup_va >= OPENSBI_TEXT_LO) &&
                       (u_core.itlb_lookup_va < OPENSBI_TEXT_HI)) ||
                      (u_core.ptw_fault_valid &&
                       u_core.ptw_fault_is_itlb &&
                       (u_core.ptw_fault_va >= OPENSBI_TEXT_LO) &&
                       (u_core.ptw_fault_va < OPENSBI_TEXT_HI)) ||
                      (u_core.fetch_exception_pending_r &&
                       (u_core.fetch_exception_pc_r >= OPENSBI_TEXT_LO) &&
                       (u_core.fetch_exception_pc_r < OPENSBI_TEXT_HI))))) begin
                    $display("[LINUX_STOP_LOW_IFETCH_FAULT] cyc=%0d priv=%0d fe_priv=%0d redir_priv=%0d instr_vm=%0b satp=%016h itlb_v=%0b itlb_fault=%0b itlb_va=%016h ptw_fault=%0b ptw_i=%0b ptw_va=%016h fe_pending=%0b fe_pc=%016h fe_code=%0d fe_mask=%0d fe_inject=%0b flush=%0b/%0b redirect=%016h trap=%0b mret=%0b sret=%0b ras_clear=%0b ras_tos=%0d ras_top=%016h ras_push=%0b/%016h ras_pop=%0b/%016h ras_restore=%0b/%0d/%0b/%016h f1=%016h req=%016h work_v=%0b work=%016h ic_req=%0b ic_addr=%016h pkt_count=%0d ftq_count=%0d",
                             sim_cycle,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.frontend_redirect_priv_c,
                             u_core.instr_vm_active,
                             u_core.csr_satp,
                             u_core.itlb_lookup_valid,
                             u_core.itlb_fault,
                             u_core.itlb_lookup_va,
                             u_core.ptw_fault_valid,
                             u_core.ptw_fault_is_itlb,
                             u_core.ptw_fault_va,
                             u_core.fetch_exception_pending_r,
                             u_core.fetch_exception_pc_r,
                             u_core.fetch_exception_code_r,
                             u_core.fetch_exception_context_mask_r,
                             u_core.fetch_exception_inject_c,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.redirect_pc,
                             u_core.trap_valid,
                             u_core.mret_commit,
                             u_core.sret_commit,
                             u_core.ras_context_clear_fe,
                             u_core.u_fetch_top.ras_tos,
                             u_core.u_fetch_top.ras_pop_addr,
                             u_core.u_fetch_top.ras_push_valid,
                             u_core.u_fetch_top.ras_push_addr,
                             u_core.u_fetch_top.ras_pop_valid,
                             u_core.u_fetch_top.ras_pop_addr,
                             u_core.ras_restore_valid_fe,
                             u_core.ras_restore_tos_fe,
                             u_core.ras_restore_top_valid_fe,
                             u_core.ras_restore_top_addr_fe,
                             u_core.u_fetch_top.f1_pc,
                             u_core.u_fetch_top.req_pc_c,
                             u_core.u_fetch_top.f2_work_valid_c,
                             u_core.u_fetch_top.f2_work_pc_c,
                             u_core.u_fetch_top.ic_req_valid,
                             u_core.u_fetch_top.ic_req_addr,
                             u_core.u_fetch_top.packet_buf_count,
                             u_core.u_fetch_top.ftq_count_ifu_to_wb);
                    $finish;
                end
            end

            if (linux_stop_on_low_vm_fetch_en != 0) begin
                if (u_core.instr_vm_active &&
                    (u_core.frontend_fetch_priv_r != PRIV_M) &&
                    (((u_core.u_fetch_top.f1_valid &&
                       (u_core.u_fetch_top.f1_pc >= OPENSBI_TEXT_LO) &&
                       (u_core.u_fetch_top.f1_pc < OPENSBI_TEXT_HI)) ||
                      (u_core.u_fetch_top.f2_work_valid_c &&
                       (u_core.u_fetch_top.f2_work_pc_c >= OPENSBI_TEXT_LO) &&
                       (u_core.u_fetch_top.f2_work_pc_c < OPENSBI_TEXT_HI)) ||
                      (u_core.u_fetch_top.req_redirect_c &&
                       (u_core.u_fetch_top.req_pc_c >= OPENSBI_TEXT_LO) &&
                       (u_core.u_fetch_top.req_pc_c < OPENSBI_TEXT_HI)) ||
                      (u_core.flush_out.valid &&
                       (u_core.frontend_redirect_priv_c != PRIV_M) &&
                       (u_core.flush_out.redirect_pc >= OPENSBI_TEXT_LO) &&
                       (u_core.flush_out.redirect_pc < OPENSBI_TEXT_HI))))) begin
                    $display("[LINUX_STOP_LOW_VM_FETCH] cyc=%0d priv=%0d fe_priv=%0d redir_priv=%0d instr_vm=%0b satp=%016h f1_v=%0b f1=%016h work_v=%0b work=%016h req_redir=%0b req=%016h bpu_redir=%0b bpu=%016h flush=%0b/%0b redirect=%016h trap=%0b mret=%0b sret=%0b ras_clear=%0b ras_tos=%0d ras_top=%016h ras_push=%0b/%016h ras_pop=%0b/%016h ras_restore=%0b/%0d/%0b/%016h bru0=%0b/%016h bru1=%0b/%016h quarantine=%0b last_pc=%016h last_commit_cyc=%0d rob_head=%0d rob_tail=%0d pkt_count=%0d ftq_count=%0d",
                             sim_cycle,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.frontend_redirect_priv_c,
                             u_core.instr_vm_active,
                             u_core.csr_satp,
                             u_core.u_fetch_top.f1_valid,
                             u_core.u_fetch_top.f1_pc,
                             u_core.u_fetch_top.f2_work_valid_c,
                             u_core.u_fetch_top.f2_work_pc_c,
                             u_core.u_fetch_top.req_redirect_c,
                             u_core.u_fetch_top.req_pc_c,
                             u_core.u_fetch_top.f2_bpu_redirect,
                             u_core.u_fetch_top.f2_bpu_target,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.redirect_pc,
                             u_core.trap_valid,
                             u_core.mret_commit,
                             u_core.sret_commit,
                             u_core.ras_context_clear_fe,
                             u_core.u_fetch_top.ras_tos,
                             u_core.u_fetch_top.ras_pop_addr,
                             u_core.u_fetch_top.ras_push_valid,
                             u_core.u_fetch_top.ras_push_addr,
                             u_core.u_fetch_top.ras_pop_valid,
                             u_core.u_fetch_top.ras_pop_addr,
                             u_core.ras_restore_valid_fe,
                             u_core.ras_restore_tos_fe,
                             u_core.ras_restore_top_valid_fe,
                             u_core.ras_restore_top_addr_fe,
                             u_core.bru0_early_redirect,
                             u_core.bru_target,
                             u_core.bru1_early_redirect,
                             u_core.bru1_target,
                             u_core.bru_redirect_quarantine_r,
                             last_commit_pc,
                             last_commit_cycle,
                             u_core.rob_head_idx,
                             u_core.rob_tail_idx,
                             u_core.u_fetch_top.packet_buf_count,
                             u_core.u_fetch_top.ftq_count_ifu_to_wb);
                    $finish;
                end
            end

            if (linux_trace_clear_bss_en != 0) begin
                if (clear_bss_post_flush_pending) begin
                    $display("[LINUX_CLEAR_BSS_POST_FLUSH] cyc=%0d rat_a3=%0d crat_a3=%0d a3=%016h rat_a4=%0d crat_a4=%0d a4=%016h head=%0d tail=%0d",
                             sim_cycle,
                             u_core.u_rename.u_rat.rat_table[13],
                             u_core.u_rename.u_rat.committed_rat[13],
                             u_core.u_int_prf.regfile_copy0[
                                 u_core.u_rename.u_rat.committed_rat[13]],
                             u_core.u_rename.u_rat.rat_table[14],
                             u_core.u_rename.u_rat.committed_rat[14],
                             u_core.u_int_prf.regfile_copy0[
                                 u_core.u_rename.u_rat.committed_rat[14]],
                             u_core.rob_head_idx,
                             u_core.rob_tail_idx);
                end
                clear_bss_post_flush_pending <= 1'b0;
            end

            if (u_core.commit_count != 0) begin
                last_commit_count <= u_core.commit_count;
                last_commit_cycle <= sim_cycle;
                for (int ci = 0; ci < PIPE_WIDTH; ci++) begin
                    if (ci < int'(u_core.commit_count)) begin
                        last_commit_pc <= u_core.rob_head_pc[ci];
                        linux_commit_ring_cycle[
                            (linux_commit_ring_wr + ci) % LINUX_TRACE_RING_DEPTH] <=
                            64'(sim_cycle);
                        linux_commit_ring_pc[
                            (linux_commit_ring_wr + ci) % LINUX_TRACE_RING_DEPTH] <=
                            u_core.rob_head_pc[ci];
                        linux_commit_ring_slot[
                            (linux_commit_ring_wr + ci) % LINUX_TRACE_RING_DEPTH] <=
                            ci[2:0];
                        linux_commit_ring_group_count[
                            (linux_commit_ring_wr + ci) % LINUX_TRACE_RING_DEPTH] <=
                            u_core.commit_count;
                        if ((linux_trace_commit_range_en != 0) &&
                            linux_trace_cycle_on &&
                            (u_core.rob_head_pc[ci] >= linux_trace_commit_lo) &&
                            (u_core.rob_head_pc[ci] < linux_trace_commit_hi)) begin
                            $display("[LINUX_COMMIT] cyc=%0d slot=%0d pc=%016h count=%0d priv=%0d",
                                     sim_cycle,
                                     ci,
                                     u_core.rob_head_pc[ci],
                                     u_core.commit_count,
                                     u_core.csr_priv_mode);
                            if (linux_trace_regs_en != 0) begin
                                $display("[LINUX_REGS] cyc=%0d pc=%016h ra=%016h sp=%016h tp=%016h s1=%016h s2=%016h s3=%016h s4=%016h a0=%016h a1=%016h a2=%016h a3=%016h a4=%016h a5=%016h satp=%016h",
                                         sim_cycle,
                                         u_core.rob_head_pc[ci],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[1]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[2]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[4]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[9]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[18]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[19]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[20]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[12]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[13]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[14]],
                                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[15]],
                                         u_core.csr_satp);
                            end
                        end
                        if ((linux_trace_clear_bss_monitor_en != 0) &&
                            (u_core.rob_head_pc[ci] == 64'hffff_ffff_8000_00f6) &&
                            u_core.commit_out[ci].valid &&
                            u_core.commit_out[ci].rd_valid &&
                            (u_core.commit_out[ci].rd_arch == 5'd13)) begin
                            if (clear_bss_a3_commit_seen_r &&
                                (u_core.u_int_prf.regfile_copy0[
                                    u_core.commit_out[ci].pdst] <
                                 clear_bss_last_commit_a3_r)) begin
                                $display("[LINUX_CLEAR_BSS_A3_COMMIT_BACKWARD] cyc=%0d slot=%0d pc=%016h old_a3=%016h new_a3=%016h pdst=%0d old_pdst=%0d rat_a3=%0d crat_a3=%0d head=%0d tail=%0d commit_count=%0d flush=%0b/%0b redirect=%016h",
                                         sim_cycle,
                                         ci,
                                         u_core.rob_head_pc[ci],
                                         clear_bss_last_commit_a3_r,
                                         u_core.u_int_prf.regfile_copy0[
                                             u_core.commit_out[ci].pdst],
                                         u_core.commit_out[ci].pdst,
                                         u_core.commit_out[ci].old_pdst,
                                         u_core.u_rename.u_rat.rat_table[13],
                                         u_core.u_rename.u_rat.committed_rat[13],
                                         u_core.rob_head_idx,
                                         u_core.rob_tail_idx,
                                         u_core.commit_count,
                                         u_core.flush_out.valid,
                                         u_core.flush_out.full_flush,
                                         u_core.flush_out.redirect_pc);
                            end
                            clear_bss_a3_commit_seen_r <= 1'b1;
                            clear_bss_last_commit_a3_r <=
                                u_core.u_int_prf.regfile_copy0[
                                    u_core.commit_out[ci].pdst];
                        end
                        if ((linux_stop_commit_rd_en != 0) &&
                            (linux_stop_commit_data_above_en != 0) &&
                            linux_trace_cycle_on &&
                            u_core.commit_out[ci].valid &&
                            u_core.commit_out[ci].rd_valid &&
                            (u_core.commit_out[ci].rd_arch == linux_stop_commit_rd) &&
                            (u_core.u_int_prf.regfile_copy0[
                                u_core.commit_out[ci].pdst] >
                             linux_stop_commit_data_above)) begin
                            $display("[LINUX_STOP_COMMIT_DATA_ABOVE] cyc=%0d slot=%0d pc=%016h rd=%0d pdst=%0d data=%016h limit=%016h priv=%0d commit_count=%0d flush=%0b/%0b redirect=%016h",
                                     sim_cycle,
                                     ci,
                                     u_core.rob_head_pc[ci],
                                     u_core.commit_out[ci].rd_arch,
                                     u_core.commit_out[ci].pdst,
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.commit_out[ci].pdst],
                                     linux_stop_commit_data_above,
                                     u_core.csr_priv_mode,
                                     u_core.commit_count,
                                     u_core.flush_out.valid,
                                     u_core.flush_out.full_flush,
                                     u_core.flush_out.redirect_pc);
                            for (int cj = 0; cj < PIPE_WIDTH; cj++) begin
                                if (cj < int'(u_core.commit_count)) begin
                                    $display("[LINUX_STOP_COMMIT_SLOT] cyc=%0d slot=%0d pc=%016h head_v=%0b ready=%0b out_v=%0b rdv=%0b rd=%0d pdst=%0d old=%0d data=%016h exc=%0b br=%0b misp=%0b sret=%0b mret=%0b",
                                             sim_cycle,
                                             cj,
                                             u_core.rob_head_pc[cj],
                                             u_core.rob_head_valid[cj],
                                             u_core.rob_head_ready[cj],
                                             u_core.commit_out[cj].valid,
                                             u_core.commit_out[cj].rd_valid,
                                             u_core.commit_out[cj].rd_arch,
                                             u_core.commit_out[cj].pdst,
                                             u_core.commit_out[cj].old_pdst,
                                             u_core.u_int_prf.regfile_copy0[
                                                 u_core.commit_out[cj].pdst],
                                             u_core.rob_head_has_exception[cj],
                                             u_core.rob_head_is_branch[cj],
                                             u_core.rob_head_branch_mispredict[cj],
                                             u_core.rob_head_is_sret[cj],
                                             u_core.rob_head_is_mret[cj]);
                                end
                            end
                            $display("[LINUX_COMMIT_RING_BEGIN] cyc=%0d count=%0d wr=%0d",
                                     sim_cycle,
                                     linux_commit_ring_count,
                                     linux_commit_ring_wr);
                            for (int rk = 0; rk < LINUX_TRACE_RING_DEPTH; rk++) begin
                                if (rk < linux_commit_ring_count) begin
                                    $display("[LINUX_COMMIT_RING] ord=%0d cyc=%0d slot=%0d group=%0d pc=%016h",
                                             rk,
                                             linux_commit_ring_cycle[
                                                 (linux_commit_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_commit_ring_count +
                                                  rk) % LINUX_TRACE_RING_DEPTH],
                                             linux_commit_ring_slot[
                                                 (linux_commit_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_commit_ring_count +
                                                  rk) % LINUX_TRACE_RING_DEPTH],
                                             linux_commit_ring_group_count[
                                                 (linux_commit_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_commit_ring_count +
                                                  rk) % LINUX_TRACE_RING_DEPTH],
                                             linux_commit_ring_pc[
                                                 (linux_commit_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_commit_ring_count +
                                                  rk) % LINUX_TRACE_RING_DEPTH]);
                                end
                            end
                            $display("[LINUX_BRU_RING_BEGIN] cyc=%0d count=%0d wr=%0d",
                                     sim_cycle,
                                     linux_bru_ring_count,
                                     linux_bru_ring_wr);
                            for (int bk = 0; bk < LINUX_TRACE_RING_DEPTH; bk++) begin
                                if (bk < linux_bru_ring_count) begin
                                    $display("[LINUX_BRU_RING] ord=%0d cyc=%0d port=%0d pc=%016h rob=%0d op=%0d bp=%0b/%016h taken=%0b target=%016h misp=%0b",
                                             bk,
                                             linux_bru_ring_cycle[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_port[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_pc[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_rob[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_op[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_bp_taken[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_bp_target[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_taken[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_target[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH],
                                             linux_bru_ring_misp[
                                                 (linux_bru_ring_wr +
                                                  LINUX_TRACE_RING_DEPTH -
                                                  linux_bru_ring_count +
                                                  bk) % LINUX_TRACE_RING_DEPTH]);
                                end
                            end
                            $finish;
                        end
                        if ((linux_stop_commit_pc_en != 0) &&
                            linux_trace_cycle_on &&
                            (u_core.rob_head_pc[ci] == linux_stop_commit_pc)) begin
                            $display("[LINUX_STOP_COMMIT_PC] cyc=%0d slot=%0d pc=%016h priv=%0d commit_count=%0d flush=%0b/%0b redirect=%016h ra=%016h sp=%016h tp=%016h a0=%016h a1=%016h a2=%016h a3=%016h a4=%016h a5=%016h s5=%016h satp=%016h",
                                     sim_cycle,
                                     ci,
                                     u_core.rob_head_pc[ci],
                                     u_core.csr_priv_mode,
                                     u_core.commit_count,
                                     u_core.flush_out.valid,
                                     u_core.flush_out.full_flush,
                                     u_core.flush_out.redirect_pc,
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[1]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[2]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[4]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[10]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[11]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[12]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[13]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[14]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[15]],
                                     u_core.u_int_prf.regfile_copy0[
                                         u_core.u_rename.u_rat.committed_rat[21]],
                                     u_core.csr_satp);
                            $finish;
                        end
                    end
                end
                linux_commit_ring_wr <=
                    (linux_commit_ring_wr + int'(u_core.commit_count)) %
                    LINUX_TRACE_RING_DEPTH;
                if ((linux_commit_ring_count + int'(u_core.commit_count)) >
                    LINUX_TRACE_RING_DEPTH) begin
                    linux_commit_ring_count <= LINUX_TRACE_RING_DEPTH;
                end else begin
                    linux_commit_ring_count <=
                        linux_commit_ring_count + int'(u_core.commit_count);
                end
            end

            if (u_core.bru_issue) begin
                linux_bru_ring_cycle[linux_bru_ring_wr] <= 64'(sim_cycle);
                linux_bru_ring_pc[linux_bru_ring_wr] <= u_core.iq0_issue_data[0].pc;
                linux_bru_ring_bp_target[linux_bru_ring_wr] <=
                    u_core.iq0_issue_data[0].bp_target;
                linux_bru_ring_target[linux_bru_ring_wr] <= u_core.bru_target;
                linux_bru_ring_rob[linux_bru_ring_wr] <=
                    u_core.iq0_issue_data[0].rob_idx;
                linux_bru_ring_port[linux_bru_ring_wr] <= 3'd0;
                linux_bru_ring_op[linux_bru_ring_wr] <= u_core.iq0_issue_data[0].br_op;
                linux_bru_ring_bp_taken[linux_bru_ring_wr] <=
                    u_core.iq0_issue_data[0].bp_taken;
                linux_bru_ring_taken[linux_bru_ring_wr] <= u_core.bru_taken;
                linux_bru_ring_misp[linux_bru_ring_wr] <= u_core.bru_mispredict;
            end
            if (u_core.bru1_issue) begin
                linux_bru_ring_cycle[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= 64'(sim_cycle);
                linux_bru_ring_pc[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.iq0_issue_data[1].pc;
                linux_bru_ring_bp_target[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.iq0_issue_data[1].bp_target;
                linux_bru_ring_target[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.bru1_target;
                linux_bru_ring_rob[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.iq0_issue_data[1].rob_idx;
                linux_bru_ring_port[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= 3'd1;
                linux_bru_ring_op[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.iq0_issue_data[1].br_op;
                linux_bru_ring_bp_taken[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.iq0_issue_data[1].bp_taken;
                linux_bru_ring_taken[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.bru1_taken;
                linux_bru_ring_misp[
                    (linux_bru_ring_wr + (u_core.bru_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH] <= u_core.bru1_mispredict;
            end
            if (u_core.bru_issue || u_core.bru1_issue) begin
                linux_bru_ring_wr <=
                    (linux_bru_ring_wr +
                     (u_core.bru_issue ? 1 : 0) +
                     (u_core.bru1_issue ? 1 : 0)) %
                    LINUX_TRACE_RING_DEPTH;
                if ((linux_bru_ring_count +
                     (u_core.bru_issue ? 1 : 0) +
                     (u_core.bru1_issue ? 1 : 0)) >
                    LINUX_TRACE_RING_DEPTH) begin
                    linux_bru_ring_count <= LINUX_TRACE_RING_DEPTH;
                end else begin
                    linux_bru_ring_count <= linux_bru_ring_count +
                        (u_core.bru_issue ? 1 : 0) +
                        (u_core.bru1_issue ? 1 : 0);
                end
            end

            if (((linux_trace_sscratch_en != 0) ||
                 (linux_stop_on_bad_kernel_sscratch_en != 0)) &&
                linux_trace_cycle_on) begin
                if ((linux_trace_sscratch_en != 0) &&
                    (u_core.trap_valid || u_core.sret_commit || u_core.mret_commit)) begin
                    $display("[LINUX_SSCRATCH_EVENT] cyc=%0d trap=%0b irq=%0b trap_pc=%016h cause=%016h to_s=%0b sret=%0b mret=%0b head_pc=%016h priv=%0d mstatus=%016h spp=%0b spie=%0b sie=%0b sscratch=%016h sepc=%016h scause=%016h",
                             sim_cycle,
                             u_core.trap_valid,
                             u_core.trap_is_interrupt,
                             u_core.trap_pc,
                             u_core.trap_cause,
                             u_core.commit_trap_to_supervisor,
                             u_core.sret_commit,
                             u_core.mret_commit,
                             u_core.rob_head_pc[0],
                             u_core.csr_priv_mode,
                             u_core.u_csr_file.mstatus_r,
                             u_core.u_csr_file.mstatus_r[8],
                             u_core.u_csr_file.mstatus_r[5],
                             u_core.u_csr_file.mstatus_r[1],
                             u_core.u_csr_file.sscratch_r,
                             u_core.csr_sepc,
                             u_core.u_csr_file.scause_r);
                end
                if ((linux_trace_sscratch_en != 0) &&
                    u_core.iq2_issue_valid[0] &&
                    (u_core.iq2_issue_data[0].fu_type == FU_CSR) &&
                    (u_core.iq2_issue_data[0].csr_addr == CSR_SSCRATCH)) begin
                    $display("[LINUX_SSCRATCH_CSR_ISSUE] cyc=%0d pc=%016h rob=%0d addr=%03h op=%0d wdata=%016h rdata=%016h illegal=%0b priv=%0d mstatus=%016h sscratch=%016h",
                             sim_cycle,
                             u_core.iq2_issue_data[0].pc,
                             u_core.iq2_issue_data[0].rob_idx,
                             u_core.iq2_issue_data[0].csr_addr,
                             u_core.iq2_issue_data[0].csr_op,
                             u_core.csr_exec_wdata,
                             u_core.csr_read_data,
                             u_core.csr_access_illegal,
                             u_core.csr_priv_mode,
                             u_core.u_csr_file.mstatus_r,
                             u_core.u_csr_file.sscratch_r);
                end
                if (u_core.csr_commit_valid &&
                    (u_core.csr_commit_addr == CSR_SSCRATCH)) begin
                    if (linux_trace_sscratch_en != 0) begin
                        $display("[LINUX_SSCRATCH_CSR_COMMIT] cyc=%0d pc=%016h addr=%03h op=%0d wdata=%016h priv=%0d mstatus_before=%016h sscratch_before=%016h",
                                 sim_cycle,
                                 u_core.rob_head_pc[0],
                                 u_core.csr_commit_addr,
                                 u_core.csr_commit_op,
                                 u_core.csr_commit_wdata,
                                 u_core.csr_priv_mode,
                                 u_core.u_csr_file.mstatus_r,
                                 u_core.u_csr_file.sscratch_r);
                    end
                    if ((linux_stop_on_bad_kernel_sscratch_en != 0) &&
                        (u_core.rob_head_pc[0] == 64'hffff_ffff_805d_abf0) &&
                        u_core.u_csr_file.mstatus_r[8] &&
                        (u_core.u_csr_file.sscratch_r != 64'd0)) begin
                        $display("[LINUX_STOP_BAD_KERNEL_SSCRATCH] cyc=%0d pc=%016h wdata=%016h mstatus=%016h sscratch_before=%016h sepc=%016h scause=%016h",
                                 sim_cycle,
                                 u_core.rob_head_pc[0],
                                 u_core.csr_commit_wdata,
                                 u_core.u_csr_file.mstatus_r,
                                 u_core.u_csr_file.sscratch_r,
                                 u_core.csr_sepc,
                                 u_core.u_csr_file.scause_r);
                        $finish;
                    end
                    if ((linux_stop_on_sscratch_nonzero_en != 0) &&
                        (u_core.csr_commit_wdata != 64'd0)) begin
                        $display("[LINUX_STOP_SSCRATCH_NONZERO] cyc=%0d pc=%016h wdata=%016h mstatus=%016h spp=%0b spie=%0b sie=%0b sepc=%016h scause=%016h",
                                 sim_cycle,
                                 u_core.rob_head_pc[0],
                                 u_core.csr_commit_wdata,
                                 u_core.u_csr_file.mstatus_r,
                                 u_core.u_csr_file.mstatus_r[8],
                                 u_core.u_csr_file.mstatus_r[5],
                                 u_core.u_csr_file.mstatus_r[1],
                                 u_core.csr_sepc,
                                 u_core.u_csr_file.scause_r);
                        $finish;
                    end
                end
            end

            if (linux_trace_clear_bss_monitor_en != 0) begin
                if (u_core.bru_issue &&
                    (u_core.iq0_issue_data[0].pc == 64'hffff_ffff_8000_00f8)) begin
                    if (!clear_bss_exit_branch_seen_r &&
                        (u_core.bypassed_data[0] >= u_core.bypassed_data[1])) begin
                        $display("[LINUX_CLEAR_BSS_EXIT_BRANCH] cyc=%0d port=0 rob=%0d a3=%016h a4=%016h rs1p=%0d rs2p=%0d bp=%0b/%016h taken=%0b target=%016h misp=%0b rat_a3=%0d crat_a3=%0d head=%0d tail=%0d commit_count=%0d",
                                 sim_cycle,
                                 u_core.iq0_issue_data[0].rob_idx,
                                 u_core.bypassed_data[0],
                                 u_core.bypassed_data[1],
                                 u_core.iq0_issue_data[0].rs1_phys,
                                 u_core.iq0_issue_data[0].rs2_phys,
                                 u_core.iq0_issue_data[0].bp_taken,
                                 u_core.iq0_issue_data[0].bp_target,
                                 u_core.bru_taken,
                                 u_core.bru_taken_target,
                                 u_core.bru_mispredict,
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_rename.u_rat.committed_rat[13],
                                 u_core.rob_head_idx,
                                 u_core.rob_tail_idx,
                                 u_core.commit_count);
                        clear_bss_exit_branch_seen_r <= 1'b1;
                    end
                    if (clear_bss_a3_issue_seen_r &&
                        (u_core.bypassed_data[0] < clear_bss_last_issue_a3_r)) begin
                        $display("[LINUX_CLEAR_BSS_A3_BRANCH_BACKWARD] cyc=%0d rob=%0d old_a3=%016h new_a3=%016h rs1p=%0d rs2p=%0d rs2=%016h bp=%0b/%016h taken=%0b target=%016h misp=%0b rat_a3=%0d crat_a3=%0d head=%0d tail=%0d",
                                 sim_cycle,
                                 u_core.iq0_issue_data[0].rob_idx,
                                 clear_bss_last_issue_a3_r,
                                 u_core.bypassed_data[0],
                                 u_core.iq0_issue_data[0].rs1_phys,
                                 u_core.iq0_issue_data[0].rs2_phys,
                                 u_core.bypassed_data[1],
                                 u_core.iq0_issue_data[0].bp_taken,
                                 u_core.iq0_issue_data[0].bp_target,
                                 u_core.bru_taken,
                                 u_core.bru_taken_target,
                                 u_core.bru_mispredict,
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_rename.u_rat.committed_rat[13],
                                 u_core.rob_head_idx,
                                 u_core.rob_tail_idx);
                    end
                    clear_bss_a3_issue_seen_r <= 1'b1;
                    clear_bss_last_issue_a3_r <= u_core.bypassed_data[0];
                end
                if (u_core.bru1_issue &&
                    (u_core.iq0_issue_data[1].pc == 64'hffff_ffff_8000_00f8)) begin
                    if (!clear_bss_exit_branch_seen_r &&
                        (u_core.bypassed_data[2] >= u_core.bypassed_data[3])) begin
                        $display("[LINUX_CLEAR_BSS_EXIT_BRANCH] cyc=%0d port=1 rob=%0d a3=%016h a4=%016h rs1p=%0d rs2p=%0d bp=%0b/%016h taken=%0b target=%016h misp=%0b rat_a3=%0d crat_a3=%0d head=%0d tail=%0d commit_count=%0d",
                                 sim_cycle,
                                 u_core.iq0_issue_data[1].rob_idx,
                                 u_core.bypassed_data[2],
                                 u_core.bypassed_data[3],
                                 u_core.iq0_issue_data[1].rs1_phys,
                                 u_core.iq0_issue_data[1].rs2_phys,
                                 u_core.iq0_issue_data[1].bp_taken,
                                 u_core.iq0_issue_data[1].bp_target,
                                 u_core.bru1_taken,
                                 u_core.bru1_taken_target,
                                 u_core.bru1_mispredict,
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_rename.u_rat.committed_rat[13],
                                 u_core.rob_head_idx,
                                 u_core.rob_tail_idx,
                                 u_core.commit_count);
                        clear_bss_exit_branch_seen_r <= 1'b1;
                    end
                    if (clear_bss_a3_issue_seen_r &&
                        (u_core.bypassed_data[2] < clear_bss_last_issue_a3_r)) begin
                        $display("[LINUX_CLEAR_BSS_A3_BRANCH_BACKWARD] cyc=%0d rob=%0d old_a3=%016h new_a3=%016h rs1p=%0d rs2p=%0d rs2=%016h bp=%0b/%016h taken=%0b target=%016h misp=%0b rat_a3=%0d crat_a3=%0d head=%0d tail=%0d",
                                 sim_cycle,
                                 u_core.iq0_issue_data[1].rob_idx,
                                 clear_bss_last_issue_a3_r,
                                 u_core.bypassed_data[2],
                                 u_core.iq0_issue_data[1].rs1_phys,
                                 u_core.iq0_issue_data[1].rs2_phys,
                                 u_core.bypassed_data[3],
                                 u_core.iq0_issue_data[1].bp_taken,
                                 u_core.iq0_issue_data[1].bp_target,
                                 u_core.bru1_taken,
                                 u_core.bru1_taken_target,
                                 u_core.bru1_mispredict,
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_rename.u_rat.committed_rat[13],
                                 u_core.rob_head_idx,
                                 u_core.rob_tail_idx);
                    end
                    clear_bss_a3_issue_seen_r <= 1'b1;
                    clear_bss_last_issue_a3_r <= u_core.bypassed_data[2];
                end
            end

            if (linux_trace_clear_bss_en != 0) begin
                if (u_core.bru_issue &&
                    (u_core.iq0_issue_data[0].pc == 64'hffff_ffff_8000_00f8)) begin
                    $display("[LINUX_CLEAR_BSS_BRU0] cyc=%0d rob=%0d rs1p=%0d rs2p=%0d rs1=%016h rs2=%016h bp=%0b/%016h taken=%0b target=%016h taken_target=%016h misp=%0b",
                             sim_cycle,
                             u_core.iq0_issue_data[0].rob_idx,
                             u_core.iq0_issue_data[0].rs1_phys,
                             u_core.iq0_issue_data[0].rs2_phys,
                             u_core.bypassed_data[0],
                             u_core.bypassed_data[1],
                             u_core.iq0_issue_data[0].bp_taken,
                             u_core.iq0_issue_data[0].bp_target,
                             u_core.bru_taken,
                             u_core.bru_target,
                             u_core.bru_taken_target,
                             u_core.bru_mispredict);
                end
                if (u_core.bru1_issue &&
                    (u_core.iq0_issue_data[1].pc == 64'hffff_ffff_8000_00f8)) begin
                    $display("[LINUX_CLEAR_BSS_BRU1] cyc=%0d rob=%0d rs1p=%0d rs2p=%0d rs1=%016h rs2=%016h bp=%0b/%016h taken=%0b target=%016h taken_target=%016h misp=%0b",
                             sim_cycle,
                             u_core.iq0_issue_data[1].rob_idx,
                             u_core.iq0_issue_data[1].rs1_phys,
                             u_core.iq0_issue_data[1].rs2_phys,
                             u_core.bypassed_data[2],
                             u_core.bypassed_data[3],
                             u_core.iq0_issue_data[1].bp_taken,
                             u_core.iq0_issue_data[1].bp_target,
                             u_core.bru1_taken,
                             u_core.bru1_target,
                             u_core.bru1_taken_target,
                             u_core.bru1_mispredict);
                end
                for (int ci = 0; ci < PIPE_WIDTH; ci++) begin
                    if ((ci < int'(u_core.commit_count)) &&
                        u_core.rob_head_branch_mispredict[ci] &&
                        (u_core.rob_head_pc[ci] == 64'hffff_ffff_8000_00f8)) begin
                        $display("[LINUX_CLEAR_BSS_FLUSH] cyc=%0d slot=%0d count=%0d redirect=%016h rat_a3=%0d crat_a3=%0d a3=%016h rat_a4=%0d crat_a4=%0d a4=%016h head=%0d tail=%0d",
                                 sim_cycle,
                                 ci,
                                 u_core.commit_count,
                                 u_core.flush_out.redirect_pc,
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_rename.u_rat.committed_rat[13],
                                 u_core.u_int_prf.regfile_copy0[
                                     u_core.u_rename.u_rat.committed_rat[13]],
                                 u_core.u_rename.u_rat.rat_table[14],
                                 u_core.u_rename.u_rat.committed_rat[14],
                                 u_core.u_int_prf.regfile_copy0[
                                     u_core.u_rename.u_rat.committed_rat[14]],
                                 u_core.rob_head_idx,
                                 u_core.rob_tail_idx);
                        for (int si = 0; si < PIPE_WIDTH; si++) begin
                            $display("[LINUX_CLEAR_BSS_SLOT] cyc=%0d slot=%0d v=%0b r=%0b pc=%016h can=%0b rdv=%0b arch=%0d pdst=%0d old=%0d br=%0b misp=%0b target=%016h",
                                     sim_cycle,
                                     si,
                                     u_core.rob_head_valid[si],
                                     u_core.rob_head_ready[si],
                                     u_core.rob_head_pc[si],
                                     u_core.commit_out[si].valid,
                                     u_core.commit_out[si].rd_valid,
                                     u_core.commit_out[si].rd_arch,
                                     u_core.commit_out[si].pdst,
                                     u_core.commit_out[si].old_pdst,
                                     u_core.rob_head_is_branch[si],
                                     u_core.rob_head_branch_mispredict[si],
                                     u_core.rob_head_branch_target[si]);
                        end
                        clear_bss_post_flush_pending <= 1'b1;
                    end
                end
            end

            if ((linux_stop_sideband_tval_en != 0) &&
                u_core.rob_sideband_exc_valid &&
                (u_core.rob_sideband_exc_tval == linux_stop_sideband_tval) &&
                linux_trace_cycle_on) begin
                $display("[LINUX_STOP_SIDEBAND_TVAL] cyc=%0d rob=%0d rob_pc=%016h code=%0d tval=%016h rob_fire=%0b rob_valid=%0b alloc_conflict=%0b not_flushed=%0b ptw_data=%0b ptw_rob=%0d ptw_va=%016h lsu_dtlb=%0b lsu_rob=%0d lsu_va=%016h head=%0d tail=%0d flush=%0b/%0b",
                         sim_cycle,
                         u_core.rob_sideband_exc_rob_idx,
                         u_core.u_rob.pc_packed[u_core.rob_sideband_exc_rob_idx * 64 +: 64],
                         u_core.rob_sideband_exc_code,
                         u_core.rob_sideband_exc_tval,
                         u_core.u_rob.sideband_exc_fire,
                         u_core.u_rob.valid_r[u_core.rob_sideband_exc_rob_idx],
                         u_core.u_rob.sideband_exc_alloc_conflict,
                         u_core.u_rob.sideband_exc_not_flushed,
                         u_core.ptw_data_fault_valid,
                         u_core.ptw_fault_rob_idx,
                         u_core.ptw_fault_va,
                         u_core.lsu_dtlb_exc_valid,
                         u_core.lsu_dtlb_exc_rob_idx,
                         u_core.lsu_dtlb_exc_va,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx,
                         u_core.flush_out.valid,
                         u_core.flush_out.full_flush);
                $finish;
            end

            if (((linux_stop_trap_pc_en != 0) ||
                 (linux_stop_trap_tval_en != 0)) &&
                u_core.trap_valid &&
                linux_trace_cycle_on &&
                ((linux_stop_trap_pc_en == 0) ||
                 (u_core.trap_pc == linux_stop_trap_pc)) &&
                ((linux_stop_trap_tval_en == 0) ||
                 (u_core.trap_val == linux_stop_trap_tval))) begin
                $display("[LINUX_STOP_TRAP] cyc=%0d pc=%016h cause=%016h val=%016h irq=%0b priv=%0d satp=%016h stvec=%016h mtvec=%016h rob_head=%0d rob_tail=%0d side_v=%0b side_rob=%0d side_pc=%016h side_code=%0d side_tval=%016h side_fire=%0b ptw_fault=%0b ptw_i=%0b ptw_rob=%0d ptw_va=%016h dtlb_exc=%0b dtlb_rob=%0d dtlb_va=%016h flush=%0b/%0b redirect=%016h last_pc=%016h a5_cur=%016h a5_comm=%016h",
                         sim_cycle,
                         u_core.trap_pc,
                         u_core.trap_cause,
                         u_core.trap_val,
                         u_core.trap_is_interrupt,
                         u_core.csr_priv_mode,
                         u_core.csr_satp,
                         u_core.csr_stvec,
                         u_core.csr_mtvec,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx,
                         u_core.rob_sideband_exc_valid,
                         u_core.rob_sideband_exc_rob_idx,
                         u_core.u_rob.pc_packed[u_core.rob_sideband_exc_rob_idx * 64 +: 64],
                         u_core.rob_sideband_exc_code,
                         u_core.rob_sideband_exc_tval,
                         u_core.u_rob.sideband_exc_fire,
                         u_core.ptw_fault_valid,
                         u_core.ptw_fault_is_itlb,
                         u_core.ptw_fault_rob_idx,
                         u_core.ptw_fault_va,
                         u_core.lsu_dtlb_exc_valid,
                         u_core.lsu_dtlb_exc_rob_idx,
                         u_core.lsu_dtlb_exc_va,
                         u_core.flush_out.valid,
                         u_core.flush_out.full_flush,
                         u_core.flush_out.redirect_pc,
                         last_commit_pc,
                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[15]],
                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[15]]);
                $finish;
            end

            if ((linux_stop_on_timer_boundary_en != 0) &&
                !linux_timer_boundary_seen_r &&
                linux_trace_cycle_on &&
                (mtip ||
                 (u_core.trap_valid &&
                  u_core.trap_is_interrupt &&
                  ((u_core.trap_cause[5:0] == IRQ_M_TIMER) ||
                   (u_core.trap_cause[5:0] == IRQ_S_TIMER))))) begin
                linux_timer_boundary_seen_r <= 1'b1;
                $display("[LINUX_STOP_TIMER_BOUNDARY] cyc=%0d priv=%0d mstatus=%016h mie=%016h mip=%016h mideleg=%016h irq_pending=%0b irq_cause=%016h trap=%0b trap_i=%0b trap_cause=%016h trap_pc=%016h trap_val=%016h interrupt_taken=%0b irq_to_s=%0b mtvec=%016h stvec=%016h mepc=%016h sepc=%016h mtip=%0b stip=%0b msip=%0b ssip=%0b time=%016h timecmp=%016h flush=%0b/%0b redirect=%016h last_pc=%016h rob_head=%0d rob_tail=%0d",
                         sim_cycle,
                         u_core.csr_priv_mode,
                         u_core.u_csr_file.mstatus_r,
                         u_core.u_csr_file.mie_r,
                         u_core.u_csr_file.mip_eff,
                         u_core.csr_mideleg,
                         u_core.csr_irq_pending,
                         u_core.csr_irq_cause,
                         u_core.trap_valid,
                         u_core.trap_is_interrupt,
                         u_core.trap_cause,
                         u_core.trap_pc,
                         u_core.trap_val,
                         u_core.commit_interrupt_taken,
                         u_core.csr_irq_to_supervisor,
                         u_core.csr_mtvec,
                         u_core.csr_stvec,
                         u_core.csr_mepc,
                         u_core.csr_sepc,
                         mtip,
                         stip,
                         msip,
                         ssip,
                         time_val,
                         u_mmio.u_clint.mtimecmp_r,
                         u_core.flush_out.valid,
                         u_core.flush_out.full_flush,
                         u_core.flush_out.redirect_pc,
                         last_commit_pc,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx);
                $finish;
            end

            if ((linux_trace_pipe_en != 0) &&
                (linux_trace_commit_range_en != 0) &&
                linux_trace_cycle_on) begin
                if (linux_trace_fe_en != 0) begin
                    $display("[LINUX_FE_STATE] cyc=%0d f1=%016h req=%016h icv=%0b icaddr=%016h enq=%0b enq_idx=%0d runv=%0b runf=%0b reqredir=%0b bpu=%0b/%016h succ=%0b/%016h work_v=%0b work=%016h widx=%0d wdel=%0b wcomp=%0b data=%0b will=%0b xcnt=%0d fcnt=%0d same=%0b str=%0b rem=%0b ftqcnt=%0d/%0d nextv=%0b nextidx=%0d nextstart=%016h",
                             sim_cycle,
                             u_core.u_fetch_top.f1_pc,
                             u_core.u_fetch_top.req_pc_c,
                             u_core.u_fetch_top.ic_req_valid,
                             u_core.u_fetch_top.ic_req_addr,
                             u_core.u_fetch_top.ftq_enq_valid,
                             u_core.u_fetch_top.ftq_enq_idx,
                             u_core.u_fetch_top.ifu_runahead_req_valid_c,
                             u_core.u_fetch_top.ifu_runahead_req_fire_c,
                             u_core.u_fetch_top.req_redirect_c,
                             u_core.u_fetch_top.f2_bpu_redirect,
                             u_core.u_fetch_top.f2_bpu_target,
                             u_core.u_fetch_top.successor_req_valid_c,
                             u_core.u_fetch_top.successor_req_pc_c,
                             u_core.u_fetch_top.f2_work_valid_c,
                             u_core.u_fetch_top.f2_work_pc_c,
                             u_core.u_fetch_top.f2_work_ftq_idx_c,
                             u_core.u_fetch_top.f2_work_owner_delivered_c,
                             u_core.u_fetch_top.f2_work_owner_complete_c,
                             u_core.u_fetch_top.f2_data_valid,
                             u_core.u_fetch_top.f2_will_emit_c,
                             u_core.u_fetch_top.extract_count,
                             u_core.u_fetch_top.final_count,
                             u_core.u_fetch_top.f2_same_owner_continue_c,
                             u_core.u_fetch_top.line_straddle_advance_c,
                             u_core.u_fetch_top.consume_remainder_c,
                             u_core.u_fetch_top.ftq_count_alloc_to_ifu,
                             u_core.u_fetch_top.ftq_count_ifu_to_wb,
                             u_core.u_fetch_top.ftq_next_ifu_owner_valid,
                             u_core.u_fetch_top.ftq_next_ifu_owner_idx,
                             (u_core.u_fetch_top.ftq_next_ifu_owner_entry.block_pc +
                              64'(u_core.u_fetch_top.ftq_next_ifu_owner_entry.start_offset)));
                    $display("[LINUX_FE_REQMETA] cyc=%0d block=%016h start=%0d pred=%0b/%0b type=%0d off=%0d tgt=%016h btb=%0b type=%0d off=%0d tgt=%016h alt=%0b type=%0d off=%0d tgt=%016h seed_hit=%0b seed_v=%0b seed_pc=%016h seed_type=%0d seed_tgt=%016h",
                             sim_cycle,
                             u_core.u_fetch_top.req_ftq_entry_c.block_pc,
                             u_core.u_fetch_top.req_ftq_entry_c.start_offset,
                             u_core.u_fetch_top.req_ftq_entry_c.pred_ctl_valid,
                             u_core.u_fetch_top.req_ftq_entry_c.pred_ctl_taken,
                             u_core.u_fetch_top.req_ftq_entry_c.pred_ctl_type,
                             u_core.u_fetch_top.req_ftq_entry_c.pred_ctl_offset,
                             u_core.u_fetch_top.req_ftq_entry_c.pred_ctl_target,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_hit,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_type,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_offset,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_target,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_alt_hit,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_alt_type,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_alt_offset,
                             u_core.u_fetch_top.req_ftq_entry_c.btb_alt_target,
                             u_core.u_fetch_top.subgroup_seed_hit_c,
                             u_core.u_fetch_top.subgroup_seed_valid_r,
                             u_core.u_fetch_top.subgroup_seed_pc_r,
                             u_core.u_fetch_top.subgroup_seed_pred_type_r,
                             u_core.u_fetch_top.subgroup_seed_pred_target_r);
                    $display("[LINUX_FE_WORKMETA] cyc=%0d block=%016h start=%0d pred=%0b/%0b type=%0d off=%0d tgt=%016h btb=%0b type=%0d off=%0d tgt=%016h alt=%0b type=%0d off=%0d tgt=%016h",
                             sim_cycle,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.block_pc,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.start_offset,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.pred_ctl_valid,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.pred_ctl_taken,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.pred_ctl_type,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.pred_ctl_offset,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.pred_ctl_target,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_hit,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_type,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_offset,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_target,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_alt_hit,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_alt_type,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_alt_offset,
                             u_core.u_fetch_top.f2_work_ftq_entry_c.btb_alt_target);
                    $display("[LINUX_FE_PRED] cyc=%0d pd=%0b slot=%0d type=%0d pc=%016h tgt=%016h bp=%0b slot=%0d type=%0d tgt=%016h ftqpred=%0b/%0b slot=%0d type=%0d tgt=%016h f2btb=%0b type=%0d off=%0d tgt=%016h f2alt=%0b type=%0d off=%0d tgt=%016h",
                             sim_cycle,
                             u_core.u_fetch_top.predecode_ctl_found,
                             u_core.u_fetch_top.predecode_ctl_slot,
                             u_core.u_fetch_top.predecode_ctl_type,
                             u_core.u_fetch_top.predecode_ctl_pc,
                             u_core.u_fetch_top.predecode_ctl_target,
                             u_core.u_fetch_top.bp_branch_found,
                             u_core.u_fetch_top.bp_branch_slot,
                             u_core.u_fetch_top.bp_type,
                             u_core.u_fetch_top.bp_target_addr,
                             u_core.u_fetch_top.ftq_pred_ctl_valid,
                             u_core.u_fetch_top.ftq_pred_ctl_taken,
                             u_core.u_fetch_top.ftq_pred_ctl_slot,
                             u_core.u_fetch_top.ftq_pred_ctl_type,
                             u_core.u_fetch_top.ftq_pred_ctl_target,
                             u_core.u_fetch_top.f2_btb_hit_r,
                             u_core.u_fetch_top.f2_btb_type_r,
                             u_core.u_fetch_top.f2_btb_offset_r,
                             u_core.u_fetch_top.f2_btb_target_r,
                             u_core.u_fetch_top.f2_btb_alt_hit_r,
                             u_core.u_fetch_top.f2_btb_alt_type_r,
                             u_core.u_fetch_top.f2_btb_alt_offset_r,
                             u_core.u_fetch_top.f2_btb_alt_target_r);
                end
                for (int fi = 0; fi < PIPE_WIDTH; fi++) begin
                    if ((fi < int'(u_core.fetch_count)) &&
                        (u_core.fetch_pc[fi] >= linux_trace_commit_lo) &&
                        (u_core.fetch_pc[fi] < linux_trace_commit_hi)) begin
                        $display("[LINUX_FETCH_OUT] cyc=%0d slot=%0d pc=%016h insn=%08h rvc=%0b count=%0d priv=%0d satp=%016h",
                                 sim_cycle,
                                 fi,
                                 u_core.fetch_pc[fi],
                                 u_core.fetch_insn[fi],
                                 u_core.fetch_is_rvc[fi],
                                 u_core.fetch_count,
                                 u_core.csr_priv_mode,
                                 u_core.csr_satp);
                    end
                end
                for (int di = 0; di < PIPE_WIDTH; di++) begin
                    if ((di < int'(u_core.dec_count_out)) &&
                        u_core.dec_insn_out[di].valid &&
                        (u_core.dec_insn_out[di].pc >= linux_trace_commit_lo) &&
                        (u_core.dec_insn_out[di].pc < linux_trace_commit_hi)) begin
                        $display("[LINUX_DECODE_OUT] cyc=%0d slot=%0d pc=%016h insn=%08h fu=%0d br=%0d csr=%0b fp=%0b exc=%0b code=%0d rvc=%0b count=%0d",
                                 sim_cycle,
                                 di,
                                 u_core.dec_insn_out[di].pc,
                                 u_core.dec_insn_out[di].insn,
                                 u_core.dec_insn_out[di].fu_type,
                                 u_core.dec_insn_out[di].br_op,
                                 u_core.dec_insn_out[di].is_csr,
                                 u_core.dec_insn_out[di].is_fp_op,
                                 u_core.dec_insn_out[di].has_exception,
                                 u_core.dec_insn_out[di].exc_code,
                                 u_core.dec_insn_out[di].is_rvc,
                                 u_core.dec_count_out);
                    end
                end
                for (int ri = 0; ri < PIPE_WIDTH; ri++) begin
                    if ((ri < int'(u_core.ren_count_w)) &&
                        u_core.ren_insn[ri].base.valid &&
                        (u_core.ren_insn[ri].base.pc >= linux_trace_commit_lo) &&
                        (u_core.ren_insn[ri].base.pc < linux_trace_commit_hi)) begin
                        $display("[LINUX_RENAME_ALLOC] cyc=%0d slot=%0d rob=%0d pc=%016h insn=%08h fu=%0d br=%0d csr=%0b fp=%0b rd=%0d pdst=%0d exc=%0b code=%0d ready_now=%0b count=%0d stall=%0b",
                                 sim_cycle,
                                 ri,
                                 u_core.ren_insn[ri].rob_idx,
                                 u_core.ren_insn[ri].base.pc,
                                 u_core.ren_insn[ri].base.insn,
                                 u_core.ren_insn[ri].base.fu_type,
                                 u_core.ren_insn[ri].base.br_op,
                                 u_core.ren_insn[ri].base.is_csr,
                                 u_core.ren_insn[ri].base.is_fp_op,
                                 u_core.ren_insn[ri].base.rd_arch,
                                 u_core.ren_insn[ri].pdst,
                                 u_core.ren_insn[ri].base.has_exception,
                                 u_core.ren_insn[ri].base.exc_code,
                                 u_core.rob_alloc_ready_now[ri],
                                 u_core.ren_count_w,
                                 u_core.rename_stall);
                    end
                end
                for (int wi = 0; wi < CDB_WIDTH; wi++) begin
                    if (u_core.cdb_valid[wi] && u_core.cdb_has_exception[wi]) begin
                        $display("[LINUX_CDB_EXC] cyc=%0d slot=%0d rob=%0d code=%0d fpu_unsup=%0b alu3=%0b csr_illegal=%0b iq2_pc=%016h iq2_fu=%0d fpu_pc=%016h fpu_fu=%0d",
                                 sim_cycle,
                                 wi,
                                 u_core.cdb_rob_idx[wi],
                                 u_core.cdb_exc_code[wi],
                                 u_core.fpu_unsupported,
                                 u_core.alu3_issue,
                                 u_core.csr_access_illegal,
                                 u_core.iq2_issue_data[0].pc,
                                 u_core.iq2_issue_data[0].fu_type,
                                 u_core.fpu_req_data_r.pc,
                                 u_core.fpu_req_data_r.fu_type);
                    end
                end
                if (u_core.rob_sideband_exc_valid) begin
                    $display("[LINUX_SIDEBAND_EXC] cyc=%0d rob=%0d rob_pc=%016h code=%0d tval=%016h rob_fire=%0b rob_valid=%0b alloc_conflict=%0b not_flushed=%0b ptw_data=%0b ptw_rob=%0d ptw_va=%016h lsu_dtlb=%0b lsu_rob=%0d lsu_va=%016h head=%0d tail=%0d flush=%0b/%0b",
                             sim_cycle,
                             u_core.rob_sideband_exc_rob_idx,
                             u_core.u_rob.pc_packed[u_core.rob_sideband_exc_rob_idx * 64 +: 64],
                             u_core.rob_sideband_exc_code,
                             u_core.rob_sideband_exc_tval,
                             u_core.u_rob.sideband_exc_fire,
                             u_core.u_rob.valid_r[u_core.rob_sideband_exc_rob_idx],
                             u_core.u_rob.sideband_exc_alloc_conflict,
                             u_core.u_rob.sideband_exc_not_flushed,
                             u_core.ptw_data_fault_valid,
                             u_core.ptw_fault_rob_idx,
                             u_core.ptw_fault_va,
                             u_core.lsu_dtlb_exc_valid,
                             u_core.lsu_dtlb_exc_rob_idx,
                             u_core.lsu_dtlb_exc_va,
                             u_core.rob_head_idx,
                             u_core.rob_tail_idx,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush);
                end
                if (u_core.iq0_issue_valid[0] &&
                    (u_core.iq0_issue_data[0].pc >= linux_trace_commit_lo) &&
                    (u_core.iq0_issue_data[0].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_IQ0_ISSUE0] cyc=%0d pc=%016h rob=%0d fu=%0d pdst=%0d rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h result=%016h",
                             sim_cycle,
                             u_core.iq0_issue_data[0].pc,
                             u_core.iq0_issue_data[0].rob_idx,
                             u_core.iq0_issue_data[0].fu_type,
                             u_core.iq0_issue_data[0].pdst,
                             u_core.iq0_issue_data[0].rs1_phys,
                             u_core.bypassed_data[0],
                             u_core.iq0_issue_data[0].rs2_phys,
                             u_core.bypassed_data[1],
                             u_core.iq0_issue_data[0].imm,
                             u_core.alu0_result);
                end
                if (u_core.iq0_issue_valid[1] &&
                    (u_core.iq0_issue_data[1].pc >= linux_trace_commit_lo) &&
                    (u_core.iq0_issue_data[1].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_IQ0_ISSUE1] cyc=%0d pc=%016h rob=%0d fu=%0d pdst=%0d rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h result=%016h",
                             sim_cycle,
                             u_core.iq0_issue_data[1].pc,
                             u_core.iq0_issue_data[1].rob_idx,
                             u_core.iq0_issue_data[1].fu_type,
                             u_core.iq0_issue_data[1].pdst,
                             u_core.iq0_issue_data[1].rs1_phys,
                             u_core.bypassed_data[2],
                             u_core.iq0_issue_data[1].rs2_phys,
                             u_core.bypassed_data[3],
                             u_core.iq0_issue_data[1].imm,
                             u_core.alu1_result);
                end
                if (u_core.iq1_issue_valid[0] &&
                    (u_core.iq1_issue_data[0].pc >= linux_trace_commit_lo) &&
                    (u_core.iq1_issue_data[0].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_IQ1_ISSUE0] cyc=%0d pc=%016h rob=%0d fu=%0d pdst=%0d rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h result=%016h",
                             sim_cycle,
                             u_core.iq1_issue_data[0].pc,
                             u_core.iq1_issue_data[0].rob_idx,
                             u_core.iq1_issue_data[0].fu_type,
                             u_core.iq1_issue_data[0].pdst,
                             u_core.iq1_issue_data[0].rs1_phys,
                             u_core.bypassed_data[4],
                             u_core.iq1_issue_data[0].rs2_phys,
                             u_core.bypassed_data[5],
                             u_core.iq1_issue_data[0].imm,
                             u_core.alu2_result);
                end
                if (u_core.iq2_issue_valid[0] &&
                    (u_core.iq2_issue_data[0].pc >= linux_trace_commit_lo) &&
                    (u_core.iq2_issue_data[0].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_IQ2_ISSUE0] cyc=%0d pc=%016h rob=%0d fu=%0d pdst=%0d rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h result=%016h",
                             sim_cycle,
                             u_core.iq2_issue_data[0].pc,
                             u_core.iq2_issue_data[0].rob_idx,
                             u_core.iq2_issue_data[0].fu_type,
                             u_core.iq2_issue_data[0].pdst,
                             u_core.iq2_issue_data[0].rs1_phys,
                             u_core.bypassed_data[6],
                             u_core.iq2_issue_data[0].rs2_phys,
                             u_core.bypassed_data[7],
                             u_core.iq2_issue_data[0].imm,
                             u_core.alu3_result);
                end
                for (int li = 0; li < 2; li++) begin
                    if (u_core.iq_load_issue_candidate_valid[li] &&
                        (u_core.iq_load_issue_data[li].pc >= linux_trace_commit_lo) &&
                        (u_core.iq_load_issue_data[li].pc < linux_trace_commit_hi)) begin
                        $display("[LINUX_LOAD_CAND_RANGE] cyc=%0d p%0d valid=%0b suppress=%0b raw=%0b pc=%016h rob=%0d pdst=%0d rs1p=%0d rs1=%016h addr=%016h size=%0d dvm=%0b tlb_wait=%0b tlb_miss=%0b tlb_fault=%0b",
                                 sim_cycle,
                                 li,
                                 u_core.iq_load_issue_valid[li],
                                 u_core.lsu_load_issue_suppress[li],
                                 u_core.lsu_load_issue_suppress_raw[li],
                                 u_core.iq_load_issue_data[li].pc,
                                 u_core.iq_load_issue_data[li].rob_idx,
                                 u_core.iq_load_issue_data[li].pdst,
                                 u_core.iq_load_issue_data[li].rs1_phys,
                                 u_core.u_lsu.load_rs1[li],
                                 u_core.u_lsu.load_eff_addr[li],
                                 u_core.iq_load_issue_data[li].mem_size,
                                 u_core.data_vm_active,
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_port_wait
                                            : u_core.u_lsu.load1_tlb_wait),
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_miss
                                            : 1'b0),
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_fault
                                            : 1'b0));
                    end
                end
                if (u_core.iq2_issue_valid[0] &&
                    (u_core.iq2_issue_data[0].fu_type == FU_CSR) &&
                    ((u_core.iq2_issue_data[0].csr_addr == 12'h180) ||
                     ((u_core.iq2_issue_data[0].pc >= linux_trace_commit_lo) &&
                      (u_core.iq2_issue_data[0].pc < linux_trace_commit_hi)))) begin
                    $display("[LINUX_CSR_ISSUE] cyc=%0d pc=%016h rob=%0d addr=%03h op=%0d wdata=%016h rdata=%016h illegal=%0b commit_v=%0b commit_addr=%03h commit_data=%016h commit_op=%0d satp=%016h bypass=%0b op_satp=%016h legal=%0b",
                             sim_cycle,
                             u_core.iq2_issue_data[0].pc,
                             u_core.iq2_issue_data[0].rob_idx,
                             u_core.iq2_issue_data[0].csr_addr,
                             u_core.iq2_issue_data[0].csr_op,
                             u_core.csr_exec_wdata,
                             u_core.csr_read_data,
                             u_core.csr_access_illegal,
                             u_core.csr_commit_valid,
                             u_core.csr_commit_addr,
                             u_core.csr_commit_wdata,
                             u_core.csr_commit_op,
                             u_core.csr_satp,
                             u_core.u_csr_file.csr_bypass,
                             u_core.u_csr_file.csr_op_satp,
                             u_core.u_csr_file.csr_op_satp_legal);
                end
                if (u_core.csr_commit_valid &&
                    ((u_core.csr_commit_addr == 12'h180) ||
                     ((u_core.rob_head_pc[0] >= linux_trace_commit_lo) &&
                      (u_core.rob_head_pc[0] < linux_trace_commit_hi)))) begin
                    $display("[LINUX_CSR_COMMIT] cyc=%0d pc=%016h addr=%03h op=%0d wdata=%016h satp_before=%016h op_satp=%016h legal=%0b",
                             sim_cycle,
                             u_core.rob_head_pc[0],
                             u_core.csr_commit_addr,
                             u_core.csr_commit_op,
                             u_core.csr_commit_wdata,
                             u_core.csr_satp,
                             u_core.u_csr_file.csr_op_satp,
                             u_core.u_csr_file.csr_op_satp_legal);
                end
            end

            if ((linux_trace_bru_en != 0) &&
                (linux_trace_commit_range_en != 0) &&
                linux_trace_cycle_on) begin
                if (u_core.bru_issue &&
                    (u_core.iq0_issue_data[0].pc >= linux_trace_commit_lo) &&
                    (u_core.iq0_issue_data[0].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_BRU0] cyc=%0d pc=%016h rob=%0d op=%0d fused=%0b ftype=%0d ckpt=%0b rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h bp_taken=%0b bp_target=%016h taken=%0b target=%016h taken_target=%016h link=%016h misp=%0b",
                             sim_cycle,
                             u_core.iq0_issue_data[0].pc,
                             u_core.iq0_issue_data[0].rob_idx,
                             u_core.iq0_issue_data[0].br_op,
                             u_core.iq0_issue_data[0].is_fused,
                             u_core.iq0_issue_data[0].fusion_type,
                             u_core.iq0_issue_data[0].uses_checkpoint,
                             u_core.iq0_issue_data[0].rs1_phys,
                             u_core.bypassed_data[0],
                             u_core.iq0_issue_data[0].rs2_phys,
                             u_core.bypassed_data[1],
                             u_core.iq0_issue_data[0].imm,
                             u_core.iq0_issue_data[0].bp_taken,
                             u_core.iq0_issue_data[0].bp_target,
                             u_core.bru_taken,
                             u_core.bru_target,
                             u_core.bru_taken_target,
                             u_core.bru_result,
                             u_core.bru_mispredict);
                end
                if (u_core.bru1_issue &&
                    (u_core.iq0_issue_data[1].pc >= linux_trace_commit_lo) &&
                    (u_core.iq0_issue_data[1].pc < linux_trace_commit_hi)) begin
                    $display("[LINUX_BRU1] cyc=%0d pc=%016h rob=%0d op=%0d fused=%0b ftype=%0d ckpt=%0b rs1p=%0d rs1=%016h rs2p=%0d rs2=%016h imm=%016h bp_taken=%0b bp_target=%016h taken=%0b target=%016h taken_target=%016h link=%016h misp=%0b",
                             sim_cycle,
                             u_core.iq0_issue_data[1].pc,
                             u_core.iq0_issue_data[1].rob_idx,
                             u_core.iq0_issue_data[1].br_op,
                             u_core.iq0_issue_data[1].is_fused,
                             u_core.iq0_issue_data[1].fusion_type,
                             u_core.iq0_issue_data[1].uses_checkpoint,
                             u_core.iq0_issue_data[1].rs1_phys,
                             u_core.bypassed_data[2],
                             u_core.iq0_issue_data[1].rs2_phys,
                             u_core.bypassed_data[3],
                             u_core.iq0_issue_data[1].imm,
                             u_core.iq0_issue_data[1].bp_taken,
                             u_core.iq0_issue_data[1].bp_target,
                             u_core.bru1_taken,
                             u_core.bru1_target,
                             u_core.bru1_taken_target,
                             u_core.bru1_result,
                             u_core.bru1_mispredict);
                end
            end

            if (linux_trace_trap_en != 0) begin
                for (int ti = 0; ti < PIPE_WIDTH; ti++) begin
                    if ((ti < int'(u_core.commit_count)) &&
                        u_core.rob_head_has_exception[ti] &&
                        ((linux_trace_fault_only_en == 0) ||
                         ((u_core.rob_head_exc_code[ti] != EXC_ECALL_U) &&
                          (u_core.rob_head_exc_code[ti] != EXC_ECALL_S) &&
                          (u_core.rob_head_exc_code[ti] != EXC_ECALL_M) &&
                          (u_core.rob_head_exc_code[ti] != EXC_BREAKPOINT) &&
                          (u_core.rob_head_exc_code[ti] != EXC_ILLEGAL_INSN)))) begin
                        $display("[LINUX_COMMIT_EXC] cyc=%0d slot=%0d pc=%016h code=%0d mtvec=%016h priv=%0d",
                                 sim_cycle, ti,
                                 u_core.rob_head_pc[ti],
                                 u_core.rob_head_exc_code[ti],
                                 u_core.csr_mtvec,
                                 u_core.csr_priv_mode);
                    end
                end
                if (u_core.trap_valid &&
                    ((linux_trace_fault_only_en == 0) ||
                     ((!u_core.trap_is_interrupt) &&
                      (u_core.trap_cause[3:0] != EXC_ECALL_U) &&
                      (u_core.trap_cause[3:0] != EXC_ECALL_S) &&
                      (u_core.trap_cause[3:0] != EXC_ECALL_M) &&
                      (u_core.trap_cause[3:0] != EXC_BREAKPOINT) &&
                      (u_core.trap_cause[3:0] != EXC_ILLEGAL_INSN)))) begin
                    $display("[LINUX_TRAP] cyc=%0d pc=%016h cause=%016h val=%016h irq=%0b mtvec=%016h stvec=%016h priv=%0d fe_priv=%0d fe_redir_priv=%0d instr_vm=%0b flush=%0b/%0b redirect=%016h",
                             sim_cycle,
                             u_core.trap_pc,
                             u_core.trap_cause,
                             u_core.trap_val,
                             u_core.trap_is_interrupt,
                             u_core.csr_mtvec,
                             u_core.csr_stvec,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.frontend_redirect_priv_c,
                             u_core.instr_vm_active,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.redirect_pc);
                    if (linux_trace_regs_en != 0) begin
                        $display("[LINUX_TRAP_REGS0] cyc=%0d pc=%016h ra=%016h sp=%016h gp=%016h tp=%016h t0=%016h t1=%016h t2=%016h",
                                 sim_cycle,
                                 u_core.trap_pc,
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[1]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[2]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[3]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[4]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[5]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[6]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[7]]);
                        $display("[LINUX_TRAP_REGS1] cyc=%0d pc=%016h s0=%016h s1=%016h a0=%016h a1=%016h a2=%016h a3=%016h a4=%016h a5=%016h a6=%016h a7=%016h",
                                 sim_cycle,
                                 u_core.trap_pc,
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[8]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[9]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[12]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[13]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[14]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[15]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[16]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[17]]);
                        $display("[LINUX_TRAP_REGS2] cyc=%0d pc=%016h s2=%016h s3=%016h s4=%016h s5=%016h s6=%016h s7=%016h s8=%016h s9=%016h s10=%016h s11=%016h t3=%016h t4=%016h t5=%016h t6=%016h satp=%016h sepc=%016h scause=%016h stval=%016h",
                                 sim_cycle,
                                 u_core.trap_pc,
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[18]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[19]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[20]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[21]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[22]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[23]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[24]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[25]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[26]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[27]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[28]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[29]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[30]],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[31]],
                                 u_core.csr_satp,
                                 u_core.csr_sepc,
                                 u_core.u_csr_file.scause_r,
                                 u_core.u_csr_file.stval_r);
                        $display("[LINUX_TRAP_CURR] cyc=%0d pc=%016h ra_p=%0d ra=%016h a0_p=%0d a0=%016h a1_p=%0d a1=%016h a2_p=%0d a2=%016h a3_p=%0d a3=%016h",
                                 sim_cycle,
                                 u_core.trap_pc,
                                 u_core.u_rename.u_rat.rat_table[1],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[1]],
                                 u_core.u_rename.u_rat.rat_table[10],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[10]],
                                 u_core.u_rename.u_rat.rat_table[11],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[11]],
                                 u_core.u_rename.u_rat.rat_table[12],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[12]],
                                 u_core.u_rename.u_rat.rat_table[13],
                                 u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.rat_table[13]]);
                    end
                end
                if ((linux_trace_fault_only_en == 0) && u_core.mret_commit) begin
                    $display("[LINUX_MRET] cyc=%0d pc=%016h mepc=%016h mcause=%016h mtval=%016h priv=%0d fe_priv=%0d instr_vm=%0b redirect=%016h",
                             sim_cycle,
                             u_core.rob_head_pc[0],
                             u_core.csr_mepc,
                             u_core.u_csr_file.mcause_r,
                             u_core.u_csr_file.mtval_r,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.instr_vm_active,
                             u_core.flush_out.redirect_pc);
                end
                if ((linux_trace_fault_only_en == 0) && u_core.sret_commit) begin
                    $display("[LINUX_SRET] cyc=%0d pc=%016h sepc=%016h scause=%016h stval=%016h priv=%0d fe_priv=%0d instr_vm=%0b redirect=%016h",
                             sim_cycle,
                             u_core.rob_head_pc[0],
                             u_core.csr_sepc,
                             u_core.u_csr_file.scause_r,
                             u_core.u_csr_file.stval_r,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.instr_vm_active,
                             u_core.flush_out.redirect_pc);
                end
            end

            if (linux_trace_mmu_en != 0) begin
                if (u_core.translation_tlb_invalidate) begin
                    $display("[LINUX_MMU_INV] cyc=%0d satp=%016h sfence=%0b satp_commit=%0b pc=%016h",
                             sim_cycle,
                             u_core.csr_satp,
                             u_core.sfence_vma_commit,
                             u_core.satp_commit_valid,
                             u_core.rob_head_pc[0]);
                end
                if (u_core.itlb_lookup_valid ||
                    u_core.itlb_miss_valid ||
                    u_core.itlb_fault) begin
                    $display("[LINUX_ITLB] cyc=%0d active=%0b priv=%0d fe_priv=%0d redir_priv=%0d va=%016h hit=%0b pa=%016h fault=%0b code=%0d miss=%0b miss_va=%016h satp=%016h flush=%0b/%0b redirect=%016h f1=%016h req=%016h",
                             sim_cycle,
                             u_core.instr_vm_active,
                             u_core.csr_priv_mode,
                             u_core.frontend_fetch_priv_r,
                             u_core.frontend_redirect_priv_c,
                             u_core.itlb_lookup_va,
                             u_core.itlb_hit,
                             u_core.itlb_pa,
                             u_core.itlb_fault,
                             u_core.itlb_fault_code,
                             u_core.itlb_miss_valid,
                             u_core.itlb_miss_va,
                             u_core.csr_satp,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.redirect_pc,
                             u_core.u_fetch_top.f1_pc,
                             u_core.u_fetch_top.req_pc_c);
                end
                if (u_core.ptw_l2_req_valid ||
                    u_core.ptw_l2_resp_valid ||
                    u_core.ptw_itlb_fill_valid ||
                    u_core.ptw_dtlb_fill_valid ||
                    u_core.ptw_fault_valid ||
                    (u_core.u_ptw.state_r != 3'd0)) begin
                    $display("[LINUX_PTW] cyc=%0d state=%0d walk_va=%016h is_i=%0b is_store=%0b level=%0d ppn=%011h pte_addr=%016h l2_req=%0b l2_acc=%0b l2_addr=%016h l2_resp=%0b l2_resp_addr=%016h pte=%016h v=%0b r=%0b w=%0b x=%0b leaf=%0b invalid=%0b ad=%0b misalign=%0b fill_i=%0b fill_d=%0b fill_vpn=%09h fill_ppn=%011h perm=%02h fault=%0b fault_i=%0b fault_va=%016h satp=%016h",
                             sim_cycle,
                             u_core.u_ptw.state_r,
                             u_core.u_ptw.walk_va_r,
                             u_core.u_ptw.walk_is_itlb_r,
                             u_core.u_ptw.walk_is_store_r,
                             u_core.u_ptw.walk_level_r,
                             u_core.u_ptw.walk_ppn_r,
                             u_core.u_ptw.pte_addr_c,
                             u_core.ptw_l2_req_valid,
                             u_core.ptw_l2_req_accepted,
                             u_core.ptw_l2_req_addr,
                             u_core.ptw_l2_resp_valid,
                             u_core.ptw_l2_resp_addr,
                             u_core.u_ptw.pte_resp_c,
                             u_core.u_ptw.pte_v_c,
                             u_core.u_ptw.pte_r_c,
                             u_core.u_ptw.pte_w_c,
                             u_core.u_ptw.pte_x_c,
                             u_core.u_ptw.pte_leaf_c,
                             u_core.u_ptw.pte_invalid_c,
                             u_core.u_ptw.pte_ad_update_needed_c,
                             u_core.u_ptw.superpage_misalign_c,
                             u_core.ptw_itlb_fill_valid,
                             u_core.ptw_dtlb_fill_valid,
                             u_core.ptw_fill_vpn,
                             u_core.ptw_fill_ppn,
                             u_core.ptw_fill_perm,
                             u_core.ptw_fault_valid,
                             u_core.ptw_fault_is_itlb,
                             u_core.ptw_fault_va,
                             u_core.csr_satp);
                end
            end

            if (data_mmio_req_valid && data_mmio_req_ready) begin
                mmio_req_count <= mmio_req_count + 1;
                if ((data_mmio_req_addr >= UART_BASE) &&
                    (data_mmio_req_addr < (UART_BASE + UART_SIZE))) begin
                    if (data_mmio_req_we)
                        mmio_uart_wr_count <= mmio_uart_wr_count + 1;
                    else
                        mmio_uart_rd_count <= mmio_uart_rd_count + 1;
                end

                if (linux_trace_mmio_en != 0) begin
                    $display("[LINUX_MMIO] cyc=%0d we=%0b addr=%016h data=%016h mask=%02h size=%0d",
                             sim_cycle, data_mmio_req_we, data_mmio_req_addr,
                             data_mmio_req_wdata, data_mmio_req_wmask,
                             data_mmio_req_size);
                end
            end

            if ((linux_trace_any_line_en != 0) && linux_trace_cycle_on) begin
                if (u_core.u_lsu.sta_issue_valid &&
                    linux_trace_line_match(u_core.u_lsu.sta_eff_addr)) begin
                    $display("[LINUX_STA_ISSUE] cyc=%0d pc=%016h rob=%0d sq=%0d addr=%016h size=%0d older0=%0b older1=%0b flush=%0b",
                             sim_cycle,
                             u_core.u_lsu.sta_issue_data.pc,
                             u_core.u_lsu.sta_issue_data.rob_idx,
                             u_core.u_lsu.sta_issue_data.sq_idx,
                             u_core.u_lsu.sta_eff_addr,
                             u_core.u_lsu.sta_issue_data.mem_size,
                             u_core.u_lsu.sta_older_than_load0,
                             u_core.u_lsu.sta_older_than_load1,
                             u_core.flush_out.valid);
                end
                if (u_core.u_lsu.std_issue_valid &&
                    u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr_valid &&
                    linux_trace_line_match(u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr)) begin
                    $display("[LINUX_STD_ISSUE] cyc=%0d pc=%016h rob=%0d sq=%0d addr=%016h data=%016h mask=%02h flush=%0b",
                             sim_cycle,
                             u_core.u_lsu.std_issue_data.pc,
                             u_core.u_lsu.std_issue_data.rob_idx,
                             u_core.u_lsu.std_issue_data.sq_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr,
                             u_core.u_lsu.std_rs2,
                             u_core.u_lsu.std_byte_mask,
                             u_core.flush_out.valid);
                end
                if (u_core.u_lsu.ordering_violation) begin
                    $display("[LINUX_ORDER_VIOL] cyc=%0d load_rob=%0d sta_rob=%0d sta_pc=%016h sta_addr=%016h",
                             sim_cycle,
                             u_core.u_lsu.violation_rob_idx,
                             u_core.u_lsu.sta_issue_data.rob_idx,
                             u_core.u_lsu.sta_issue_data.pc,
                             u_core.u_lsu.sta_eff_addr);
                end
            end

            if ((linux_trace_preempt_pa_en != 0) && linux_trace_cycle_on) begin
                if (u_core.u_lsu.sta_issue_valid &&
                    linux_trace_preempt_match(u_core.u_lsu.sta_mem_addr)) begin
                    $display("[LINUX_PREEMPT_STA] cyc=%0d pc=%016h rob=%0d sq=%0d va=%016h pa=%016h size=%0d accept=%0b qv=%0b qrob=%0d qav=%0b qdv=%0b qcomm=%0b flush=%0b/%0b ra=%016h sp=%016h tp=%016h s1=%016h s2=%016h s3=%016h s4=%016h a0=%016h a1=%016h a2=%016h a3=%016h a4=%016h a5=%016h satp=%016h",
                             sim_cycle,
                             u_core.u_lsu.sta_issue_data.pc,
                             u_core.u_lsu.sta_issue_data.rob_idx,
                             u_core.u_lsu.sta_issue_data.sq_idx,
                             u_core.u_lsu.sta_eff_addr,
                             u_core.u_lsu.sta_mem_addr,
                             u_core.u_lsu.sta_issue_data.mem_size,
                             u_core.u_lsu.u_store_queue.sta_fill_accept,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].rob_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].addr_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].data_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].committed,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[1]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[2]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[4]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[9]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[18]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[19]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[20]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[12]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[13]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[14]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[15]],
                             u_core.csr_satp);
                end
                if (u_core.u_lsu.std_issue_valid &&
                    u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr_valid &&
                    linux_trace_preempt_match(u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr)) begin
                    $display("[LINUX_PREEMPT_STD] cyc=%0d pc=%016h rob=%0d sq=%0d addr=%016h data=%016h mask=%02h accept=%0b qv=%0b qrob=%0d qcomm=%0b flush=%0b/%0b ra=%016h sp=%016h tp=%016h s1=%016h s2=%016h s3=%016h s4=%016h a0=%016h a1=%016h a2=%016h a3=%016h a4=%016h a5=%016h satp=%016h",
                             sim_cycle,
                             u_core.u_lsu.std_issue_data.pc,
                             u_core.u_lsu.std_issue_data.rob_idx,
                             u_core.u_lsu.std_issue_data.sq_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr,
                             u_core.u_lsu.std_rs2,
                             u_core.u_lsu.std_byte_mask,
                             u_core.u_lsu.u_store_queue.std_fill_accept,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].rob_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].committed,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[1]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[2]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[4]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[9]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[18]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[19]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[20]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[10]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[11]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[12]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[13]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[14]],
                             u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[15]],
                             u_core.csr_satp);
                end
                for (int lp = 0; lp < 2; lp++) begin
                    if (u_core.u_lsu.load_issue_valid[lp] &&
                        linux_trace_preempt_match(u_core.u_lsu.load_mem_addr[lp])) begin
                        $display("[LINUX_PREEMPT_LD_REQ] cyc=%0d port=%0d pc=%016h rob=%0d lq=%0d va=%016h pa=%016h size=%0d pdst=%0d suppress=%0b flush=%0b/%0b",
                                 sim_cycle,
                                 lp,
                                 u_core.u_lsu.load_issue_data[lp].pc,
                                 u_core.u_lsu.load_issue_data[lp].rob_idx,
                                 u_core.u_lsu.load_issue_data[lp].lq_idx,
                                 u_core.u_lsu.load_eff_addr[lp],
                                 u_core.u_lsu.load_mem_addr[lp],
                                 u_core.u_lsu.load_issue_data[lp].mem_size,
                                 u_core.u_lsu.load_issue_data[lp].pdst,
                                 u_core.u_lsu.load_issue_suppress[lp],
                                 u_core.flush_out.valid,
                                 u_core.flush_out.full_flush);
                    end
                    if (u_core.u_lsu.load_wb_valid[lp] &&
                        linux_trace_preempt_match(u_core.u_lsu.load_eff_addr_r[lp])) begin
                        $display("[LINUX_PREEMPT_LD_WB] cyc=%0d port=%0d pc=%016h rob=%0d lq=%0d pa=%016h data=%016h pdst=%0d exc=%0b code=%0d flush=%0b/%0b",
                                 sim_cycle,
                                 lp,
                                 u_core.u_lsu.load_issue_data_r[lp].pc,
                                 u_core.u_lsu.load_wb_rob_idx[lp],
                                 u_core.u_lsu.load_issue_data_r[lp].lq_idx,
                                 u_core.u_lsu.load_eff_addr_r[lp],
                                 u_core.u_lsu.load_wb_data[lp],
                                 u_core.u_lsu.load_wb_pdst[lp],
                                 u_core.u_lsu.load_wb_has_exception[lp],
                                 u_core.u_lsu.load_wb_exc_code[lp],
                                 u_core.flush_out.valid,
                                 u_core.flush_out.full_flush);
                    end
                end
            end

            if ((linux_trace_commit_range_en != 0) && linux_trace_cycle_on) begin
                if (u_core.u_lsu.sta_issue_valid &&
                    (u_core.u_lsu.sta_issue_data.pc >= linux_trace_commit_lo) &&
                    (u_core.u_lsu.sta_issue_data.pc <= linux_trace_commit_hi)) begin
                    $display("[LINUX_STA_PC] cyc=%0d pc=%016h rob=%0d sq=%0d va=%016h pa=%016h size=%0d accept=%0b qv=%0b qrob=%0d qav=%0b qdv=%0b qcomm=%0b dtlb_v=%0b dtlb_va=%016h hit=%0b fault=%0b code=%0d flush=%0b",
                             sim_cycle,
                             u_core.u_lsu.sta_issue_data.pc,
                             u_core.u_lsu.sta_issue_data.rob_idx,
                             u_core.u_lsu.sta_issue_data.sq_idx,
                             u_core.u_lsu.sta_eff_addr,
                             u_core.u_lsu.sta_mem_addr,
                             u_core.u_lsu.sta_issue_data.mem_size,
                             u_core.u_lsu.u_store_queue.sta_fill_accept,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].rob_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].addr_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].data_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.sta_issue_data.sq_idx].committed,
                             u_core.dtlb_lookup_valid,
                             u_core.dtlb_lookup_va,
                             u_core.dtlb_hit,
                             u_core.dtlb_fault,
                             u_core.dtlb_fault_code,
                             u_core.flush_out.valid);
                end
                if (u_core.u_lsu.std_issue_valid &&
                    (u_core.u_lsu.std_issue_data.pc >= linux_trace_commit_lo) &&
                    (u_core.u_lsu.std_issue_data.pc <= linux_trace_commit_hi)) begin
                    $display("[LINUX_STD_PC] cyc=%0d pc=%016h rob=%0d sq=%0d data=%016h mask=%02h accept=%0b qv=%0b qrob=%0d qav=%0b qaddr=%016h qdv=%0b qdata=%016h qmask=%02h qcomm=%0b flush=%0b",
                             sim_cycle,
                             u_core.u_lsu.std_issue_data.pc,
                             u_core.u_lsu.std_issue_data.rob_idx,
                             u_core.u_lsu.std_issue_data.sq_idx,
                             u_core.u_lsu.std_rs2,
                             u_core.u_lsu.std_byte_mask,
                             u_core.u_lsu.u_store_queue.std_fill_accept,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].rob_idx,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].addr,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].data_valid,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].data,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].byte_mask,
                             u_core.u_lsu.u_store_queue.queue[u_core.u_lsu.std_issue_data.sq_idx].committed,
                             u_core.flush_out.valid);
                end
            end

            if ((linux_stop_store_pc_en != 0) &&
                (linux_stop_store_data_above_en != 0) &&
                linux_trace_cycle_on &&
                u_core.u_lsu.std_issue_valid &&
                (u_core.u_lsu.std_issue_data.pc == linux_stop_store_pc) &&
                (u_core.u_lsu.std_rs2 > linux_stop_store_data_above)) begin
                $display("[LINUX_STOP_STORE_DATA_ABOVE] cyc=%0d pc=%016h rob=%0d sq=%0d data=%016h limit=%016h mask=%02h flush=%0b",
                         sim_cycle,
                         u_core.u_lsu.std_issue_data.pc,
                         u_core.u_lsu.std_issue_data.rob_idx,
                         u_core.u_lsu.std_issue_data.sq_idx,
                         u_core.u_lsu.std_rs2,
                         linux_stop_store_data_above,
                         u_core.u_lsu.std_byte_mask,
                         u_core.flush_out.valid);
                $finish;
            end

            if (((linux_trace_load_pc_en != 0) ||
                 (linux_trace_load_range_en != 0) ||
                 (linux_stop_on_trace_load_range_en != 0)) &&
                linux_trace_cycle_on) begin
                for (int li = 0; li < 2; li++) begin
                    if (u_core.iq_load_issue_candidate_valid[li] &&
                        (((linux_trace_load_pc_en != 0) &&
                          (u_core.iq_load_issue_data[li].pc == linux_trace_load_pc)) ||
                         ((linux_trace_load_range_en != 0) &&
                          (u_core.iq_load_issue_data[li].pc >= linux_trace_commit_lo) &&
                          (u_core.iq_load_issue_data[li].pc < linux_trace_commit_hi)) ||
                         ((linux_stop_on_trace_load_range_en != 0) &&
                          (u_core.iq_load_issue_data[li].pc >= linux_trace_commit_lo) &&
                          (u_core.iq_load_issue_data[li].pc < linux_trace_commit_hi))) &&
                        u_core.lsu_load_issue_suppress_raw[li]) begin
                        $display("[LINUX_LOAD_SUPPRESS] cyc=%0d p%0d rob=%0d pdst=%0d pc=%016h addr=%016h size=%0d rs1p=%0d rs1=%016h prf=%016h bhit=%0b imm=%016h fused=%0b raw=%0b vm=%0b mf=%0b dvm=%0b tlb_wait=%0b tlb_miss=%0b tlb_fault=%0b dtlb_v=%0b dtlb_va=%016h dtlb_hit=%0b dtlb_fault=%0b dtlb_code=%0d misalign=%0b cross=%0b mmio=%0b sq_wait=%0b partial=%0b fwd=%0b amo_busy=%0b flush=%0b",
                                 sim_cycle,
                                 li,
                                 u_core.iq_load_issue_data[li].rob_idx,
                                 u_core.iq_load_issue_data[li].pdst,
                                 u_core.iq_load_issue_data[li].pc,
                                 u_core.u_lsu.load_eff_addr[li],
                                 u_core.iq_load_issue_data[li].mem_size,
                                 u_core.iq_load_issue_data[li].rs1_phys,
                                 u_core.u_lsu.load_rs1[li],
                                 ((li == 0) ? u_core.prf_rdata[8]
                                            : u_core.prf_rdata[9]),
                                 ((li == 0) ? u_core.bypass_hit[8]
                                            : u_core.bypass_hit[9]),
                                 u_core.iq_load_issue_data[li].imm,
                                 u_core.iq_load_issue_data[li].is_fused,
                                 u_core.lsu_load_issue_suppress_raw[li],
                                 u_core.vm_serial_load_issue_suppress[li],
                                 u_core.mem_fence_load_issue_suppress[li],
                                 u_core.data_vm_active,
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_port_wait
                                            : u_core.u_lsu.load1_tlb_wait),
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_miss
                                            : 1'b0),
                                 ((li == 0) ? u_core.u_lsu.load0_tlb_fault
                                            : 1'b0),
                                 u_core.dtlb_lookup_valid,
                                 u_core.dtlb_lookup_va,
                                 u_core.dtlb_hit,
                                 u_core.dtlb_fault,
                                 u_core.dtlb_fault_code,
                                 u_core.u_lsu.load_addr_misaligned[li],
                                 u_core.u_lsu.load_cross_line[li],
                                 u_core.u_lsu.load_addr_mmio[li],
                                 ((li == 0) ? u_core.u_lsu.p0_sq_order_wait_block
                                            : u_core.u_lsu.p1_sq_order_wait_block),
                                 ((li == 0) ? u_core.u_lsu.p0_partial_fwd_wait
                                            : u_core.u_lsu.p1_partial_fwd_wait),
                                 ((li == 0) ? u_core.u_lsu.p0_fwd_hit
                                            : u_core.u_lsu.p1_any_fwd_hit),
                                 u_core.u_lsu.amo_busy,
                                 u_core.flush_out.valid);
                    end
                    if (u_core.u_lsu.load_issue_valid[li] &&
                        (((linux_trace_load_pc_en != 0) &&
                          (u_core.u_lsu.load_issue_data[li].pc == linux_trace_load_pc)) ||
                         ((linux_trace_load_range_en != 0) &&
                          (u_core.u_lsu.load_issue_data[li].pc >= linux_trace_commit_lo) &&
                          (u_core.u_lsu.load_issue_data[li].pc < linux_trace_commit_hi)) ||
                         ((linux_stop_on_trace_load_range_en != 0) &&
                          (u_core.u_lsu.load_issue_data[li].pc >= linux_trace_commit_lo) &&
                          (u_core.u_lsu.load_issue_data[li].pc < linux_trace_commit_hi)))) begin
                        $display("[LINUX_LOAD_ISSUE] cyc=%0d p%0d rob=%0d pdst=%0d pc=%016h addr=%016h size=%0d rs1p=%0d rs1=%016h prf=%016h bhit=%0b imm=%016h fused=%0b mmio=%0b miss=%0b hit=%0b p0fwd=%0b same=%0b sq=%0b sq_part=%0b sq_wait=%0b csb=%0b sq_data=%016h csb_data=%016h",
                                 sim_cycle, li,
                                 u_core.u_lsu.load_issue_data[li].rob_idx,
                                 u_core.u_lsu.load_issue_data[li].pdst,
                                 u_core.u_lsu.load_issue_data[li].pc,
                                 u_core.u_lsu.load_eff_addr[li],
                                 u_core.u_lsu.load_issue_data[li].mem_size,
                                 u_core.u_lsu.load_issue_data[li].rs1_phys,
                                 u_core.u_lsu.load_rs1[li],
                                 ((li == 0) ? u_core.prf_rdata[8]
                                            : u_core.prf_rdata[9]),
                                 ((li == 0) ? u_core.bypass_hit[8]
                                            : u_core.bypass_hit[9]),
                                 u_core.u_lsu.load_issue_data[li].imm,
                                 u_core.u_lsu.load_issue_data[li].is_fused,
                                 u_core.u_lsu.load_addr_mmio[li],
                                 ((li == 0) ? u_core.u_lsu.p0_miss_detect
                                            : u_core.u_lsu.p1_miss_detect),
                                 u_core.dc_load_resp_hit[li],
                                 ((li == 0) ? u_core.u_lsu.p0_fwd_hit
                                            : u_core.u_lsu.p1_any_fwd_hit),
                                 ((li == 0) ? u_core.u_lsu.same_cycle_fwd_hit
                                            : 1'b0),
                                 ((li == 0) ? u_core.u_lsu.sq_fwd_hit
                                            : u_core.u_lsu.sq_fwd_hit_p1),
                                 ((li == 0) ? u_core.u_lsu.sq_fwd_partial
                                            : u_core.u_lsu.sq_fwd_partial_p1),
                                 ((li == 0) ? u_core.u_lsu.sq_fwd_wait
                                            : u_core.u_lsu.sq_wait_p1),
                                 ((li == 0) ? u_core.u_lsu.csb_fwd_hit
                                            : u_core.u_lsu.csb_fwd_hit_p1),
                                 ((li == 0) ? u_core.u_lsu.sq_fwd_data
                                            : u_core.u_lsu.sq_fwd_data_p1),
                                 ((li == 0) ? u_core.u_lsu.csb_fwd_data
                                            : u_core.u_lsu.csb_fwd_data_p1));
                        if ((linux_stop_on_trace_load_pc_en != 0) ||
                            (linux_stop_on_trace_load_range_en != 0)) begin
                            $display("[LINUX_STOP_TRACE_LOAD] cyc=%0d p%0d pc=%016h addr=%016h rs1=%016h imm=%016h fused=%0b satp=%016h priv=%0d flush=%0b",
                                     sim_cycle,
                                     li,
                                     u_core.u_lsu.load_issue_data[li].pc,
                                     u_core.u_lsu.load_eff_addr[li],
                                     u_core.u_lsu.load_rs1[li],
                                     u_core.u_lsu.load_issue_data[li].imm,
                                     u_core.u_lsu.load_issue_data[li].is_fused,
                                     u_core.csr_satp,
                                     u_core.csr_priv_mode,
                                     u_core.flush_out.valid);
                            $finish;
                        end
                        for (int ti = 0; ti < TRACE_LOAD_TRACK; ti++) begin
                            if (!trace_load_valid[ti]) begin
                                trace_load_valid[ti] <= 1'b1;
                                trace_load_rob[ti] <= u_core.u_lsu.load_issue_data[li].rob_idx;
                                trace_load_pdst[ti] <= u_core.u_lsu.load_issue_data[li].pdst;
                                trace_load_pc[ti] <= u_core.u_lsu.load_issue_data[li].pc;
                                trace_load_addr[ti] <= u_core.u_lsu.load_eff_addr[li];
                                break;
                            end
                        end
                        if (li == 0) begin
                            $display("[LINUX_LSU_ORDDBG] cyc=%0d rob_head=%0d sq_head=%0d sq_tail=%0d sq_commit=%0d sq_count=%0d csb_head=%0d csb_tail=%0d csb_count=%0d",
                                     sim_cycle,
                                     u_core.rob_head_idx,
                                     u_core.u_lsu.u_store_queue.head_r,
                                     u_core.u_lsu.u_store_queue.tail_r,
                                     u_core.u_lsu.u_store_queue.commit_ptr_r,
                                     u_core.u_lsu.u_store_queue.count_r,
                                     u_core.u_lsu.u_csb.head_r,
                                     u_core.u_lsu.u_csb.tail_r,
                                     u_core.u_lsu.u_csb.count_r);
                            for (int si = 0; si < SQ_DEPTH; si++) begin
                                if (u_core.u_lsu.u_store_queue.queue[si].valid &&
                                    u_core.u_lsu.u_store_queue.queue[si].addr_valid &&
                                    ((u_core.u_lsu.u_store_queue.queue[si].addr[63:3] ==
                                      u_core.u_lsu.load_eff_addr[0][63:3]) ||
                                     ((linux_trace_any_line_en != 0) &&
                                      linux_trace_line_match(u_core.u_lsu.u_store_queue.queue[si].addr)))) begin
                                    $display("[LINUX_SQ_MATCH] cyc=%0d idx=%0d rob=%0d committed=%0b data_v=%0b data=%016h mask=%02h",
                                             sim_cycle,
                                             si,
                                             u_core.u_lsu.u_store_queue.queue[si].rob_idx,
                                             u_core.u_lsu.u_store_queue.queue[si].committed,
                                             u_core.u_lsu.u_store_queue.queue[si].data_valid,
                                             u_core.u_lsu.u_store_queue.queue[si].data,
                                             u_core.u_lsu.u_store_queue.queue[si].byte_mask);
                                end
                            end
                            for (int ci = 0; ci < CSB_DEPTH; ci++) begin
                                if (u_core.u_lsu.u_csb.buf_q[ci].valid &&
                                    ((u_core.u_lsu.u_csb.buf_q[ci].addr[63:3] ==
                                      u_core.u_lsu.load_eff_addr[0][63:3]) ||
                                     ((linux_trace_any_line_en != 0) &&
                                      linux_trace_line_match(u_core.u_lsu.u_csb.buf_q[ci].addr)))) begin
                                    $display("[LINUX_CSB_MATCH] cyc=%0d idx=%0d data=%016h mask=%02h",
                                             sim_cycle,
                                             ci,
                                             u_core.u_lsu.u_csb.buf_q[ci].data,
                                             u_core.u_lsu.u_csb.buf_q[ci].byte_mask);
                                end
                            end
                        end
                    end
                    if (u_core.dc_load_req_valid[li] &&
                        (linux_trace_any_line_en != 0) &&
                        linux_trace_line_match(u_core.dc_load_req_addr[li])) begin
                        $display("[LINUX_DC_REQ] cyc=%0d p%0d addr=%016h size=%0d resp_valid=%0b hit=%0b",
                                 sim_cycle, li,
                                 u_core.dc_load_req_addr[li],
                                 u_core.dc_load_req_size[li],
                                 u_core.dc_load_resp_valid[li],
                                 u_core.dc_load_resp_hit[li]);
                    end
                    if (u_core.lsu_load_wb_valid[li]) begin
                        for (int ti = 0; ti < TRACE_LOAD_TRACK; ti++) begin
                            if (trace_load_valid[ti] &&
                                (trace_load_rob[ti] == u_core.lsu_load_wb_rob_idx[li]) &&
                                (trace_load_pdst[ti] == u_core.lsu_load_wb_pdst[li])) begin
                                $display("[LINUX_LOAD_WB_TARGET] cyc=%0d p%0d rob=%0d pdst=%0d pc=%016h addr=%016h data=%016h exc=%0b",
                                         sim_cycle, li,
                                         u_core.lsu_load_wb_rob_idx[li],
                                         u_core.lsu_load_wb_pdst[li],
                                         trace_load_pc[ti],
                                         trace_load_addr[ti],
                                         u_core.lsu_load_wb_data[li],
                                         u_core.lsu_load_wb_has_exception[li]);
                                trace_load_valid[ti] <= 1'b0;
                            end
                        end
                    end
                end
                if (u_core.dc_fill_snoop_valid &&
                    (linux_trace_any_line_en != 0) &&
                    linux_trace_line_match(u_core.dc_fill_snoop_addr)) begin
                    $display("[LINUX_DC_FILL] cyc=%0d addr=%016h d08=%016h d30=%016h",
                             sim_cycle, u_core.dc_fill_snoop_addr,
                             u_core.dc_fill_snoop_data[8*8 +: 64],
                             u_core.dc_fill_snoop_data[48*8 +: 64]);
                end
            end

            if ((linux_trace_amo_en != 0) && linux_trace_cycle_on) begin
                if (u_core.iq_load_issue_candidate_valid[0] &&
                    u_core.iq_load_issue_data[0].is_amo) begin
                    $display("[LINUX_AMO_CAND] cyc=%0d pc=%016h rob=%0d op=%0d suppress=%0b raw=%0b valid=%0b addr=%016h dcreq=%0b p0fwd=%0b sq_hit=%0b sq_wait=%0b sq_part=%0b csb_hit=%0b sta_old=%0b busy=%0b wait=%0b store=%0b committed=%0b req=%0b wb=%0b flush=%0b/%0b/%0d head=%0d tail=%0d partial=%0b kill=%0b",
                             sim_cycle,
                             u_core.iq_load_issue_data[0].pc,
                             u_core.iq_load_issue_data[0].rob_idx,
                             u_core.iq_load_issue_data[0].amo_op,
                             u_core.lsu_load_issue_suppress[0],
                             u_core.lsu_load_issue_suppress_raw[0],
                             u_core.u_lsu.load_issue_valid[0],
                             u_core.u_lsu.load_eff_addr[0],
                             u_core.u_lsu.dcache_load_req_valid[0],
                             u_core.u_lsu.p0_fwd_hit,
                             u_core.u_lsu.sq_fwd_hit,
                             u_core.u_lsu.sq_fwd_wait,
                             u_core.u_lsu.sq_fwd_partial,
                             u_core.u_lsu.csb_fwd_hit,
                             u_core.u_lsu.sta_older_than_load0,
                             u_core.u_lsu.amo_busy,
                             u_core.u_lsu.amo_wait_load_r,
                             u_core.u_lsu.amo_store_valid_r,
                             u_core.u_lsu.amo_store_committed_r,
                             u_core.u_lsu.amo_store_req_valid,
                             u_core.u_lsu.amo_wb_valid_r,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx,
                             u_core.rob_head_idx,
                             u_core.rob_tail_idx,
                             u_core.rename_buf_partial_clear[u_core.iq_load_issue_data[0].rob_idx],
                             u_core.u_lsu.amo_flush_kill);
                end
                if (u_core.flush_out.valid &&
                    (u_core.u_lsu.amo_busy ||
                     (u_core.iq_load_issue_candidate_valid[0] &&
                      u_core.iq_load_issue_data[0].is_amo))) begin
                    $display("[LINUX_AMO_FLUSH] cyc=%0d valid=%0b full=%0b rob_tail=%0d redirect=%016h head=%0d tail=%0d busy=%0b wait=%0b store=%0b committed=%0b req=%0b wb=%0b amo_rob=%0d kill=%0b live_wb=%0b/%0b lsu_wb=%0b/%0b",
                             sim_cycle,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx,
                             u_core.flush_out.redirect_pc,
                             u_core.rob_head_idx,
                             u_core.rob_tail_idx,
                             u_core.u_lsu.amo_busy,
                             u_core.u_lsu.amo_wait_load_r,
                             u_core.u_lsu.amo_store_valid_r,
                             u_core.u_lsu.amo_store_committed_r,
                             u_core.u_lsu.amo_store_req_valid,
                             u_core.u_lsu.amo_wb_valid_r,
                             u_core.u_lsu.amo_data_r.rob_idx,
                             u_core.u_lsu.amo_flush_kill,
                             u_core.load_wb_valid_live[0],
                             u_core.load_wb_valid_live[1],
                             u_core.lsu_load_wb_valid[0],
                             u_core.lsu_load_wb_valid[1]);
                end
                if (u_core.u_lsu.amo_load_issue_fire) begin
                    $display("[LINUX_AMO_LOAD_FIRE] cyc=%0d pc=%016h rob=%0d addr=%016h rs2=%016h dcreq=%0b",
                             sim_cycle,
                             u_core.u_lsu.load_issue_data[0].pc,
                             u_core.u_lsu.load_issue_data[0].rob_idx,
                             u_core.u_lsu.load_eff_addr[0],
                             u_core.u_lsu.load_rs2[0],
                             u_core.u_lsu.dcache_load_req_valid[0]);
                end
                if (u_core.u_lsu.amo_load_hit_fire ||
                    u_core.u_lsu.amo_load_fill_fire) begin
                    $display("[LINUX_AMO_LOAD_DONE] cyc=%0d hit=%0b fill=%0b rob=%0d addr=%016h old=%016h new_data=%016h mask=%02h",
                             sim_cycle,
                             u_core.u_lsu.amo_load_hit_fire,
                             u_core.u_lsu.amo_load_fill_fire,
                             u_core.u_lsu.amo_data_r.rob_idx,
                             u_core.u_lsu.amo_addr_r,
                             u_core.u_lsu.amo_load_value,
                             u_core.u_lsu.amo_store_data_calc,
                             u_core.u_lsu.amo_store_mask_calc);
                end
                if (u_core.u_lsu.amo_store_valid_r ||
                    u_core.u_lsu.amo_store_ack_fire) begin
                    $display("[LINUX_AMO_STORE] cyc=%0d valid=%0b committed=%0b req=%0b ack=%0b commit_fire=%0b rob=%0d addr=%016h data=%016h mask=%02h dc_ack=%0b flush=%0b/%0b/%0d kill=%0b",
                             sim_cycle,
                             u_core.u_lsu.amo_store_valid_r,
                             u_core.u_lsu.amo_store_committed_r,
                             u_core.u_lsu.amo_store_req_valid,
                             u_core.u_lsu.amo_store_ack_fire,
                             u_core.u_lsu.amo_store_commit_fire,
                             u_core.u_lsu.amo_data_r.rob_idx,
                             u_core.u_lsu.amo_addr_r,
                             u_core.u_lsu.amo_store_data_r,
                             u_core.u_lsu.amo_store_mask_r,
                             u_core.dc_store_ack,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx,
                             u_core.u_lsu.amo_flush_kill);
                end
                if (u_core.u_lsu.amo_wb_valid_r) begin
                    $display("[LINUX_AMO_WB] cyc=%0d rob=%0d pdst=%0d data=%016h flush=%0b/%0b/%0d live=%0b lsu=%0b top_r=%0b partial=%0b",
                             sim_cycle,
                             u_core.u_lsu.amo_wb_rob_idx_r,
                             u_core.u_lsu.amo_wb_pdst_r,
                             u_core.u_lsu.amo_wb_data_r,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx,
                             u_core.load_wb_valid_live[0],
                             u_core.lsu_load_wb_valid[0],
                             u_core.load_wb_valid_r[0],
                             u_core.rename_buf_partial_clear[u_core.u_lsu.amo_wb_rob_idx_r]);
                end
            end

            if ((linux_trace_any_line_en != 0) && linux_trace_cycle_on) begin
                if (u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_req_valid &&
                    linux_trace_line_match(u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_req_addr)) begin
                    $display("[LINUX_IC_L2_REQ] cyc=%0d addr=%016h accepted=%0b ready=%0b s1_v=%0b s1_addr=%016h hit=%0b m0_v=%0b m0_addr=%016h m0_sent=%0b m0_done=%0b m1_v=%0b m1_addr=%016h m1_sent=%0b m1_done=%0b need=%0b req_idx=%0d match=%0b",
                             sim_cycle,
                             u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_req_addr,
                             u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_req_accepted,
                             u_core.u_l2_cache.icache_req_ready,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.s1_valid,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.s1_addr,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.cache_hit,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_valid[0],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_addr[0],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_req_sent[0],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_fill_done[0],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_valid[1],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_addr[1],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_req_sent[1],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_fill_done[1],
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_need_req,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_req_idx,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_addr_match);
                end
                if (u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_resp_valid &&
                    linux_trace_line_match(u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_resp_addr)) begin
                    $display("[LINUX_IC_L2_RESP] cyc=%0d addr=%016h sc_inst=%0b sc_idx=%0d mshr_fwd=%0b resp_v=%0b resp_hit=%0b icq_full=%0b icq_count=%0d",
                             sim_cycle,
                             u_core.u_fetch_top.u_ifu_line_fetch.icache_fill_resp_addr,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.sc_install_valid,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.sc_install_idx,
                             u_core.u_fetch_top.u_ifu_line_fetch.u_icache.mshr_fwd_valid,
                             u_core.u_fetch_top.u_ifu_line_fetch.ic_resp_valid_comb,
                             u_core.u_fetch_top.u_ifu_line_fetch.ic_resp_hit_comb,
                             u_core.u_fetch_top.u_ifu_line_fetch.icq_full_o,
                             u_core.u_fetch_top.u_ifu_line_fetch.icq_count_o);
                end
                if (u_core.u_fetch_top.pf_l2_req_valid &&
                    linux_trace_line_match(u_core.u_fetch_top.pf_l2_req_addr)) begin
                    $display("[LINUX_PF_L2_REQ] cyc=%0d addr=%016h ready=%0b",
                             sim_cycle,
                             u_core.u_fetch_top.pf_l2_req_addr,
                             u_core.u_fetch_top.pf_l2_req_ready);
                end
                if (u_core.u_fetch_top.u_ifu_line_fetch.pf_l2_resp_valid &&
                    linux_trace_line_match(u_core.u_fetch_top.u_ifu_line_fetch.pf_l2_resp_addr)) begin
                    $display("[LINUX_PF_L2_RESP] cyc=%0d addr=%016h",
                             sim_cycle,
                             u_core.u_fetch_top.u_ifu_line_fetch.pf_l2_resp_addr);
                end
                if (u_core.u_dcache.ld0_new_miss_req &&
                    linux_trace_line_match(u_core.u_dcache.ld0_line_addr)) begin
                    $display("[LINUX_DMISS0] cyc=%0d line=%016h free=%0b alloc=%0b merge=%0b l2_state=%0d active=%0d fill_avail=%0b fill_idx=%0d wb_avail=%0b wb_idx=%0d",
                             sim_cycle, u_core.u_dcache.ld0_line_addr,
                             u_core.u_dcache.mshr_free_avail,
                             u_core.u_dcache.ld0_miss_alloc_sel,
                             u_core.u_dcache.ld0_miss_merge_req,
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q,
                             u_core.u_dcache.fill_mshr_avail,
                             u_core.u_dcache.fill_mshr_idx,
                             u_core.u_dcache.wb_mshr_avail,
                             u_core.u_dcache.wb_mshr_idx);
                    $display("[LINUX_LSU_MISS0_TERM] cyc=%0d detect=%0b keep=%0b valid_r=%0b nocache=%0b amo=%0b resp=%0b retry=%0b lmb_free=%0b lmb_retry=%0b r_pc=%016h r_rob=%0d r_lq=%0d r_addr=%016h cur_valid=%0b cur_pc=%016h cur_rob=%0d cur_lq=%0d flush=%0b/%0b/%0d",
                             sim_cycle,
                             u_core.u_lsu.p0_miss_detect,
                             u_core.u_lsu.load_pipe_flush_keep[0],
                             u_core.u_lsu.load_issue_valid_r[0],
                             u_core.u_lsu.load_nocache_r[0],
                             u_core.u_lsu.load_issue_data_r[0].is_amo,
                             u_core.dc_load_resp_valid[0],
                             u_core.dc_load_miss_retry[0],
                             u_core.u_lsu.lmb_free_avail,
                             u_core.u_lsu.p0_lmb_retry_req,
                             u_core.u_lsu.load_issue_data_r[0].pc,
                             u_core.u_lsu.load_issue_data_r[0].rob_idx,
                             u_core.u_lsu.load_issue_data_r[0].lq_idx,
                             u_core.u_lsu.load_eff_addr_r[0],
                             u_core.u_lsu.load_issue_valid[0],
                             u_core.u_lsu.load_issue_data[0].pc,
                             u_core.u_lsu.load_issue_data[0].rob_idx,
                             u_core.u_lsu.load_issue_data[0].lq_idx,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx);
                end
                if (u_core.u_dcache.ld1_new_miss_req &&
                    linux_trace_line_match(u_core.u_dcache.ld1_line_addr)) begin
                    $display("[LINUX_DMISS1] cyc=%0d line=%016h free=%0b alloc=%0b merge=%0b same_line_block=%0b diff_line_block=%0b retry=%0b l2_state=%0d active=%0d fill_avail=%0b fill_idx=%0d wb_avail=%0b wb_idx=%0d",
                             sim_cycle,
                             u_core.u_dcache.ld1_line_addr,
                             u_core.u_dcache.mshr_free_avail,
                             u_core.u_dcache.ld1_miss_alloc_sel,
                             u_core.u_dcache.ld1_miss_merge_req,
                             u_core.u_dcache.ld1_new_blocked_same_line,
                             u_core.u_dcache.ld1_new_blocked_diff_line,
                             u_core.dc_load_miss_retry[1],
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q,
                             u_core.u_dcache.fill_mshr_avail,
                             u_core.u_dcache.fill_mshr_idx,
                             u_core.u_dcache.wb_mshr_avail,
                             u_core.u_dcache.wb_mshr_idx);
                    $display("[LINUX_LSU_MISS1_TERM] cyc=%0d detect=%0b keep=%0b valid_r=%0b nocache=%0b amo=%0b resp=%0b retry=%0b lmb_free=%0b lmb_retry=%0b r_pc=%016h r_rob=%0d r_lq=%0d r_addr=%016h cur_valid=%0b cur_pc=%016h cur_rob=%0d cur_lq=%0d flush=%0b/%0b/%0d",
                             sim_cycle,
                             u_core.u_lsu.p1_miss_detect,
                             u_core.u_lsu.load_pipe_flush_keep[1],
                             u_core.u_lsu.load_issue_valid_r[1],
                             u_core.u_lsu.load_nocache_r[1],
                             u_core.u_lsu.load_issue_data_r[1].is_amo,
                             u_core.dc_load_resp_valid[1],
                             u_core.dc_load_miss_retry[1],
                             u_core.u_lsu.lmb_p1_alloc_avail,
                             u_core.u_lsu.p1_lmb_retry_req,
                             u_core.u_lsu.load_issue_data_r[1].pc,
                             u_core.u_lsu.load_issue_data_r[1].rob_idx,
                             u_core.u_lsu.load_issue_data_r[1].lq_idx,
                             u_core.u_lsu.load_eff_addr_r[1],
                             u_core.u_lsu.load_issue_valid[1],
                             u_core.u_lsu.load_issue_data[1].pc,
                             u_core.u_lsu.load_issue_data[1].rob_idx,
                             u_core.u_lsu.load_issue_data[1].lq_idx,
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx);
                end
                if (u_core.u_dcache.ld0_miss_merge_req &&
                    linux_trace_line_match(u_core.u_dcache.ld0_line_addr)) begin
                    $display("[LINUX_DMERGE0] cyc=%0d line=%016h match_idx=%0d m0_valid=%0b m0_addr=%016h m0_fill_pend=%0b m0_wb_pend=%0b m0_done=%0b m0_store=%0b m1_valid=%0b m1_addr=%016h m1_fill_pend=%0b m1_wb_pend=%0b m1_done=%0b m1_store=%0b l2_state=%0d active=%0d fill_avail=%0b fill_idx=%0d wb_avail=%0b wb_idx=%0d",
                             sim_cycle, u_core.u_dcache.ld0_line_addr,
                             u_core.u_dcache.mshr_match_idx,
                             u_core.u_dcache.mshr[0].valid,
                             u_core.u_dcache.mshr[0].addr,
                             u_core.u_dcache.mshr[0].fill_pend,
                             u_core.u_dcache.mshr[0].writeback_pend,
                             u_core.u_dcache.mshr[0].fill_done,
                             u_core.u_dcache.mshr[0].store_pending,
                             u_core.u_dcache.mshr[1].valid,
                             u_core.u_dcache.mshr[1].addr,
                             u_core.u_dcache.mshr[1].fill_pend,
                             u_core.u_dcache.mshr[1].writeback_pend,
                             u_core.u_dcache.mshr[1].fill_done,
                             u_core.u_dcache.mshr[1].store_pending,
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q,
                             u_core.u_dcache.fill_mshr_avail,
                             u_core.u_dcache.fill_mshr_idx,
                             u_core.u_dcache.wb_mshr_avail,
                             u_core.u_dcache.wb_mshr_idx);
                end
                if (u_core.u_dcache.ld1_miss_merge_req &&
                    linux_trace_line_match(u_core.u_dcache.ld1_line_addr)) begin
                    $display("[LINUX_DMERGE1] cyc=%0d line=%016h match_idx=%0d m0_valid=%0b m0_addr=%016h m0_fill_pend=%0b m0_wb_pend=%0b m0_done=%0b m0_store=%0b m1_valid=%0b m1_addr=%016h m1_fill_pend=%0b m1_wb_pend=%0b m1_done=%0b m1_store=%0b l2_state=%0d active=%0d fill_avail=%0b fill_idx=%0d wb_avail=%0b wb_idx=%0d",
                             sim_cycle, u_core.u_dcache.ld1_line_addr,
                             u_core.u_dcache.mshr_ld1_match_idx,
                             u_core.u_dcache.mshr[0].valid,
                             u_core.u_dcache.mshr[0].addr,
                             u_core.u_dcache.mshr[0].fill_pend,
                             u_core.u_dcache.mshr[0].writeback_pend,
                             u_core.u_dcache.mshr[0].fill_done,
                             u_core.u_dcache.mshr[0].store_pending,
                             u_core.u_dcache.mshr[1].valid,
                             u_core.u_dcache.mshr[1].addr,
                             u_core.u_dcache.mshr[1].fill_pend,
                             u_core.u_dcache.mshr[1].writeback_pend,
                             u_core.u_dcache.mshr[1].fill_done,
                             u_core.u_dcache.mshr[1].store_pending,
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q,
                             u_core.u_dcache.fill_mshr_avail,
                             u_core.u_dcache.fill_mshr_idx,
                             u_core.u_dcache.wb_mshr_avail,
                             u_core.u_dcache.wb_mshr_idx);
                end
                if (u_core.u_lsu.p0_miss_detect &&
                    linux_trace_line_match(u_core.u_lsu.load_eff_addr_r[0])) begin
                    $display("[LINUX_LSU_MISS0] cyc=%0d pc=%016h rob=%0d lq=%0d addr=%016h retry=%0b free=%0b alloc=%0b fill_hit=%0b keep=%0b flush=%0b/%0b/%0d",
                             sim_cycle,
                             u_core.u_lsu.load_issue_data_r[0].pc,
                             u_core.u_lsu.load_issue_data_r[0].rob_idx,
                             u_core.u_lsu.load_issue_data_r[0].lq_idx,
                             u_core.u_lsu.load_eff_addr_r[0],
                             u_core.u_lsu.p0_lmb_retry_req,
                             u_core.u_lsu.lmb_free_avail,
                             u_core.u_lsu.p0_miss_detect &&
                                 u_core.u_lsu.lmb_free_avail,
                             u_core.u_lsu.p0_miss_fill_hit,
                             u_core.u_lsu.load_pipe_flush_keep[0],
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx);
                end
                if (u_core.u_lsu.p1_miss_detect &&
                    linux_trace_line_match(u_core.u_lsu.load_eff_addr_r[1])) begin
                    $display("[LINUX_LSU_MISS1] cyc=%0d pc=%016h rob=%0d lq=%0d addr=%016h retry=%0b free=%0b alloc=%0b fill_hit=%0b keep=%0b flush=%0b/%0b/%0d",
                             sim_cycle,
                             u_core.u_lsu.load_issue_data_r[1].pc,
                             u_core.u_lsu.load_issue_data_r[1].rob_idx,
                             u_core.u_lsu.load_issue_data_r[1].lq_idx,
                             u_core.u_lsu.load_eff_addr_r[1],
                             u_core.u_lsu.p1_lmb_retry_req,
                             u_core.u_lsu.lmb_p1_alloc_avail,
                             u_core.u_lsu.p1_miss_detect &&
                                 u_core.u_lsu.lmb_p1_alloc_avail,
                             u_core.u_lsu.p1_miss_fill_hit,
                             u_core.u_lsu.load_pipe_flush_keep[1],
                             u_core.flush_out.valid,
                             u_core.flush_out.full_flush,
                             u_core.flush_out.rob_idx);
                end
                if (u_core.u_lsu.lmb_any_match &&
                    linux_trace_line_match(u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].line_addr)) begin
                    $display("[LINUX_LMB_FILL_MATCH] cyc=%0d idx=%0d pc=%016h rob=%0d lq=%0d line=%016h wb_free=%0b ready_any=%0b",
                             sim_cycle,
                             u_core.u_lsu.lmb_match_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].pc,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].rob_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].lq_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_match_idx].line_addr,
                             u_core.u_lsu.lmb_wb_port_free,
                             u_core.u_lsu.lmb_ready_any);
                end
                if (u_core.u_lsu.lmb_ready_any &&
                    linux_trace_line_match(u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].line_addr)) begin
                    $display("[LINUX_LMB_READY] cyc=%0d idx=%0d pc=%016h rob=%0d lq=%0d line=%016h wb_free=%0b any_match=%0b",
                             sim_cycle,
                             u_core.u_lsu.lmb_ready_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].pc,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].rob_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].lq_idx,
                             u_core.u_lsu.lmb[u_core.u_lsu.lmb_ready_idx].line_addr,
                             u_core.u_lsu.lmb_wb_port_free,
                             u_core.u_lsu.lmb_any_match);
                end
                if (u_core.dc_l2_req_valid &&
                    linux_trace_line_match(u_core.dc_l2_req_addr)) begin
                    $display("[LINUX_DC_L2_REQ] cyc=%0d we=%0b addr=%016h ready=%0b w08=%016h w30=%016h wt_count=%0d wt_head=%0d wt_tail=%0d l2_hit=%0b l2_match=%0b l2_free=%0b l2_inv_wb=%0b",
                             sim_cycle, u_core.dc_l2_req_we,
                             u_core.dc_l2_req_addr, u_core.dc_l2_req_ready,
                             u_core.dc_l2_req_wdata[8*8 +: 64],
                             u_core.dc_l2_req_wdata[48*8 +: 64],
                             u_core.u_dcache.wt_count_q,
                             u_core.u_dcache.wt_head_q,
                             u_core.u_dcache.wt_tail_q,
                             u_core.u_l2_cache.hit_any,
                             u_core.u_l2_cache.mshr_addr_match,
                             u_core.u_l2_cache.mshr_has_free,
                             u_core.u_l2_cache.inv_wb_pending);
                end
                if (u_core.dc_l2_resp_valid &&
                    linux_trace_line_match(u_core.dc_l2_resp_addr)) begin
                    $display("[LINUX_DC_L2_RESP] cyc=%0d addr=%016h r08=%016h r30=%016h",
                             sim_cycle, u_core.dc_l2_resp_addr,
                             u_core.dc_l2_resp_data[8*8 +: 64],
                             u_core.dc_l2_resp_data[48*8 +: 64]);
                end
                if (u_core.u_lsu.sq_drain_valid &&
                    linux_trace_line_match(u_core.u_lsu.sq_drain_entry.addr)) begin
                    $display("[LINUX_SQ_DRAIN] cyc=%0d ready=%0b rob=%0d addr=%016h data=%016h mask=%02h size=%0d head=%0d count=%0d",
                             sim_cycle,
                             u_core.u_lsu.sq_drain_ready,
                             u_core.u_lsu.sq_drain_entry.rob_idx,
                             u_core.u_lsu.sq_drain_entry.addr,
                             u_core.u_lsu.sq_drain_entry.data,
                             u_core.u_lsu.sq_drain_entry.byte_mask,
                             u_core.u_lsu.sq_drain_entry.size,
                             u_core.u_lsu.u_store_queue.head_r,
                             u_core.u_lsu.u_store_queue.count_r);
                end
                if (u_core.u_lsu.csb_deq_valid &&
                    linux_trace_line_match(u_core.u_lsu.csb_deq_addr)) begin
                    $display("[LINUX_CSB_DEQ] cyc=%0d ack=%0b addr=%016h data=%016h mask=%02h size=%0d head=%0d count=%0d split=%0b active=%0b",
                             sim_cycle,
                             u_core.u_lsu.csb_deq_ack,
                             u_core.u_lsu.csb_deq_addr,
                             u_core.u_lsu.csb_deq_data,
                             u_core.u_lsu.csb_deq_byte_mask,
                             u_core.u_lsu.csb_deq_size,
                             u_core.u_lsu.u_csb.head_r,
                             u_core.u_lsu.u_csb.count_r,
                             u_core.u_lsu.csb_deq_cross_line,
                             u_core.u_lsu.split_store_active_r);
                end
                if (u_core.dc_store_req_valid &&
                    linux_trace_line_match(u_core.dc_store_req_addr)) begin
                    $display("[LINUX_DC_STORE] cyc=%0d addr=%016h data=%016h mask=%02h ack=%0b",
                             sim_cycle,
                             u_core.dc_store_req_addr,
                             u_core.dc_store_req_data,
                             u_core.dc_store_req_byte_mask,
                             u_core.dc_store_ack);
                end
                if (mem_req_valid && !mem_req_we &&
                    linux_trace_line_match(mem_req_addr)) begin
                    $display("[LINUX_MEM_REQ] cyc=%0d addr=%016h ready=%0b issue_idx=%0d issue_src=%0d respq_count=%0d",
                             sim_cycle,
                             mem_req_addr,
                             mem_req_ready,
                             u_core.u_l2_cache.mshr_issue_idx,
                             u_core.u_l2_cache.mshr[u_core.u_l2_cache.mshr_issue_idx].source,
                             u_core.u_l2_cache.respq_count_q);
                end
                if (mem_resp_valid && mem_read_pending_r &&
                    linux_trace_line_match(mem_read_addr_r)) begin
                    $display("[LINUX_MEM_RESP] cyc=%0d addr=%016h resp_found=%0b resp_idx=%0d resp_src=%0d respq_count=%0d direct=%0b enq=%0b deq=%0b",
                             sim_cycle,
                             mem_read_addr_r,
                             u_core.u_l2_cache.mshr_resp_found,
                             u_core.u_l2_cache.mshr_resp_idx,
                             u_core.u_l2_cache.mshr[u_core.u_l2_cache.mshr_resp_idx].source,
                             u_core.u_l2_cache.respq_count_q,
                             u_core.u_l2_cache.mem_resp_direct,
                             u_core.u_l2_cache.respq_enq,
                             u_core.u_l2_cache.respq_deq);
                end
            end

            if ((linux_trace_preempt_pa_en != 0) && linux_trace_cycle_on) begin
                if (u_core.u_lsu.sq_drain_valid &&
                    linux_trace_preempt_match(u_core.u_lsu.sq_drain_entry.addr)) begin
                    $display("[LINUX_PREEMPT_SQ_DRAIN] cyc=%0d ready=%0b rob=%0d addr=%016h data=%016h mask=%02h size=%0d head=%0d count=%0d",
                             sim_cycle,
                             u_core.u_lsu.sq_drain_ready,
                             u_core.u_lsu.sq_drain_entry.rob_idx,
                             u_core.u_lsu.sq_drain_entry.addr,
                             u_core.u_lsu.sq_drain_entry.data,
                             u_core.u_lsu.sq_drain_entry.byte_mask,
                             u_core.u_lsu.sq_drain_entry.size,
                             u_core.u_lsu.u_store_queue.head_r,
                             u_core.u_lsu.u_store_queue.count_r);
                end
                if (u_core.dc_store_req_valid &&
                    linux_trace_preempt_match(u_core.dc_store_req_addr)) begin
                    $display("[LINUX_PREEMPT_DC_STORE] cyc=%0d addr=%016h data=%016h mask=%02h ack=%0b",
                             sim_cycle,
                             u_core.dc_store_req_addr,
                             u_core.dc_store_req_data,
                             u_core.dc_store_req_byte_mask,
                             u_core.dc_store_ack);
                end
            end

            if (linux_trace_l2_en != 0) begin
                if (u_core.dc_l2_req_valid) begin
                    $display("[LINUX_DC_L2_REQ_ANY] cyc=%0d we=%0b addr=%016h ready=%0b dc_state=%0d dc_active=%0d dc_m0=%016h dc_m0_fp=%0b dc_m1=%016h dc_m1_fp=%0b l2_hit=%0b l2_dup=%0b l2_free=%0b l2_full=%0b",
                             sim_cycle,
                             u_core.dc_l2_req_we,
                             u_core.dc_l2_req_addr,
                             u_core.dc_l2_req_ready,
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q,
                             u_core.u_dcache.mshr[0].addr,
                             u_core.u_dcache.mshr[0].fill_pend,
                             u_core.u_dcache.mshr[1].addr,
                             u_core.u_dcache.mshr[1].fill_pend,
                             u_core.u_l2_cache.hit_any,
                             u_core.u_l2_cache.mshr_addr_match,
                             u_core.u_l2_cache.mshr_has_free,
                             u_core.u_l2_cache.mshr_full);
                end
                if (u_core.dc_l2_resp_valid) begin
                    $display("[LINUX_DC_L2_RESP_ANY] cyc=%0d addr=%016h dc_state=%0d dc_active=%0d",
                             sim_cycle,
                             u_core.dc_l2_resp_addr,
                             u_core.u_dcache.l2_state_q,
                             u_core.u_dcache.l2_active_mshr_q);
                end
                if (mem_req_valid && mem_req_ready) begin
                    $display("[LINUX_MEM_REQ_ANY] cyc=%0d we=%0b addr=%016h l2_issue=%0b l2_issue_idx=%0d l2_inv_wb=%0b",
                             sim_cycle,
                             mem_req_we,
                             mem_req_addr,
                             u_core.u_l2_cache.mshr_has_issue,
                             u_core.u_l2_cache.mshr_issue_idx,
                             u_core.u_l2_cache.inv_wb_pending);
                end
                if (mem_resp_valid) begin
                    $display("[LINUX_MEM_RESP_ANY] cyc=%0d l2_found=%0b l2_resp_idx=%0d",
                             sim_cycle,
                             u_core.u_l2_cache.mshr_resp_found,
                             u_core.u_l2_cache.mshr_resp_idx);
                end
            end

            mem_read_pending_r <= mem_req_valid && !mem_req_we && mem_req_ready;
            if (mem_req_valid && !mem_req_we && mem_req_ready)
                mem_read_addr_r <= mem_req_addr;

            if (uart_tx_valid) begin
                if (uart_stdout_en != 0)
                    $write("%c", uart_tx_data);
                if (uart_log_fd != 0)
                    $fwrite(uart_log_fd, "%c", uart_tx_data);
                if ((uart_tx_data == 8'h0a) || (uart_tx_data == 8'h0d)) begin
                    if (uart_stdout_en != 0)
                        $fflush();
                    if (uart_log_fd != 0)
                        $fflush(uart_log_fd);
                end

                if (smoke_check_en != 0) begin
                    if (uart_tx_data == smoke_pattern[smoke_idx]) begin
                        smoke_idx <= smoke_idx + 1;
                        if ((smoke_idx + 1) == smoke_pattern.len()) begin
                            $display("PASS: UART smoke matched at cycle %0d", sim_cycle);
                            $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                                     perf_mcycle, perf_minstret,
                                     $itor(perf_minstret) / $itor(perf_mcycle));
                            $finish;
                        end
                    end else if (uart_tx_data == smoke_pattern[0]) begin
                        smoke_idx <= 1;
                    end else begin
                        smoke_idx <= 0;
                    end
                end

                if ((uart_fail_stop_en != 0) && !uart_fail_pending_r) begin
                    if (uart_tx_data == uart_fail_panic_pattern[uart_fail_panic_idx]) begin
                        uart_fail_panic_idx <= uart_fail_panic_idx + 1;
                        if ((uart_fail_panic_idx + 1) == uart_fail_panic_pattern.len()) begin
                            $display("[LINUX_STOP_UART_FAILURE] pattern=\"%s\" cyc=%0d delay=%0d last_pc=%016h satp=%016h trap=%0b cause=%016h val=%016h rob_head=%0d rob_tail=%0d last_commit_cyc=%0d",
                                     uart_fail_panic_pattern,
                                     sim_cycle,
                                     uart_fail_delay_cycles,
                                     last_commit_pc,
                                     u_core.csr_satp,
                                     u_core.trap_valid,
                                     u_core.trap_cause,
                                     u_core.trap_val,
                                     u_core.rob_head_idx,
                                     u_core.rob_tail_idx,
                                     last_commit_cycle);
                            if (uart_fail_delay_cycles > 0) begin
                                uart_fail_pending_r <= 1'b1;
                                uart_fail_cycle_r <= sim_cycle;
                            end else begin
                                $finish;
                            end
                        end
                    end else if (uart_tx_data == uart_fail_panic_pattern[0]) begin
                        uart_fail_panic_idx <= 1;
                    end else begin
                        uart_fail_panic_idx <= 0;
                    end

                    if (uart_tx_data == uart_fail_oops_pattern[uart_fail_oops_idx]) begin
                        uart_fail_oops_idx <= uart_fail_oops_idx + 1;
                        if ((uart_fail_oops_idx + 1) == uart_fail_oops_pattern.len()) begin
                            $display("[LINUX_STOP_UART_FAILURE] pattern=\"%s\" cyc=%0d delay=%0d last_pc=%016h satp=%016h trap=%0b cause=%016h val=%016h rob_head=%0d rob_tail=%0d last_commit_cyc=%0d",
                                     uart_fail_oops_pattern,
                                     sim_cycle,
                                     uart_fail_delay_cycles,
                                     last_commit_pc,
                                     u_core.csr_satp,
                                     u_core.trap_valid,
                                     u_core.trap_cause,
                                     u_core.trap_val,
                                     u_core.rob_head_idx,
                                     u_core.rob_tail_idx,
                                     last_commit_cycle);
                            if (uart_fail_delay_cycles > 0) begin
                                uart_fail_pending_r <= 1'b1;
                                uart_fail_cycle_r <= sim_cycle;
                            end else begin
                                $finish;
                            end
                        end
                    end else if (uart_tx_data == uart_fail_oops_pattern[0]) begin
                        uart_fail_oops_idx <= 1;
                    end else begin
                        uart_fail_oops_idx <= 0;
                    end

                    if (uart_tx_data == uart_fail_bug_pattern[uart_fail_bug_idx]) begin
                        uart_fail_bug_idx <= uart_fail_bug_idx + 1;
                        if ((uart_fail_bug_idx + 1) == uart_fail_bug_pattern.len()) begin
                            $display("[LINUX_STOP_UART_FAILURE] pattern=\"%s\" cyc=%0d delay=%0d last_pc=%016h satp=%016h trap=%0b cause=%016h val=%016h rob_head=%0d rob_tail=%0d last_commit_cyc=%0d",
                                     uart_fail_bug_pattern,
                                     sim_cycle,
                                     uart_fail_delay_cycles,
                                     last_commit_pc,
                                     u_core.csr_satp,
                                     u_core.trap_valid,
                                     u_core.trap_cause,
                                     u_core.trap_val,
                                     u_core.rob_head_idx,
                                     u_core.rob_tail_idx,
                                     last_commit_cycle);
                            if (uart_fail_delay_cycles > 0) begin
                                uart_fail_pending_r <= 1'b1;
                                uart_fail_cycle_r <= sim_cycle;
                            end else begin
                                $finish;
                            end
                        end
                    end else if (uart_tx_data == uart_fail_bug_pattern[0]) begin
                        uart_fail_bug_idx <= 1;
                    end else begin
                        uart_fail_bug_idx <= 0;
                    end
                end
            end

            if (uart_fail_pending_r &&
                ((sim_cycle - uart_fail_cycle_r) >= uart_fail_delay_cycles)) begin
                $display("[LINUX_STOP_UART_FAILURE_DELAY_DONE] cyc=%0d first_failure_cyc=%0d delay=%0d",
                         sim_cycle,
                         uart_fail_cycle_r,
                         uart_fail_delay_cycles);
                $finish;
            end

            if ((status_en != 0) && (status_interval > 0) &&
                (sim_cycle > 0) && ((sim_cycle % status_interval) == 0)) begin
                $display("[LINUX_STATUS] cyc=%0d mcycle=%0d minstret=%0d priv=%0d satp=%016h mstatus=%016h mie=%016h mip=%016h mideleg=%016h last_pc=%016h a3=%016h a4=%016h last_commit_cyc=%0d commit_count=%0d rob_empty=%0b rob_head=%0d rob_tail=%0d rob_free=%0d trap=%0b trap_cause=%016h trap_val=%016h irq_pending=%0b irq_cause=%016h mtip=%0b msip=%0b time=%016h timecmp=%016h mmio_req=%0b mmio_wait=%0b mmio_we=%0b mmio_addr=%016h mmio_count=%0d uart_rd=%0d uart_wr=%0d f1_valid=%0b f1_pc=%016h fe_stall=%0b work_v=%0b work_pc=%016h work_line=%014h work_owner=%0b work_deliv=%0b data_v=%0b seq=%016h extract=%0d final=%0d emit=%0b consumed=%0b same=%0b rem=%0b lstr=%0b crem=%0b bp=%0b/%0b/%0d split=%0b ic_req=%0b ic_addr=%016h ic_resp=%0b ic_hit=%0b icq_count=%0d icq_v=%0b icq_pc=%016h icq_line=%014h icq_owner=%0b line_resp=%0b pkt_count=%0d ftq_count=%0d mem_req=%0b mem_we=%0b mem_addr=%016h mem_resp=%0b",
                         sim_cycle,
                         perf_mcycle,
                         perf_minstret,
                         u_core.csr_priv_mode,
                         u_core.csr_satp,
                         u_core.u_csr_file.mstatus_r,
                         u_core.u_csr_file.mie_r,
                         u_core.u_csr_file.mip_eff,
                         u_core.csr_mideleg,
                         last_commit_pc,
                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[13]],
                         u_core.u_int_prf.regfile_copy0[u_core.u_rename.u_rat.committed_rat[14]],
                         last_commit_cycle,
                         last_commit_count,
                         u_core.rob_empty,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx,
                         u_core.rob_free_count,
                         u_core.trap_valid,
                         u_core.trap_cause,
                         u_core.trap_val,
                         u_core.csr_irq_pending,
                         u_core.csr_irq_cause,
                         mtip,
                         msip,
                         time_val,
                         u_mmio.u_clint.mtimecmp_r,
                         u_core.u_lsu.mmio_req_valid_r,
                         u_core.u_lsu.mmio_wait_resp_r,
                         u_core.u_lsu.mmio_req_we_r,
                         u_core.u_lsu.mmio_req_addr_r,
                         mmio_req_count,
                         mmio_uart_rd_count,
                         mmio_uart_wr_count,
                         u_core.u_fetch_top.f1_valid,
                         u_core.u_fetch_top.f1_pc,
                         u_core.u_fetch_top.fe_stall,
                         u_core.u_fetch_top.f2_work_valid_c,
                         u_core.u_fetch_top.f2_work_pc_c,
                         u_core.u_fetch_top.f2_work_line_addr_c,
                         u_core.u_fetch_top.f2_work_ftq_valid_c,
                         u_core.u_fetch_top.f2_work_owner_delivered_c,
                         u_core.u_fetch_top.f2_data_valid,
                         u_core.u_fetch_top.f2_seq_next_pc,
                         u_core.u_fetch_top.extract_count,
                         u_core.u_fetch_top.final_count,
                         u_core.u_fetch_top.f2_will_emit_c,
                         u_core.u_fetch_top.f2_pc_consumed_c,
                         u_core.u_fetch_top.f2_same_owner_continue_c,
                         u_core.u_fetch_top.remainder_valid_r,
                         u_core.u_fetch_top.line_straddle_advance_c,
                         u_core.u_fetch_top.consume_remainder_c,
                         u_core.u_fetch_top.bp_branch_found,
                         u_core.u_fetch_top.bp_taken,
                         u_core.u_fetch_top.bp_branch_slot,
                         u_core.u_fetch_top.subgroup_split_before_ctl_c,
                         u_core.u_fetch_top.ic_req_valid,
                         u_core.u_fetch_top.ic_req_addr,
                         u_core.u_fetch_top.ic_resp_valid,
                         u_core.u_fetch_top.ic_resp_hit,
                         u_core.u_fetch_top.icq_count,
                         u_core.u_fetch_top.icq_deq_valid,
                         u_core.u_fetch_top.icq_deq_pc,
                         u_core.u_fetch_top.icq_deq_line_addr,
                         u_core.u_fetch_top.icq_deq_owner_match_c,
                         u_core.u_fetch_top.u_ifu_line_fetch.line_resp_valid_o,
                         u_core.u_fetch_top.packet_buf_count,
                         u_core.u_fetch_top.ftq_count,
                         mem_req_valid,
                         mem_req_we,
                         mem_req_addr,
                         mem_resp_valid);
                if (perf_profile_en != 0) begin
                    $display("[PERF_PROFILE] cyc=%0d itlb_lookups=%0d itlb_misses=%0d ptw_walks_itlb=%0d ptw_walks_dtlb=%0d ptw_busy_cycles=%0d ptw_faults=%0d fe_stall_total=%0d fe_stall_xlate=%0d fe_stall_icache=%0d fe_stall_backend=%0d flush_commit=%0d flush_bru=%0d flush_satp=%0d dtlb_lookups=%0d dtlb_misses=%0d dcache_accesses=%0d dcache_misses=%0d l2_grant_dcache=%0d l2_grant_ptw=%0d l2_grant_icache=%0d l2_icache_req_cyc=%0d l2_icache_starve=%0d l2_icache_starve_by_ptw=%0d l2_icache_starve_by_dcache=%0d l2_dc_ptw_collide=%0d ic_mshr_full_cyc=%0d",
                             sim_cycle,
                             u_core.u_mmu_mem_profiler.itlb_lookups,
                             u_core.u_mmu_mem_profiler.itlb_misses,
                             u_core.u_mmu_mem_profiler.ptw_walks_itlb,
                             u_core.u_mmu_mem_profiler.ptw_walks_dtlb,
                             u_core.u_mmu_mem_profiler.ptw_busy_cycles,
                             u_core.u_mmu_mem_profiler.ptw_faults,
                             u_core.u_fetch_top.u_fetch_frontend_profiler.fe_stall_total,
                             u_core.u_fetch_top.u_fetch_frontend_profiler.fe_stall_xlate,
                             u_core.u_fetch_top.u_fetch_frontend_profiler.fe_stall_icache,
                             u_core.u_fetch_top.u_fetch_frontend_profiler.fe_stall_backend,
                             u_core.u_mmu_mem_profiler.flush_commit,
                             u_core.u_mmu_mem_profiler.flush_bru,
                             u_core.u_mmu_mem_profiler.flush_satp,
                             u_core.u_mmu_mem_profiler.dtlb_lookups,
                             u_core.u_mmu_mem_profiler.dtlb_misses,
                             u_core.u_mmu_mem_profiler.dcache_accesses,
                             u_core.u_mmu_mem_profiler.dcache_misses,
                             u_core.u_mmu_mem_profiler.l2_grant_dcache,
                             u_core.u_mmu_mem_profiler.l2_grant_ptw,
                             u_core.u_mmu_mem_profiler.l2_grant_icache,
                             u_core.u_mmu_mem_profiler.l2_icache_req_cyc,
                             u_core.u_mmu_mem_profiler.l2_icache_starve,
                             u_core.u_mmu_mem_profiler.l2_icache_starve_by_ptw,
                             u_core.u_mmu_mem_profiler.l2_icache_starve_by_dcache,
                             u_core.u_mmu_mem_profiler.l2_dc_ptw_collide,
                             u_core.u_mmu_mem_profiler.ic_mshr_full_cyc);
                end
            end

            if ((linux_stop_on_no_commit_en != 0) &&
                (last_commit_cycle != 64'd0) &&
                (sim_cycle > (last_commit_cycle + linux_no_commit_limit))) begin
                $display("[LINUX_STOP_NO_COMMIT] cyc=%0d last_commit_pc=%016h last_commit_cycle=%0d idle_cycles=%0d limit=%0d priv=%0d satp=%016h mip=%016h mie=%016h mstatus=%016h rob_head=%0d rob_tail=%0d rob_free=%0d lq_full=%0b",
                         sim_cycle,
                         last_commit_pc,
                         last_commit_cycle,
                         sim_cycle - last_commit_cycle,
                         linux_no_commit_limit,
                         u_core.csr_priv_mode,
                         u_core.csr_satp,
                         u_core.u_csr_file.mip_eff,
                         u_core.u_csr_file.mie_r,
                         u_core.u_csr_file.mstatus_r,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx,
                         u_core.rob_free_count,
                         u_core.lq_full);
                $display("[LINUX_DEBUG_HEAD] v=%b r=%b pc0=%016h pc1=%016h is_load=%b is_store=%b is_branch=%b is_serial=%b",
                         u_core.rob_head_valid,
                         u_core.rob_head_ready,
                         u_core.rob_head_pc[0],
                         u_core.rob_head_pc[1],
                         u_core.rob_head_is_load,
                         u_core.rob_head_is_store,
                         u_core.rob_head_is_branch,
                         (u_core.rob_head_is_csr |
                          u_core.rob_head_is_fence |
                          u_core.rob_head_is_fence_i |
                          u_core.rob_head_is_mret |
                          u_core.rob_head_is_sret |
                          u_core.rob_head_is_sfence_vma |
                          u_core.rob_head_is_ecall |
                          u_core.rob_head_is_wfi));
                linux_dump_stall_debug();
                $finish;
            end

            if (sim_cycle >= max_cycles) begin
                $display("TIMEOUT after %0d cycles", sim_cycle);
                $display("[LINUX_DEBUG] last_commit_pc=%016h last_commit_cycle=%0d last_commit_count=%0d",
                         last_commit_pc, last_commit_cycle, last_commit_count);
                $display("[LINUX_DEBUG] mmio_req=%0d uart_rd=%0d uart_wr=%0d",
                         mmio_req_count, mmio_uart_rd_count, mmio_uart_wr_count);
                $display("[LINUX_DEBUG_CORE] rob_empty=%0b rob_free=%0d rob_head=%0d rob_tail=%0d rename_stall=%0b int_free=%0d fp_free=%0d fl_req=%0d fl_avail=%0d fp_req=%0d fp_avail=%0d hold=%b ren_raw=%0d dq_full=%0b lq_full=%0b sq_full=%0b iq_occ=%0d/%0d/%0d",
                         u_core.rob_empty,
                         u_core.rob_free_count,
                         u_core.rob_head_idx,
                         u_core.rob_tail_idx,
                         u_core.rename_stall,
                         u_core.u_rename.fl_free_count,
                         u_core.u_rename.fp_fl_free_count,
                         u_core.u_rename.fl_req_count,
                         u_core.u_rename.fl_avail_count,
                         u_core.u_rename.fp_fl_req_count,
                         u_core.u_rename.fp_fl_avail_count,
                         u_core.u_rename.hold_valid,
                         u_core.ren_count_raw,
                         u_core.dq_full,
                         u_core.lq_full,
                         u_core.sq_full,
                         u_core.iq0_occ,
                         u_core.iq1_occ,
                         u_core.iq2_occ);
                $display("[LINUX_DEBUG_HEAD] v=%b r=%b pc0=%016h pc1=%016h is_load=%b is_store=%b is_branch=%b is_serial=%b",
                         u_core.rob_head_valid,
                         u_core.rob_head_ready,
                         u_core.rob_head_pc[0],
                         u_core.rob_head_pc[1],
                         u_core.rob_head_is_load,
                         u_core.rob_head_is_store,
                         u_core.rob_head_is_branch,
                         (u_core.rob_head_is_csr |
                          u_core.rob_head_is_fence |
                          u_core.rob_head_is_fence_i |
                          u_core.rob_head_is_mret |
                          u_core.rob_head_is_sret |
                          u_core.rob_head_is_sfence_vma |
                          u_core.rob_head_is_ecall |
                          u_core.rob_head_is_wfi));
                linux_dump_stall_debug();
                if (linux_owner_hist_en != 0) begin
                    $display("[LINUX_OWNER_HIST_ALL] count=%0d wr=%0d",
                             linux_owner_hist_count, linux_owner_hist_wr);
                    for (linux_hist_dump_pos = 0;
                         linux_hist_dump_pos < linux_owner_hist_count;
                         linux_hist_dump_pos = linux_hist_dump_pos + 1) begin
                        linux_hist_dump_idx =
                            (linux_owner_hist_wr + LOAD_OWNER_HIST_DEPTH -
                             linux_owner_hist_count + linux_hist_dump_pos) %
                            LOAD_OWNER_HIST_DEPTH;
                        $display("[LINUX_OWNER_HIST_EV] cyc=%0d ev=%0d p%0d pc=%016h rob=%0d lq=%0d addr=%016h flags=%016h",
                                 linux_owner_hist_cycle[linux_hist_dump_idx],
                                 linux_owner_hist_event[linux_hist_dump_idx],
                                 linux_owner_hist_port[linux_hist_dump_idx],
                                 linux_owner_hist_pc[linux_hist_dump_idx],
                                 linux_owner_hist_rob[linux_hist_dump_idx],
                                 linux_owner_hist_lq[linux_hist_dump_idx],
                                 linux_owner_hist_addr[linux_hist_dump_idx],
                                 linux_owner_hist_flags[linux_hist_dump_idx]);
                    end
                end
                $display("[LINUX_IQLOAD_DUMP] cand_v=%b supp_raw=%b vm_supp=%b fence_supp=%b",
                         u_core.iq_load_issue_candidate_valid,
                         u_core.lsu_load_issue_suppress_raw,
                         u_core.vm_serial_load_issue_suppress,
                         u_core.mem_fence_load_issue_suppress);
                $display("[LINUX_DISPATCH_DUMP] iqld_occ=%0d iqst_occ=%0d iqstd_occ=%0d ld_cred=%0d st_cred=%0d dq_full=%0b dq_deq=%0d iq0occ=%0d iq1occ=%0d iq2occ=%0d iq0f=%0b iq1f=%0b iq2f=%0b",
                         u_core.iq_load_occ, u_core.iq_store_occ, u_core.iq_std_occ,
                         u_core.dq_load_iq_credit, u_core.dq_store_iq_credit,
                         u_core.dq_full, u_core.dq_deq_count,
                         u_core.iq0_occ, u_core.iq1_occ, u_core.iq2_occ,
                         u_core.iq0_full, u_core.iq1_full, u_core.iq2_full);
                for (linux_hist_dump_pos = 0; linux_hist_dump_pos < 32;
                     linux_hist_dump_pos = linux_hist_dump_pos + 1) begin
                    if (u_core.u_iq_load.entry_valid[linux_hist_dump_pos]) begin
                        $display("[LINUX_IQLOAD_EV] e=%0d rob=%0d s1r=%0b s2r=%0b s3r=%0b rs1p=%0d rs2p=%0d tbl1=%0b tbl2=%0b",
                                 linux_hist_dump_pos,
                                 u_core.u_iq_load.rob_idx_r[linux_hist_dump_pos],
                                 u_core.u_iq_load.src1_ready[linux_hist_dump_pos],
                                 u_core.u_iq_load.src2_ready[linux_hist_dump_pos],
                                 u_core.u_iq_load.src3_ready[linux_hist_dump_pos],
                                 u_core.u_iq_load.rs1_phys_r[linux_hist_dump_pos],
                                 u_core.u_iq_load.rs2_phys_r[linux_hist_dump_pos],
                                 u_core.preg_ready_table[u_core.u_iq_load.rs1_phys_r[linux_hist_dump_pos]],
                                 u_core.preg_ready_table[u_core.u_iq_load.rs2_phys_r[linux_hist_dump_pos]]);
                    end
                end
                for (linux_hist_dump_pos = 0; linux_hist_dump_pos < 32;
                     linux_hist_dump_pos = linux_hist_dump_pos + 1) begin
                    if (u_core.u_iq0.entry_valid[linux_hist_dump_pos]) begin
                        $display("[LINUX_IQ0_EV] e=%0d rob=%0d s1r=%0b s2r=%0b rs1p=%0d rs2p=%0d tbl1=%0b tbl2=%0b",
                                 linux_hist_dump_pos,
                                 u_core.u_iq0.rob_idx_r[linux_hist_dump_pos],
                                 u_core.u_iq0.src1_ready[linux_hist_dump_pos],
                                 u_core.u_iq0.src2_ready[linux_hist_dump_pos],
                                 u_core.u_iq0.rs1_phys_r[linux_hist_dump_pos],
                                 u_core.u_iq0.rs2_phys_r[linux_hist_dump_pos],
                                 u_core.preg_ready_table[u_core.u_iq0.rs1_phys_r[linux_hist_dump_pos]],
                                 u_core.preg_ready_table[u_core.u_iq0.rs2_phys_r[linux_hist_dump_pos]]);
                    end
                end
                $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                         perf_mcycle, perf_minstret,
                         $itor(perf_minstret) / $itor(perf_mcycle));
                $finish;
            end
        end
    end

endmodule
