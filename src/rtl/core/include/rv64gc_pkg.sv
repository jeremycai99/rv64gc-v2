/* file: rv64gc_pkg.sv
 Description: Top-level package with microarchitectural parameters.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
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
    localparam int LQ_DEPTH       = 64;
    localparam int SQ_DEPTH       = 64;
    localparam int CSB_DEPTH      = 32;  // committed store buffer (was 24)

    localparam int LQ_IDX_BITS    = $clog2(LQ_DEPTH);   // 6
    localparam int SQ_IDX_BITS    = $clog2(SQ_DEPTH);   // 6
    localparam int CSB_IDX_BITS   = $clog2(CSB_DEPTH);   // 5

    // =========================================================================
    // Functional units
    // =========================================================================
    localparam int NUM_ALU        = 3;
    localparam int MUL_LATENCY    = 3;
    localparam int CDB_WIDTH      = 4;
    localparam int NUM_BYPASS_SRCS = 4;
    // PRF write port count is kept at 6 (4 ALU/DIV/CSR + 2 load writeback)
    // independent of CDB_WIDTH (wakeup broadcast width).
    localparam int PRF_WRITE_PORTS = 6;

    // =========================================================================
    // Loop buffer
    // =========================================================================
    localparam int LOOP_BUF_DEPTH = 64;

    // =========================================================================
    // µop cache (gen-2, replaces loop buffer when proven; parallel during
    // bring-up behind +UOC_ENABLE plusarg).
    //
    // Geometry: 32 sets × 8 ways × 6 µops per entry = 1,536 µop slots.
    // Indexed by fetch-group start PC: PC[5:1] (RVC 2-byte alignment).
    // Modeled after Intel DSB / AMD Zen op-cache / ARM Mop-cache.
    // =========================================================================
    localparam int UOC_SETS        = 32;
    localparam int UOC_WAYS        = 8;
    localparam int UOC_PER_ENTRY   = PIPE_WIDTH;          // 6 µops/entry
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

    // L1 I-Cache: 32 KB, 4-way, 64B lines
    localparam int L1I_SIZE       = 32768;
    localparam int L1I_WAYS       = 4;
    localparam int L1I_SETS       = L1I_SIZE / (L1I_WAYS * LINE_SIZE);  // 128
    localparam int L1I_SET_BITS   = $clog2(L1I_SETS);     // 7
    localparam int L1I_TAG_BITS   = XLEN - L1I_SET_BITS - LINE_BITS;   // 51

    // L1 D-Cache: 64 KB, 4-way, 4-bank, 64B lines
    localparam int L1D_SIZE       = 65536;
    localparam int L1D_WAYS       = 4;
    localparam int L1D_BANKS      = 4;
    localparam int L1D_SETS       = L1D_SIZE / (L1D_WAYS * LINE_SIZE);  // 256
    localparam int L1D_SET_BITS   = $clog2(L1D_SETS);     // 8
    localparam int L1D_TAG_BITS   = XLEN - L1D_SET_BITS - LINE_BITS;   // 50
    localparam int L1D_MSHR_DEPTH = 16;

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
    localparam logic [63:0] PLIC_BASE     = 64'h0C00_0000;
    localparam logic [63:0] UART_BASE     = 64'h1000_0000;
    localparam logic [63:0] DRAM_BASE     = 64'h8000_0000;
    localparam logic [63:0] RESET_VECTOR  = 64'h8000_0000;

    // Simulation
    localparam logic [63:0] TOHOST_ADDR      = 64'h8000_1000;
    localparam logic [63:0] TOHOST_ADDR_ALT1 = 64'h8000_2000;
    localparam logic [63:0] TOHOST_ADDR_ALT2 = 64'h8000_3000;

endpackage
`endif
