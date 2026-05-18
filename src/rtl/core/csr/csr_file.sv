/* file: csr_file.sv
 Description: Privilege-aware CSR file with M/S/U mode, traps, and counters.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef CSR_FILE_SV
`define CSR_FILE_SV

module csr_file
    import rv64gc_pkg::*;
    import isa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // CSR read (for CSR instructions – combinational)
    input  logic [11:0] read_addr,
    input  logic        read_write_intent,
    output logic [63:0] read_data,
    output logic        read_illegal,

    // CSR write (from commit — serialized, at most 1/cycle)
    input  logic        write_valid,
    input  logic [11:0] write_addr,
    input  logic [63:0] write_data,
    input  logic [1:0]  write_op,       // csr_op_e: 0=RW, 1=RS, 2=RC
    input  logic        fflags_acc_valid_i,
    input  logic [4:0]  fflags_acc_bits_i,
    input  logic        fp_state_dirty_i,

    // Trap interface (from commit)
    input  logic        trap_valid,
    input  logic [63:0] trap_cause,
    input  logic [63:0] trap_pc,        // PC of faulting/interrupting instruction
    input  logic [63:0] trap_val,       // mtval/stval value
    input  logic        trap_is_interrupt,
    input  logic        trap_to_supervisor,

    // Return from trap
    input  logic        mret_valid,
    input  logic        sret_valid,

    // Outputs for pipeline use
    output logic [63:0] mtvec,
    output logic [63:0] stvec,
    output logic [63:0] mepc,
    output logic [63:0] sepc,
    output logic [1:0]  priv_mode,
    output logic [2:0]  frm_out,

    // Interrupt outputs
    output logic        irq_pending,
    output logic [63:0] irq_cause,
    output logic        irq_to_supervisor,

    // Performance counters
    input  logic [3:0]  insn_retired_count,  // architectural instructions from commit
    output logic [63:0] mcycle_val,
    output logic [63:0] minstret_val,

    // Timer (from external CLINT)
    input  logic [63:0] time_val,

    // External interrupts
    input  logic        mtip, msip, meip,
    input  logic        stip, ssip, seip,

    // Privileged translation state
    output logic        mstatus_mprv,
    output logic [1:0]  mstatus_mpp,
    output logic [1:0]  mstatus_fs,
    output logic        mstatus_sum,
    output logic        mstatus_mxr,
    output logic [63:0] satp,
    output logic [63:0] medeleg,
    output logic [63:0] mideleg
);

    // =========================================================================
    // Local parameters: sstatus visible / writable masks (privileged spec)
    // =========================================================================
    localparam logic [63:0] SSTATUS_MASK =
        (64'h1 << 63) | (64'h3 << 32) | (64'h1 << 19) | (64'h1 << 18) |
        (64'h3 << 15) | (64'h3 << 13) | (64'h1 << 8)  | (64'h1 << 6)  |
        (64'h1 << 5)  | (64'h1 << 1);

    localparam logic [63:0] SSTATUS_WMASK =
        (64'h3 << 32) | (64'h1 << 19) | (64'h1 << 18) | (64'h3 << 15) |
        (64'h3 << 13) | (64'h1 << 8)  | (64'h1 << 6)  | (64'h1 << 5)  |
        (64'h1 << 1);

    // misa: implemented Stage 3 contract, RV64G(C) + S + U.
    localparam logic [63:0] MISA_VAL =
        (64'h2 << 62)  |   // MXL = 2 (RV64)
        (64'h1 << 0)   |   // A – Atomics
        (64'h1 << 2)   |   // C – Compressed
        (64'h1 << 3)   |   // D – Double-precision FP
        (64'h1 << 5)   |   // F – Single-precision FP
        (64'h1 << 8)   |   // I – Integer
        (64'h1 << 12)  |   // M – Multiply
        (64'h1 << 18)  |   // S – Supervisor
        (64'h1 << 20);     // U – User

    // =========================================================================
    // CSR storage
    // =========================================================================
    logic [63:0] mstatus_r;
    logic [63:0] mtvec_r;
    logic [63:0] stvec_r;
    logic [63:0] mepc_r;
    logic [63:0] sepc_r;
    logic [63:0] mcause_r;
    logic [63:0] scause_r;
    logic [63:0] mtval_r;
    logic [63:0] stval_r;
    logic [63:0] mscratch_r;
    logic [63:0] sscratch_r;
    logic [63:0] medeleg_r;
    logic [63:0] mideleg_r;
    logic [63:0] mie_r;
    logic [63:0] mip_r;          // software-writable shadow
    logic [63:0] mcounteren_r;
    logic [63:0] scounteren_r;
    logic [63:0] senvcfg_r;
    logic [63:0] mcountinhibit_r;
    logic [63:0] mcycle_r;
    logic [63:0] minstret_r;
    logic [63:0] pmpcfg0_r;
    logic [63:0] pmpaddr0_r;
    logic [63:0] satp_r;
    logic [63:0] tcontrol_r;
    logic [1:0]  priv_r;
    logic [4:0]  fflags_r;
    logic [2:0]  frm_r;

    // =========================================================================
    // Continuous output assignments
    // =========================================================================
    assign mtvec       = mtvec_r;
    assign stvec       = stvec_r;
    assign mepc        = mepc_r;
    assign sepc        = sepc_r;
    assign priv_mode   = priv_r;
    assign frm_out     = frm_r;
    assign mstatus_mprv = mstatus_r[17];
    assign mstatus_mpp = mstatus_r[12:11];
    assign mstatus_fs  = mstatus_r[14:13];
    assign mstatus_sum = mstatus_r[18];
    assign mstatus_mxr = mstatus_r[19];
    assign satp        = satp_r;
    assign medeleg     = medeleg_r;
    assign mideleg     = mideleg_r;
    assign mcycle_val  = mcycle_r;
    assign minstret_val= minstret_r;

    // =========================================================================
    // Effective MIP: hardware interrupt lines override soft shadow
    // =========================================================================
    logic [63:0] mip_eff;
    always_comb begin
        mip_eff                = mip_r;
        mip_eff[IRQ_M_TIMER]  = mtip;
        mip_eff[IRQ_M_SOFT]   = msip;
        mip_eff[IRQ_M_EXT]    = meip;
        mip_eff[IRQ_S_TIMER]  = mip_r[IRQ_S_TIMER] | stip;
        mip_eff[IRQ_S_SOFT]   = mip_r[IRQ_S_SOFT]  | ssip;
        mip_eff[IRQ_S_EXT]    = mip_r[IRQ_S_EXT]   | seip;
    end

    // =========================================================================
    // Interrupt pending / cause logic
    // =========================================================================
    always_comb begin
        irq_pending       = 1'b0;
        irq_cause         = 64'd0;
        irq_to_supervisor = 1'b0;

        if (mip_eff[IRQ_M_EXT] && mie_r[IRQ_M_EXT] &&
            ((priv_r != PRIV_M) || mstatus_r[3])) begin
            irq_pending = 1'b1;
            irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_M_EXT};
        end else if (mip_eff[IRQ_M_SOFT] && mie_r[IRQ_M_SOFT] &&
                     ((priv_r != PRIV_M) || mstatus_r[3])) begin
            irq_pending = 1'b1;
            irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_M_SOFT};
        end else if (mip_eff[IRQ_M_TIMER] && mie_r[IRQ_M_TIMER] &&
                     ((priv_r != PRIV_M) || mstatus_r[3])) begin
            irq_pending = 1'b1;
            irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_M_TIMER};
        end else if (mip_eff[IRQ_S_EXT] && mie_r[IRQ_S_EXT]) begin
            if (mideleg_r[IRQ_S_EXT] && (priv_r != PRIV_M) &&
                ((priv_r == PRIV_U) || mstatus_r[1])) begin
                irq_pending       = 1'b1;
                irq_cause         = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_EXT};
                irq_to_supervisor = 1'b1;
            end else if (!mideleg_r[IRQ_S_EXT] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_EXT};
            end
        end else if (mip_eff[IRQ_S_SOFT] && mie_r[IRQ_S_SOFT]) begin
            if (mideleg_r[IRQ_S_SOFT] && (priv_r != PRIV_M) &&
                ((priv_r == PRIV_U) || mstatus_r[1])) begin
                irq_pending       = 1'b1;
                irq_cause         = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_SOFT};
                irq_to_supervisor = 1'b1;
            end else if (!mideleg_r[IRQ_S_SOFT] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_SOFT};
            end
        end else if (mip_eff[IRQ_S_TIMER] && mie_r[IRQ_S_TIMER]) begin
            if (mideleg_r[IRQ_S_TIMER] && (priv_r != PRIV_M) &&
                ((priv_r == PRIV_U) || mstatus_r[1])) begin
                irq_pending       = 1'b1;
                irq_cause         = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_TIMER};
                irq_to_supervisor = 1'b1;
            end else if (!mideleg_r[IRQ_S_TIMER] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_TIMER};
            end
        end
    end

    // =========================================================================
    // Inline CSR apply_op: wire-based for all (cur, wdata, op) combinations.
    // ((op == 2'd0) ? (wdata) : (op == 2'd1) ? ((cur) | (wdata)) : (op == 2'd2) ? ((cur) & ~(wdata)) : (cur)) = (op==0) ? wdata : (op==1) ? cur|wdata :
    //                            (op==2) ? cur & ~wdata : cur;
    //
    // norm_mstatus(ms): force SXL/UXL=2 (RV64) and compute SD bit.
    // Both inlined at every usage site.
    // =========================================================================

    // =========================================================================
    // Intermediate signals for mstatus/sstatus bypass (module-scope wires)
    // =========================================================================
    logic        csr_bypass;
    logic [63:0] mstatus_norm;
    logic [63:0] mstatus_wdata_op;
    logic [63:0] mstatus_norm_bypass;
    logic [63:0] ss_wdata_op;
    logic [63:0] sstatus_applied;
    logic [63:0] sstatus_applied_norm;
    logic [63:0] sstatus_view;
    logic [63:0] sstatus_view_bypass;
    logic        csr_addr_supported;
    logic        csr_priv_illegal;
    logic        csr_readonly_illegal;
    logic        csr_counter_illegal;
    logic        csr_counter_addr;
    logic [1:0]  csr_counter_bit;

    assign csr_bypass = write_valid && !trap_valid && !mret_valid && !sret_valid &&
                        (write_addr == read_addr);

    assign mstatus_wdata_op      = ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mstatus_r) | (write_data)) : (write_op == 2'd2) ? ((mstatus_r) & ~(write_data)) : (mstatus_r));
    // Inline norm_mstatus: force SXL=2, UXL=2, compute SD
    always_comb begin
        mstatus_norm         = mstatus_r;
        mstatus_norm[35:34]  = 2'b10;
        mstatus_norm[33:32]  = 2'b10;
        mstatus_norm[63]     = (mstatus_norm[14:13] == 2'b11) ||
                               (mstatus_norm[16:15] == 2'b11);
    end
    always_comb begin
        mstatus_norm_bypass         = mstatus_wdata_op;
        mstatus_norm_bypass[35:34]  = 2'b10;
        mstatus_norm_bypass[33:32]  = 2'b10;
        mstatus_norm_bypass[63]     = (mstatus_norm_bypass[14:13] == 2'b11) ||
                                      (mstatus_norm_bypass[16:15] == 2'b11);
    end

    // sstatus: apply write only to writable S-visible bits
    assign ss_wdata_op           = ((write_op == 2'd0) ? (write_data & SSTATUS_WMASK) : (write_op == 2'd1) ? ((mstatus_r & SSTATUS_WMASK) | (write_data & SSTATUS_WMASK)) : (write_op == 2'd2) ? ((mstatus_r & SSTATUS_WMASK) & ~(write_data & SSTATUS_WMASK)) : (mstatus_r & SSTATUS_WMASK));
    assign sstatus_applied       = (mstatus_r & ~SSTATUS_WMASK) |
                                   (ss_wdata_op & SSTATUS_WMASK);
    always_comb begin
        sstatus_applied_norm         = sstatus_applied;
        sstatus_applied_norm[35:34]  = 2'b10;
        sstatus_applied_norm[33:32]  = 2'b10;
        sstatus_applied_norm[63]     = (sstatus_applied_norm[14:13] == 2'b11) ||
                                       (sstatus_applied_norm[16:15] == 2'b11);
    end
    assign sstatus_view          = mstatus_norm        & SSTATUS_MASK;
    assign sstatus_view_bypass   = sstatus_applied_norm & SSTATUS_MASK;

    // =========================================================================
    // CSR access legality for the in-flight CSR instruction.
    // =========================================================================
    assign csr_priv_illegal = (priv_r < read_addr[9:8]);
    assign csr_readonly_illegal = read_write_intent && (read_addr[11:10] == 2'b11);

    always_comb begin
        csr_counter_addr = 1'b1;
        csr_counter_bit  = 2'd0;
        case (read_addr)
            CSR_CYCLE:   csr_counter_bit = 2'd0;
            CSR_TIME:    csr_counter_bit = 2'd1;
            CSR_INSTRET: csr_counter_bit = 2'd2;
            default: begin
                csr_counter_addr = 1'b0;
                csr_counter_bit  = 2'd0;
            end
        endcase
    end

    always_comb begin
        csr_counter_illegal = 1'b0;
        if (csr_counter_addr) begin
            if (priv_r == PRIV_S) begin
                csr_counter_illegal = !mcounteren_r[csr_counter_bit];
            end else if (priv_r == PRIV_U) begin
                csr_counter_illegal =
                    !mcounteren_r[csr_counter_bit] ||
                    !scounteren_r[csr_counter_bit];
            end
        end
    end

    always_comb begin
        case (read_addr)
            CSR_FFLAGS,
            CSR_FRM,
            CSR_FCSR,
            CSR_SSTATUS,
            CSR_SIE,
            CSR_STVEC,
            CSR_SCOUNTEREN,
            CSR_SENVCFG,
            CSR_SSCRATCH,
            CSR_SEPC,
            CSR_SCAUSE,
            CSR_STVAL,
            CSR_SIP,
            CSR_SATP,
            CSR_MSTATUS,
            CSR_MISA,
            CSR_MEDELEG,
            CSR_MIDELEG,
            CSR_MIE,
            CSR_MTVEC,
            CSR_MCOUNTEREN,
            CSR_MCOUNTINHIBIT,
            CSR_MSCRATCH,
            CSR_MEPC,
            CSR_MCAUSE,
            CSR_MTVAL,
            CSR_MIP,
            CSR_PMPCFG0,
            CSR_PMPADDR0,
            CSR_TSELECT,
            CSR_TDATA1,
            CSR_TDATA2,
            CSR_TCONTROL,
            CSR_MVENDORID,
            CSR_MARCHID,
            CSR_MIMPID,
            CSR_MHARTID,
            CSR_MCYCLE,
            CSR_MINSTRET,
            CSR_CYCLE,
            CSR_TIME,
            CSR_INSTRET: csr_addr_supported = 1'b1;
            default:    csr_addr_supported = 1'b0;
        endcase
    end

    assign read_illegal =
        !csr_addr_supported ||
        csr_priv_illegal ||
        csr_readonly_illegal ||
        csr_counter_illegal;

    // =========================================================================
    // Precomputed CSR operation results for FFLAGS/FRM/FCSR/SATP bypass
    // =========================================================================
    logic [63:0] csr_op_fflags, csr_op_frm, csr_op_fcsr, csr_op_satp;
    logic        csr_op_satp_legal;
    always_comb begin
        case (write_op)
            2'd0:    csr_op_fflags = write_data;
            2'd1:    csr_op_fflags = {59'd0,fflags_r} | write_data;
            2'd2:    csr_op_fflags = {59'd0,fflags_r} & ~write_data;
            default: csr_op_fflags = {59'd0,fflags_r};
        endcase
        case (write_op)
            2'd0:    csr_op_frm = write_data;
            2'd1:    csr_op_frm = {61'd0,frm_r} | write_data;
            2'd2:    csr_op_frm = {61'd0,frm_r} & ~write_data;
            default: csr_op_frm = {61'd0,frm_r};
        endcase
        case (write_op)
            2'd0:    csr_op_fcsr = write_data;
            2'd1:    csr_op_fcsr = {56'd0,frm_r,fflags_r} | write_data;
            2'd2:    csr_op_fcsr = {56'd0,frm_r,fflags_r} & ~write_data;
            default: csr_op_fcsr = {56'd0,frm_r,fflags_r};
        endcase
        case (write_op)
            2'd0:    csr_op_satp = write_data;
            2'd1:    csr_op_satp = satp_r | write_data;
            2'd2:    csr_op_satp = satp_r & ~write_data;
            default: csr_op_satp = satp_r;
        endcase
        csr_op_satp_legal =
            (csr_op_satp[63:60] == 4'd0) ||
            (csr_op_satp[63:60] == 4'd8) ||
            (csr_op_satp[63:60] == 4'd9);
    end

    // =========================================================================
    // Combinational read port (with same-cycle bypass)
    // =========================================================================
    always_comb begin
        case (read_addr)
            CSR_FFLAGS:    read_data = csr_bypass ?
                               {59'd0, csr_op_fflags[4:0]}
                             : {59'd0, fflags_r};
            CSR_FRM:       read_data = csr_bypass ?
                               {61'd0, csr_op_frm[2:0]}
                             : {61'd0, frm_r};
            CSR_FCSR:      read_data = csr_bypass ?
                               {56'd0, csr_op_fcsr[7:0]}
                             : {56'd0, frm_r, fflags_r};

            CSR_SSTATUS:   read_data = csr_bypass ? sstatus_view_bypass : sstatus_view;
            CSR_SIE:       read_data = csr_bypass ?
                               (((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mie_r) | (write_data)) : (write_op == 2'd2) ? ((mie_r) & ~(write_data)) : (mie_r)) & mideleg_r)
                             : (mie_r & mideleg_r);
            CSR_STVEC:     read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((stvec_r) | (write_data)) : (write_op == 2'd2) ? ((stvec_r) & ~(write_data)) : (stvec_r)) : stvec_r;
            CSR_SCOUNTEREN:read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((scounteren_r) | (write_data)) : (write_op == 2'd2) ? ((scounteren_r) & ~(write_data)) : (scounteren_r)) : scounteren_r;
            CSR_SENVCFG:   read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((senvcfg_r) | (write_data)) : (write_op == 2'd2) ? ((senvcfg_r) & ~(write_data)) : (senvcfg_r)) : senvcfg_r;
            CSR_SSCRATCH:  read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((sscratch_r) | (write_data)) : (write_op == 2'd2) ? ((sscratch_r) & ~(write_data)) : (sscratch_r)) : sscratch_r;
            CSR_SEPC:      read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((sepc_r) | (write_data)) : (write_op == 2'd2) ? ((sepc_r) & ~(write_data)) : (sepc_r)) : sepc_r;
            CSR_SCAUSE:    read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((scause_r) | (write_data)) : (write_op == 2'd2) ? ((scause_r) & ~(write_data)) : (scause_r)) : scause_r;
            CSR_STVAL:     read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((stval_r) | (write_data)) : (write_op == 2'd2) ? ((stval_r) & ~(write_data)) : (stval_r)) : stval_r;
            CSR_SIP:       read_data = csr_bypass ?
                               (((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mip_eff) | (write_data)) : (write_op == 2'd2) ? ((mip_eff) & ~(write_data)) : (mip_eff)) & mideleg_r)
                             : (mip_eff & mideleg_r);
            CSR_SATP:      read_data = (csr_bypass && csr_op_satp_legal)
                             ? csr_op_satp : satp_r;

            CSR_MSTATUS:   read_data = csr_bypass ? mstatus_norm_bypass : mstatus_norm;
            CSR_MISA:      read_data = MISA_VAL;
            CSR_MEDELEG:   read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((medeleg_r) | (write_data)) : (write_op == 2'd2) ? ((medeleg_r) & ~(write_data)) : (medeleg_r)) : medeleg_r;
            CSR_MIDELEG:   read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mideleg_r) | (write_data)) : (write_op == 2'd2) ? ((mideleg_r) & ~(write_data)) : (mideleg_r)) : mideleg_r;
            CSR_MIE:       read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mie_r) | (write_data)) : (write_op == 2'd2) ? ((mie_r) & ~(write_data)) : (mie_r)) : mie_r;
            CSR_MTVEC:     read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mtvec_r) | (write_data)) : (write_op == 2'd2) ? ((mtvec_r) & ~(write_data)) : (mtvec_r)) : mtvec_r;
            CSR_MCOUNTEREN:read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcounteren_r) | (write_data)) : (write_op == 2'd2) ? ((mcounteren_r) & ~(write_data)) : (mcounteren_r)) : mcounteren_r;
            CSR_MCOUNTINHIBIT: read_data = csr_bypass ?
                               ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcountinhibit_r) | (write_data)) : (write_op == 2'd2) ? ((mcountinhibit_r) & ~(write_data)) : (mcountinhibit_r)) : mcountinhibit_r;
            CSR_MSCRATCH:  read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mscratch_r) | (write_data)) : (write_op == 2'd2) ? ((mscratch_r) & ~(write_data)) : (mscratch_r)) : mscratch_r;
            CSR_MEPC:      read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mepc_r) | (write_data)) : (write_op == 2'd2) ? ((mepc_r) & ~(write_data)) : (mepc_r)) : mepc_r;
            CSR_MCAUSE:    read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcause_r) | (write_data)) : (write_op == 2'd2) ? ((mcause_r) & ~(write_data)) : (mcause_r)) : mcause_r;
            CSR_MTVAL:     read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mtval_r) | (write_data)) : (write_op == 2'd2) ? ((mtval_r) & ~(write_data)) : (mtval_r)) : mtval_r;
            CSR_MIP:       read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mip_eff) | (write_data)) : (write_op == 2'd2) ? ((mip_eff) & ~(write_data)) : (mip_eff)) : mip_eff;
            CSR_PMPCFG0:   read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((pmpcfg0_r) | (write_data)) : (write_op == 2'd2) ? ((pmpcfg0_r) & ~(write_data)) : (pmpcfg0_r)) : pmpcfg0_r;
            CSR_PMPADDR0:  read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((pmpaddr0_r) | (write_data)) : (write_op == 2'd2) ? ((pmpaddr0_r) & ~(write_data)) : (pmpaddr0_r)) : pmpaddr0_r;
            CSR_TSELECT:   read_data = 64'd0;
            CSR_TDATA1:    read_data = 64'd0;
            CSR_TDATA2:    read_data = 64'd0;
            CSR_TCONTROL:  read_data = csr_bypass ? ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((tcontrol_r) | (write_data)) : (write_op == 2'd2) ? ((tcontrol_r) & ~(write_data)) : (tcontrol_r)) : tcontrol_r;
            CSR_MVENDORID: read_data = 64'd0;
            CSR_MARCHID:   read_data = 64'd0;
            CSR_MIMPID:    read_data = 64'd0;
            CSR_MHARTID:   read_data = 64'd0;
            CSR_MCYCLE:    read_data = mcycle_r;
            CSR_MINSTRET:  read_data = minstret_r;
            CSR_CYCLE:     read_data = mcycle_r;
            CSR_TIME:      read_data = time_val;
            CSR_INSTRET:   read_data = minstret_r;
            default:       read_data = 64'd0;
        endcase
    end

    // =========================================================================
    // Sequential write logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_r       <= (64'h2 << 34) | (64'h2 << 32);
            mtvec_r         <= 64'd0;
            stvec_r         <= 64'd0;
            mepc_r          <= 64'd0;
            sepc_r          <= 64'd0;
            mcause_r        <= 64'd0;
            scause_r        <= 64'd0;
            mtval_r         <= 64'd0;
            stval_r         <= 64'd0;
            mscratch_r      <= 64'd0;
            sscratch_r      <= 64'd0;
            medeleg_r       <= 64'd0;
            mideleg_r       <= 64'd0;
            mie_r           <= 64'd0;
            mip_r           <= 64'd0;
            mcounteren_r    <= 64'd0;
            scounteren_r    <= 64'd0;
            senvcfg_r       <= 64'd0;
            mcountinhibit_r <= 64'd0;
            mcycle_r        <= 64'd0;
            minstret_r      <= 64'd0;
            pmpcfg0_r       <= 64'd0;
            pmpaddr0_r      <= 64'd0;
            satp_r          <= 64'd0;
            tcontrol_r      <= 64'd0;
            priv_r          <= PRIV_M;
            fflags_r        <= 5'd0;
            frm_r           <= 3'd0;
        end else begin
            // Performance counters (always running unless inhibited)
            if (!mcountinhibit_r[0])
                mcycle_r   <= mcycle_r + 64'd1;
            if (!mcountinhibit_r[2])
                minstret_r <= minstret_r + {60'd0, insn_retired_count};

            // Priority: trap > mret/sret > csr-write
            if (trap_valid) begin
                if (trap_to_supervisor) begin
                    sepc_r           <= trap_pc;
                    scause_r         <= trap_cause;
                    stval_r          <= trap_val;
                    mstatus_r[8]     <= (priv_r != PRIV_U);  // SPP
                    mstatus_r[5]     <= mstatus_r[1];         // SPIE = SIE
                    mstatus_r[1]     <= 1'b0;                 // SIE = 0
                    priv_r           <= PRIV_S;
                end else begin
                    mepc_r           <= trap_pc;
                    mcause_r         <= trap_cause;
                    mtval_r          <= trap_val;
                    mstatus_r[7]     <= mstatus_r[3];         // MPIE = MIE
                    mstatus_r[3]     <= 1'b0;                 // MIE = 0
                    mstatus_r[12:11] <= priv_r;               // MPP
                    priv_r           <= PRIV_M;
                end
            end else if (mret_valid) begin
                mstatus_r[3]     <= mstatus_r[7];             // MIE = MPIE
                mstatus_r[7]     <= 1'b1;                     // MPIE = 1
                priv_r           <= mstatus_r[12:11];
                if (mstatus_r[12:11] != PRIV_M)
                    mstatus_r[17] <= 1'b0;                    // clear MPRV
                mstatus_r[12:11] <= PRIV_U;                   // MPP = U
            end else if (sret_valid) begin
                mstatus_r[1]  <= mstatus_r[5];                // SIE = SPIE
                mstatus_r[5]  <= 1'b1;                        // SPIE = 1
                priv_r        <= mstatus_r[8] ? PRIV_S : PRIV_U;
                mstatus_r[17] <= 1'b0;                        // clear MPRV
                mstatus_r[8]  <= 1'b0;                        // SPP = U
            end else begin
                if (fp_state_dirty_i)
                    mstatus_r[14:13] <= 2'b11;
                if (fflags_acc_valid_i)
                    fflags_r <= fflags_r | fflags_acc_bits_i;
                if (write_valid) begin
                    case (write_addr)
                    CSR_FFLAGS: begin
                        fflags_r        <= csr_op_fflags[4:0];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_FRM: begin
                        frm_r           <= csr_op_frm[2:0];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_FCSR: begin
                        // no local variable: compute inline
                        fflags_r        <= csr_op_fcsr[4:0];
                        frm_r           <= csr_op_fcsr[7:5];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_SSTATUS:
                        mstatus_r <= sstatus_applied_norm;
                    CSR_SIE:
                        mie_r <= (mie_r & ~mideleg_r) |
                                 (((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mie_r) | (write_data)) : (write_op == 2'd2) ? ((mie_r) & ~(write_data)) : (mie_r)) & mideleg_r);
                    CSR_STVEC:       stvec_r      <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((stvec_r) | (write_data)) : (write_op == 2'd2) ? ((stvec_r) & ~(write_data)) : (stvec_r));
                    CSR_SCOUNTEREN:  scounteren_r <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((scounteren_r) | (write_data)) : (write_op == 2'd2) ? ((scounteren_r) & ~(write_data)) : (scounteren_r));
                    CSR_SENVCFG:     senvcfg_r    <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((senvcfg_r) | (write_data)) : (write_op == 2'd2) ? ((senvcfg_r) & ~(write_data)) : (senvcfg_r));
                    CSR_SSCRATCH:    sscratch_r   <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((sscratch_r) | (write_data)) : (write_op == 2'd2) ? ((sscratch_r) & ~(write_data)) : (sscratch_r));
                    CSR_SEPC:        sepc_r       <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((sepc_r) | (write_data)) : (write_op == 2'd2) ? ((sepc_r) & ~(write_data)) : (sepc_r));
                    CSR_SCAUSE:      scause_r     <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((scause_r) | (write_data)) : (write_op == 2'd2) ? ((scause_r) & ~(write_data)) : (scause_r));
                    CSR_STVAL:       stval_r      <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((stval_r) | (write_data)) : (write_op == 2'd2) ? ((stval_r) & ~(write_data)) : (stval_r));
                    CSR_SIP:
                        mip_r <= (mip_r & ~mideleg_r) |
                                 (((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mip_r) | (write_data)) : (write_op == 2'd2) ? ((mip_r) & ~(write_data)) : (mip_r)) & mideleg_r);
                    CSR_SATP: begin
                        // Accept Bare (0), Sv39 (8), Sv48 (9)
                        if (csr_op_satp_legal)
                            satp_r <= csr_op_satp;
                    end
                    CSR_MSTATUS:
                        mstatus_r <= mstatus_norm_bypass;
                    CSR_MEDELEG:     medeleg_r    <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((medeleg_r) | (write_data)) : (write_op == 2'd2) ? ((medeleg_r) & ~(write_data)) : (medeleg_r));
                    CSR_MIDELEG:     mideleg_r    <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mideleg_r) | (write_data)) : (write_op == 2'd2) ? ((mideleg_r) & ~(write_data)) : (mideleg_r));
                    CSR_MIE:         mie_r        <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mie_r) | (write_data)) : (write_op == 2'd2) ? ((mie_r) & ~(write_data)) : (mie_r));
                    CSR_MTVEC:       mtvec_r      <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mtvec_r) | (write_data)) : (write_op == 2'd2) ? ((mtvec_r) & ~(write_data)) : (mtvec_r));
                    CSR_MCOUNTEREN:  mcounteren_r <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcounteren_r) | (write_data)) : (write_op == 2'd2) ? ((mcounteren_r) & ~(write_data)) : (mcounteren_r));
                    CSR_MCOUNTINHIBIT:
                        mcountinhibit_r <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcountinhibit_r) | (write_data)) : (write_op == 2'd2) ? ((mcountinhibit_r) & ~(write_data)) : (mcountinhibit_r));
                    CSR_MSCRATCH:    mscratch_r   <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mscratch_r) | (write_data)) : (write_op == 2'd2) ? ((mscratch_r) & ~(write_data)) : (mscratch_r));
                    CSR_MEPC:        mepc_r       <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mepc_r) | (write_data)) : (write_op == 2'd2) ? ((mepc_r) & ~(write_data)) : (mepc_r));
                    CSR_MCAUSE:      mcause_r     <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcause_r) | (write_data)) : (write_op == 2'd2) ? ((mcause_r) & ~(write_data)) : (mcause_r));
                    CSR_MTVAL:       mtval_r      <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mtval_r) | (write_data)) : (write_op == 2'd2) ? ((mtval_r) & ~(write_data)) : (mtval_r));
                    CSR_MIP:         mip_r        <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mip_r) | (write_data)) : (write_op == 2'd2) ? ((mip_r) & ~(write_data)) : (mip_r));
                    CSR_PMPCFG0:     pmpcfg0_r    <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((pmpcfg0_r) | (write_data)) : (write_op == 2'd2) ? ((pmpcfg0_r) & ~(write_data)) : (pmpcfg0_r));
                    CSR_PMPADDR0:    pmpaddr0_r   <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((pmpaddr0_r) | (write_data)) : (write_op == 2'd2) ? ((pmpaddr0_r) & ~(write_data)) : (pmpaddr0_r));
                    CSR_TCONTROL:    tcontrol_r   <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((tcontrol_r) | (write_data)) : (write_op == 2'd2) ? ((tcontrol_r) & ~(write_data)) : (tcontrol_r));
                    CSR_MCYCLE,
                    CSR_CYCLE:       mcycle_r     <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((mcycle_r) | (write_data)) : (write_op == 2'd2) ? ((mcycle_r) & ~(write_data)) : (mcycle_r));
                    CSR_MINSTRET,
                    CSR_INSTRET:     minstret_r   <= ((write_op == 2'd0) ? (write_data) : (write_op == 2'd1) ? ((minstret_r) | (write_data)) : (write_op == 2'd2) ? ((minstret_r) & ~(write_data)) : (minstret_r));
                    // read-only: misa, mhartid, mvendorid, marchid, mimpid
                    default: ;
                    endcase
                end
            end
        end
    end

endmodule

`endif  // CSR_FILE_SV
