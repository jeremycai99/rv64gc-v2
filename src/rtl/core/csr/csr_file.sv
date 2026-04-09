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
    output logic [63:0] read_data,

    // CSR write (from commit — serialized, at most 1/cycle)
    input  logic        write_valid,
    input  logic [11:0] write_addr,
    input  logic [63:0] write_data,
    input  logic [1:0]  write_op,       // csr_op_e: 0=RW, 1=RS, 2=RC

    // Trap interface (from commit)
    input  logic        trap_valid,
    input  logic [63:0] trap_cause,
    input  logic [63:0] trap_pc,        // PC of faulting/interrupting instruction
    input  logic [63:0] trap_val,       // mtval/stval value
    input  logic        trap_is_interrupt,

    // Return from trap
    input  logic        mret_valid,
    input  logic        sret_valid,

    // Outputs for pipeline use
    output logic [63:0] mtvec,
    output logic [63:0] stvec,
    output logic [63:0] mepc,
    output logic [63:0] sepc,
    output logic [1:0]  priv_mode,

    // Interrupt outputs
    output logic        irq_pending,
    output logic [63:0] irq_cause,

    // Performance counters
    input  logic [2:0]  insn_retired_count,  // from commit
    output logic [63:0] mcycle_val,
    output logic [63:0] minstret_val,

    // Timer (from external CLINT)
    input  logic [63:0] time_val,

    // External interrupts
    input  logic        mtip, msip, meip,
    input  logic        stip, ssip, seip,

    // SATP (for MMU)
    output logic [63:0] satp
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

    // misa: RV64IMAFDC + S + U
    localparam logic [63:0] MISA_VAL =
        (64'h2 << 62)  |   // MXL = 2 (RV64)
        (64'h1 << 0)   |   // A – Atomics
        (64'h1 << 3)   |   // D – Double FP
        (64'h1 << 5)   |   // F – Single FP
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
    assign satp        = satp_r;
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
        irq_pending = 1'b0;
        irq_cause   = 64'd0;

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
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_EXT};
            end else if (!mideleg_r[IRQ_S_EXT] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_EXT};
            end
        end else if (mip_eff[IRQ_S_SOFT] && mie_r[IRQ_S_SOFT]) begin
            if (mideleg_r[IRQ_S_SOFT] && (priv_r != PRIV_M) &&
                ((priv_r == PRIV_U) || mstatus_r[1])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_SOFT};
            end else if (!mideleg_r[IRQ_S_SOFT] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_SOFT};
            end
        end else if (mip_eff[IRQ_S_TIMER] && mie_r[IRQ_S_TIMER]) begin
            if (mideleg_r[IRQ_S_TIMER] && (priv_r != PRIV_M) &&
                ((priv_r == PRIV_U) || mstatus_r[1])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_TIMER};
            end else if (!mideleg_r[IRQ_S_TIMER] &&
                         ((priv_r != PRIV_M) || mstatus_r[3])) begin
                irq_pending = 1'b1;
                irq_cause   = 64'h8000_0000_0000_0000 | {58'd0, IRQ_S_TIMER};
            end
        end
    end

    // =========================================================================
    // Helper functions (module-scope)
    // =========================================================================

    // Apply CSR write operation: RW / RS / RC
    function automatic logic [63:0] apply_op(
        input logic [63:0] cur,
        input logic [63:0] wdata,
        input logic [1:0]  op
    );
        case (op)
            2'd0:    return wdata;
            2'd1:    return cur | wdata;
            2'd2:    return cur & ~wdata;
            default: return cur;
        endcase
    endfunction

    // Normalise mstatus: force SXL/UXL=2 (RV64) and compute SD
    function automatic logic [63:0] norm_mstatus(input logic [63:0] ms);
        logic [63:0] n;
        n        = ms;
        n[35:34] = 2'b10;
        n[33:32] = 2'b10;
        n[63]    = (n[14:13] == 2'b11) || (n[16:15] == 2'b11);
        return n;
    endfunction

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

    assign csr_bypass = write_valid && !trap_valid && !mret_valid && !sret_valid &&
                        (write_addr == read_addr);

    assign mstatus_wdata_op      = apply_op(mstatus_r, write_data, write_op);
    assign mstatus_norm          = norm_mstatus(mstatus_r);
    assign mstatus_norm_bypass   = norm_mstatus(mstatus_wdata_op);

    // sstatus: apply write only to writable S-visible bits
    assign ss_wdata_op           = apply_op(mstatus_r & SSTATUS_WMASK,
                                            write_data & SSTATUS_WMASK,
                                            write_op);
    assign sstatus_applied       = (mstatus_r & ~SSTATUS_WMASK) |
                                   (ss_wdata_op & SSTATUS_WMASK);
    assign sstatus_applied_norm  = norm_mstatus(sstatus_applied);
    assign sstatus_view          = mstatus_norm        & SSTATUS_MASK;
    assign sstatus_view_bypass   = sstatus_applied_norm & SSTATUS_MASK;

    // =========================================================================
    // Combinational read port (with same-cycle bypass)
    // =========================================================================
    always_comb begin
        case (read_addr)
            CSR_FFLAGS:    read_data = csr_bypass ?
                               {59'd0, apply_op({59'd0,fflags_r}, write_data, write_op)[4:0]}
                             : {59'd0, fflags_r};
            CSR_FRM:       read_data = csr_bypass ?
                               {61'd0, apply_op({61'd0,frm_r}, write_data, write_op)[2:0]}
                             : {61'd0, frm_r};
            CSR_FCSR:      read_data = csr_bypass ?
                               {56'd0, apply_op({56'd0,frm_r,fflags_r}, write_data, write_op)[7:0]}
                             : {56'd0, frm_r, fflags_r};

            CSR_SSTATUS:   read_data = csr_bypass ? sstatus_view_bypass : sstatus_view;
            CSR_SIE:       read_data = csr_bypass ?
                               (apply_op(mie_r, write_data, write_op) & mideleg_r)
                             : (mie_r & mideleg_r);
            CSR_STVEC:     read_data = csr_bypass ? apply_op(stvec_r, write_data, write_op) : stvec_r;
            CSR_SCOUNTEREN:read_data = csr_bypass ? apply_op(scounteren_r, write_data, write_op) : scounteren_r;
            CSR_SENVCFG:   read_data = csr_bypass ? apply_op(senvcfg_r, write_data, write_op) : senvcfg_r;
            CSR_SSCRATCH:  read_data = csr_bypass ? apply_op(sscratch_r, write_data, write_op) : sscratch_r;
            CSR_SEPC:      read_data = csr_bypass ? apply_op(sepc_r, write_data, write_op) : sepc_r;
            CSR_SCAUSE:    read_data = csr_bypass ? apply_op(scause_r, write_data, write_op) : scause_r;
            CSR_STVAL:     read_data = csr_bypass ? apply_op(stval_r, write_data, write_op) : stval_r;
            CSR_SIP:       read_data = csr_bypass ?
                               (apply_op(mip_eff, write_data, write_op) & mideleg_r)
                             : (mip_eff & mideleg_r);
            CSR_SATP:      read_data = csr_bypass ? apply_op(satp_r, write_data, write_op) : satp_r;

            CSR_MSTATUS:   read_data = csr_bypass ? mstatus_norm_bypass : mstatus_norm;
            CSR_MISA:      read_data = MISA_VAL;
            CSR_MEDELEG:   read_data = csr_bypass ? apply_op(medeleg_r, write_data, write_op) : medeleg_r;
            CSR_MIDELEG:   read_data = csr_bypass ? apply_op(mideleg_r, write_data, write_op) : mideleg_r;
            CSR_MIE:       read_data = csr_bypass ? apply_op(mie_r, write_data, write_op) : mie_r;
            CSR_MTVEC:     read_data = csr_bypass ? apply_op(mtvec_r, write_data, write_op) : mtvec_r;
            CSR_MCOUNTEREN:read_data = csr_bypass ? apply_op(mcounteren_r, write_data, write_op) : mcounteren_r;
            CSR_MCOUNTINHIBIT: read_data = csr_bypass ?
                               apply_op(mcountinhibit_r, write_data, write_op) : mcountinhibit_r;
            CSR_MSCRATCH:  read_data = csr_bypass ? apply_op(mscratch_r, write_data, write_op) : mscratch_r;
            CSR_MEPC:      read_data = csr_bypass ? apply_op(mepc_r, write_data, write_op) : mepc_r;
            CSR_MCAUSE:    read_data = csr_bypass ? apply_op(mcause_r, write_data, write_op) : mcause_r;
            CSR_MTVAL:     read_data = csr_bypass ? apply_op(mtval_r, write_data, write_op) : mtval_r;
            CSR_MIP:       read_data = csr_bypass ? apply_op(mip_eff, write_data, write_op) : mip_eff;
            CSR_PMPCFG0:   read_data = csr_bypass ? apply_op(pmpcfg0_r, write_data, write_op) : pmpcfg0_r;
            CSR_PMPADDR0:  read_data = csr_bypass ? apply_op(pmpaddr0_r, write_data, write_op) : pmpaddr0_r;
            CSR_TSELECT:   read_data = 64'd0;
            CSR_TDATA1:    read_data = 64'd0;
            CSR_TDATA2:    read_data = 64'd0;
            CSR_TCONTROL:  read_data = csr_bypass ? apply_op(tcontrol_r, write_data, write_op) : tcontrol_r;
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
    // Trap delegation: to S-mode or M-mode?
    // =========================================================================
    logic trap_to_s;
    always_comb begin
        if (trap_is_interrupt)
            trap_to_s = mideleg_r[{1'b0, trap_cause[4:0]}] &&
                        (priv_r != PRIV_M) &&
                        ((priv_r == PRIV_U) || mstatus_r[1]);
        else
            trap_to_s = medeleg_r[{2'b00, trap_cause[3:0]}] &&
                        (priv_r != PRIV_M);
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
                minstret_r <= minstret_r + {61'd0, insn_retired_count};

            // Priority: trap > mret/sret > csr-write
            if (trap_valid) begin
                if (trap_to_s) begin
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
            end else if (write_valid) begin
                case (write_addr)
                    CSR_FFLAGS: begin
                        fflags_r        <= apply_op({59'd0,fflags_r}, write_data, write_op)[4:0];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_FRM: begin
                        frm_r           <= apply_op({61'd0,frm_r}, write_data, write_op)[2:0];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_FCSR: begin
                        // no local variable: compute inline
                        fflags_r        <= apply_op({56'd0,frm_r,fflags_r}, write_data, write_op)[4:0];
                        frm_r           <= apply_op({56'd0,frm_r,fflags_r}, write_data, write_op)[7:5];
                        mstatus_r[14:13]<= 2'b11;
                    end
                    CSR_SSTATUS:
                        mstatus_r <= norm_mstatus(
                                        (mstatus_r & ~SSTATUS_WMASK) |
                                        (apply_op(mstatus_r & SSTATUS_WMASK,
                                                  write_data & SSTATUS_WMASK,
                                                  write_op) & SSTATUS_WMASK));
                    CSR_SIE:
                        mie_r <= (mie_r & ~mideleg_r) |
                                 (apply_op(mie_r, write_data, write_op) & mideleg_r);
                    CSR_STVEC:       stvec_r      <= apply_op(stvec_r,      write_data, write_op);
                    CSR_SCOUNTEREN:  scounteren_r <= apply_op(scounteren_r, write_data, write_op);
                    CSR_SENVCFG:     senvcfg_r    <= apply_op(senvcfg_r,    write_data, write_op);
                    CSR_SSCRATCH:    sscratch_r   <= apply_op(sscratch_r,   write_data, write_op);
                    CSR_SEPC:        sepc_r       <= apply_op(sepc_r,       write_data, write_op);
                    CSR_SCAUSE:      scause_r     <= apply_op(scause_r,     write_data, write_op);
                    CSR_STVAL:       stval_r      <= apply_op(stval_r,      write_data, write_op);
                    CSR_SIP:
                        mip_r <= (mip_r & ~mideleg_r) |
                                 (apply_op(mip_r, write_data, write_op) & mideleg_r);
                    CSR_SATP: begin
                        // Accept Bare (0), Sv39 (8), Sv48 (9)
                        if (apply_op(satp_r, write_data, write_op)[63:60] == 4'd0 ||
                            apply_op(satp_r, write_data, write_op)[63:60] == 4'd8 ||
                            apply_op(satp_r, write_data, write_op)[63:60] == 4'd9)
                            satp_r <= apply_op(satp_r, write_data, write_op);
                    end
                    CSR_MSTATUS:
                        mstatus_r <= norm_mstatus(apply_op(mstatus_r, write_data, write_op));
                    CSR_MEDELEG:     medeleg_r    <= apply_op(medeleg_r,    write_data, write_op);
                    CSR_MIDELEG:     mideleg_r    <= apply_op(mideleg_r,    write_data, write_op);
                    CSR_MIE:         mie_r        <= apply_op(mie_r,        write_data, write_op);
                    CSR_MTVEC:       mtvec_r      <= apply_op(mtvec_r,      write_data, write_op);
                    CSR_MCOUNTEREN:  mcounteren_r <= apply_op(mcounteren_r, write_data, write_op);
                    CSR_MCOUNTINHIBIT:
                        mcountinhibit_r <= apply_op(mcountinhibit_r, write_data, write_op);
                    CSR_MSCRATCH:    mscratch_r   <= apply_op(mscratch_r,   write_data, write_op);
                    CSR_MEPC:        mepc_r       <= apply_op(mepc_r,       write_data, write_op);
                    CSR_MCAUSE:      mcause_r     <= apply_op(mcause_r,     write_data, write_op);
                    CSR_MTVAL:       mtval_r      <= apply_op(mtval_r,      write_data, write_op);
                    CSR_MIP:         mip_r        <= apply_op(mip_r,        write_data, write_op);
                    CSR_PMPCFG0:     pmpcfg0_r    <= apply_op(pmpcfg0_r,   write_data, write_op);
                    CSR_PMPADDR0:    pmpaddr0_r   <= apply_op(pmpaddr0_r,  write_data, write_op);
                    CSR_TCONTROL:    tcontrol_r   <= apply_op(tcontrol_r,   write_data, write_op);
                    CSR_MCYCLE,
                    CSR_CYCLE:       mcycle_r     <= apply_op(mcycle_r,    write_data, write_op);
                    CSR_MINSTRET,
                    CSR_INSTRET:     minstret_r   <= apply_op(minstret_r,  write_data, write_op);
                    // read-only: misa, mhartid, mvendorid, marchid, mimpid
                    default: ;
                endcase
            end
        end
    end

endmodule

`endif  // CSR_FILE_SV
