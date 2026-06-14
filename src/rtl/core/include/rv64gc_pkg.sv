/* file: rv64gc_pkg.sv
 Description: Top-level package with microarchitectural parameters.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Revision history:
    - Apr. 09, 2026: Imported into rv64gc-v2 RTL tree.
 */
`ifndef RV64GC_PKG_SV
`define RV64GC_PKG_SV
package rv64gc_pkg;

    // =========================================================================
    // ISA constants
    // =========================================================================
    localparam int XLEN           = 64;
    localparam int ILEN           = 32;
    localparam int ARCH_REGS      = 32;
    localparam int ARCH_REG_BITS  = 5;

    // =========================================================================
    // Pipeline widths (4-wide superscalar)
    // =========================================================================
    localparam int PIPE_WIDTH     = 4;   // fetch/decode/rename/dispatch/commit
    localparam int FETCH_WIDTH    = PIPE_WIDTH;
    localparam int DECODE_WIDTH   = PIPE_WIDTH;
    localparam int RENAME_WIDTH   = PIPE_WIDTH;
    localparam int DISPATCH_WIDTH = PIPE_WIDTH;
    localparam int COMMIT_WIDTH   = PIPE_WIDTH;
    localparam int FETCH_BYTES    = FETCH_WIDTH * 4;  // 16 bytes

    // =========================================================================
    // Physical register file
    // =========================================================================
    localparam int INT_PRF_DEPTH  = 160;
    localparam int PHYS_REG_BITS  = 8;   // $clog2(160) <= 8
    localparam int FP_PRF_DEPTH   = 96;
    localparam int PHYS_TAG_COUNT = 1 << PHYS_REG_BITS;
    localparam int FP_PHYS_BASE   = INT_PRF_DEPTH;

    // =========================================================================
    // Reorder buffer
    // =========================================================================
    localparam int ROB_DEPTH      = 128;
    localparam int ROB_IDX_BITS   = 7;   // $clog2(128) = 7

    // =========================================================================
    // Free list
    // =========================================================================
    localparam int INT_FREE_LIST_DEPTH = INT_PRF_DEPTH - ARCH_REGS; // 128
    localparam int FP_FREE_LIST_DEPTH  = FP_PRF_DEPTH - ARCH_REGS;  // 64

    // =========================================================================
    // Checkpoints (branch snapshots)
    // =========================================================================
    localparam int NUM_CHECKPOINTS = 64;
    localparam int CHECKPOINT_BITS = 6;  // $clog2(64) = 6

    // =========================================================================
    // Issue queues
    // =========================================================================
    localparam int NUM_INT_IQS    = 3;
    localparam int IQ_INT_DEPTH   = 24;
    localparam int IQ_SELECT_PORTS = 2;  // select ports per IQ
    localparam int IQ_MEM_DEPTH   = 32;
    localparam int IQ_FP_DEPTH    = 32;

    // =========================================================================
    // Dispatch queues
    // =========================================================================
    localparam int DQ_INT_DEPTH   = 32;
    localparam int DQ_MEM_DEPTH   = 32;
    localparam int DQ_FP_DEPTH    = 16;
    localparam int DECODE_QUEUE_DEPTH = 32;

    // =========================================================================
    // Load/Store queues
    // =========================================================================
    // Power-of-2 depths: pointer arithmetic wraps correctly with simple
    // bit truncation (idx mod 2^N).  Non-power-of-2 (original 48) caused
    // pointer wrap past physical entries → SQ count overflow after flush.
    localparam int LQ_DEPTH       = 32;  // baseline arm (depth-64 arm captured: backend_d64_full/)
    localparam int SQ_DEPTH       = 32;  // baseline arm (depth-64 arm captured: backend_d64_full/)
    localparam int CSB_DEPTH      = 32;  // committed store buffer (was 24)

    localparam int LQ_IDX_BITS    = $clog2(LQ_DEPTH);   // 5
    localparam int SQ_IDX_BITS    = $clog2(SQ_DEPTH);   // 5
    localparam int CSB_IDX_BITS   = $clog2(CSB_DEPTH);   // 5

    // =========================================================================
    // Translation lookaside buffers
    // =========================================================================
    localparam int ITLB_DEPTH     = 16;
    localparam int DTLB_DEPTH     = 32;

    // =========================================================================
    // Functional units
    // =========================================================================
    localparam int NUM_ALU        = 3;
    localparam int MUL_LATENCY    = 3;
    localparam int CDB_WIDTH      = 4;
    // Bypass slots: 4 CDB-registered (CDB[0..3]) + 2 load_wb combinational (Load0, Load1).
    // Both load ports MUST have a bypass slot — spec_wakeup wakes consumers at T+2 but
    // PRF write doesn't latch until T+3, so missing-load-bypass = stale-PRF-read = wrong
    // operand to BRU = spurious mis-flag (see Stage 2 cm bug fix on master).
    localparam int NUM_BYPASS_SRCS = 6;
    // PRF write port count is kept at 6 (4 ALU/DIV/CSR + 2 load writeback)
    // independent of CDB_WIDTH (wakeup broadcast width).
    localparam int PRF_WRITE_PORTS = 6;

    // =========================================================================
    // UOP cache / decoded-op cache.
    //
    // Geometry: 32 sets × 8 ways × 4 µops per entry = 1,024 µop slots.
    // Indexed by fetch-group start PC: PC[5:1] (RVC 2-byte alignment).
    // Modeled after Intel DSB, AMD Zen op-cache, and Arm macro-op caches.
    // =========================================================================
    localparam int UOC_SETS        = 32;
    localparam int UOC_WAYS        = 8;
    localparam int UOC_PER_ENTRY   = PIPE_WIDTH;          // 4 µops/entry
    localparam int UOC_INDEX_BITS  = $clog2(UOC_SETS);    // 5
    localparam int UOC_WAY_BITS    = $clog2(UOC_WAYS);    // 3
    localparam int UOC_OFFSET_BITS = 1;                   // PC[0] ignored (RVC 2B align)
    localparam int UOC_TAG_BITS    = XLEN - UOC_INDEX_BITS - UOC_OFFSET_BITS; // 58
    localparam int UOC_PLRU_BITS   = UOC_WAYS - 1;        // 7-bit tree pLRU per set

    // =========================================================================
    // Frontend queues
    // =========================================================================
    localparam int FTQ_DEPTH      = 24;
    localparam int FTQ_IDX_BITS   = $clog2(FTQ_DEPTH);
    localparam int FTQ_EPOCH_BITS = 4;
    localparam int FTQ_ALLOC_TAG_BITS = 16;

    // =========================================================================
    // Cache geometry
    // =========================================================================
    localparam int LINE_SIZE      = 64;                    // bytes per cache line
    localparam int LINE_BITS      = $clog2(LINE_SIZE);     // 6
    localparam int LINE_WORDS     = LINE_SIZE / 8;         // 8 dwords per line

    // L1 I-Cache: 32 KB, 8-way, 64B lines (8-way → 4KB/way for alias-free VIPT)
    localparam int L1I_SIZE       = 32768;
    localparam int L1I_WAYS       = 8;   // 8-way for alias-free VIPT (4KB/way = page size)
    localparam int L1I_SETS       = L1I_SIZE / (L1I_WAYS * LINE_SIZE);  // 64
    localparam int L1I_SET_BITS   = $clog2(L1I_SETS);     // 6  (index addr[11:6] in page offset)
    localparam int L1I_TAG_BITS   = XLEN - L1I_SET_BITS - LINE_BITS;   // 52

    // L1 D-Cache: 64 KB, 4-way, 2-bank, 64B lines
    localparam int L1D_SIZE       = 65536;
    localparam int L1D_WAYS       = 4;
    localparam int L1D_BANKS      = 2;
    localparam int L1D_SETS       = L1D_SIZE / (L1D_WAYS * LINE_SIZE);  // 256
    localparam int L1D_SET_BITS   = $clog2(L1D_SETS);     // 8
    localparam int L1D_TAG_BITS   = XLEN - L1D_SET_BITS - LINE_BITS;   // 50
    localparam int L1D_MSHR_DEPTH = 16;
    // No-write-allocate (write-validate full-line store-misses): skip the read-
    // for-ownership fill for compulsory streaming full-line writes; install the
    // store-defined line clean + write-through. Gated; 1'b0 = baseline (write-allocate).
    localparam logic NO_WRITE_ALLOCATE_ENABLE = 1'b1;
    // Store-pipe S1 re-latch bubble fix: during a store-ack cycle the D-cache
    // S0 lookup takes the CSB's NEXT entry (head+1 peek) instead of re-reading
    // the stale head, sustaining 1 store-ack/cyc back-to-back (vs 0.5 with the
    // legacy duplicate-suppression bubble).  1'b0 = legacy 2-cycle cadence.
    localparam logic STORE_PIPE_NOBUBBLE_ENABLE = 1'b1;
    // FPU pipelined-issue fix: the FPU request register natively supports
    // load-while-drain, but the IQ2 issue suppress keys on bare occupancy
    // (fpu_req_valid_r), forcing one FP-arith op per 2 cycles (0.5/cyc cap).
    // When set, suppress only while the register is occupied AND the FPU
    // cannot drain it this cycle (fpu_req_valid_r && !fpu_ready) -> 1 op/cyc.
    localparam logic FPU_PIPELINED_ISSUE_ENABLE = 1'b0;
    // L2-fill FSM dead-cycle fix A: assert the fill request combinationally
    // from L2_IDLE (mirroring the WT-drain arm's loop-safe comb-assert idiom)
    // and transition straight to L2_FILL_WAIT when l2_req_ready, instead of
    // registering an L2_IDLE -> L2_FILL_REQ hop that wastes one req-channel
    // cycle per fill (measured fill period 10 cyc on an 8-cyc L2 hit).  The
    // comb arm uses a guarded MSHR selection that masks entries whose fill
    // response arrives this cycle (fill_pend clear is registered).
    // 1'b0 = legacy registered dispatch (byte-identical baseline).
    localparam logic L2_FILL_COMB_REQ_ENABLE = 1'b0;
    // IFU dup-hold cursor fix A -- straddle re-extraction: an emit whose raw
    // extraction hit a line-straddling 32-bit instr clears same_owner_continue
    // and owner_complete (pred_checker), so no structured cursor-advance term
    // fires and the f1_pc_r fallback re-lands on the just-emitted PC: one dead
    // cycle vetoed by ifu_duplicate_guard per straddle emit.  When set, an
    // explicit advance term steps the work cursor to seq_next_pc (the straddle
    // PC, same line by construction) ahead of the fallback; the remainder
    // machinery stitches the straddling instr unchanged.  1'b0 = legacy.
    localparam logic IFU_STRADDLE_ADVANCE_FIX_ENABLE = 1'b1;
    // IFU dup-hold cursor fix B -- consumed-remainder echo: the cycle after a
    // remainder consume-emit, the consumed_remainder_r cursor-mux branch
    // outranks same-owner advance and re-loads the PC being emitted that very
    // cycle: one dead cycle, the day-late dup-advance then redoes the same
    // step.  When set, same-owner advance outranks the echo branch AND the F1
    // re-pin to post_remainder_pc_r is skipped under the identical condition,
    // keeping f1_pc_r and the work cursor in lockstep (a divergence would let
    // required_ftq_need_alloc_c allocate a fresh owner at an already-emitted
    // PC -- a double-enqueue the owner-tagged guard cannot catch).
    // 1'b0 = legacy echo.
    localparam logic IFU_REMAINDER_ECHO_FIX_ENABLE = 1'b1;
    // Loop-predictor exact spec-count hardening: the loop-exit corrector
    // needs an exact speculative trip count at lookup, but spec updates
    // register at end-of-cycle and the same-cycle count-bypass is gated by a
    // learned confidence (loop_bypass_conf) trained up only by mispredicted
    // correct-limit exits and down by correct exits -- a homeostat that
    // re-equilibrates at quantized exit-mispredict plateaus (50%/75%) when
    // the cursor fixes shrink the lookup-to-update distance at line
    // crossings.  When set: (a) the same-cycle bypass becomes unconditional
    // (it is deterministic bookkeeping of an already-made prediction, not a
    // speculation -- the conf gate is what manufactures the plateaus), and
    // (b) a 1-deep pending register makes a loop spec update that fired last
    // cycle visible to this cycle's lookups even when the end-of-cycle array
    // write did not happen (truncated emit at a line crossing); the pending
    // state honors the flush-copy restore (capture gated !flush, dies with
    // the flush, never leaks wrong-path counts into the restored state).
    // 1'b0 = legacy conf-gated homeostat (bit-identical baseline).
    localparam logic LOOP_SPEC_COUNT_EXACT_ENABLE = 1'b0;
    // Loop-predictor commit-side spec-count no-clobber (FIX-THEN-PROMOTE
    // piece 2, 2026-06-12).  Measured root cause of the 4-workload mispredict
    // regression under the cursor fixes (and of a pre-existing exit-misp
    // floor in BOTH arms): on a committed loop exit the update path
    // unconditionally wrote loop_spec_count <= 0, a commit-order sync that is
    // only correct when no younger instance is in flight.  The speculative
    // count stream is fetch-order self-consistent (the exit's own spec update
    // resets it, subsequent instances count from there) and every divergence
    // is repaired by the flush-copy restore, so the no-flush commit-side
    // reset can only destroy valid in-flight counts of the NEXT loop
    // instance.  The legacy dup-hold dead cycles masked the race by delaying
    // the next instance's fetch past the exit commit; the cursor fixes
    // removed that delay and flipped the race (event-exact first-divergence
    // traces: log/piece2_runs/lpwtrace_*).  When set, the commit-side
    // loop_spec_count reset on exit fires only under flush (where commit
    // order == fetch order by squash).  1'b0 = legacy clobber (bit-identical
    // baseline).
    localparam logic LOOP_SPEC_COMMIT_NOCLOBBER_ENABLE = 1'b1;
    // Commit TAGE-update spill queue (FIX-THEN-PROMOTE piece 2b, 2026-06-12).
    // The commit-side trainer presents at most ONE conditional-branch update
    // per commit batch (oldest wins); a 4-wide batch containing two or more
    // committed conditionals silently drops the younger ones.  Tight loops
    // with 2-3 conditionals per 4-instr window (embench-ud 0x233c+0x2342,
    // minver 0x2064/0x206e/0x2078) chronically starve whichever branch sits
    // younger in the batch, and the batch PHASE is set by frontend packet
    // boundaries -- the cursor fixes shifted it, collapsing ud's loop-
    // corrector training (visible updates 64,199 -> 60,476 for an identical
    // committed instruction stream; conf-3 occupancy 13,755 -> 1,536).  When
    // set, all committed conditionals of a batch enter a strict-order FIFO
    // drained 1/cycle into the TAGE update port (flow-through when empty, so
    // the common 1-cond case is cycle-identical); drops occur only on FIFO
    // overflow.  Commit-side updates are post-architectural, so delayed
    // presentation is squash-safe and each entry carries its own GHR.
    // 1'b0 = legacy oldest-only (bit-identical baseline).
    localparam logic TAGE_UPDATE_SPILL_ENABLE = 1'b0;
    localparam int   TAGE_UPDATE_SPILL_DEPTH  = 8;

    // =========================================================================
    // D-side stride/stream hardware prefetcher (Lever A, FUND verdict
    // doc/dprefetch_census_2026-06-14.md).  A PC-indexed constant-stride table
    // in the LSU is trained on completing loads (byte-granular stride -- the
    // regular quantity; a line-granular stride alternates 0/+1 and defeats
    // detection, census bug #1).  On a confident-stride load it issues
    // DEGREE prefetches (addr = demand_addr + k*stride, k=1..DEGREE) into a
    // FREE L1D MSHR via a dedicated dcache prefetch port -- demand strict-
    // priority for the single alloc slot, confidence-gated, drop-on-MSHR-full.
    // The census proved degree-1 is UNTIMELY on every high-coverage row
    // (STREAM/memcpy line-cross misses every 2-7 cyc < 8-cyc L2 latency), so
    // DEGREE>=2 is mandatory.  The engine trains and prefetches on the
    // PHYSICAL byte address (port-0 load_eff_addr_r is post-DTLB in VM mode)
    // and drops any prefetch whose target crosses the demand 4 KB page
    // (pf_pa[63:12] != demand_pa[63:12]) -- this keeps the PA correct without
    // a speculative DTLB lookup or page walk (the census paged-safety rule).
    // ENABLE=0 -> the prefetch issue is masked to 0 => bit-exact baseline.
    localparam logic D_PREFETCH_ENABLE = 1'b0;
    // Stride-table sizing (HW budget, sized down from the census's 8192).
    localparam int   DPF_TABLE_SETS    = 64;               // PC-indexed entries
    localparam int   DPF_TABLE_IDX_BITS= $clog2(DPF_TABLE_SETS); // 6
    localparam int   DPF_CONF_BAR      = 2;                // confident at >=2 of 3
    // Prefetch lookahead.  DEGREE = how many lines ahead to request per train
    // event; >=2 mandatory (census timeliness).  One prefetch issued per cycle
    // (the dcache has a single MSHR alloc slot); the per-load degree is swept
    // by retiring k=1..DEGREE round-robin off the confident PC's last train.
    localparam int   DPF_DEGREE        = 3;                // lookahead lines (>=2)
    localparam int   DPF_PAGE_OFF_BITS = 12;               // 4 KB page (Sv39/48)
    // MLP / bandwidth gate: suppress prefetch issue when the in-flight demand-
    // miss count (LMB occupancy, of 32) is at/above this.  The high-MLP STREAM
    // rows saturate fill bandwidth (~30 in flight) and a prefetch there displaces
    // demand (measured stream-l2 +4% without this gate); the low-MLP real kernel
    // (mostly-idle LMB) prefetches freely.  8 of 32 = back off once a quarter of
    // the LMB is in flight (well below STREAM's ~30, above the kernel's baseline).
    localparam int   DPF_MLP_GATE      = 32;               // LMB-occ backstop (permissive; dcache MSHR gate is authoritative)
    // Dcache MSHR reservation: a prefetch may allocate an L1D MSHR only when
    // fewer than this many of the 16 MSHRs are occupied -- the upper
    // (16-DPF_MSHR_RESERVE) MSHRs are reserved for DEMAND.  This is the decisive
    // anti-displacement gate (the LSU-LMB MLP gate above does not track dcache-
    // MSHR pressure on the high-MLP STREAM rows: stream-l2's LMB drains fast so
    // its LMB-occ stays low, but its MSHRs are demand-saturated).  6 of 16 = a
    // prefetch needs >=10 free MSHRs; the bandwidth-bound STREAM rows refuse it,
    // the low-MLP kernel/memcpy (mostly-idle MSHRs) allow it.
    localparam int   DPF_MSHR_RESERVE  = 6;                // dcache MSHR occ ceiling for PF
    // Demand fill-backlog gate (the stream-l2 separation STUDY knob).  The
    // dcache->L2 interface is SINGLE-OUTSTANDING (the L2 FSM serializes fills one
    // at a time, IDLE->FILL_REQ->FILL_WAIT->IDLE).  mshr_fill_backlog counts
    // MSHRs still owed an L2 fill (fill_pend, !writeback, !is_pf = DEMAND only) --
    // the demand queue at that channel.  A prefetch issues only when the backlog
    // is below this depth.  MEASURED RESULT (doc/dprefetch_streaml2_throttle_*):
    // this does NOT separate stream-l2 (backlog_max 5-6) from memcpy (backlog_max
    // 4) -- the distributions overlap, and memcpy needs gate>=4 for its full win,
    // which also admits stream-l2's prefetches.  Shipped DISABLED (=MSHR_DEPTH)
    // so it is a no-op; left in place as the documented study instrument
    // (sim-overridable via +DPF_BACKLOG_GATE=<n>).  ENABLE-0 path unaffected.
    localparam int   DPF_FILL_BACKLOG_GATE = 16;          // =MSHR_DEPTH => gate OFF (no-op)

    // L2 Cache: 2 MB, 8-way, 64B lines, 32 MSHRs, 8-cycle hit
    localparam int L2_SIZE        = 2097152;
    localparam int L2_WAYS        = 8;
    localparam int L2_SETS        = L2_SIZE / (L2_WAYS * LINE_SIZE);    // 4096
    localparam int L2_SET_BITS    = $clog2(L2_SETS);       // 12
    localparam int L2_TAG_BITS    = XLEN - L2_SET_BITS - LINE_BITS;    // 46
    localparam int L2_MSHR_DEPTH  = 32;
    localparam int L2_HIT_LATENCY = 8;

    // =========================================================================
    // Branch prediction
    // =========================================================================
    // TAGE predictor
    localparam int TAGE_BASE_ENTRIES = 4096;               // 4K bimodal base
    localparam int TAGE_NUM_TABLES   = 4;                  // 4 tagged tables
    localparam int TAGE_TABLE_ENTRIES = 256;               // 256 entries each
    localparam int TAGE_TAG_BITS     = 12;                 // 12-bit tags

    // Statistical corrector
    localparam int SC_ENTRIES         = 1024;

    // Loop predictor
    localparam int LOOP_PRED_ENTRIES  = 64;

    // BTB
    //
    // The fetch frontend indexes the BTB by cache line and stores a byte
    // offset for each control-flow site in that line. Dhrystone's hot text
    // region has several lines with 5-7 distinct control transfers, so the
    // original 4-way organization cannot represent them without thrashing.
    // Keep the set count stable for alias behavior and raise only the per-line
    // associativity.
    localparam int BTB_ENTRIES    = 2048;
    localparam int BTB_WAYS       = 8;
    localparam int BTB_SETS       = BTB_ENTRIES / BTB_WAYS; // 256

    // RAS and GHR
    localparam int RAS_DEPTH      = 24;
    localparam int GHR_BITS       = 64;

    // =========================================================================
    // SoC
    // =========================================================================
    localparam int NUM_HARTS      = 1;

    // =========================================================================
    // Memory map
    // =========================================================================
    localparam logic [63:0] BOOT_ROM_BASE = 64'h0000_0000;
    localparam logic [63:0] CLINT_BASE    = 64'h0200_0000;
    localparam logic [63:0] CLINT_SIZE    = 64'h0001_0000;
    localparam logic [63:0] PLIC_BASE     = 64'h0C00_0000;
    localparam logic [63:0] PLIC_SIZE     = 64'h0400_0000;
    localparam logic [63:0] UART_BASE     = 64'h1000_0000;
    localparam logic [63:0] UART_SIZE     = 64'h0000_0100;
    localparam logic [63:0] DRAM_BASE     = 64'h8000_0000;
    localparam logic [63:0] RESET_VECTOR  = 64'h8000_0000;

    // Simulation
    localparam logic [63:0] TOHOST_ADDR      = 64'h8000_1000;
    localparam logic [63:0] TOHOST_ADDR_ALT1 = 64'h8000_2000;
    localparam logic [63:0] TOHOST_ADDR_ALT2 = 64'h8000_3000;

endpackage
`endif
