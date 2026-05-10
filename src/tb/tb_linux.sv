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
    string uart_log_path;
    string smoke_pattern;

    initial begin
        max_cycles = 100000;
        uart_log_fd = 0;
        uart_stdout_en = 1;
        smoke_check_en = 0;
        uart_log_path = "";
        smoke_pattern = "RV64GC-V2 STAGE3 UART OK";

        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        void'($value$plusargs("UART_STDOUT=%d", uart_stdout_en));
        if ($value$plusargs("UART_LOGFILE=%s", uart_log_path)) begin
            uart_log_fd = $fopen(uart_log_path, "w");
        end
        smoke_check_en = $test$plusargs("UART_SMOKE_CHECK") ? 1 : 0;
    end

    final begin
        if (uart_log_fd != 0)
            $fclose(uart_log_fd);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sim_cycle <= 0;
            smoke_idx <= 0;
        end else begin
            sim_cycle <= sim_cycle + 1;

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
                $display("IPC: mcycle=%0d minstret=%0d IPC=%f",
                         perf_mcycle, perf_minstret,
                         $itor(perf_minstret) / $itor(perf_mcycle));
                $finish;
            end
        end
    end

endmodule
