/* file: tb_linux.sv
 Description: Linux platform simulation top for rv64gc-v2.
 Author: Jeremy Cai
 Date: May 10, 2026
 Version: 1.0
*/
`timescale 1ns/1ps

module tb_linux;
    import rv64gc_pkg::*;

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
        .iq_ready_enq_bypass_enable  (1'b0),
        .iq_ready_enq_bypass_alu_only(1'b0),
        .perf_mcycle                 (perf_mcycle),
        .perf_minstret               (perf_minstret)
    );

    sim_memory u_mem (
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
    integer linux_trace_mmio_en;
    integer mmio_req_count;
    integer mmio_uart_rd_count;
    integer mmio_uart_wr_count;
    logic [63:0] last_commit_pc;
    logic [63:0] last_commit_cycle;
    integer last_commit_count;
    integer linux_trace_load_pc_en;
    logic [63:0] linux_trace_load_pc;
    integer linux_trace_line_en;
    logic [63:0] linux_trace_line;
    integer linux_trace_l2_en;
    integer linux_trace_trap_en;
    logic [63:0] mem_read_addr_r;
    logic        mem_read_pending_r;
    string uart_log_path;
    string smoke_pattern;

    localparam int TRACE_LOAD_TRACK = 8;
    logic                    trace_load_valid [0:TRACE_LOAD_TRACK-1];
    logic [ROB_IDX_BITS-1:0] trace_load_rob [0:TRACE_LOAD_TRACK-1];
    logic [PHYS_REG_BITS-1:0] trace_load_pdst [0:TRACE_LOAD_TRACK-1];
    logic [63:0]             trace_load_pc [0:TRACE_LOAD_TRACK-1];
    logic [63:0]             trace_load_addr [0:TRACE_LOAD_TRACK-1];

    initial begin
        max_cycles = 100000;
        uart_log_fd = 0;
        uart_stdout_en = 1;
        smoke_check_en = 0;
        linux_trace_mmio_en = 0;
        linux_trace_load_pc_en = 0;
        linux_trace_load_pc = 64'd0;
        linux_trace_line_en = 0;
        linux_trace_line = 64'd0;
        linux_trace_l2_en = 0;
        linux_trace_trap_en = 0;
        uart_log_path = "";
        smoke_pattern = "RV64GC-V2 STAGE3 UART OK";

        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        void'($value$plusargs("UART_STDOUT=%d", uart_stdout_en));
        if ($value$plusargs("UART_LOGFILE=%s", uart_log_path)) begin
            uart_log_fd = $fopen(uart_log_path, "w");
        end
        smoke_check_en = $test$plusargs("UART_SMOKE_CHECK") ? 1 : 0;
        linux_trace_mmio_en = $test$plusargs("LINUX_TRACE_MMIO") ? 1 : 0;
        if ($value$plusargs("LINUX_TRACE_LOAD_PC=%h", linux_trace_load_pc))
            linux_trace_load_pc_en = 1;
        if ($value$plusargs("LINUX_TRACE_LINE=%h", linux_trace_line)) begin
            linux_trace_line_en = 1;
            linux_trace_line[5:0] = 6'd0;
        end
        if ($test$plusargs("LINUX_TRACE_L2"))
            linux_trace_l2_en = 1;
        if ($test$plusargs("LINUX_TRACE_TRAP"))
            linux_trace_trap_en = 1;
    end

    final begin
        if (uart_log_fd != 0)
            $fclose(uart_log_fd);
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
            mem_read_addr_r <= 64'd0;
            mem_read_pending_r <= 1'b0;
            for (int ti = 0; ti < TRACE_LOAD_TRACK; ti++) begin
                trace_load_valid[ti] <= 1'b0;
                trace_load_rob[ti] <= '0;
                trace_load_pdst[ti] <= '0;
                trace_load_pc[ti] <= 64'd0;
                trace_load_addr[ti] <= 64'd0;
            end
        end else begin
            sim_cycle <= sim_cycle + 1;

            if (u_core.commit_count != 0) begin
                last_commit_count <= u_core.commit_count;
                last_commit_cycle <= sim_cycle;
                for (int ci = 0; ci < PIPE_WIDTH; ci++) begin
                    if (ci < int'(u_core.commit_count))
                        last_commit_pc <= u_core.rob_head_pc[ci];
                end
            end

            if (linux_trace_trap_en != 0) begin
                for (int ti = 0; ti < PIPE_WIDTH; ti++) begin
                    if ((ti < int'(u_core.commit_count)) &&
                        u_core.rob_head_has_exception[ti]) begin
                        $display("[LINUX_COMMIT_EXC] cyc=%0d slot=%0d pc=%016h code=%0d mtvec=%016h priv=%0d",
                                 sim_cycle, ti,
                                 u_core.rob_head_pc[ti],
                                 u_core.rob_head_exc_code[ti],
                                 u_core.csr_mtvec,
                                 u_core.csr_priv_mode);
                    end
                end
                if (u_core.trap_valid) begin
                    $display("[LINUX_TRAP] cyc=%0d pc=%016h cause=%016h val=%016h irq=%0b mtvec=%016h stvec=%016h priv=%0d",
                             sim_cycle,
                             u_core.trap_pc,
                             u_core.trap_cause,
                             u_core.trap_val,
                             u_core.trap_is_interrupt,
                             u_core.csr_mtvec,
                             u_core.csr_stvec,
                             u_core.csr_priv_mode);
                end
                if (u_core.mret_commit) begin
                    $display("[LINUX_MRET] cyc=%0d pc=%016h mepc=%016h mcause=%016h mtval=%016h priv=%0d",
                             sim_cycle,
                             u_core.rob_head_pc[0],
                             u_core.csr_mepc,
                             u_core.u_csr_file.mcause_r,
                             u_core.u_csr_file.mtval_r,
                             u_core.csr_priv_mode);
                end
                if (u_core.sret_commit) begin
                    $display("[LINUX_SRET] cyc=%0d pc=%016h sepc=%016h scause=%016h stval=%016h priv=%0d",
                             sim_cycle,
                             u_core.rob_head_pc[0],
                             u_core.csr_sepc,
                             u_core.u_csr_file.scause_r,
                             u_core.u_csr_file.stval_r,
                             u_core.csr_priv_mode);
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

            if (linux_trace_load_pc_en != 0) begin
                for (int li = 0; li < 2; li++) begin
                    if (u_core.iq_load_issue_candidate_valid[li] &&
                        (u_core.iq_load_issue_data[li].pc == linux_trace_load_pc) &&
                        u_core.lsu_load_issue_suppress_raw[li]) begin
                        $display("[LINUX_LOAD_SUPPRESS] cyc=%0d p%0d rob=%0d pc=%016h",
                                 sim_cycle, li,
                                 u_core.iq_load_issue_data[li].rob_idx,
                                 u_core.iq_load_issue_data[li].pc);
                    end
                    if (u_core.u_lsu.load_issue_valid[li] &&
                        (u_core.u_lsu.load_issue_data[li].pc == linux_trace_load_pc)) begin
                        $display("[LINUX_LOAD_ISSUE] cyc=%0d p%0d rob=%0d pdst=%0d pc=%016h addr=%016h size=%0d mmio=%0b miss=%0b hit=%0b",
                                 sim_cycle, li,
                                 u_core.u_lsu.load_issue_data[li].rob_idx,
                                 u_core.u_lsu.load_issue_data[li].pdst,
                                 u_core.u_lsu.load_issue_data[li].pc,
                                 u_core.u_lsu.load_eff_addr[li],
                                 u_core.u_lsu.load_issue_data[li].mem_size,
                                 u_core.u_lsu.load_addr_mmio[li],
                                 ((li == 0) ? u_core.u_lsu.p0_miss_detect
                                            : u_core.u_lsu.p1_miss_detect),
                                 u_core.dc_load_resp_hit[li]);
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
                    end
                    if (u_core.dc_load_req_valid[li] &&
                        ((linux_trace_line_en == 0) ||
                         ({u_core.dc_load_req_addr[li][63:6], 6'd0} == linux_trace_line))) begin
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
                if (u_core.dc_fill_snoop_valid) begin
                    $display("[LINUX_DC_FILL] cyc=%0d addr=%016h",
                             sim_cycle, u_core.dc_fill_snoop_addr);
                end
            end

            if (linux_trace_line_en != 0) begin
                if (u_core.u_dcache.ld0_new_miss_req &&
                    (u_core.u_dcache.ld0_line_addr == linux_trace_line)) begin
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
                end
                if (u_core.u_dcache.ld0_miss_merge_req &&
                    (u_core.u_dcache.ld0_line_addr == linux_trace_line)) begin
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
                if (u_core.dc_l2_req_valid &&
                    ({u_core.dc_l2_req_addr[63:6], 6'd0} == linux_trace_line)) begin
                    $display("[LINUX_DC_L2_REQ] cyc=%0d we=%0b addr=%016h ready=%0b",
                             sim_cycle, u_core.dc_l2_req_we,
                             u_core.dc_l2_req_addr, u_core.dc_l2_req_ready);
                end
                if (u_core.dc_l2_resp_valid &&
                    ({u_core.dc_l2_resp_addr[63:6], 6'd0} == linux_trace_line)) begin
                    $display("[LINUX_DC_L2_RESP] cyc=%0d addr=%016h",
                             sim_cycle, u_core.dc_l2_resp_addr);
                end
                if (u_core.dc_store_req_valid &&
                    ({u_core.dc_store_req_addr[63:6], 6'd0} == linux_trace_line)) begin
                    $display("[LINUX_DC_STORE] cyc=%0d addr=%016h data=%016h mask=%02h ack=%0b",
                             sim_cycle,
                             u_core.dc_store_req_addr,
                             u_core.dc_store_req_data,
                             u_core.dc_store_req_byte_mask,
                             u_core.dc_store_ack);
                end
                if (mem_req_valid && !mem_req_we &&
                    ({mem_req_addr[63:6], 6'd0} == linux_trace_line)) begin
                    $display("[LINUX_MEM_REQ] cyc=%0d addr=%016h ready=%0b",
                             sim_cycle, mem_req_addr, mem_req_ready);
                end
                if (mem_resp_valid && mem_read_pending_r &&
                    ({mem_read_addr_r[63:6], 6'd0} == linux_trace_line)) begin
                    $display("[LINUX_MEM_RESP] cyc=%0d addr=%016h",
                             sim_cycle, mem_read_addr_r);
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
            end

            if (sim_cycle > 0 && (sim_cycle % 10000) == 0) begin
                $display("... cycle %0d  mcycle=%0d minstret=%0d",
                         sim_cycle, perf_mcycle, perf_minstret);
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
                $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                         perf_mcycle, perf_minstret,
                         $itor(perf_minstret) / $itor(perf_mcycle));
                $finish;
            end
        end
    end

endmodule
