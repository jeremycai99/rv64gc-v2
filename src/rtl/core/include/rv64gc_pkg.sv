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
    // Pipeline widths (6-wide superscalar)
    // =========================================================================
    localparam int PIPE_WIDTH     = 6;   // fetch/decode/rename/dispatch/commit
    localparam int FETCH_WIDTH    = PIPE_WIDTH;
    localparam int DECODE_WIDTH   = PIPE_WIDTH;
    localparam int RENAME_WIDTH   = PIPE_WIDTH;
    localparam int DISPATCH_WIDTH = PIPE_WIDTH;
    localparam int COMMIT_WIDTH   = PIPE_WIDTH;
    localparam int FETCH_BYTES    = FETCH_WIDTH * 4;  // 24 bytes

    // =========================================================================
    // Physical register file
    // =========================================================================
    localparam int INT_PRF_DEPTH  = 256;
    localparam int PHYS_REG_BITS  = 8;   // $clog2(256) = 8
    localparam int FP_PRF_DEPTH   = 128;

    // =========================================================================
    // Reorder buffer
    // =========================================================================
    localparam int ROB_DEPTH      = 192;
    localparam int ROB_IDX_BITS   = 8;   // ceil(log2(192)) = 8

    // =========================================================================
    // Free list
    // =========================================================================
    localparam int INT_FREE_LIST_DEPTH = INT_PRF_DEPTH - ARCH_REGS; // 224
    localparam int FP_FREE_LIST_DEPTH  = FP_PRF_DEPTH - ARCH_REGS;  // 96

    // =========================================================================
    // Checkpoints (branch snapshots)
    // =========================================================================
    localparam int NUM_CHECKPOINTS = 4;
    localparam int CHECKPOINT_BITS = 2;  // $clog2(4) = 2

    // =========================================================================
    // Issue queues
    // =========================================================================
    localparam int NUM_INT_IQS    = 3;
    localparam int IQ_INT_DEPTH   = 32;
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
    localparam int LQ_DEPTH       = 48;
    localparam int SQ_DEPTH       = 48;
    localparam int CSB_DEPTH      = 24;  // committed store buffer

    localparam int LQ_IDX_BITS    = $clog2(LQ_DEPTH);   // 6
    localparam int SQ_IDX_BITS    = $clog2(SQ_DEPTH);   // 6
    localparam int CSB_IDX_BITS   = $clog2(CSB_DEPTH);   // 5

    // =========================================================================
    // Functional units
    // =========================================================================
    localparam int NUM_ALU        = 4;
    localparam int MUL_LATENCY    = 3;
    localparam int CDB_WIDTH      = 6;
    localparam int NUM_BYPASS_SRCS = 6;

    // =========================================================================
    // Loop buffer
    // =========================================================================
    localparam int LOOP_BUF_DEPTH = 64;

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
    localparam int BTB_ENTRIES    = 1024;
    localparam int BTB_WAYS       = 4;
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
