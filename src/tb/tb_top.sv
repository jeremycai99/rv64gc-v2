/* file: tb_top.sv
 * Description: Top-level simulation testbench.  Instantiates rv64gc_core_top
 *              and sim_memory, wires them together, and exposes tohost
 *              pass/fail signals to the Verilator C++ driver.
 * Version: 2.0
 */

module tb_top
    import rv64gc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    output logic        tohost_valid,
    output logic [63:0] tohost_value,

    // Performance counters (for benchmark IPC reporting)
    output logic [63:0] perf_mcycle,
    output logic [63:0] perf_minstret
);

    // =========================================================================
    // Cycle counter used as time_val for the CSR file
    // =========================================================================
    logic [63:0] cycle_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_count <= '0;
        else
            cycle_count <= cycle_count + 64'd1;
    end

    // =========================================================================
    // L2-to-memory wires
    // =========================================================================
    logic        mem_req_valid;
    logic [63:0] mem_req_addr;
    logic        mem_req_we;
    logic [511:0] mem_req_wdata;
    logic        mem_req_ready;
    logic        mem_resp_valid;
    logic [511:0] mem_resp_data;

    // =========================================================================
    // Core instantiation
    // =========================================================================
    // Core-level tohost detection (snoops CSB drain to D-cache)
    logic        core_tohost_valid;
    logic [63:0] core_tohost_data;

    rv64gc_core_top u_core (
        .clk             (clk),
        .rst_n           (rst_n),

        // L2-to-memory interface
        .mem_req_valid   (mem_req_valid),
        .mem_req_addr    (mem_req_addr),
        .mem_req_we      (mem_req_we),
        .mem_req_wdata   (mem_req_wdata),
        .mem_req_ready   (mem_req_ready),
        .mem_resp_valid  (mem_resp_valid),
        .mem_resp_data   (mem_resp_data),

        // External interrupts — tied off for simulation
        .mtip            (1'b0),
        .msip            (1'b0),
        .meip            (1'b0),
        .stip            (1'b0),
        .ssip            (1'b0),
        .seip            (1'b0),

        // Timer
        .time_val        (cycle_count),

        // Tohost address from package
        .tohost_addr     (TOHOST_ADDR),

        // Tohost detection
        .tohost_wr_valid (core_tohost_valid),
        .tohost_wr_data  (core_tohost_data),

        // Performance counters
        .perf_mcycle     (perf_mcycle),
        .perf_minstret   (perf_minstret)
    );

    // Use core-level tohost detection (immediate, no cache writeback delay)
    // Latch the core_tohost into a sticky flop so the C++ driver can see
    // the pulse even if it sampled in the wrong half-cycle.
    logic        core_tohost_seen_q;
    logic [63:0] core_tohost_data_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_tohost_seen_q <= 1'b0;
            core_tohost_data_q <= 64'd0;
        end else if (core_tohost_valid && !core_tohost_seen_q) begin
            core_tohost_seen_q <= 1'b1;
            core_tohost_data_q <= core_tohost_data;
        end
    end

    assign tohost_valid = core_tohost_seen_q;
    assign tohost_value = core_tohost_data_q;

    // =========================================================================
    // Simulation memory instantiation
    // =========================================================================
    sim_memory u_mem (
        .clk             (clk),
        .rst_n           (rst_n),

        // L2 cache to memory interface
        .mem_req_valid   (mem_req_valid),
        .mem_req_addr    (mem_req_addr),
        .mem_req_we      (mem_req_we),
        .mem_req_wdata   (mem_req_wdata),
        .mem_req_ready   (mem_req_ready),
        .mem_resp_valid  (mem_resp_valid),
        .mem_resp_data   (mem_resp_data),

        // Tohost monitoring
        .tohost_addr     (TOHOST_ADDR),
        .tohost_valid    (tohost_valid),
        .tohost_value    (tohost_value)
    );

endmodule
