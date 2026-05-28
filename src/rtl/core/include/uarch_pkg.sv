/* file: uarch_pkg.sv
 Description: Microarchitectural types: decoded_insn_t, iq_entry_t, etc.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Revision history:
    - Apr. 09, 2026: Imported into rv64gc-v2 RTL tree.
 */
`ifndef UARCH_PKG_SV
`define UARCH_PKG_SV
package uarch_pkg;

    import rv64gc_pkg::*;
    import fpu_pkg::*;

    localparam logic [3:0] EXC_INTERNAL_REPLAY = 4'd14;

    // =========================================================================
    // Functional unit type (3 bits)
    // =========================================================================
    typedef enum logic [2:0] {
        FU_ALU  = 3'd0,
        FU_BRU  = 3'd1,
        FU_MUL  = 3'd2,
        FU_DIV  = 3'd3,
        FU_LOAD = 3'd4,
        FU_STA  = 3'd5,  // store address
        FU_STD  = 3'd6,  // store data
        FU_CSR  = 3'd7
    } fu_type_e;

    // =========================================================================
    // ALU operation (6 bits) - base + Zba + Zbb + Zbs + Zicond
    // 37 operations require 6 bits (spec says 5 but enumerates 37 ops)
    // =========================================================================
    typedef enum logic [5:0] {
        // Base integer (0-11)
        ALU_ADD       = 6'd0,
        ALU_SUB       = 6'd1,
        ALU_AND       = 6'd2,
        ALU_OR        = 6'd3,
        ALU_XOR       = 6'd4,
        ALU_SLT       = 6'd5,
        ALU_SLTU      = 6'd6,
        ALU_SLL       = 6'd7,
        ALU_SRL       = 6'd8,
        ALU_SRA       = 6'd9,
        ALU_LUI       = 6'd10,
        ALU_PASS2     = 6'd11, // pass operand 2 (for AUIPC: PC + imm)
        // Zba (12-14)
        ALU_SH1ADD    = 6'd12,
        ALU_SH2ADD    = 6'd13,
        ALU_SH3ADD    = 6'd14,
        // Zbb (15-30)
        ALU_MIN       = 6'd15,
        ALU_MAX       = 6'd16,
        ALU_MINU      = 6'd17,
        ALU_MAXU      = 6'd18,
        ALU_CLZ       = 6'd19,
        ALU_CTZ       = 6'd20,
        ALU_CPOP      = 6'd21,
        ALU_ANDN      = 6'd22,
        ALU_ORN       = 6'd23,
        ALU_XNOR      = 6'd24,
        ALU_ROL       = 6'd25,
        ALU_ROR       = 6'd26,
        ALU_SEXTB     = 6'd27,
        ALU_SEXTH     = 6'd28,
        ALU_REV8      = 6'd29,
        ALU_ORCB      = 6'd30,
        // Zbs (31-34)
        ALU_BSET      = 6'd31,
        ALU_BCLR      = 6'd32,
        ALU_BINV      = 6'd33,
        ALU_BEXT      = 6'd34,
        // Zicond (35-36)
        ALU_CZERO_EQZ = 6'd35,
        ALU_CZERO_NEZ = 6'd36
    } alu_op_e;

    // =========================================================================
    // Branch operation (3 bits)
    // =========================================================================
    typedef enum logic [2:0] {
        BR_EQ   = 3'd0,
        BR_NE   = 3'd1,
        BR_LT   = 3'd2,
        BR_GE   = 3'd3,
        BR_LTU  = 3'd4,
        BR_GEU  = 3'd5,
        BR_JAL  = 3'd6,
        BR_JALR = 3'd7
    } br_op_e;

    // =========================================================================
    // Multiply operation (2 bits)
    // =========================================================================
    typedef enum logic [1:0] {
        MUL_MUL    = 2'd0,
        MUL_MULH   = 2'd1,
        MUL_MULHSU = 2'd2,
        MUL_MULHU  = 2'd3
    } mul_op_e;

    // =========================================================================
    // Divide operation (2 bits)
    // =========================================================================
    typedef enum logic [1:0] {
        DIV_DIV  = 2'd0,
        DIV_DIVU = 2'd1,
        DIV_REM  = 2'd2,
        DIV_REMU = 2'd3
    } div_op_e;

    // =========================================================================
    // Memory size (2 bits)
    // =========================================================================
    typedef enum logic [1:0] {
        MEM_BYTE  = 2'd0,
        MEM_HALF  = 2'd1,
        MEM_WORD  = 2'd2,
        MEM_DWORD = 2'd3
    } mem_size_e;

    // =========================================================================
    // CSR operation (2 bits)
    // =========================================================================
    typedef enum logic [1:0] {
        CSR_RW   = 2'd0,
        CSR_RS   = 2'd1,
        CSR_RC   = 2'd2,
        CSR_NONE = 2'd3
    } csr_op_e;

    // =========================================================================
    // Decoded instruction (output of decode stage)
    // =========================================================================
    typedef struct packed {
        logic               valid;
        logic [63:0]        pc;
        logic [63:0]        trap_pc;        // first architectural PC for precise trap restart
        logic [31:0]        insn;           // raw instruction bits
        // Source/destination registers
        logic [4:0]         rs1_arch;
        logic [4:0]         rs2_arch;
        logic [4:0]         rs3_arch;
        logic [4:0]         rd_arch;
        logic               rs1_valid;
        logic               rs2_valid;
        logic               rs3_valid;
        logic               rd_valid;
        // Immediate
        logic [63:0]        imm;
        // Operation type
        fu_type_e           fu_type;
        alu_op_e            alu_op;
        br_op_e             br_op;
        mul_op_e            mul_op;
        div_op_e            div_op;
        mem_size_e          mem_size;
        csr_op_e            csr_op;
        logic [11:0]        csr_addr;
        // Flags
        logic               is_branch;
        logic               is_jal;
        logic               is_jalr;
        logic               is_load;
        logic               is_store;
        logic               is_csr;
        logic               is_mul;
        logic               is_div;
        logic               is_w_op;        // W-suffix (32-bit op on RV64)
        logic               is_unsigned;    // unsigned load or Zba unsigned-word op
        logic               use_imm;        // ALU operand B is immediate
        logic               is_fence;
        logic               is_fence_i;
        logic               is_ecall;
        logic               is_ebreak;
        logic               is_mret;
        logic               is_sret;
        logic               is_sfence_vma;
        logic               is_wfi;
        logic               is_amo;
        logic [4:0]         amo_op;         // AMO funct5
        logic               amo_aq;
        logic               amo_rl;
        logic               is_fp_op;
        logic               rs1_is_fp;
        logic               rs2_is_fp;
        logic               rs3_is_fp;
        logic               rd_is_fp;
        fp_fmt_e            fp_fmt;
        fp_fmt_e            fp_dst_fmt;
        fp_int_fmt_e        fp_int_fmt;
        fp_rm_e             fp_rm;
        fpu_pipe_e          fp_pipe;
        fpu_op_e            fp_op;
        logic               fp_op_mod;
        fpu_misc_op_e       fp_misc_op;
        fmv_op_e            fmv_op;
        logic               is_rvc;
        // Branch prediction info (filled by fetch)
        logic               bp_taken;
        logic [63:0]        bp_target;
        logic               bp_owner;
        logic               bp_from_subgroup;
        logic [63:0]        bp_lookup_pc;
        logic [4:0]         bp_ras_tos;
        logic [63:0]        bp_ras_top;
        logic [GHR_BITS-1:0] bp_ghr;
        logic               has_exception;
        logic [3:0]         exc_code;
        logic [63:0]        exc_tval;
        // NEW v2 fields: instruction fusion
        logic               is_fused;
        logic [31:0]        fused_imm;
        logic [2:0]         fusion_type;
    } decoded_insn_t;

    // =========================================================================
    // Frontend fetch packet (fetch buffer payload)
    // Packed arrays are used here so the whole packet can be queued as a
    // single packed object through the fetch buffer without unpacked-array
    // port issues.
    // =========================================================================
    typedef struct packed {
        logic [63:0]                    block_pc;
        logic [5:0]                     start_offset;
        logic [63:0]                    fallthrough_pc;
        logic                           pred_ctl_valid;
        logic                           pred_ctl_taken;
        logic [5:0]                     pred_ctl_offset;
        logic [2:0]                     pred_ctl_type;
        logic [63:0]                    pred_ctl_target;
        logic                           pred_from_subgroup;
        logic                           btb_hit;
        logic [5:0]                     btb_offset;
        logic [2:0]                     btb_type;
        logic [63:0]                    btb_target;
        logic                           btb_alt_hit;
        logic [5:0]                     btb_alt_offset;
        logic [2:0]                     btb_alt_type;
        logic [63:0]                    btb_alt_target;
        logic                           tage_taken;
        logic                           tage_confident;
        logic [4:0]                     ras_tos_snapshot;
        logic [63:0]                    ras_top_snapshot;
        logic [GHR_BITS-1:0]            ghr_snapshot;
    } ftq_entry_t;

    typedef struct packed {
        logic                           valid;
        logic [FTQ_IDX_BITS-1:0]        ftq_idx;
        logic [FTQ_EPOCH_BITS-1:0]      ftq_epoch;
        logic [FTQ_ALLOC_TAG_BITS-1:0]  ftq_alloc_tag;
        logic                           ftq_owner_complete;
        logic [63:0]                    ftq_block_pc;
        logic [5:0]                     ftq_start_offset;
        logic [63:LINE_BITS]            ifu_line_addr;
        logic                           ifu_line_reused;
        logic [63:0]                    ftq_bp_lookup_pc;
        logic                           ftq_pred_valid;
        logic                           ftq_pred_taken;
        logic [5:0]                     ftq_pred_offset;
        logic [2:0]                     ftq_pred_type;
        logic [63:0]                    ftq_pred_target;
        logic                           ftq_pred_from_subgroup;
        logic                           pd_ctl_valid;
        logic [2:0]                     pd_ctl_slot;
        logic [2:0]                     pd_ctl_type;
        logic [63:0]                    pd_ctl_target;
        logic [2:0]                     fetch_count;
        logic [PIPE_WIDTH-1:0][31:0]    fetch_insn;
        logic [PIPE_WIDTH-1:0][63:0]    fetch_pc;
        logic [PIPE_WIDTH-1:0]          fetch_is_rvc;
        logic [PIPE_WIDTH-1:0]          fetch_bp_taken;
        logic [PIPE_WIDTH-1:0][63:0]    fetch_bp_target;
        logic [4:0]                     fetch_bp_ras_tos;
        logic [63:0]                    fetch_bp_ras_top;
        logic [GHR_BITS-1:0]            fetch_bp_ghr;
    } fetch_packet_t;

    // =========================================================================
    // Renamed instruction (output of rename stage)
    // Padded to 448 bits (7x64) to avoid Verilator struct-array misalignment.
    // =========================================================================
    localparam int RENAMED_INSN_PAYLOAD_BITS = $bits(decoded_insn_t) +
        ROB_IDX_BITS + (5 * PHYS_REG_BITS) + 3 + CHECKPOINT_BITS + 1 +
        SQ_IDX_BITS + LQ_IDX_BITS;
    localparam int RENAMED_INSN_PAD_BITS =
        (640 > RENAMED_INSN_PAYLOAD_BITS) ?
        (640 - RENAMED_INSN_PAYLOAD_BITS) : 1;

    typedef struct packed {
        logic [RENAMED_INSN_PAD_BITS-1:0] _pad;
        decoded_insn_t                  base;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       rs1_phys;
        logic [PHYS_REG_BITS-1:0]       rs2_phys;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [PHYS_REG_BITS-1:0]       old_pdst;
        logic [PHYS_REG_BITS-1:0]       rs3_phys;
        logic                           rs1_ready;
        logic                           rs2_ready;
        logic                           rs3_ready;
        logic [CHECKPOINT_BITS-1:0]     checkpoint_id;
        logic                           uses_checkpoint;
        logic [SQ_IDX_BITS-1:0]         sq_idx;
        logic [LQ_IDX_BITS-1:0]         lq_idx;
    } renamed_insn_t;

    // =========================================================================
    // ROB entry
    // =========================================================================
    typedef struct packed {
        logic               valid;
        logic               ready;          // execution complete
        logic [63:0]        pc;
        logic               has_exception;
        logic [3:0]         exc_code;
        logic               is_branch;
        logic               is_store;
        logic               is_load;
        logic               is_csr;
        logic               is_fence;
        logic               is_fence_i;
        logic               is_mret;
        logic               is_sret;
        logic               is_sfence_vma;
        logic               is_ecall;
        logic               is_wfi;
        // Branch resolution (filled by BRU at writeback)
        logic               branch_taken;
        logic [63:0]        branch_target;
        logic               branch_mispredict;
        // CSR writeback (deferred to commit)
        logic [11:0]        csr_addr;
        logic [63:0]        csr_wdata;
        logic               csr_we;
    } rob_entry_t;

    // =========================================================================
    // Issue queue entry
    // Padded to 448 bits (7x64) to ensure Verilator aligns struct arrays
    // correctly. Without padding, non-64-bit-aligned packed structs have caused
    // field misalignment when stored in unpacked arrays, corrupting pc/imm in
    // the BRU path.
    // =========================================================================
    typedef struct packed {
        logic [127:0]                   _pad;
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [PHYS_REG_BITS-1:0]       rs1_phys;
        logic [PHYS_REG_BITS-1:0]       rs2_phys;
        logic [PHYS_REG_BITS-1:0]       rs3_phys;
        logic                           rs1_ready;
        logic                           rs2_ready;
        logic                           rs3_ready;
        logic [63:0]                    imm;
        fu_type_e                       fu_type;
        alu_op_e                        alu_op;
        br_op_e                         br_op;
        mul_op_e                        mul_op;
        div_op_e                        div_op;
        mem_size_e                      mem_size;
        csr_op_e                        csr_op;
        logic [11:0]                    csr_addr;
        logic                           is_w_op;
        logic                           is_unsigned;
        logic                           use_imm;
        logic [63:0]                    pc;
        logic                           bp_taken;
        logic [63:0]                    bp_target;
        logic [4:0]                     bp_ras_tos;
        logic [63:0]                    bp_ras_top;
        logic [1:0]                     bp_ras_op;
        logic [GHR_BITS-1:0]            bp_ghr;
        // v2 fusion fields
        logic                           is_fused;
        logic [2:0]                     fusion_type;
        logic [31:0]                    fused_imm;
        // AMO
        logic                           is_amo;
        logic [4:0]                     amo_op;
        logic                           amo_aq;
        logic                           amo_rl;
        logic                           is_fp_op;
        logic                           rs1_is_fp;
        logic                           rs2_is_fp;
        logic                           rs3_is_fp;
        logic                           rd_is_fp;
        fp_fmt_e                        fp_fmt;
        fp_fmt_e                        fp_dst_fmt;
        fp_int_fmt_e                    fp_int_fmt;
        fp_rm_e                         fp_rm;
        fpu_pipe_e                      fp_pipe;
        fpu_op_e                        fp_op;
        logic                           fp_op_mod;
        fpu_misc_op_e                   fp_misc_op;
        fmv_op_e                        fmv_op;
        logic                           is_rvc;
        // Checkpoint / LSQ indices
        logic [CHECKPOINT_BITS-1:0]     checkpoint_id;
        logic                           uses_checkpoint;
        logic [SQ_IDX_BITS-1:0]         sq_idx;
        logic [LQ_IDX_BITS-1:0]         lq_idx;
    } iq_entry_t;

    // =========================================================================
    // Wakeup tag (broadcast from FU to IQs)
    // =========================================================================
    typedef struct packed {
        logic                           valid;
        logic [PHYS_REG_BITS-1:0]       pdst;
    } wakeup_tag_t;

    // =========================================================================
    // Writeback result (FU to ROB/PRF)
    // =========================================================================
    typedef struct packed {
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [63:0]                    data;
        logic                           has_exception;
        logic [3:0]                     exc_code;
        // Branch specific
        logic                           is_branch;
        logic                           branch_taken;
        logic [63:0]                    branch_target;
        logic                           branch_mispredict;
        // CSR specific
        logic                           csr_we;
        logic [11:0]                    csr_addr;
        logic [63:0]                    csr_wdata;
    } wb_result_t;

    // =========================================================================
    // Flush signal
    // =========================================================================
    typedef struct packed {
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [63:0]                    redirect_pc;
        logic [CHECKPOINT_BITS-1:0]     checkpoint_id;
        logic                           full_flush;
        logic [4:0]                     ras_tos;
        logic                           ras_top_restore_valid;
        logic [63:0]                    ras_top_restore_addr;
        logic                           ghr_restore_valid;
        logic [GHR_BITS-1:0]            ghr_restore_val;
    } flush_t;

    // =========================================================================
    // Commit signal (ROB head to rename/free list)
    // =========================================================================
    typedef struct packed {
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [PHYS_REG_BITS-1:0]       old_pdst;
        logic [4:0]                     rd_arch;
        logic                           rd_valid;
    } commit_t;

    // =========================================================================
    // Rename buffer entry (parallel to ROB)
    // =========================================================================
    typedef struct packed {
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [PHYS_REG_BITS-1:0]       old_pdst;
        logic [4:0]                     rd_arch;
        logic                           rd_valid;
        logic                           rd_is_fp;
        logic                           bp_owner;
        logic [63:0]                    bp_lookup_pc;
        logic [4:0]                     bp_ras_tos;
        logic [63:0]                    bp_ras_top;
        logic [1:0]                     bp_ras_op;
        logic [GHR_BITS-1:0]            bp_ghr;
    } rename_buf_entry_t;

    // =========================================================================
    // Cache and LSU types
    // =========================================================================

    // D-cache request from LSU
    typedef struct packed {
        logic                           valid;
        logic                           we;
        logic [63:0]                    addr;
        logic [63:0]                    wdata;
        logic [7:0]                     wmask;
        logic [1:0]                     size;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [LQ_IDX_BITS-1:0]         lq_idx;
        logic                           is_unsigned;
    } dcache_req_t;

    // D-cache response to LSU
    typedef struct packed {
        logic                           valid;
        logic [63:0]                    rdata;
        logic                           hit;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [LQ_IDX_BITS-1:0]         lq_idx;
        logic [1:0]                     size;
        logic                           is_unsigned;
    } dcache_resp_t;

    // Cache fill request to next level (L2 or memory)
    typedef struct packed {
        logic                           valid;
        logic [63:0]                    addr;
        logic                           we;
        logic [LINE_SIZE*8-1:0]         wdata;
    } cache_mem_req_t;

    // Cache fill response from next level
    typedef struct packed {
        logic                           valid;
        logic [63:0]                    addr;
        logic [LINE_SIZE*8-1:0]         rdata;
    } cache_mem_resp_t;

    // Load queue entry
    typedef struct packed {
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [PHYS_REG_BITS-1:0]       pdst;
        logic [63:0]                    addr;
        logic                           addr_valid;
        logic                           executed;
        logic [1:0]                     size;
        logic                           is_unsigned;
        logic                           has_result;
        logic [63:0]                    data;
    } lq_entry_t;

    // Store queue entry
    typedef struct packed {
        logic                           valid;
        logic [ROB_IDX_BITS-1:0]        rob_idx;
        logic [63:0]                    addr;
        logic                           addr_valid;
        logic [63:0]                    data;
        logic                           data_valid;
        logic [7:0]                     byte_mask;
        logic [1:0]                     size;
        logic                           committed;
    } sq_entry_t;

    // Committed store buffer entry
    typedef struct packed {
        logic                           valid;
        logic [63:0]                    addr;
        logic [63:0]                    data;
        logic [7:0]                     byte_mask;
        logic [1:0]                     size;
    } csb_entry_t;

endpackage
`endif
