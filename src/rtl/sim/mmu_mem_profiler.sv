/* file: mmu_mem_profiler.sv
 Description: Simulation-only MMU + memory-system performance profiler.
              Pure observer: bound into rv64gc_core_top, drives nothing.
              Counts I-TLB/PTW (family 1), pipeline flushes (family 3),
              and D-side TLB/cache (family 4). Compiled out when SIMULATION
              is undefined.
 Author: Jeremy Cai
 Date: June 01, 2026
*/
`ifdef SIMULATION
module mmu_mem_profiler
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    // Family 1: I-TLB / PTW
    input  wire        itlb_lookup_valid,
    input  wire        itlb_hit,
    input  wire        ptw_itlb_req_fire,
    input  wire        ptw_itlb_fill,
    input  wire        ptw_dtlb_req_fire,
    input  wire        ptw_dtlb_fill,
    input  wire        ptw_itlb_fault,
    input  wire        ptw_dtlb_fault,
    input  wire [63:0] satp_raw,
    // Family 3: flushes
    input  wire        commit_flush_valid,
    input  wire        bru_flush_valid,
    // Family 4: D-side
    input  wire        dtlb_lookup_valid,
    input  wire        dtlb_hit,
    input  wire        dcache_resp_valid,
    input  wire        dcache_resp_hit
);

    // ---- Derived signals: ptw busy + satp change ----
    logic [63:0] satp_prev;
    logic        ptw_busy_r;
    wire         ptw_walk_start = ptw_itlb_req_fire || ptw_dtlb_req_fire;
    wire         ptw_walk_end   = ptw_itlb_fill || ptw_dtlb_fill
                                  || ptw_itlb_fault || ptw_dtlb_fault;
    wire         satp_changed   = (satp_raw != satp_prev);

    // ---- Family 1: I-TLB / PTW ----
    longint unsigned itlb_lookups;
    longint unsigned itlb_misses;
    longint unsigned ptw_walks_itlb;
    longint unsigned ptw_walks_dtlb;
    longint unsigned ptw_busy_cycles;
    longint unsigned ptw_faults;

    // ---- Family 3: flushes ----
    longint unsigned flush_commit;
    longint unsigned flush_bru;
    longint unsigned flush_satp;

    // ---- Family 4: D-side ----
    longint unsigned dtlb_lookups;
    longint unsigned dtlb_misses;
    longint unsigned dcache_accesses;
    longint unsigned dcache_misses;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            satp_prev <= '0; ptw_busy_r <= 1'b0;
            itlb_lookups <= '0; itlb_misses <= '0;
            ptw_walks_itlb <= '0; ptw_walks_dtlb <= '0;
            ptw_busy_cycles <= '0; ptw_faults <= '0;
            flush_commit <= '0; flush_bru <= '0; flush_satp <= '0;
            dtlb_lookups <= '0; dtlb_misses <= '0;
            dcache_accesses <= '0; dcache_misses <= '0;
        end else begin
            satp_prev <= satp_raw;
            if (ptw_walk_start)    ptw_busy_r <= 1'b1;
            else if (ptw_walk_end) ptw_busy_r <= 1'b0;
            // Family 1
            if (itlb_lookup_valid) itlb_lookups <= itlb_lookups + 1;
            if (itlb_lookup_valid && !itlb_hit) itlb_misses <= itlb_misses + 1;
            if (ptw_itlb_req_fire) ptw_walks_itlb <= ptw_walks_itlb + 1;
            if (ptw_dtlb_req_fire) ptw_walks_dtlb <= ptw_walks_dtlb + 1;
            if (ptw_busy_r)        ptw_busy_cycles <= ptw_busy_cycles + 1;
            if (ptw_itlb_fault || ptw_dtlb_fault) ptw_faults <= ptw_faults + 1;
            // Family 3
            if (commit_flush_valid) flush_commit <= flush_commit + 1;
            if (bru_flush_valid)    flush_bru <= flush_bru + 1;
            if (satp_changed)       flush_satp <= flush_satp + 1;
            // Family 4
            if (dtlb_lookup_valid) dtlb_lookups <= dtlb_lookups + 1;
            if (dtlb_lookup_valid && !dtlb_hit) dtlb_misses <= dtlb_misses + 1;
            if (dcache_resp_valid) dcache_accesses <= dcache_accesses + 1;
            if (dcache_resp_valid && !dcache_resp_hit) dcache_misses <= dcache_misses + 1;
        end
    end

endmodule
`endif
