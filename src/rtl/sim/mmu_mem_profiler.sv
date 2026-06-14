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
    input  wire        ptw_flush_abort,
    input  wire [63:0] satp_raw,
    // Family 3: flushes
    input  wire        commit_flush_valid,
    input  wire        bru_flush_valid,
    // Family 4: D-side
    input  wire        dtlb_lookup_valid,
    input  wire        dtlb_hit,
    input  wire        dcache_resp_valid,
    input  wire        dcache_resp_hit,
    // Family 5: L2 source arbitration (QoS) + ICache MSHR (idea-7 / idea-8)
    // Strict fixed priority in l2_cache.sv:487-512 is DCache > PTW > ICache >
    // Prefetch. These observe whether the ICache fill port starves under kernel
    // D-side + page-walk L2 traffic. Pure observers.
    input  wire        l2_dcache_req_valid,
    input  wire        l2_dcache_req_ready,
    input  wire        l2_ptw_req_valid,
    input  wire        l2_ptw_req_ready,
    input  wire        l2_icache_req_valid,
    input  wire        l2_icache_req_ready,
    input  wire        l2_prefetch_req_valid,
    input  wire        ic_mshr_free_avail
);

    // ---- Derived signals: ptw busy + satp change ----
    logic [63:0] satp_prev;
    logic        ptw_busy_r;
    wire         ptw_walk_start = ptw_itlb_req_fire || ptw_dtlb_req_fire;
    // walk_end must also cover flush-aborted walks: ptw.sv:269-277 forces
    // S_IDLE on flush_i/translation_flush_i without ever emitting a fill or
    // a fault, which left ptw_busy_r stuck (boot read ~93% busy).
    wire         ptw_walk_end   = ptw_itlb_fill || ptw_dtlb_fill
                                  || ptw_itlb_fault || ptw_dtlb_fault
                                  || ptw_flush_abort;
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

    // ---- Family 5: L2 source arbitration (QoS) + ICache MSHR ----
    longint unsigned l2_grant_dcache;   // L2 cycles granted to D-cache
    longint unsigned l2_grant_ptw;      // L2 cycles granted to PTW
    longint unsigned l2_grant_icache;   // L2 cycles granted to I-cache
    longint unsigned l2_icache_req_cyc; // cycles I-cache asserted an L2 fill req
    longint unsigned l2_icache_starve;  // I-cache wanted L2 but lost arbitration
    longint unsigned l2_icache_starve_by_ptw;   // ... lost specifically to PTW
    longint unsigned l2_icache_starve_by_dcache;// ... lost specifically to D-cache
    longint unsigned l2_dc_ptw_collide; // cycles D-cache AND PTW both want L2
    longint unsigned ic_mshr_full_cyc;  // I-cache MSHR (depth 2) had no free entry

    // Grant = source is highest-priority valid requestor that is also ready.
    wire l2_grant_dc_c  = l2_dcache_req_valid && l2_dcache_req_ready;
    wire l2_grant_ptw_c = l2_ptw_req_valid && l2_ptw_req_ready && !l2_dcache_req_valid;
    wire l2_grant_ic_c  = l2_icache_req_valid && l2_icache_req_ready
                          && !l2_dcache_req_valid && !l2_ptw_req_valid;
    // I-cache starve = wants L2 but a higher-priority source (DCache/PTW) holds it.
    wire l2_ic_starve_c = l2_icache_req_valid &&
                          (l2_dcache_req_valid || l2_ptw_req_valid);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            satp_prev <= '0; ptw_busy_r <= 1'b0;
            itlb_lookups <= '0; itlb_misses <= '0;
            ptw_walks_itlb <= '0; ptw_walks_dtlb <= '0;
            ptw_busy_cycles <= '0; ptw_faults <= '0;
            flush_commit <= '0; flush_bru <= '0; flush_satp <= '0;
            dtlb_lookups <= '0; dtlb_misses <= '0;
            dcache_accesses <= '0; dcache_misses <= '0;
            l2_grant_dcache <= '0; l2_grant_ptw <= '0; l2_grant_icache <= '0;
            l2_icache_req_cyc <= '0; l2_icache_starve <= '0;
            l2_icache_starve_by_ptw <= '0; l2_icache_starve_by_dcache <= '0;
            l2_dc_ptw_collide <= '0; ic_mshr_full_cyc <= '0;
        end else begin
            satp_prev <= satp_raw;
            // set wins over clear on same-cycle start+end (conservative occupancy)
            if (ptw_walk_start)    ptw_busy_r <= 1'b1;
            else if (ptw_walk_end) ptw_busy_r <= 1'b0;
            // Family 1
            if (itlb_lookup_valid) itlb_lookups <= itlb_lookups + 64'd1;
            if (itlb_lookup_valid && !itlb_hit) itlb_misses <= itlb_misses + 64'd1;
            if (ptw_itlb_req_fire) ptw_walks_itlb <= ptw_walks_itlb + 64'd1;
            if (ptw_dtlb_req_fire) ptw_walks_dtlb <= ptw_walks_dtlb + 64'd1;
            if (ptw_busy_r)        ptw_busy_cycles <= ptw_busy_cycles + 64'd1;
            if (ptw_itlb_fault || ptw_dtlb_fault) ptw_faults <= ptw_faults + 64'd1;
            // Family 3
            if (commit_flush_valid) flush_commit <= flush_commit + 64'd1;
            if (bru_flush_valid)    flush_bru <= flush_bru + 64'd1;
            if (satp_changed)       flush_satp <= flush_satp + 64'd1;
            // Family 4
            if (dtlb_lookup_valid) dtlb_lookups <= dtlb_lookups + 64'd1;
            if (dtlb_lookup_valid && !dtlb_hit) dtlb_misses <= dtlb_misses + 64'd1;
            if (dcache_resp_valid) dcache_accesses <= dcache_accesses + 64'd1;
            if (dcache_resp_valid && !dcache_resp_hit) dcache_misses <= dcache_misses + 64'd1;
            // Family 5: L2 QoS + ICache MSHR
            if (l2_grant_dc_c)  l2_grant_dcache <= l2_grant_dcache + 64'd1;
            if (l2_grant_ptw_c) l2_grant_ptw    <= l2_grant_ptw + 64'd1;
            if (l2_grant_ic_c)  l2_grant_icache <= l2_grant_icache + 64'd1;
            if (l2_icache_req_valid) l2_icache_req_cyc <= l2_icache_req_cyc + 64'd1;
            if (l2_ic_starve_c) l2_icache_starve <= l2_icache_starve + 64'd1;
            // attribute the starve cause (DCache wins priority over PTW)
            if (l2_icache_req_valid && l2_dcache_req_valid)
                l2_icache_starve_by_dcache <= l2_icache_starve_by_dcache + 64'd1;
            else if (l2_icache_req_valid && l2_ptw_req_valid)
                l2_icache_starve_by_ptw <= l2_icache_starve_by_ptw + 64'd1;
            if (l2_dcache_req_valid && l2_ptw_req_valid)
                l2_dc_ptw_collide <= l2_dc_ptw_collide + 64'd1;
            if (!ic_mshr_free_avail) ic_mshr_full_cyc <= ic_mshr_full_cyc + 64'd1;
        end
    end

endmodule

bind rv64gc_core_top mmu_mem_profiler u_mmu_mem_profiler (
    .clk                 (clk),
    .rst_n               (rst_n),
    .itlb_lookup_valid   (u_itlb.lookup_valid_i),
    .itlb_hit            (u_itlb.hit_o),
    .ptw_itlb_req_fire   (u_ptw.itlb_req_valid_i && u_ptw.itlb_req_ready_o),
    .ptw_itlb_fill       (u_ptw.itlb_fill_valid_o),
    .ptw_dtlb_req_fire   (u_ptw.dtlb_req_valid_i && u_ptw.dtlb_req_ready_o),
    .ptw_dtlb_fill       (u_ptw.dtlb_fill_valid_o),
    .ptw_itlb_fault      (u_ptw.fault_valid_o &&  u_ptw.fault_is_itlb_o),
    .ptw_dtlb_fault      (u_ptw.fault_valid_o && !u_ptw.fault_is_itlb_o),
    .ptw_flush_abort     (u_ptw.flush_i || u_ptw.translation_flush_i),
    .satp_raw            (csr_satp),
    .commit_flush_valid  (commit_flush.valid),
    .bru_flush_valid     (bru_flush.valid),
    .dtlb_lookup_valid   (u_dtlb.lookup_valid_i),
    .dtlb_hit            (u_dtlb.hit_o),
    // D-cache access = a load in s1 lookup; miss = a looked-up load that did not hit.
    // (load_resp_valid is hit-only in this dcache, so it cannot express a miss.)
    .dcache_resp_valid   (u_dcache.s1_ld0_valid || u_dcache.s1_ld1_valid),
    .dcache_resp_hit     (!((u_dcache.s1_ld0_valid && !u_dcache.ld0_cache_hit) ||
                            (u_dcache.s1_ld1_valid && !u_dcache.ld1_cache_hit))),
    // Family 5: L2 source arbitration (read off the L2 ports) + ICache MSHR.
    .l2_dcache_req_valid   (u_l2_cache.dcache_req_valid),
    .l2_dcache_req_ready    (u_l2_cache.dcache_req_ready),
    .l2_ptw_req_valid       (u_l2_cache.ptw_req_valid),
    .l2_ptw_req_ready       (u_l2_cache.ptw_req_ready),
    .l2_icache_req_valid    (u_l2_cache.icache_req_valid),
    .l2_icache_req_ready    (u_l2_cache.icache_req_ready),
    .l2_prefetch_req_valid  (u_l2_cache.prefetch_req_valid),
    .ic_mshr_free_avail     (u_fetch_top.u_ifu_line_fetch.u_icache.ic_mshr_free_avail)
);
`endif
