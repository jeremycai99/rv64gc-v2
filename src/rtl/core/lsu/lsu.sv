/* file: lsu.sv
 Description: Load-store unit with 2-load 1-store ports and forwarding.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
`ifndef LSU_SV
`define LSU_SV

module lsu
    import rv64gc_pkg::*;
    import isa_pkg::*;
    import uarch_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // Issue inputs (from issue queues)
    input logic [1:0] load_issue_candidate_valid,
    input logic [1:0] load_issue_valid,
    input iq_entry_t load_issue_data [0:1],
    input logic sta_issue_candidate_valid,
    input logic sta_issue_valid,
    input iq_entry_t sta_issue_data,
    input logic std_issue_valid,
    input iq_entry_t std_issue_data,

    // PRF read data (from regfile)
    input logic [63:0] load_rs1 [0:1],
    input logic [63:0] load_rs2 [0:1],
    input logic [63:0] sta_rs1,
    input logic [63:0] std_rs2,

    // Writeback to CDB (load results)
    output logic [1:0] load_wb_valid,
    output logic [ROB_IDX_BITS-1:0] load_wb_rob_idx [0:1],
    output logic [PHYS_REG_BITS-1:0] load_wb_pdst [0:1],
    output logic [63:0] load_wb_data [0:1],
    output mem_size_e load_wb_mem_size [0:1],
    output logic [1:0] load_wb_has_exception,
    output logic [3:0] load_wb_exc_code [0:1],

    // STA writeback (mark store ROB entry as address-computed)
    output logic sta_wb_valid,
    output logic [ROB_IDX_BITS-1:0] sta_wb_rob_idx,
    output logic std_wb_valid,
    output logic [ROB_IDX_BITS-1:0] std_wb_rob_idx,

    // Commit counts (from commit unit)
    input logic [2:0] store_commit_count,
    input logic [2:0] load_commit_count,

    // Speculative wakeup (load issues -> wake dependents)
    output logic [1:0] spec_wakeup_valid,
    output logic [PHYS_REG_BITS-1:0] spec_wakeup_tag [0:1],
    // Cancel (cache miss -> cancel speculative wakeup)
    output logic [1:0] spec_cancel_valid,
    output logic [PHYS_REG_BITS-1:0] spec_cancel_tag [0:1],

    // LQ/SQ allocation (from rename)
    input logic [2:0] lq_alloc_count,
    input logic [2:0] sq_alloc_count,
    input logic [ROB_IDX_BITS-1:0] lq_alloc_rob_idx [0:PIPE_WIDTH-1],
    input logic [ROB_IDX_BITS-1:0] sq_alloc_rob_idx [0:PIPE_WIDTH-1],
    output logic [LQ_IDX_BITS-1:0] lq_alloc_idx [0:PIPE_WIDTH-1],
    output logic [SQ_IDX_BITS-1:0] sq_alloc_idx [0:PIPE_WIDTH-1],
    output logic lq_full,
    output logic sq_full,
    input logic [ROB_IDX_BITS-1:0] rob_head,

    // Ordering violation (to commit for flush)
    output logic ordering_violation,
    output logic [ROB_IDX_BITS-1:0] violation_rob_idx,
    output logic [1:0] load_issue_suppress,
    output logic sta_issue_suppress,

    // DTLB sideband. Data VM is asserted when SATP translation applies to the
    // effective data privilege mode.
    input logic data_vm_active_i,
    input logic dtlb_hit_i,
    input logic [63:0] dtlb_pa_i,
    input logic dtlb_fault_i,
    input logic [3:0] dtlb_fault_code_i,
    output logic dtlb_lookup_valid_o,
    output logic [63:0] dtlb_lookup_va_o,
    output logic dtlb_lookup_is_store_o,
    output logic dtlb_miss_valid_o,
    output logic [63:0] dtlb_miss_va_o,
    output logic [ROB_IDX_BITS-1:0] dtlb_miss_rob_idx_o,
    output logic dtlb_miss_is_store_o,
    output logic dtlb_exc_valid_o,
    output logic [63:0] dtlb_exc_va_o,
    output logic [ROB_IDX_BITS-1:0] dtlb_exc_rob_idx_o,
    output logic [3:0] dtlb_exc_code_o,

    // D-cache interface
    output logic [1:0] dcache_load_req_valid,
    output logic [63:0] dcache_load_req_addr [0:1],
    output logic [1:0] dcache_load_req_size [0:1],
    output logic [1:0] dcache_load_req_is_unsigned,
    input logic [1:0] dcache_load_resp_valid,
    input logic [63:0] dcache_load_resp_data [0:1],
    input logic [1:0] dcache_load_resp_hit,
    input logic [1:0] dcache_load_miss_retry,

    // D-cache store port (from CSB)
    output logic dcache_store_req_valid,
    output logic [63:0] dcache_store_req_addr,
    output logic [63:0] dcache_store_req_data,
    output logic [7:0] dcache_store_req_byte_mask,
    input logic dcache_store_ack,

    // L2 fill snoop (for load miss handling)
    // The LSU watches L2 → D-cache fill responses and matches them against
    // in-flight missed loads tracked in the Load Miss Buffer.  When a fill
    // arrives for a line that has a pending load, the LSU extracts the
    // requested bytes from the fill line and writes back the load result
    // via the CDB.  This is the "late response" path for missed loads.
    input logic        dcache_fill_valid,
    input logic [63:0] dcache_fill_addr,
    input logic [LINE_SIZE*8-1:0] dcache_fill_data,

    // Uncached data MMIO interface
    output logic        data_mmio_req_valid,
    output logic        data_mmio_req_we,
    output logic [63:0] data_mmio_req_addr,
    output logic [63:0] data_mmio_req_wdata,
    output logic [7:0]  data_mmio_req_wmask,
    output logic [1:0]  data_mmio_req_size,
    input  logic        data_mmio_req_ready,
    input  logic        data_mmio_resp_valid,
    input  logic [63:0] data_mmio_resp_data,
    output logic        fence_i_ready,

    // Flush
    input flush_t flush_in
);

    // Forward declarations (used by spec_wakeup before full definition)
    logic [1:0] load_issue_valid_r;
    logic [1:0] load_issue_valid_rr;
    logic [1:0] load_nocache_r;
    logic [1:0] load_nocache_rr;
    logic            p1_eff_valid;
    logic            p1_eff_misalign;
    logic [63:0]     p1_eff_addr;
    iq_entry_t       p1_eff_data;
    logic            p1_eff_nocache;
    logic            p1_eff_addr_mmio;
    logic            p0_fwd_hit;
    logic            fwd_hold_valid_r;
    logic            p1_fwd_hold_valid_r;
    logic            p0_dcache_hit_valid;
    logic            p1_normal_wb_valid;
    logic            p0_fwd_spill_to_p1;
    logic            p1_fast_fwd_fire;
    logic            fwd_hold_blocked;
    logic            lmb_wb_port_free;
    logic            mmio_resp_hold_valid_r;
    logic            mmio_load0_block;
    logic            mmio_load1_block;
    logic            mmio_store_launch;
    logic            mmio_load0_launch;
    logic            mmio_load1_launch;
    logic            mmio_load_wb_fire;
    logic            lmb_any_valid;
    logic            amo_busy;
    logic            amo_issue_fire;
    logic            amo_load_issue_fire;
    logic            amo_sc_issue_fire;
    logic            amo_load_hit_fire;
    logic            amo_load_fill_fire;
    logic            amo_store_ack_fire;
    logic            amo_serial_block;
    logic            amo_forward_block;
    logic            amo_flush_kill;
    logic            amo_wait_load_r;
    logic            amo_store_valid_r;
    logic            amo_wb_valid_r;
    iq_entry_t       amo_data_r;
    logic [63:0]     amo_addr_r;
    logic [63:0]     amo_rs2_r;
    logic [63:0]     amo_old_value_r;
    logic [63:0]     amo_store_data_r;
    logic [7:0]      amo_store_mask_r;
    logic [ROB_IDX_BITS-1:0]  amo_wb_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] amo_wb_pdst_r;
    logic [LQ_IDX_BITS-1:0]   amo_wb_lq_idx_r;
    logic [63:0]              amo_wb_data_r;

    // =========================================================================
    // Load AGU: effective address computation (x2)
    // =========================================================================
    // For fused AUIPC+LD: base address comes from the PC of the AUIPC half,
    // not from rs1 (which is x0/zero for the fused uop because the auipc has
    // no source register).  Detect this case via is_fused on a load and use
    // pc + imm.  Other fusions never produce loads.
    logic [63:0] load_eff_addr [0:1];
    logic [63:0] load_mem_addr [0:1];
    logic [1:0]  load_addr_natural_misaligned;
    logic [1:0]  load_addr_misaligned;
    logic [1:0]  load_cross_line;
    logic [3:0]  load_size_bytes [0:1];
    logic [1:0]  load_addr_mmio;

    genvar li;
    generate
        for (li = 0; li < 2; li++) begin : gen_load_agu
            wire is_pc_rel_ld = load_issue_data[li].is_fused;
            assign load_eff_addr[li] =
                (is_pc_rel_ld ? load_issue_data[li].pc : load_rs1[li])
                + load_issue_data[li].imm;

            // Natural alignment check based on access size.  Ordinary cached
            // integer loads are allowed to complete through the cache line
            // byte extraction path; AMOs still require natural alignment.
            logic [2:0] ld_off;
            assign ld_off = load_eff_addr[li][2:0];

            always_comb begin
                load_size_bytes[li] = 4'd1;
                case (load_issue_data[li].mem_size)
                    MEM_HALF: begin
                        load_size_bytes[li] = 4'd2;
                        load_addr_natural_misaligned[li] = ld_off[0];
                    end
                    MEM_WORD: begin
                        load_size_bytes[li] = 4'd4;
                        load_addr_natural_misaligned[li] = |ld_off[1:0];
                    end
                    MEM_DWORD: begin
                        load_size_bytes[li] = 4'd8;
                        load_addr_natural_misaligned[li] = |ld_off[2:0];
                    end
                    default: begin
                        load_size_bytes[li] = 4'd1;
                        load_addr_natural_misaligned[li] = 1'b0;
                    end
                endcase
                load_cross_line[li] =
                    ({1'b0, load_eff_addr[li][5:0]} +
                     {3'b000, load_size_bytes[li]}) > 7'd64;
            end

            assign load_addr_misaligned[li] =
                load_addr_natural_misaligned[li] &&
                load_issue_data[li].is_amo;

        end
    endgenerate

    // =========================================================================
    // Store AGU: effective address computation (x1)
    // =========================================================================
    // For fused AUIPC+ST: same logic as fused loads — use pc instead of rs1
    // because the store's base register comes from the auipc half.
    logic [63:0] sta_eff_addr;
    logic [63:0] sta_mem_addr;
    logic        sta_addr_natural_misaligned;
    logic        sta_addr_misaligned;
    logic        sta_addr_mmio;
    logic [2:0]  sta_off;

    wire sta_is_pc_rel = sta_issue_data.is_fused;
    assign sta_eff_addr = (sta_is_pc_rel ? sta_issue_data.pc : sta_rs1)
                        + sta_issue_data.imm;
    assign sta_off = sta_eff_addr[2:0];

    always_comb begin
        case (sta_issue_data.mem_size)
            MEM_HALF:  sta_addr_natural_misaligned = sta_off[0];
            MEM_WORD:  sta_addr_natural_misaligned = |sta_off[1:0];
            MEM_DWORD: sta_addr_natural_misaligned = |sta_off[2:0];
            default:   sta_addr_natural_misaligned = 1'b0;
        endcase
    end

    // Store AMOs are issued through the load/AMO path.  Normal stores can be
    // byte merged into the cache line at arbitrary byte offsets.
    assign sta_addr_misaligned = 1'b0;

    // =========================================================================
    // DTLB lookup scaffold
    // =========================================================================
    logic dtlb_lookup_sel_store;
    logic dtlb_lookup_sel_load0;
    logic dtlb_lookup_miss;
    logic dtlb_lookup_fault;
    logic sta_tlb_port_wait;
    logic sta_tlb_miss;
    logic sta_tlb_fault;
    logic load0_tlb_port_wait;
    logic load0_tlb_miss;
    logic load0_tlb_fault;
    logic load1_tlb_wait;
    logic [ROB_IDX_BITS-1:0] dtlb_lookup_rob_idx;
    logic [ROB_IDX_BITS:0]   dtlb_sta_age;
    logic [ROB_IDX_BITS:0]   dtlb_load0_age;
    logic                    dtlb_store_older_than_load0;

    always_comb begin
        if (sta_issue_data.rob_idx >= rob_head) begin
            dtlb_sta_age =
                {1'b0, sta_issue_data.rob_idx} - {1'b0, rob_head};
        end else begin
            dtlb_sta_age =
                (ROB_IDX_BITS+1)'(ROB_DEPTH) -
                {1'b0, rob_head} +
                {1'b0, sta_issue_data.rob_idx};
        end

        if (load_issue_data[0].rob_idx >= rob_head) begin
            dtlb_load0_age =
                {1'b0, load_issue_data[0].rob_idx} - {1'b0, rob_head};
        end else begin
            dtlb_load0_age =
                (ROB_IDX_BITS+1)'(ROB_DEPTH) -
                {1'b0, rob_head} +
                {1'b0, load_issue_data[0].rob_idx};
        end
    end

    assign dtlb_store_older_than_load0 =
        sta_issue_candidate_valid &&
        load_issue_candidate_valid[0] &&
        (dtlb_sta_age < dtlb_load0_age);

    assign dtlb_lookup_sel_store =
        sta_issue_candidate_valid &&
        !sta_addr_misaligned &&
        !flush_in.valid &&
        (!load_issue_candidate_valid[0] ||
         load_addr_misaligned[0] ||
         dtlb_store_older_than_load0);
    assign dtlb_lookup_sel_load0 =
        !dtlb_lookup_sel_store &&
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        !flush_in.valid;
    assign dtlb_lookup_valid_o =
        data_vm_active_i &&
        (dtlb_lookup_sel_store || dtlb_lookup_sel_load0);
    assign dtlb_lookup_va_o =
        dtlb_lookup_sel_store ? sta_eff_addr : load_eff_addr[0];
    assign dtlb_lookup_is_store_o = dtlb_lookup_sel_store;
    assign dtlb_lookup_rob_idx =
        dtlb_lookup_sel_store ? sta_issue_data.rob_idx : load_issue_data[0].rob_idx;
    assign dtlb_lookup_miss =
        dtlb_lookup_valid_o && !dtlb_hit_i && !dtlb_fault_i;
    assign dtlb_lookup_fault =
        dtlb_lookup_valid_o && dtlb_fault_i;
    assign sta_tlb_port_wait =
        data_vm_active_i &&
        sta_issue_candidate_valid &&
        !sta_addr_misaligned &&
        !flush_in.valid &&
        !dtlb_lookup_sel_store;
    assign sta_tlb_miss =
        data_vm_active_i &&
        dtlb_lookup_sel_store &&
        !dtlb_hit_i &&
        !dtlb_fault_i;
    assign sta_tlb_fault =
        data_vm_active_i &&
        dtlb_lookup_sel_store &&
        dtlb_fault_i;
    assign load0_tlb_port_wait =
        data_vm_active_i &&
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        !flush_in.valid &&
        !dtlb_lookup_sel_load0;
    assign load0_tlb_miss =
        data_vm_active_i &&
        dtlb_lookup_sel_load0 &&
        !dtlb_hit_i &&
        !dtlb_fault_i;
    assign load0_tlb_fault =
        data_vm_active_i &&
        dtlb_lookup_sel_load0 &&
        dtlb_fault_i;
    assign load1_tlb_wait =
        data_vm_active_i &&
        load_issue_candidate_valid[1] &&
        !load_addr_misaligned[1] &&
        !flush_in.valid;
    assign dtlb_miss_valid_o = dtlb_lookup_miss;
    assign dtlb_miss_va_o = dtlb_lookup_va_o;
    assign dtlb_miss_rob_idx_o = dtlb_lookup_rob_idx;
    assign dtlb_miss_is_store_o = dtlb_lookup_is_store_o;
    assign dtlb_exc_valid_o = dtlb_lookup_fault;
    assign dtlb_exc_va_o = dtlb_lookup_va_o;
    assign dtlb_exc_rob_idx_o = dtlb_lookup_rob_idx;
    assign dtlb_exc_code_o = dtlb_fault_code_i;
    assign sta_issue_suppress =
        sta_tlb_port_wait || sta_tlb_miss || sta_tlb_fault;

    assign sta_mem_addr =
        (data_vm_active_i && dtlb_lookup_sel_store && dtlb_hit_i && !dtlb_fault_i)
            ? dtlb_pa_i
            : sta_eff_addr;
    assign load_mem_addr[0] =
        (data_vm_active_i && dtlb_lookup_sel_load0 && dtlb_hit_i && !dtlb_fault_i)
            ? dtlb_pa_i
            : load_eff_addr[0];
    assign load_mem_addr[1] = load_eff_addr[1];

    assign sta_addr_mmio =
        ((sta_mem_addr >= CLINT_BASE) &&
         (sta_mem_addr < (CLINT_BASE + CLINT_SIZE))) ||
        ((sta_mem_addr >= PLIC_BASE) &&
         (sta_mem_addr < (PLIC_BASE + PLIC_SIZE))) ||
        ((sta_mem_addr >= UART_BASE) &&
         (sta_mem_addr < (UART_BASE + UART_SIZE)));

    assign load_addr_mmio[0] =
        ((load_mem_addr[0] >= CLINT_BASE) &&
         (load_mem_addr[0] < (CLINT_BASE + CLINT_SIZE))) ||
        ((load_mem_addr[0] >= PLIC_BASE) &&
         (load_mem_addr[0] < (PLIC_BASE + PLIC_SIZE))) ||
        ((load_mem_addr[0] >= UART_BASE) &&
         (load_mem_addr[0] < (UART_BASE + UART_SIZE)));
    assign load_addr_mmio[1] =
        ((load_mem_addr[1] >= CLINT_BASE) &&
         (load_mem_addr[1] < (CLINT_BASE + CLINT_SIZE))) ||
        ((load_mem_addr[1] >= PLIC_BASE) &&
         (load_mem_addr[1] < (PLIC_BASE + PLIC_SIZE))) ||
        ((load_mem_addr[1] >= UART_BASE) &&
         (load_mem_addr[1] < (UART_BASE + UART_SIZE)));

    // =========================================================================
    // Store data: byte mask generation
    // =========================================================================
    logic [7:0] std_byte_mask;

    always_comb begin
        case (std_issue_data.mem_size)
            MEM_BYTE:  std_byte_mask = 8'h01;
            MEM_HALF:  std_byte_mask = 8'h03;
            MEM_WORD:  std_byte_mask = 8'h0F;
            MEM_DWORD: std_byte_mask = 8'hFF;
            default:   std_byte_mask = 8'h01;
        endcase
    end

    // =========================================================================
    // STA writeback to ROB (mark address computed)
    //
    // Bug fix: do NOT gate with ~flush_in.valid.
    //
    // On a branch mispredict, the flush fires the same cycle as the STA may
    // issue.  If the store is OLDER than the mispredicting branch, it must
    // survive the flush — the SQ's own flush logic will distinguish which
    // entries to discard by ROB age.  Silently dropping the STA causes the
    // older store to be lost: its SQ entry never gets addr_valid, its ROB
    // entry never gets ready (because sta_wb_valid never fires), and
    // commit permanently stalls.
    assign sta_wb_valid   = sta_issue_valid;
    assign sta_wb_rob_idx = sta_issue_data.rob_idx;
    assign std_wb_valid   = std_issue_valid;
    assign std_wb_rob_idx = std_issue_data.rob_idx;

    // =========================================================================
    // Speculative wakeup: actual D-cache request issue -> wake dependents
    //
    // With one-cycle D-cache hits:
    //   - T+0: load request enters D-cache, spec_wakeup pulses.
    //   - T+1: IQ has latched the wakeup.  If the load hit, its data is on
    //          the combinational load CDB/bypass and the dependent can issue.
    //   - T+1: if the load missed, spec_cancel clears the speculative ready
    //          before eligibility, so the dependent does not issue.
    //
    // The assignments live with D-cache request generation below, after SQ
    // forwarding, retry, and conflict logic decide which requests really fire.
    // =========================================================================

    // =========================================================================
    // Store-to-load forwarding wires (SQ and CSB)
    // =========================================================================
    // Port 0 forwards from same-cycle STA/STD, SQ, and CSB.
    // Port 1 probes SQ and CSB as well. A committed store can leave the SQ
    // before it reaches D-cache; younger loads on either port must still see it.
    logic        sq_fwd_hit;
    logic        sq_fwd_partial;
    logic        sq_fwd_wait;
    logic        sq_fwd_wait_addr_unknown;
    logic        sq_fwd_wait_data_missing;
    logic [63:0] sq_fwd_data;
    logic        sq_wait_p1;
    logic        sq_wait_p1_addr_unknown;
    logic        sq_wait_p1_data_missing;
    logic        sq_fwd_hit_p1;
    logic        sq_fwd_partial_p1;
    logic [63:0] sq_fwd_data_p1;
    logic        p1_wait_req_valid;
    logic [63:0] p1_wait_req_addr;
    logic [1:0]  p1_wait_req_size;
    logic [ROB_IDX_BITS-1:0] p1_wait_req_rob_idx;

    logic        csb_fwd_hit;
    logic        csb_fwd_partial;
    logic [63:0] csb_fwd_data;
    logic        csb_fwd_hit_p1;
    logic        csb_fwd_partial_p1;
    logic [63:0] csb_fwd_data_p1;
    logic        csb_enq_fwd_hit;
    logic [63:0] csb_enq_fwd_data;
    logic        csb_enq_fwd_hit_p1;
    logic [63:0] csb_enq_fwd_data_p1;
    logic        csb_enq_fwd_partial;
    logic        csb_enq_fwd_partial_p1;
    logic [7:0]  csb_enq_fwd_bmask;
    logic [7:0]  csb_enq_fwd_req1_bmask;
    logic [7:0]  csb_enq_fwd_overlap0;
    logic [7:0]  csb_enq_fwd_overlap1;
    logic        csb_enq_cross_dword;
    logic [3:0]  csb_enq_size_bytes;
    logic [3:0]  p1_wait_req_size_bytes;
    logic        p1_wait_req_cross_dword;
    logic [63:0] csb_enq_last_addr;
    logic [63:0] p1_wait_req_last_addr;
    logic        csb_enq_fwd_same_dword0;
    logic        csb_enq_fwd_same_dword1;
    logic        csb_enq_fwd_range_overlap0;
    logic        csb_enq_fwd_range_overlap1;
    logic        csb_enq_fwd_cross_block0;
    logic        csb_enq_fwd_cross_block1;
    logic        p1_any_fwd_hit;
    logic        p0_partial_fwd_wait;
    logic        p1_partial_fwd_wait;
    logic        p0_sq_order_wait_block;
    logic        p1_sq_order_wait_block;
    logic [1:0]  load_issue_spec_past_addr_unknown;

    // =========================================================================
    // Same-cycle STA/STD → load forwarding bypass
    // =========================================================================
    // When a store and a load issue on the SAME cycle and the load's address
    // matches the store's address (and the store fully covers the load's
    // byte mask), we must forward directly from the store's in-flight
    // STA/STD data — the SQ entry hasn't yet been written this cycle, so the
    // SQ CAM won't see it.  This path has HIGHER priority than the SQ CAM
    // (younger store wins over older SQ entries).
    logic        same_cycle_fwd_hit;
    logic        same_cycle_fwd_partial;
    logic [63:0] same_cycle_fwd_data;
    logic        same_cycle_sta_wait0;
    logic        same_cycle_sta_wait1;
    logic        sta_std_same_store;
    logic [7:0]  sta_byte_mask_dyn;
    logic [7:0]  load0_byte_mask_dyn;
    logic [7:0]  load1_byte_mask_dyn;
    logic        sta_cross_dword;
    logic        load0_cross_dword;
    logic        load1_cross_dword;
    logic [2:0]  sta_byte_off;
    logic [2:0]  load0_byte_off;
    logic [2:0]  load1_byte_off;
    logic [3:0]  sta_size_bytes;
    logic [3:0]  load0_size_bytes;
    logic [3:0]  load1_size_bytes;
    logic [63:0] sta_last_addr;
    logic [63:0] load0_last_addr;
    logic [63:0] load1_last_addr;
    logic [ROB_IDX_BITS:0] sta_issue_age;
    logic [ROB_IDX_BITS:0] load0_issue_age;
    logic [ROB_IDX_BITS:0] load1_issue_age;
    logic                  sta_older_than_load0;
    logic                  sta_older_than_load1;

    assign sta_byte_off   = sta_mem_addr[2:0];
    assign load0_byte_off = load_mem_addr[0][2:0];
    assign load1_byte_off = load_mem_addr[1][2:0];

    always_comb begin
        case (sta_issue_data.mem_size)
            MEM_BYTE:  sta_byte_mask_dyn = 8'h01 << sta_byte_off;
            MEM_HALF:  sta_byte_mask_dyn = 8'h03 << sta_byte_off;
            MEM_WORD:  sta_byte_mask_dyn = 8'h0F << sta_byte_off;
            MEM_DWORD: sta_byte_mask_dyn = 8'hFF;
            default:   sta_byte_mask_dyn = 8'h00;
        endcase
        case (load_issue_data[0].mem_size)
            MEM_BYTE:  load0_byte_mask_dyn = 8'h01 << load0_byte_off;
            MEM_HALF:  load0_byte_mask_dyn = 8'h03 << load0_byte_off;
            MEM_WORD:  load0_byte_mask_dyn = 8'h0F << load0_byte_off;
            MEM_DWORD: load0_byte_mask_dyn = 8'hFF;
            default:   load0_byte_mask_dyn = 8'h00;
        endcase
        case (load_issue_data[1].mem_size)
            MEM_BYTE:  load1_byte_mask_dyn = 8'h01 << load1_byte_off;
            MEM_HALF:  load1_byte_mask_dyn = 8'h03 << load1_byte_off;
            MEM_WORD:  load1_byte_mask_dyn = 8'h0F << load1_byte_off;
            MEM_DWORD: load1_byte_mask_dyn = 8'hFF;
            default:   load1_byte_mask_dyn = 8'h00;
        endcase
        case (sta_issue_data.mem_size)
            MEM_BYTE:  sta_size_bytes = 4'd1;
            MEM_HALF:  sta_size_bytes = 4'd2;
            MEM_WORD:  sta_size_bytes = 4'd4;
            MEM_DWORD: sta_size_bytes = 4'd8;
            default:   sta_size_bytes = 4'd1;
        endcase
        case (load_issue_data[0].mem_size)
            MEM_BYTE:  load0_size_bytes = 4'd1;
            MEM_HALF:  load0_size_bytes = 4'd2;
            MEM_WORD:  load0_size_bytes = 4'd4;
            MEM_DWORD: load0_size_bytes = 4'd8;
            default:   load0_size_bytes = 4'd1;
        endcase
        case (load_issue_data[1].mem_size)
            MEM_BYTE:  load1_size_bytes = 4'd1;
            MEM_HALF:  load1_size_bytes = 4'd2;
            MEM_WORD:  load1_size_bytes = 4'd4;
            MEM_DWORD: load1_size_bytes = 4'd8;
            default:   load1_size_bytes = 4'd1;
        endcase
    end

    assign sta_last_addr   = sta_mem_addr + {60'd0, sta_size_bytes} - 64'd1;
    assign load0_last_addr = load_mem_addr[0] + {60'd0, load0_size_bytes} - 64'd1;
    assign load1_last_addr = load_mem_addr[1] + {60'd0, load1_size_bytes} - 64'd1;

    always_comb begin
        case (sta_issue_data.mem_size)
            MEM_HALF:  sta_cross_dword = (sta_byte_off > 3'd6);
            MEM_WORD:  sta_cross_dword = (sta_byte_off > 3'd4);
            MEM_DWORD: sta_cross_dword = (sta_byte_off != 3'd0);
            default:   sta_cross_dword = 1'b0;
        endcase
        case (load_issue_data[0].mem_size)
            MEM_HALF:  load0_cross_dword = (load0_byte_off > 3'd6);
            MEM_WORD:  load0_cross_dword = (load0_byte_off > 3'd4);
            MEM_DWORD: load0_cross_dword = (load0_byte_off != 3'd0);
            default:   load0_cross_dword = 1'b0;
        endcase
        case (load_issue_data[1].mem_size)
            MEM_HALF:  load1_cross_dword = (load1_byte_off > 3'd6);
            MEM_WORD:  load1_cross_dword = (load1_byte_off > 3'd4);
            MEM_DWORD: load1_cross_dword = (load1_byte_off != 3'd0);
            default:   load1_cross_dword = 1'b0;
        endcase
    end

    function automatic logic [ROB_IDX_BITS:0] lsu_rob_age_from_head(
        input logic [ROB_IDX_BITS-1:0] idx
    );
        if (idx >= rob_head)
            lsu_rob_age_from_head = {1'b0, idx} - {1'b0, rob_head};
        else
            lsu_rob_age_from_head = ROB_DEPTH[ROB_IDX_BITS:0] - {1'b0, rob_head} + {1'b0, idx};
    endfunction

    assign sta_issue_age       = lsu_rob_age_from_head(sta_issue_data.rob_idx);
    assign load0_issue_age     = lsu_rob_age_from_head(load_issue_data[0].rob_idx);
    assign load1_issue_age     = lsu_rob_age_from_head(load_issue_data[1].rob_idx);
    assign sta_older_than_load0 = sta_issue_valid &&
                                  load_issue_candidate_valid[0] &&
                                  (sta_issue_age < load0_issue_age);
    assign sta_older_than_load1 = sta_issue_valid &&
                                  load_issue_candidate_valid[1] &&
                                  (sta_issue_age < load1_issue_age);
    assign sta_std_same_store   = sta_issue_valid && std_issue_valid &&
                                  (sta_issue_data.sq_idx == std_issue_data.sq_idx);

    // Same-cycle coverage check: store must be fully covering the load's
    // bytes AND address[63:3] must match (same 8-byte aligned word).
    // STA/STD issue independently, so only treat them as a forwarding pair
    // when they belong to the same SQ entry.
    logic same_cycle_addr_match0;
    logic same_cycle_addr_match1;
    logic same_cycle_range_overlap0;
    logic same_cycle_range_overlap1;
    logic [7:0] same_cycle_overlap0;
    logic [7:0] same_cycle_overlap1;
    // Suppression must be decided from the stable candidate signal.  Using
    // load_issue_valid here feeds the issue suppress decision back into the
    // issue queue select path and can form a zero-delay loop.  Actual
    // forwarding still requires load_issue_valid in same_cycle_fwd_hit below.
    assign same_cycle_addr_match0 =
        load_issue_candidate_valid[0] & sta_issue_valid &
        (sta_mem_addr[63:3] == load_mem_addr[0][63:3]);
    assign same_cycle_addr_match1 =
        load_issue_candidate_valid[1] & sta_issue_valid &
        (sta_mem_addr[63:3] == load_mem_addr[1][63:3]);
    assign same_cycle_range_overlap0 =
        load_issue_candidate_valid[0] & sta_issue_valid &
        (sta_mem_addr <= load0_last_addr) &
        (load_mem_addr[0] <= sta_last_addr);
    assign same_cycle_range_overlap1 =
        load_issue_candidate_valid[1] & sta_issue_valid &
        (sta_mem_addr <= load1_last_addr) &
        (load_mem_addr[1] <= sta_last_addr);
    assign same_cycle_overlap0 = (sta_older_than_load0 && same_cycle_addr_match0)
                               ? (sta_byte_mask_dyn & load0_byte_mask_dyn)
                               : 8'h00;
    assign same_cycle_overlap1 = (sta_older_than_load1 && same_cycle_addr_match1)
                               ? (sta_byte_mask_dyn & load1_byte_mask_dyn)
                               : 8'h00;
    assign same_cycle_fwd_hit = load_issue_valid[0] & ~load_addr_misaligned[0] &
                                ~flush_in.valid &
                                sta_older_than_load0 &
                                sta_std_same_store &
                                same_cycle_addr_match0 &
                                !(sta_cross_dword || load0_cross_dword) &
                                ((sta_byte_mask_dyn & load0_byte_mask_dyn)
                                 == load0_byte_mask_dyn);
    assign same_cycle_fwd_partial =
        load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid &
        sta_older_than_load0 &
        same_cycle_range_overlap0 &
        ~same_cycle_fwd_hit;
    assign same_cycle_sta_wait0 =
        load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid &
        sta_older_than_load0 &
        same_cycle_range_overlap0 &
        ~same_cycle_fwd_hit;
    assign same_cycle_sta_wait1 =
        load_issue_candidate_valid[1] & ~load_addr_misaligned[1] & ~flush_in.valid &
        sta_older_than_load1 &
        same_cycle_range_overlap1;

    // Build same-cycle fwd data: for each byte position `b` in the memory
    // dword that is covered by the store, take the store's byte at position
    // `b - sta_byte_off` of std_rs2 (std_rs2 is LSB-aligned to the store's
    // own address, so its byte 0 corresponds to memory byte sta_byte_off).
    always_comb begin
        same_cycle_fwd_data = '0;
        for (int b = 0; b < 8; b++) begin
            if (same_cycle_overlap0[b] && (b >= int'(sta_byte_off))) begin
                same_cycle_fwd_data[b*8 +: 8] =
                    std_rs2[(b - int'(sta_byte_off)) * 8 +: 8];
            end
        end
    end

    // =========================================================================
    // Store Queue
    // =========================================================================
    logic        sq_drain_valid;
    sq_entry_t   sq_drain_entry;
    logic        sq_drain_ready;

    store_queue u_store_queue (
        .clk             (clk),
        .rst_n           (rst_n),
        // Allocate
        .alloc_count     (sq_alloc_count),
        .alloc_rob_idx   (sq_alloc_rob_idx),
        .alloc_idx       (sq_alloc_idx),
        .full            (sq_full),
        .rob_head        (rob_head),
        // STA fill (do NOT gate with flush: older stores must survive
        // mispredict flushes; the SQ flush handler filters by ROB age).
        .sta_valid       (sta_issue_valid),
        .sta_idx         (sta_issue_data.sq_idx),
        .sta_rob_idx     (sta_issue_data.rob_idx),
        .sta_addr        (sta_mem_addr),
        .sta_size        (sta_issue_data.mem_size),
        // STD fill (same rationale: let older stores through; SQ filters)
        .std_valid       (std_issue_valid),
        .std_idx         (std_issue_data.sq_idx),
        .std_rob_idx     (std_issue_data.rob_idx),
        .std_data        (std_rs2),
        .std_byte_mask   (std_byte_mask),
        // Store-to-load forwarding (from load port 0).
        // Gate fwd_req_addr to 0 when invalid to prevent stale
        // load_eff_addr from oscillating through Verilator's eval loop.
        .fwd_req_valid   (load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid),
        .fwd_req_addr    ((load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid)
                          ? load_mem_addr[0] : 64'd0),
        .fwd_req_size    (load_issue_data[0].mem_size),
        .fwd_req_rob_idx (load_issue_data[0].rob_idx),
        .fwd_hit         (sq_fwd_hit),
        .fwd_partial     (sq_fwd_partial),
        .fwd_wait        (sq_fwd_wait),
        .fwd_wait_addr_unknown(sq_fwd_wait_addr_unknown),
        .fwd_wait_data_missing(sq_fwd_wait_data_missing),
        .fwd_data        (sq_fwd_data),
        .wait_req_valid  (p1_wait_req_valid),
        .wait_req_addr   (p1_wait_req_addr),
        .wait_req_size   (p1_wait_req_size),
        .wait_req_rob_idx(p1_wait_req_rob_idx),
        .wait_fwd_hit    (sq_fwd_hit_p1),
        .wait_partial    (sq_fwd_partial_p1),
        .wait_wait       (sq_wait_p1),
        .wait_wait_addr_unknown(sq_wait_p1_addr_unknown),
        .wait_wait_data_missing(sq_wait_p1_data_missing),
        .wait_data       (sq_fwd_data_p1),
        .wait_hit        (),
        // Commit
        .commit_count    (store_commit_count),
        // Drain to CSB
        .drain_valid     (sq_drain_valid),
        .drain_entry     (sq_drain_entry),
        .drain_ready     (sq_drain_ready),
        // Flush
        .flush_valid     (flush_in.valid),
        .flush_rob_tail  (flush_in.rob_idx),
        .flush_full      (flush_in.full_flush)
    );

    // =========================================================================
    // Load Queue
    // =========================================================================
    // Load queue exec fill: only port 0 for now (port 1 follows same pattern)
    // We record both ports but ordering violation check uses the STA port.
    // The load queue has a single exec port; we mux between the two load ports
    // using a registered round-robin or priority. For simplicity, port 0 has
    // priority; port 1 fills on the next cycle via a hold register.

    // Port 0 exec fill signals
    logic        lq_exec_valid;
    logic [LQ_IDX_BITS-1:0] lq_exec_idx;
    logic [ROB_IDX_BITS-1:0] lq_exec_rob_idx;
    logic [63:0] lq_exec_addr;
    logic [1:0]  lq_exec_size;
    logic        lq_exec_is_unsigned;
    logic        lq_exec1_valid;
    logic [LQ_IDX_BITS-1:0] lq_exec1_idx;
    logic [ROB_IDX_BITS-1:0] lq_exec1_rob_idx;
    logic [63:0] lq_exec1_addr;
    logic [1:0]  lq_exec1_size;
    logic        lq_exec1_is_unsigned;

    // Port 1 skid FIFO for deferred LQ exec fill.  The LQ has one address
    // write port; port 1 must be queued whenever port 0 or an older queued
    // port-1 entry uses that port.
    localparam int LQ_P1_HOLD_DEPTH = 4;
    localparam int LQ_P1_HOLD_PTR_BITS = $clog2(LQ_P1_HOLD_DEPTH);

    logic        lq_p1_hold_valid_r;
    logic        lq_p1_hold_full;
    logic        lq_p1_hold_pop;
    logic        lq_p1_hold_push;
    logic        lq_p1_issue_block;
    logic [LQ_P1_HOLD_PTR_BITS-1:0] lq_p1_hold_head_r;
    logic [LQ_P1_HOLD_PTR_BITS-1:0] lq_p1_hold_tail_r;
    logic [LQ_P1_HOLD_PTR_BITS:0]   lq_p1_hold_count_r;
    logic [LQ_IDX_BITS-1:0]         lq_p1_hold_idx_r      [0:LQ_P1_HOLD_DEPTH-1];
    logic [ROB_IDX_BITS-1:0]        lq_p1_hold_rob_idx_r  [0:LQ_P1_HOLD_DEPTH-1];
    logic [63:0]                    lq_p1_hold_addr_r     [0:LQ_P1_HOLD_DEPTH-1];
    logic [1:0]                     lq_p1_hold_size_r     [0:LQ_P1_HOLD_DEPTH-1];
    logic                           lq_p1_hold_unsigned_r [0:LQ_P1_HOLD_DEPTH-1];

    // The LQ has two address-fill ports.  This keeps a dual-issued port-1
    // load visible to later store-address ordering checks in the same way as
    // port 0.  The old skid FIFO remains reset/idle as a diagnostic guard; it
    // is no longer part of the functional LQ address-fill path.
    logic p0_exec_fire;
    logic p1_exec_fire;
    assign p0_exec_fire = load_issue_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid;
    assign p1_exec_fire = p1_eff_valid       & ~p1_eff_misalign        & ~flush_in.valid;
    assign lq_p1_hold_valid_r = (lq_p1_hold_count_r != '0);
    assign lq_p1_hold_full    = (lq_p1_hold_count_r == LQ_P1_HOLD_DEPTH);
    assign lq_p1_issue_block  = 1'b0;
    assign lq_p1_hold_pop     = 1'b0;
    assign lq_p1_hold_push    = 1'b0;

    // Port 0 address fill.
    always_comb begin
        if (p0_exec_fire) begin
            lq_exec_valid       = 1'b1;
            lq_exec_idx         = load_issue_data[0].lq_idx;
            lq_exec_rob_idx     = load_issue_data[0].rob_idx;
            lq_exec_addr        = load_mem_addr[0];
            lq_exec_size        = load_issue_data[0].mem_size;
            lq_exec_is_unsigned = load_issue_data[0].is_unsigned;
        end else begin
            lq_exec_valid       = 1'b0;
            lq_exec_idx         = '0;
            lq_exec_rob_idx     = '0;
            lq_exec_addr        = '0;
            lq_exec_size        = '0;
            lq_exec_is_unsigned = 1'b0;
        end
    end

    // Port 1 address fill.  Uses the EFFECTIVE issue source, so retries and
    // store-forwarded port-1 loads record the same metadata as the D-cache
    // request/writeback pipeline.
    assign lq_exec1_valid       = p1_exec_fire;
    assign lq_exec1_idx         = p1_eff_data.lq_idx;
    assign lq_exec1_rob_idx     = p1_eff_data.rob_idx;
    assign lq_exec1_addr        = p1_eff_addr;
    assign lq_exec1_size        = p1_eff_data.mem_size;
    assign lq_exec1_is_unsigned = p1_eff_data.is_unsigned;

    // Capture deferred port-1 LQ exec metadata.  Uses p1_eff, which already
    // accounts for d-cache conflict retries and store-forwarding blocks.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_p1_hold_head_r  <= '0;
            lq_p1_hold_tail_r  <= '0;
            lq_p1_hold_count_r <= '0;
        end else if (flush_in.valid) begin
            lq_p1_hold_head_r  <= '0;
            lq_p1_hold_tail_r  <= '0;
            lq_p1_hold_count_r <= '0;
        end else begin
            if (lq_p1_hold_push) begin
                lq_p1_hold_idx_r[lq_p1_hold_tail_r]      <= p1_eff_data.lq_idx;
                lq_p1_hold_rob_idx_r[lq_p1_hold_tail_r]  <= p1_eff_data.rob_idx;
                lq_p1_hold_addr_r[lq_p1_hold_tail_r]     <= p1_eff_addr;
                lq_p1_hold_size_r[lq_p1_hold_tail_r]     <= p1_eff_data.mem_size;
                lq_p1_hold_unsigned_r[lq_p1_hold_tail_r] <= p1_eff_data.is_unsigned;
                lq_p1_hold_tail_r <= lq_p1_hold_tail_r + 1'b1;
            end

            if (lq_p1_hold_pop) begin
                lq_p1_hold_head_r <= lq_p1_hold_head_r + 1'b1;
            end

            case ({lq_p1_hold_push, lq_p1_hold_pop})
                2'b10: lq_p1_hold_count_r <= lq_p1_hold_count_r + 1'b1;
                2'b01: lq_p1_hold_count_r <= lq_p1_hold_count_r - 1'b1;
                default: ;
            endcase
`ifdef SIMULATION
            if (lq_p1_hold_push && lq_p1_hold_full && !lq_p1_hold_pop) begin
                $error("LSU LQ port1 skid overflow: p1 load accepted with no LQ exec slot");
            end
`endif
        end
    end

    // =========================================================================
    // Load pipeline metadata: shift-register chain
    // =========================================================================
    // The D-cache tag/data RAMs are synchronous-read and the hit response is
    // driven from S1, one cycle after issue.  Track the issued load metadata so
    // cache-hit writeback uses the matching rob_idx / pdst / lq_idx /
    // byte_offset, not the current post-issue values.
    //
    // Stages:
    //   *_r  = 1 cycle after issue (matches dcache_load_resp_valid for a hit)
    //   *_rr = legacy/debug stage; miss/hit functional paths use *_r.
    // =========================================================================
    iq_entry_t load_issue_data_r  [0:1];
    iq_entry_t load_issue_data_rr [0:1];
    // load_issue_valid_r/rr declared earlier (forward decl)
    logic [63:0] load_eff_addr_r  [0:1];
    logic [63:0] load_eff_addr_rr [0:1];
    // load_nocache_r/rr declared earlier (forward decl)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_issue_valid_r  <= '0;
            load_issue_valid_rr <= '0;
            load_nocache_r      <= '0;
            load_nocache_rr     <= '0;
            for (int i = 0; i < 2; i++) begin
                load_issue_data_r[i]  <= '0;
                load_issue_data_rr[i] <= '0;
                load_eff_addr_r[i]    <= '0;
                load_eff_addr_rr[i]   <= '0;
            end
        end else if (flush_in.valid) begin
            // Kill all in-flight load metadata on a redirect. Keeping the
            // one-cycle stage live lets a wrong-path miss allocate an LMB
            // entry after the flush, then write stale data into a recycled
            // ROB/pdst when the fill returns.
            load_issue_valid_r  <= '0;
            load_issue_valid_rr <= '0;
            load_nocache_r      <= '0;
            load_nocache_rr     <= '0;
            for (int i = 0; i < 2; i++) begin
                load_issue_data_r[i]  <= '0;
                load_issue_data_rr[i] <= '0;
                load_eff_addr_r[i]    <= '0;
                load_eff_addr_rr[i]   <= '0;
            end
        end else begin
            // Port 0 propagates the original issue.  Port 1 propagates the
            // EFFECTIVE issue (which includes the retry register), so the
            // writeback metadata at _rr matches the cycle the dcache
            // responds for the deferred load.
            load_issue_valid_r[0] <= load_issue_valid[0];
            load_issue_valid_r[1] <= p1_eff_valid;
            load_issue_data_r[0]  <= load_issue_data[0];
            load_issue_data_r[1]  <= p1_eff_data;
            load_eff_addr_r[0]    <= load_mem_addr[0];
            load_eff_addr_r[1]    <= p1_eff_addr;
            load_nocache_r[0]     <= load_issue_valid[0] &
                                     (load_cross_line[0] |
                                      load_addr_misaligned[0] | load_addr_mmio[0] |
                                      load_issue_data[0].is_amo |
                                      p0_fwd_hit |
                                      p0_partial_fwd_wait | flush_in.valid);
            load_nocache_r[1]     <= p1_eff_valid & p1_eff_nocache;

            // Stage 2 retained for debug-only traces and legacy assertions.
            load_issue_valid_rr   <= load_issue_valid_r;
            load_issue_data_rr[0] <= load_issue_data_r[0];
            load_issue_data_rr[1] <= load_issue_data_r[1];
            load_eff_addr_rr[0]   <= load_eff_addr_r[0];
            load_eff_addr_rr[1]   <= load_eff_addr_r[1];
            load_nocache_rr[0]    <= load_nocache_r[0];
            load_nocache_rr[1]    <= load_nocache_r[1];
        end
    end

    // =========================================================================
    // LQ result fill: whichever path drove load_wb[0] this cycle also
    // records the result into the load queue.  Because the LMB needs to be
    // declared below before we can reference its fields here, we forward-
    // declare the lq_result source selector and bind it in the same
    // writeback always_comb block below.
    // =========================================================================
    logic                   lq_result_valid;
    logic [LQ_IDX_BITS-1:0] lq_result_idx;
    logic [63:0]            lq_result_data;

    logic                   lq_result_valid_r;
    logic [LQ_IDX_BITS-1:0] lq_result_idx_r;
    logic [63:0]            lq_result_data_r;
    logic [LQ_IDX_BITS-1:0] lq_result_idx_sel;  // combinational selector

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_result_valid_r <= 1'b0;
        end else if (flush_in.valid) begin
            lq_result_valid_r <= 1'b0;
        end else begin
            lq_result_valid_r <= load_wb_valid[0];
            lq_result_idx_r   <= lq_result_idx_sel;
            lq_result_data_r  <= load_wb_data[0];
        end
    end

    assign lq_result_valid = lq_result_valid_r;
    assign lq_result_idx   = lq_result_idx_r;
    assign lq_result_data  = lq_result_data_r;

    load_queue u_load_queue (
        .clk               (clk),
        .rst_n             (rst_n),
        // Allocate
        .alloc_count       (lq_alloc_count),
        .alloc_rob_idx     (lq_alloc_rob_idx),
        .alloc_idx         (lq_alloc_idx),
        .full              (lq_full),
        .rob_head          (rob_head),
        // Load execution (address fill)
        .exec_valid        (lq_exec_valid),
        .exec_idx          (lq_exec_idx),
        .exec_rob_idx      (lq_exec_rob_idx),
        .exec_addr         (lq_exec_addr),
        .exec_size         (lq_exec_size),
        .exec_is_unsigned  (lq_exec_is_unsigned),
        .exec1_valid       (lq_exec1_valid),
        .exec1_idx         (lq_exec1_idx),
        .exec1_rob_idx     (lq_exec1_rob_idx),
        .exec1_addr        (lq_exec1_addr),
        .exec1_size        (lq_exec1_size),
        .exec1_is_unsigned (lq_exec1_is_unsigned),
        // Load result
        .result_valid      (lq_result_valid),
        .result_idx        (lq_result_idx),
        .result_data       (lq_result_data),
        // Store-to-load ordering violation check (from STA).
        // Use the same unguarded STA valid as above; a flush-cycle STA that
        // is older than the flush point still needs its ordering check.
        .st_addr_valid     (sta_issue_valid),
        .st_addr           (sta_mem_addr),
        .st_size           (sta_issue_data.mem_size),
        .st_rob_idx        (sta_issue_data.rob_idx),
        .ordering_violation(ordering_violation),
        .violation_rob_idx (violation_rob_idx),
        // Commit
        .commit_count      (load_commit_count),
        // Flush
        .flush_valid       (flush_in.valid),
        .flush_rob_tail    (flush_in.rob_idx),
        .flush_full        (flush_in.full_flush)
    );

    // =========================================================================
    // Committed Store Buffer
    // =========================================================================
    logic        csb_enq_ready;
    logic        csb_deq_valid;
    logic [63:0] csb_deq_addr;
    logic [63:0] csb_deq_data;
    logic [7:0]  csb_deq_byte_mask;
    logic [1:0]  csb_deq_size;
    logic        csb_deq_ack;
    logic        csb_deq_mmio;
    logic        csb_deq_cross_line;
    logic [3:0]  csb_deq_size_bytes;
    logic [3:0]  csb_split_first_bytes;
    logic [3:0]  csb_split_second_bytes;
    logic [7:0]  csb_split_first_mask;
    logic [7:0]  csb_split_second_mask;
    logic [63:0] csb_split_second_addr;
    logic [63:0] csb_split_second_data;
    logic        split_store_active_r;
    logic [63:0] split_store_addr_r;
    logic [63:0] split_store_data_r;
    logic [7:0]  split_store_mask_r;
    logic        split_store_start;
    logic        split_store_req_valid;
    logic [63:0] split_store_req_addr;
    logic [63:0] split_store_req_data;
    logic [7:0]  split_store_req_mask;
    logic        split_store_first_ack;
    logic        split_store_second_ack;
    logic        csb_normal_store_req_valid;
    logic        csb_store_ack;

    committed_store_buffer u_csb (
        .clk            (clk),
        .rst_n          (rst_n),
        // Enqueue from SQ drain
        .enq_valid      (sq_drain_valid),
        .enq_data       (sq_drain_entry),
        .enq_ready      (csb_enq_ready),
        // Dequeue to D-cache
        .deq_valid      (csb_deq_valid),
        .deq_addr       (csb_deq_addr),
        .deq_data       (csb_deq_data),
        .deq_byte_mask  (csb_deq_byte_mask),
        .deq_size       (csb_deq_size),
        .deq_ack        (csb_deq_ack),
        // Store-to-load forwarding
        .fwd_valid      (load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid),
        .fwd_addr       ((load_issue_candidate_valid[0] & ~load_addr_misaligned[0] & ~flush_in.valid)
                          ? load_mem_addr[0] : 64'd0),
        .fwd_size       (load_issue_data[0].mem_size),
        .fwd_hit        (csb_fwd_hit),
        .fwd_partial    (csb_fwd_partial),
        .fwd_data       (csb_fwd_data),
        .fwd1_valid     (p1_wait_req_valid),
        .fwd1_addr      (p1_wait_req_valid ? p1_wait_req_addr : 64'd0),
        .fwd1_size      (p1_wait_req_size),
        .fwd1_hit       (csb_fwd_hit_p1),
        .fwd1_partial   (csb_fwd_partial_p1),
        .fwd1_data      (csb_fwd_data_p1),
        // Full
        .full           ()
    );

    assign sq_drain_ready = csb_enq_ready;

    assign csb_deq_mmio =
        ((csb_deq_addr >= CLINT_BASE) &&
         (csb_deq_addr < (CLINT_BASE + CLINT_SIZE))) ||
        ((csb_deq_addr >= PLIC_BASE) &&
         (csb_deq_addr < (PLIC_BASE + PLIC_SIZE))) ||
        ((csb_deq_addr >= UART_BASE) &&
         (csb_deq_addr < (UART_BASE + UART_SIZE)));

    always_comb begin
        case (csb_deq_size)
            MEM_HALF:  csb_deq_size_bytes = 4'd2;
            MEM_WORD:  csb_deq_size_bytes = 4'd4;
            MEM_DWORD: csb_deq_size_bytes = 4'd8;
            default:   csb_deq_size_bytes = 4'd1;
        endcase
        csb_deq_cross_line =
            ({1'b0, csb_deq_addr[5:0]} + {3'b000, csb_deq_size_bytes}) >
            7'd64;
        csb_split_first_bytes =
            csb_deq_cross_line
                ? 4'(7'd64 - {1'b0, csb_deq_addr[5:0]})
                : csb_deq_size_bytes;
        csb_split_second_bytes = csb_deq_size_bytes - csb_split_first_bytes;
        csb_split_first_mask   = 8'h00;
        csb_split_second_mask  = 8'h00;
        for (int b = 0; b < 8; b++) begin
            if (b < int'(csb_split_first_bytes))
                csb_split_first_mask[b] = 1'b1;
            if (b < int'(csb_split_second_bytes))
                csb_split_second_mask[b] = 1'b1;
        end
        csb_split_second_addr =
            {csb_deq_addr[63:LINE_BITS] + 1'b1, {LINE_BITS{1'b0}}};
        csb_split_second_data =
            csb_deq_data >> ({3'b000, csb_split_first_bytes} * 4'd8);
    end

    assign split_store_start =
        csb_deq_valid &&
        !csb_deq_mmio &&
        csb_deq_cross_line &&
        !split_store_active_r;
    assign split_store_req_valid = split_store_start || split_store_active_r;
    assign split_store_req_addr  = split_store_active_r
                                 ? split_store_addr_r
                                 : csb_deq_addr;
    assign split_store_req_data  = split_store_active_r
                                 ? split_store_data_r
                                 : csb_deq_data;
    assign split_store_req_mask  = split_store_active_r
                                 ? split_store_mask_r
                                 : csb_split_first_mask;
    assign split_store_first_ack =
        split_store_start &&
        !amo_store_valid_r &&
        dcache_store_ack;
    assign split_store_second_ack =
        split_store_active_r &&
        !amo_store_valid_r &&
        dcache_store_ack;
    assign csb_normal_store_req_valid =
        csb_deq_valid &&
        !csb_deq_mmio &&
        !csb_deq_cross_line &&
        !split_store_active_r;
    assign csb_store_ack = (csb_deq_cross_line || split_store_active_r)
                         ? split_store_second_ack
                         : dcache_store_ack;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            split_store_active_r <= 1'b0;
            split_store_addr_r   <= 64'd0;
            split_store_data_r   <= 64'd0;
            split_store_mask_r   <= 8'd0;
        end else if (flush_in.valid) begin
            split_store_active_r <= 1'b0;
        end else begin
            if (split_store_second_ack) begin
                split_store_active_r <= 1'b0;
            end else if (split_store_first_ack) begin
                split_store_active_r <= 1'b1;
                split_store_addr_r   <= csb_split_second_addr;
                split_store_data_r   <= csb_split_second_data;
                split_store_mask_r   <= csb_split_second_mask;
            end
        end
    end

    assign dcache_store_req_valid     = amo_store_valid_r
                                      ? 1'b1
                                      : (split_store_req_valid |
                                         csb_normal_store_req_valid);
    assign dcache_store_req_addr      = amo_store_valid_r
                                      ? amo_addr_r
                                      : (split_store_req_valid
                                         ? split_store_req_addr
                                         : csb_deq_addr);
    assign dcache_store_req_data      = amo_store_valid_r
                                      ? amo_store_data_r
                                      : (split_store_req_valid
                                         ? split_store_req_data
                                         : csb_deq_data);
    assign dcache_store_req_byte_mask = amo_store_valid_r
                                      ? amo_store_mask_r
                                      : (split_store_req_valid
                                         ? split_store_req_mask
                                         : csb_deq_byte_mask);

    // =========================================================================
    // D-cache load request generation
    // =========================================================================
    // Send to D-cache only if no SQ/CSB forwarding hit and no misalign.
    //
    // p0_fwd_hit covers three sources: the same-cycle STA/STD bypass, the
    // SQ CAM (older stores in the SQ), and the CSB CAM (committed but not
    // yet drained stores).  Any of these hitting means we do NOT send the
    // load to the D-cache (avoids polluting the cache and wasting an MSHR).
    // p0_fwd_hit declared earlier (forward decl)
    always_comb begin
        case (sq_drain_entry.size)
            MEM_BYTE:  csb_enq_fwd_bmask = 8'h01 << sq_drain_entry.addr[2:0];
            MEM_HALF:  csb_enq_fwd_bmask = 8'h03 << sq_drain_entry.addr[2:0];
            MEM_WORD:  csb_enq_fwd_bmask = 8'h0F << sq_drain_entry.addr[2:0];
            MEM_DWORD: csb_enq_fwd_bmask = 8'hFF;
            default:   csb_enq_fwd_bmask = 8'h00;
        endcase
        case (p1_wait_req_size)
            MEM_BYTE:  csb_enq_fwd_req1_bmask = 8'h01 << p1_wait_req_addr[2:0];
            MEM_HALF:  csb_enq_fwd_req1_bmask = 8'h03 << p1_wait_req_addr[2:0];
            MEM_WORD:  csb_enq_fwd_req1_bmask = 8'h0F << p1_wait_req_addr[2:0];
            MEM_DWORD: csb_enq_fwd_req1_bmask = 8'hFF;
            default:   csb_enq_fwd_req1_bmask = 8'h00;
        endcase
        case (sq_drain_entry.size)
            MEM_BYTE: begin
                csb_enq_size_bytes = 4'd1;
                csb_enq_cross_dword = 1'b0;
            end
            MEM_HALF: begin
                csb_enq_size_bytes = 4'd2;
                csb_enq_cross_dword = (sq_drain_entry.addr[2:0] > 3'd6);
            end
            MEM_WORD: begin
                csb_enq_size_bytes = 4'd4;
                csb_enq_cross_dword = (sq_drain_entry.addr[2:0] > 3'd4);
            end
            MEM_DWORD: begin
                csb_enq_size_bytes = 4'd8;
                csb_enq_cross_dword = (sq_drain_entry.addr[2:0] != 3'd0);
            end
            default: begin
                csb_enq_size_bytes = 4'd1;
                csb_enq_cross_dword = 1'b0;
            end
        endcase
        case (p1_wait_req_size)
            MEM_BYTE: begin
                p1_wait_req_size_bytes = 4'd1;
                p1_wait_req_cross_dword = 1'b0;
            end
            MEM_HALF: begin
                p1_wait_req_size_bytes = 4'd2;
                p1_wait_req_cross_dword = (p1_wait_req_addr[2:0] > 3'd6);
            end
            MEM_WORD: begin
                p1_wait_req_size_bytes = 4'd4;
                p1_wait_req_cross_dword = (p1_wait_req_addr[2:0] > 3'd4);
            end
            MEM_DWORD: begin
                p1_wait_req_size_bytes = 4'd8;
                p1_wait_req_cross_dword = (p1_wait_req_addr[2:0] != 3'd0);
            end
            default: begin
                p1_wait_req_size_bytes = 4'd1;
                p1_wait_req_cross_dword = 1'b0;
            end
        endcase
    end

    assign csb_enq_last_addr =
        sq_drain_entry.addr + {60'd0, csb_enq_size_bytes} - 64'd1;
    assign p1_wait_req_last_addr =
        p1_wait_req_addr + {60'd0, p1_wait_req_size_bytes} - 64'd1;
    assign csb_enq_fwd_same_dword0 =
        sq_drain_entry.addr[63:3] == load_mem_addr[0][63:3];
    assign csb_enq_fwd_same_dword1 =
        sq_drain_entry.addr[63:3] == p1_wait_req_addr[63:3];
    assign csb_enq_fwd_range_overlap0 =
        sq_drain_valid && sq_drain_ready &&
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        !flush_in.valid &&
        (sq_drain_entry.addr <= load0_last_addr) &&
        (load_mem_addr[0] <= csb_enq_last_addr);
    assign csb_enq_fwd_range_overlap1 =
        sq_drain_valid && sq_drain_ready &&
        p1_wait_req_valid &&
        (sq_drain_entry.addr <= p1_wait_req_last_addr) &&
        (p1_wait_req_addr <= csb_enq_last_addr);
    assign csb_enq_fwd_cross_block0 =
        csb_enq_fwd_range_overlap0 &&
        (csb_enq_cross_dword || load0_cross_dword || !csb_enq_fwd_same_dword0);
    assign csb_enq_fwd_cross_block1 =
        csb_enq_fwd_range_overlap1 &&
        (csb_enq_cross_dword || p1_wait_req_cross_dword || !csb_enq_fwd_same_dword1);

    assign csb_enq_fwd_overlap0 =
        (csb_enq_fwd_range_overlap0 && csb_enq_fwd_same_dword0)
            ? (csb_enq_fwd_bmask & load0_byte_mask_dyn)
            : 8'h00;
    assign csb_enq_fwd_overlap1 =
        (csb_enq_fwd_range_overlap1 && csb_enq_fwd_same_dword1)
            ? (csb_enq_fwd_bmask & csb_enq_fwd_req1_bmask)
            : 8'h00;

    assign csb_enq_fwd_hit =
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        !flush_in.valid &&
        !csb_enq_fwd_cross_block0 &&
        (csb_enq_fwd_overlap0 == load0_byte_mask_dyn);
    assign csb_enq_fwd_hit_p1 =
        p1_wait_req_valid &&
        !csb_enq_fwd_cross_block1 &&
        (csb_enq_fwd_overlap1 == csb_enq_fwd_req1_bmask);
    assign csb_enq_fwd_partial =
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        !flush_in.valid &&
        (csb_enq_fwd_range_overlap0 || (csb_enq_fwd_overlap0 != 8'h00)) &&
        !csb_enq_fwd_hit;
    assign csb_enq_fwd_partial_p1 =
        p1_wait_req_valid &&
        (csb_enq_fwd_range_overlap1 || (csb_enq_fwd_overlap1 != 8'h00)) &&
        !csb_enq_fwd_hit_p1;

    always_comb begin
        csb_enq_fwd_data    = '0;
        csb_enq_fwd_data_p1 = '0;
        for (int b = 0; b < 8; b++) begin
            if (csb_enq_fwd_overlap0[b] &&
                (b >= int'(sq_drain_entry.addr[2:0]))) begin
                csb_enq_fwd_data[b*8 +: 8] =
                    sq_drain_entry.data[
                        (b - int'(sq_drain_entry.addr[2:0])) * 8 +: 8
                    ];
            end
            if (csb_enq_fwd_overlap1[b] &&
                (b >= int'(sq_drain_entry.addr[2:0]))) begin
                csb_enq_fwd_data_p1[b*8 +: 8] =
                    sq_drain_entry.data[
                        (b - int'(sq_drain_entry.addr[2:0])) * 8 +: 8
                    ];
            end
        end
    end

    assign p0_fwd_hit =
        same_cycle_fwd_hit |
        sq_fwd_hit |
        csb_enq_fwd_hit |
        csb_fwd_hit;
    assign p1_any_fwd_hit =
        sq_fwd_hit_p1 |
        csb_enq_fwd_hit_p1 |
        csb_fwd_hit_p1;
    assign p0_partial_fwd_wait =
        sq_fwd_partial |
        same_cycle_fwd_partial |
        csb_enq_fwd_partial |
        csb_fwd_partial;
    assign p1_partial_fwd_wait =
        sq_fwd_partial_p1 |
        csb_enq_fwd_partial_p1 |
        csb_fwd_partial_p1;
    assign p0_sq_order_wait_block =
        sq_fwd_wait_data_missing || sq_fwd_wait_addr_unknown;
    assign p1_sq_order_wait_block =
        sq_wait_p1_data_missing || sq_wait_p1_addr_unknown;
    assign fence_i_ready =
        !sq_drain_valid &&
        !csb_deq_valid &&
        !split_store_active_r &&
        !data_mmio_req_valid;

    // -------------------------------------------------------------------------
    // Port-1 retry hold register for d-cache same-set conflicts.
    //
    // The d-cache suppresses port 1 when both loads target the same set
    // (bank conflict).  Without a retry path, port 1's load would be lost
    // and the ROB entry would never become ready, deadlocking commit.
    //
    // We replicate port 1's metadata pipeline (issue → _r → _rr) on a
    // shifted timeline so the writeback path can still match the cache
    // response.  When a conflict is detected, port 1 is captured into the
    // retry register and re-fired through dcache port 1 the *next* cycle
    // (when port 0 is presumably free or, at worst, still conflicting and
    // we re-hold).
    // -------------------------------------------------------------------------
    logic            p1_retry_valid_r;
    iq_entry_t       p1_retry_data_r;
    logic [63:0]     p1_retry_addr_r;
    logic            p1_retry_misalign_r;
    logic            p1_retry_load_nocache_r;
    logic            p1_retry_addr_mmio;
    logic            p1_miss_retry_req;
    logic            p1_fwd_blocked;
    logic            split_load_busy;
    logic            split_load_start;
    logic            split_load_wb_fire;
`ifdef SIMULATION
    logic            sim_p1_fast_fwd_enable;
    initial begin
        sim_p1_fast_fwd_enable = $test$plusargs("LSU_P1_FAST_FWD");
    end
`else
    localparam logic sim_p1_fast_fwd_enable = 1'b0;
`endif

    assign p0_dcache_hit_valid = !flush_in.valid
                               && dcache_load_resp_valid[0]
                               && load_issue_valid_r[0]
                               && !load_nocache_r[0]
                               && !load_issue_data_r[0].is_amo;
    assign p1_normal_wb_valid  = (load_issue_valid[1] && load_addr_misaligned[1] && !flush_in.valid)
                               || (!flush_in.valid
                                   && dcache_load_resp_valid[1]
                                   && load_issue_valid_r[1]
                                   && !load_nocache_r[1]);
    assign p0_fwd_spill_to_p1  = fwd_hold_valid_r && p0_dcache_hit_valid && !p1_normal_wb_valid;
    assign fwd_hold_blocked    = fwd_hold_valid_r && p0_dcache_hit_valid && p1_normal_wb_valid;
    assign lmb_wb_port_free    = !p0_dcache_hit_valid &&
                                  !fwd_hold_valid_r &&
                                  !amo_wb_valid_r;
    assign p1_fast_fwd_fire    =
        sim_p1_fast_fwd_enable &&
        p1_eff_valid &&
        !p1_eff_misalign &&
        p1_any_fwd_hit &&
        !p1_sq_order_wait_block &&
        !p1_partial_fwd_wait &&
        !sta_issue_valid &&
        !p1_normal_wb_valid &&
        !p0_fwd_spill_to_p1 &&
        !p1_fwd_hold_valid_r;

    assign amo_busy = amo_wait_load_r | amo_store_valid_r | amo_wb_valid_r;
    assign amo_serial_block =
        amo_busy |
        csb_deq_valid |
        lmb_any_valid |
        (load_issue_valid_r != 2'b00) |
        (load_issue_valid_rr != 2'b00) |
        p1_retry_valid_r |
        p1_miss_retry_req |
        fwd_hold_valid_r |
        p1_fwd_hold_valid_r;
    assign amo_issue_fire =
        load_issue_valid[0] &&
        load_issue_data[0].is_amo &&
        !load_addr_misaligned[0] &&
        !load_addr_mmio[0] &&
        !flush_in.valid;
    assign amo_load_issue_fire = amo_issue_fire &&
                                 (load_issue_data[0].amo_op != AMO_SC) &&
                                 dcache_load_req_valid[0];
    assign amo_sc_issue_fire   = amo_issue_fire &&
                                 (load_issue_data[0].amo_op == AMO_SC);

    assign amo_forward_block =
        sta_older_than_load0 |
        sq_fwd_wait |
        sq_fwd_hit |
        p0_partial_fwd_wait |
        csb_enq_fwd_hit |
        csb_fwd_hit;
    assign amo_flush_kill = flush_in.valid && flush_in.full_flush;

    assign load_issue_suppress[0] =
        load_issue_candidate_valid[0] &&
        (flush_in.valid ||
         split_load_busy ||
         load0_tlb_miss ||
         load0_tlb_port_wait ||
         load0_tlb_fault ||
         (!load_addr_misaligned[0] &&
          (p0_sq_order_wait_block || sq_fwd_partial ||
           csb_fwd_partial || same_cycle_sta_wait0 ||
           fwd_hold_blocked || mmio_load0_block ||
           amo_busy ||
           (load_issue_data[0].is_amo &&
            ((load_issue_data[0].rob_idx != rob_head) ||
             amo_serial_block ||
             amo_forward_block ||
             load_addr_mmio[0])))));

`ifndef SYNTHESIS
    bit sim_allow_same_line_dual_load;
    initial sim_allow_same_line_dual_load =
        $test$plusargs("ALLOW_SAME_LINE_DUAL_LOAD");
`endif

    // Combinational: same-set conflict between port 0 and port 1.  The
    // same-line relaxation is kept behind a simulation-only switch because
    // CoreMark still shows a wrong-path/performance collapse when it is enabled.
    logic dcache_conflict;
    assign dcache_conflict = load_issue_valid[0] && load_issue_valid[1]
                            && ~load_addr_misaligned[0]
                            && ~load_addr_misaligned[1]
                            && (load_eff_addr[0][13:6] ==
                                load_eff_addr[1][13:6])
`ifndef SYNTHESIS
                            && (!sim_allow_same_line_dual_load ||
                                (load_eff_addr[0][63:LINE_BITS] !=
                                 load_eff_addr[1][63:LINE_BITS]))
`endif
`ifdef SYNTHESIS
                            && 1'b1
`endif
                            ;

`ifndef SYNTHESIS
    localparam int SIM_P1_CONFLICT_TOPN = 16;

    logic sim_p1_conf_en;
    integer sim_p1_conf_total_cnt;
    integer sim_p1_conf_capture_cnt;
    integer sim_p1_conf_same_line_cnt;
    integer sim_p1_conf_diff_line_cnt;
    integer sim_p1_conf_sq_hit_cnt;
    integer sim_p1_conf_sq_wait_cnt;
    integer sim_p1_conf_sq_partial_cnt;
    integer sim_p1_conf_lq_block_cnt;
    integer sim_p1_lq_push_cnt;
    integer sim_p1_lq_pop_cnt;
    integer sim_p1_lq_full_cnt;
    integer sim_p1_lq_max_occ;
    logic [63:0] sim_p1_conf_p0_pc   [0:SIM_P1_CONFLICT_TOPN-1];
    logic [63:0] sim_p1_conf_p1_pc   [0:SIM_P1_CONFLICT_TOPN-1];
    integer      sim_p1_conf_count   [0:SIM_P1_CONFLICT_TOPN-1];
    integer      sim_p1_conf_sameln  [0:SIM_P1_CONFLICT_TOPN-1];
    integer      sim_p1_conf_diffln  [0:SIM_P1_CONFLICT_TOPN-1];

    initial sim_p1_conf_en =
        ($test$plusargs("PERF_PROFILE") || $test$plusargs("TRACE_P1_CONFLICT"))
            ? 1'b1 : 1'b0;

    function automatic logic sim_same_cache_line(
        input logic [63:0] a,
        input logic [63:0] b
    );
        sim_same_cache_line = (a[63:LINE_BITS] == b[63:LINE_BITS]);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_p1_conf_total_cnt     <= 0;
            sim_p1_conf_capture_cnt   <= 0;
            sim_p1_conf_same_line_cnt <= 0;
            sim_p1_conf_diff_line_cnt <= 0;
            sim_p1_conf_sq_hit_cnt    <= 0;
            sim_p1_conf_sq_wait_cnt   <= 0;
            sim_p1_conf_sq_partial_cnt <= 0;
            sim_p1_conf_lq_block_cnt  <= 0;
            sim_p1_lq_push_cnt        <= 0;
            sim_p1_lq_pop_cnt         <= 0;
            sim_p1_lq_full_cnt        <= 0;
            sim_p1_lq_max_occ         <= 0;
            for (int i = 0; i < SIM_P1_CONFLICT_TOPN; i++) begin
                sim_p1_conf_p0_pc[i]  <= '0;
                sim_p1_conf_p1_pc[i]  <= '0;
                sim_p1_conf_count[i]  <= 0;
                sim_p1_conf_sameln[i] <= 0;
                sim_p1_conf_diffln[i] <= 0;
            end
        end else if (sim_p1_conf_en) begin
            automatic logic same_line_now;
            same_line_now = sim_same_cache_line(load_eff_addr[0], load_eff_addr[1]);

            if (int'(lq_p1_hold_count_r) > sim_p1_lq_max_occ)
                sim_p1_lq_max_occ <= int'(lq_p1_hold_count_r);
            if (lq_p1_hold_push)
                sim_p1_lq_push_cnt <= sim_p1_lq_push_cnt + 1;
            if (lq_p1_hold_pop)
                sim_p1_lq_pop_cnt <= sim_p1_lq_pop_cnt + 1;
            if (lq_p1_hold_full)
                sim_p1_lq_full_cnt <= sim_p1_lq_full_cnt + 1;

            if (dcache_conflict) begin
                automatic int hit_idx;
                automatic int empty_idx;
                automatic logic do_capture;

                hit_idx = -1;
                empty_idx = -1;
                do_capture = !sq_wait_p1 && !p1_partial_fwd_wait && !sq_fwd_hit_p1;

                sim_p1_conf_total_cnt <= sim_p1_conf_total_cnt + 1;
                if (do_capture)
                    sim_p1_conf_capture_cnt <= sim_p1_conf_capture_cnt + 1;
                if (same_line_now)
                    sim_p1_conf_same_line_cnt <= sim_p1_conf_same_line_cnt + 1;
                else
                    sim_p1_conf_diff_line_cnt <= sim_p1_conf_diff_line_cnt + 1;
                if (sq_fwd_hit_p1)
                    sim_p1_conf_sq_hit_cnt <= sim_p1_conf_sq_hit_cnt + 1;
                if (sq_wait_p1)
                    sim_p1_conf_sq_wait_cnt <= sim_p1_conf_sq_wait_cnt + 1;
                if (sq_fwd_partial_p1)
                    sim_p1_conf_sq_partial_cnt <= sim_p1_conf_sq_partial_cnt + 1;
                if (lq_p1_issue_block)
                    sim_p1_conf_lq_block_cnt <= sim_p1_conf_lq_block_cnt + 1;

                for (int i = 0; i < SIM_P1_CONFLICT_TOPN; i++) begin
                    if ((hit_idx < 0) &&
                        (sim_p1_conf_count[i] != 0) &&
                        (sim_p1_conf_p0_pc[i] == load_issue_data[0].pc) &&
                        (sim_p1_conf_p1_pc[i] == load_issue_data[1].pc)) begin
                        hit_idx = i;
                    end
                    if ((empty_idx < 0) && (sim_p1_conf_count[i] == 0))
                        empty_idx = i;
                end

                if (hit_idx >= 0) begin
                    sim_p1_conf_count[hit_idx] <= sim_p1_conf_count[hit_idx] + 1;
                    if (same_line_now)
                        sim_p1_conf_sameln[hit_idx] <= sim_p1_conf_sameln[hit_idx] + 1;
                    else
                        sim_p1_conf_diffln[hit_idx] <= sim_p1_conf_diffln[hit_idx] + 1;
                end else if (empty_idx >= 0) begin
                    sim_p1_conf_p0_pc[empty_idx]  <= load_issue_data[0].pc;
                    sim_p1_conf_p1_pc[empty_idx]  <= load_issue_data[1].pc;
                    sim_p1_conf_count[empty_idx]  <= 1;
                    sim_p1_conf_sameln[empty_idx] <= same_line_now ? 1 : 0;
                    sim_p1_conf_diffln[empty_idx] <= same_line_now ? 0 : 1;
                end

                if ($test$plusargs("TRACE_P1_CONFLICT")) begin
                    $display("[LSU_P1_CONFLICT] cyc=%0t p0_pc=%016h p1_pc=%016h p0_addr=%016h p1_addr=%016h same_line=%b capture=%b sq_hit=%b sq_wait=%b sq_partial=%b lq_block=%b retry_live=%b",
                        $time, load_issue_data[0].pc, load_issue_data[1].pc,
                        load_eff_addr[0], load_eff_addr[1], same_line_now,
                        do_capture, sq_fwd_hit_p1, sq_wait_p1,
                        sq_fwd_partial_p1, lq_p1_issue_block,
                        p1_retry_valid_r);
                end
            end
        end
    end

    final begin
        if (sim_p1_conf_en) begin
            $display("");
            $display("=== LSU P1 CONFLICT SUMMARY ===");
            $display("total/capture same_line/diff_line : %0d / %0d   %0d / %0d",
                     sim_p1_conf_total_cnt, sim_p1_conf_capture_cnt,
                     sim_p1_conf_same_line_cnt, sim_p1_conf_diff_line_cnt);
            $display("blocked by sq_hit/wait/partial/lq : %0d / %0d / %0d / %0d",
                     sim_p1_conf_sq_hit_cnt, sim_p1_conf_sq_wait_cnt,
                     sim_p1_conf_sq_partial_cnt, sim_p1_conf_lq_block_cnt);
            $display("LQ p1 skid push/pop/full/max_occ  : %0d / %0d / %0d / %0d",
                     sim_p1_lq_push_cnt, sim_p1_lq_pop_cnt,
                     sim_p1_lq_full_cnt, sim_p1_lq_max_occ);
            $display("p0_pc              p1_pc              count same_line diff_line");
            for (int i = 0; i < SIM_P1_CONFLICT_TOPN; i++) begin
                if (sim_p1_conf_count[i] != 0) begin
                    $display("%016h %016h %0d %0d %0d",
                             sim_p1_conf_p0_pc[i], sim_p1_conf_p1_pc[i],
                             sim_p1_conf_count[i], sim_p1_conf_sameln[i],
                             sim_p1_conf_diffln[i]);
                end
            end
        end
    end
`endif

    // Effective port 1 sources: prefer the retry register if valid;
    // otherwise the new issue (suppressed on conflict).
    // p1_eff_valid/misalign/addr/data/nocache declared earlier (forward decl)

    always_comb begin
        if (p1_retry_valid_r) begin
            p1_wait_req_valid   = 1'b1;
            p1_wait_req_addr    = p1_retry_addr_r;
            p1_wait_req_size    = p1_retry_data_r.mem_size;
            p1_wait_req_rob_idx = p1_retry_data_r.rob_idx;
        end else begin
            p1_wait_req_valid   = load_issue_candidate_valid[1] &&
                                  ~load_addr_misaligned[1] &&
                                  ~flush_in.valid;
            p1_wait_req_addr    = load_eff_addr[1];
            p1_wait_req_size    = load_issue_data[1].mem_size;
            p1_wait_req_rob_idx = load_issue_data[1].rob_idx;
        end
    end

    assign p1_fwd_blocked =
        !p1_retry_valid_r &&
        load_issue_candidate_valid[1] &&
        !load_addr_misaligned[1] &&
        !flush_in.valid &&
        p1_any_fwd_hit &&
        !p1_sq_order_wait_block &&
        p1_fwd_hold_valid_r;

    assign load_issue_suppress[1] =
        load_issue_candidate_valid[1] &&
        (flush_in.valid ||
         split_load_busy ||
         load_cross_line[1] ||
         load1_tlb_wait ||
         amo_busy ||
         load_issue_data[1].is_amo ||
         (load_issue_candidate_valid[0] && load_issue_data[0].is_amo) ||
         p1_retry_valid_r ||
         p1_miss_retry_req ||
         (!load_addr_misaligned[1] && !p1_retry_valid_r &&
          (p1_sq_order_wait_block || p1_partial_fwd_wait || p1_fwd_blocked ||
           same_cycle_sta_wait1 || lq_p1_issue_block || mmio_load1_block)));

    assign load_issue_spec_past_addr_unknown = 2'b00;

    assign p1_retry_addr_mmio =
        ((p1_retry_addr_r >= CLINT_BASE) &&
         (p1_retry_addr_r < (CLINT_BASE + CLINT_SIZE))) ||
        ((p1_retry_addr_r >= PLIC_BASE) &&
         (p1_retry_addr_r < (PLIC_BASE + PLIC_SIZE))) ||
        ((p1_retry_addr_r >= UART_BASE) &&
         (p1_retry_addr_r < (UART_BASE + UART_SIZE)));

    assign p1_eff_addr_mmio =
        ((p1_eff_addr >= CLINT_BASE) &&
         (p1_eff_addr < (CLINT_BASE + CLINT_SIZE))) ||
        ((p1_eff_addr >= PLIC_BASE) &&
         (p1_eff_addr < (PLIC_BASE + PLIC_SIZE))) ||
        ((p1_eff_addr >= UART_BASE) &&
         (p1_eff_addr < (UART_BASE + UART_SIZE)));

    always_comb begin
        if (p1_retry_valid_r) begin
            p1_eff_valid    = !p1_sq_order_wait_block &&
                              !p1_partial_fwd_wait &&
                              !lq_p1_issue_block &&
                              (!p1_any_fwd_hit || !p1_fwd_hold_valid_r);
            p1_eff_data     = p1_retry_data_r;
            p1_eff_addr     = p1_retry_addr_r;
            p1_eff_misalign = p1_retry_misalign_r;
            p1_eff_nocache  = p1_retry_load_nocache_r |
                              p1_retry_addr_mmio |
                              p1_any_fwd_hit | p1_partial_fwd_wait;
        end else if (load_issue_valid[1] && !p1_sq_order_wait_block && !p1_partial_fwd_wait &&
                     !lq_p1_issue_block &&
                     (p1_any_fwd_hit ? !p1_fwd_hold_valid_r : !dcache_conflict)) begin
            p1_eff_valid    = 1'b1;
            p1_eff_data     = load_issue_data[1];
            p1_eff_addr     = load_eff_addr[1];
            p1_eff_misalign = load_addr_misaligned[1];
            p1_eff_nocache  = load_addr_misaligned[1] | flush_in.valid |
                              load_addr_mmio[1] |
                              p1_any_fwd_hit | p1_partial_fwd_wait;
        end else begin
            p1_eff_valid    = 1'b0;
            p1_eff_data     = '0;
            p1_eff_addr     = '0;
            p1_eff_misalign = 1'b0;
            p1_eff_nocache  = 1'b0;
        end
    end

    // Capture port 1 on a d-cache set conflict.  Address-known / data-not-ready
    // hazards use load_issue_suppress to keep the IQ entry live instead.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_retry_valid_r <= 1'b0;
        end else if (flush_in.valid) begin
            p1_retry_valid_r <= 1'b0;
        end else begin
            if (p1_retry_valid_r) begin
                // Drain after one cycle unless the retried load is still
                // blocked by an older store whose address is known but whose
                // data has not reached the SQ yet.
                if (!p1_sq_order_wait_block && !p1_partial_fwd_wait &&
                    !lq_p1_issue_block &&
                    (!p1_any_fwd_hit || !p1_fwd_hold_valid_r))
                    p1_retry_valid_r <= 1'b0;
            end
            if (dcache_conflict && !p1_miss_retry_req &&
                !p1_sq_order_wait_block &&
                !p1_partial_fwd_wait && !p1_any_fwd_hit) begin
                p1_retry_valid_r        <= 1'b1;
                p1_retry_data_r         <= load_issue_data[1];
                p1_retry_addr_r         <= load_eff_addr[1];
                p1_retry_misalign_r     <= load_addr_misaligned[1];
                p1_retry_load_nocache_r <= load_addr_misaligned[1] | flush_in.valid;
            end
            if (p1_miss_retry_req) begin
                p1_retry_valid_r        <= 1'b1;
                p1_retry_data_r         <= load_issue_data_r[1];
                p1_retry_addr_r         <= load_eff_addr_r[1];
                p1_retry_misalign_r     <= 1'b0;
                p1_retry_load_nocache_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Uncached data MMIO request path
    // =========================================================================
    logic        mmio_req_valid_r;
    logic        mmio_req_we_r;
    logic        mmio_req_is_load_r;
    logic        mmio_req_drop_r;
    logic [63:0] mmio_req_addr_r;
    logic [63:0] mmio_req_wdata_r;
    logic [7:0]  mmio_req_wmask_r;
    logic [1:0]  mmio_req_size_r;
    iq_entry_t   mmio_req_load_data_r;

    logic        mmio_wait_resp_r;
    logic        mmio_store_resp_fire_r;
    logic        mmio_available;

    logic [63:0] mmio_resp_raw_r;
    iq_entry_t   mmio_resp_load_data_r;
    logic [63:0] mmio_resp_ext;

    assign mmio_available =
        !mmio_req_valid_r && !mmio_wait_resp_r && !mmio_resp_hold_valid_r;

    assign mmio_store_launch =
        mmio_available && !mmio_store_resp_fire_r &&
        csb_deq_valid && csb_deq_mmio;

    assign mmio_load0_launch =
        mmio_available && !mmio_store_launch &&
        load_issue_valid[0] &&
        !load_addr_misaligned[0] &&
        load_addr_mmio[0] &&
        !p0_fwd_hit &&
        !p0_partial_fwd_wait &&
        !flush_in.valid;

    assign mmio_load1_launch =
        mmio_available && !mmio_store_launch && !mmio_load0_launch &&
        p1_eff_valid &&
        !p1_eff_misalign &&
        p1_eff_addr_mmio &&
        !p1_any_fwd_hit &&
        !p1_partial_fwd_wait &&
        !flush_in.valid;

    assign mmio_load0_block =
        load_issue_candidate_valid[0] &&
        !load_addr_misaligned[0] &&
        load_addr_mmio[0] &&
        (!mmio_available || mmio_store_launch);

    assign mmio_load1_block =
        load_issue_candidate_valid[1] &&
        !load_addr_misaligned[1] &&
        load_addr_mmio[1] &&
        (!mmio_available || mmio_store_launch || mmio_load0_launch);

    assign data_mmio_req_valid = mmio_req_valid_r;
    assign data_mmio_req_we    = mmio_req_we_r;
    assign data_mmio_req_addr  = mmio_req_addr_r;
    assign data_mmio_req_wdata = mmio_req_wdata_r;
    assign data_mmio_req_wmask = mmio_req_wmask_r;
    assign data_mmio_req_size  = mmio_req_size_r;

    always_comb begin
        case (mmio_resp_load_data_r.mem_size)
            MEM_BYTE:  mmio_resp_ext = mmio_resp_load_data_r.is_unsigned
                        ? {56'b0, mmio_resp_raw_r[7:0]}
                        : {{56{mmio_resp_raw_r[7]}}, mmio_resp_raw_r[7:0]};
            MEM_HALF:  mmio_resp_ext = mmio_resp_load_data_r.is_unsigned
                        ? {48'b0, mmio_resp_raw_r[15:0]}
                        : {{48{mmio_resp_raw_r[15]}}, mmio_resp_raw_r[15:0]};
            MEM_WORD:  mmio_resp_ext = mmio_resp_load_data_r.is_unsigned
                        ? {32'b0, mmio_resp_raw_r[31:0]}
                        : {{32{mmio_resp_raw_r[31]}}, mmio_resp_raw_r[31:0]};
            default:   mmio_resp_ext = mmio_resp_raw_r;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mmio_req_valid_r        <= 1'b0;
            mmio_req_we_r           <= 1'b0;
            mmio_req_is_load_r      <= 1'b0;
            mmio_req_drop_r         <= 1'b0;
            mmio_req_addr_r         <= 64'd0;
            mmio_req_wdata_r        <= 64'd0;
            mmio_req_wmask_r        <= 8'd0;
            mmio_req_size_r         <= '0;
            mmio_req_load_data_r    <= '0;
            mmio_wait_resp_r        <= 1'b0;
            mmio_store_resp_fire_r  <= 1'b0;
            mmio_resp_hold_valid_r  <= 1'b0;
            mmio_resp_raw_r         <= 64'd0;
            mmio_resp_load_data_r   <= '0;
        end else begin
            mmio_store_resp_fire_r <= 1'b0;

            if (mmio_load_wb_fire) begin
                mmio_resp_hold_valid_r <= 1'b0;
            end

            if (flush_in.valid && mmio_resp_hold_valid_r) begin
                mmio_resp_hold_valid_r <= 1'b0;
            end

            if (flush_in.valid && mmio_req_is_load_r) begin
                if (mmio_req_valid_r) begin
                    mmio_req_valid_r <= 1'b0;
                    mmio_req_drop_r  <= 1'b0;
                end
                if (mmio_wait_resp_r) begin
                    mmio_req_drop_r <= 1'b1;
                end
            end

            if (mmio_wait_resp_r && data_mmio_resp_valid) begin
                mmio_wait_resp_r <= 1'b0;
                mmio_req_drop_r  <= 1'b0;
                if (mmio_req_is_load_r && !mmio_req_drop_r && !flush_in.valid) begin
                    mmio_resp_hold_valid_r <= 1'b1;
                    mmio_resp_raw_r        <= data_mmio_resp_data;
                    mmio_resp_load_data_r  <= mmio_req_load_data_r;
                end else if (!mmio_req_is_load_r) begin
                    mmio_store_resp_fire_r <= 1'b1;
                end
            end

            if (mmio_req_valid_r && data_mmio_req_ready) begin
                mmio_req_valid_r <= 1'b0;
                mmio_wait_resp_r <= 1'b1;
            end

            if (mmio_store_launch) begin
                mmio_req_valid_r     <= 1'b1;
                mmio_req_we_r        <= 1'b1;
                mmio_req_is_load_r   <= 1'b0;
                mmio_req_drop_r      <= 1'b0;
                mmio_req_addr_r      <= csb_deq_addr;
                mmio_req_wdata_r     <= csb_deq_data;
                mmio_req_wmask_r     <= csb_deq_byte_mask;
                mmio_req_size_r      <= MEM_DWORD;
                mmio_req_load_data_r <= '0;
            end else if (mmio_load0_launch) begin
                mmio_req_valid_r     <= 1'b1;
                mmio_req_we_r        <= 1'b0;
                mmio_req_is_load_r   <= 1'b1;
                mmio_req_drop_r      <= 1'b0;
                mmio_req_addr_r      <= load_mem_addr[0];
                mmio_req_wdata_r     <= 64'd0;
                mmio_req_wmask_r     <= 8'd0;
                mmio_req_size_r      <= load_issue_data[0].mem_size;
                mmio_req_load_data_r <= load_issue_data[0];
            end else if (mmio_load1_launch) begin
                mmio_req_valid_r     <= 1'b1;
                mmio_req_we_r        <= 1'b0;
                mmio_req_is_load_r   <= 1'b1;
                mmio_req_drop_r      <= 1'b0;
                mmio_req_addr_r      <= p1_eff_addr;
                mmio_req_wdata_r     <= 64'd0;
                mmio_req_wmask_r     <= 8'd0;
                mmio_req_size_r      <= p1_eff_data.mem_size;
                mmio_req_load_data_r <= p1_eff_data;
            end
        end
    end

    assign csb_deq_ack = csb_deq_mmio ? mmio_store_resp_fire_r
                         : (amo_store_valid_r ? 1'b0 : csb_store_ack);

    // =========================================================================
    // Split-line load assist
    // =========================================================================
    // The D-cache can extract arbitrary bytes inside one 64-byte line, but a
    // strict RV64GC compliance row also exercises accesses that straddle a
    // line boundary.  Handle ordinary cached cross-line loads here by issuing
    // two aligned dword reads through D-cache port 0 and merging the bytes.
    typedef enum logic [2:0] {
        SPLIT_LD_IDLE  = 3'd0,
        SPLIT_LD_REQ0  = 3'd1,
        SPLIT_LD_WAIT0 = 3'd2,
        SPLIT_LD_REQ1  = 3'd3,
        SPLIT_LD_WAIT1 = 3'd4,
        SPLIT_LD_WB    = 3'd5
    } split_load_state_e;

    split_load_state_e split_load_state_r;
    iq_entry_t         split_load_data_r;
    logic [63:0]       split_load_addr_r;
    logic [63:0]       split_load_wait_addr_r;
    logic [63:0]       split_load_first_dword_r;
    logic [63:0]       split_load_second_dword_r;
    logic [63:0]       split_load_req_addr;
    logic              split_load_req_valid;
    logic              split_load_resp_valid;
    logic [63:0]       split_load_resp_data;
    logic [63:0]       split_load_fill_dword;
    logic [63:0]       split_load_merged_raw;
    logic [63:0]       split_load_result;
    logic [3:0]        split_load_first_bytes;

    assign split_load_busy = (split_load_state_r != SPLIT_LD_IDLE);
    assign split_load_start =
        load_issue_valid[0] &&
        load_cross_line[0] &&
        !load_addr_misaligned[0] &&
        !load_addr_mmio[0] &&
        !load_issue_data[0].is_amo &&
        !p0_fwd_hit &&
        !p0_partial_fwd_wait &&
        !flush_in.valid;

    always_comb begin
        split_load_req_valid = 1'b0;
        split_load_req_addr  = 64'd0;
        if (split_load_state_r == SPLIT_LD_REQ0) begin
            split_load_req_valid = 1'b1;
            split_load_req_addr  = {split_load_addr_r[63:3], 3'b000};
        end else if (split_load_state_r == SPLIT_LD_REQ1) begin
            split_load_req_valid = 1'b1;
            split_load_req_addr  =
                {split_load_addr_r[63:LINE_BITS] + 1'b1, {LINE_BITS{1'b0}}};
        end
    end

    always_comb begin
        split_load_fill_dword =
            dcache_fill_data[{split_load_wait_addr_r[5:3], 6'b000000} +: 64];
        split_load_resp_valid = 1'b0;
        split_load_resp_data  = 64'd0;
        if (dcache_load_resp_valid[0]) begin
            split_load_resp_valid = 1'b1;
            split_load_resp_data  = dcache_load_resp_data[0];
        end else if (dcache_fill_valid &&
                     (dcache_fill_addr[63:LINE_BITS] ==
                      split_load_wait_addr_r[63:LINE_BITS])) begin
            split_load_resp_valid = 1'b1;
            split_load_resp_data  = split_load_fill_dword;
        end
    end

    always_comb begin
        split_load_first_bytes =
            4'(7'd64 - {1'b0, split_load_addr_r[5:0]});
        split_load_merged_raw =
            (split_load_first_dword_r >>
             ({3'b000, split_load_addr_r[2:0]} * 4'd8)) |
            (split_load_second_dword_r <<
             ({3'b000, split_load_first_bytes} * 4'd8));
        case (split_load_data_r.mem_size)
            MEM_BYTE:  split_load_result = split_load_data_r.is_unsigned
                        ? {56'b0, split_load_merged_raw[7:0]}
                        : {{56{split_load_merged_raw[7]}}, split_load_merged_raw[7:0]};
            MEM_HALF:  split_load_result = split_load_data_r.is_unsigned
                        ? {48'b0, split_load_merged_raw[15:0]}
                        : {{48{split_load_merged_raw[15]}}, split_load_merged_raw[15:0]};
            MEM_WORD:  split_load_result = split_load_data_r.is_unsigned
                        ? {32'b0, split_load_merged_raw[31:0]}
                        : {{32{split_load_merged_raw[31]}}, split_load_merged_raw[31:0]};
            default:   split_load_result = split_load_merged_raw;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            split_load_state_r        <= SPLIT_LD_IDLE;
            split_load_data_r         <= '0;
            split_load_addr_r         <= 64'd0;
            split_load_wait_addr_r    <= 64'd0;
            split_load_first_dword_r  <= 64'd0;
            split_load_second_dword_r <= 64'd0;
        end else if (flush_in.valid) begin
            split_load_state_r <= SPLIT_LD_IDLE;
        end else begin
            case (split_load_state_r)
                SPLIT_LD_IDLE: begin
                    if (split_load_start) begin
                        split_load_state_r <= SPLIT_LD_REQ0;
                        split_load_data_r  <= load_issue_data[0];
                        split_load_addr_r  <= load_mem_addr[0];
                    end
                end

                SPLIT_LD_REQ0: begin
                    split_load_wait_addr_r <= split_load_req_addr;
                    split_load_state_r     <= SPLIT_LD_WAIT0;
                end

                SPLIT_LD_WAIT0: begin
                    if (split_load_resp_valid) begin
                        split_load_first_dword_r <= split_load_resp_data;
                        split_load_state_r       <= SPLIT_LD_REQ1;
                    end
                end

                SPLIT_LD_REQ1: begin
                    split_load_wait_addr_r <= split_load_req_addr;
                    split_load_state_r     <= SPLIT_LD_WAIT1;
                end

                SPLIT_LD_WAIT1: begin
                    if (split_load_resp_valid) begin
                        split_load_second_dword_r <= split_load_resp_data;
                        split_load_state_r        <= SPLIT_LD_WB;
                    end
                end

                SPLIT_LD_WB: begin
                    if (split_load_wb_fire)
                        split_load_state_r <= SPLIT_LD_IDLE;
                end

                default: split_load_state_r <= SPLIT_LD_IDLE;
            endcase
        end
    end

    assign dcache_load_req_valid[0] = split_load_req_valid |
                                      (load_issue_valid[0]
                                       & ~load_addr_misaligned[0]
                                       & ~load_cross_line[0]
                                       & ~split_load_busy
                                       & ~load_addr_mmio[0]
                                       & ~p0_fwd_hit
                                       & ~p0_partial_fwd_wait
                                       & ~(load_issue_data[0].is_amo &&
                                           (load_issue_data[0].amo_op == AMO_SC))
                                       & ~flush_in.valid);
    assign dcache_load_req_addr[0]  = split_load_req_valid
                                    ? split_load_req_addr
                                    : load_mem_addr[0];
    assign dcache_load_req_size[0]  = split_load_req_valid
                                    ? MEM_DWORD
                                    : load_issue_data[0].mem_size;
    assign dcache_load_req_is_unsigned[0] = split_load_req_valid
                                          ? 1'b1
                                          : load_issue_data[0].is_unsigned;

    assign dcache_load_req_valid[1] = p1_eff_valid
                                    & ~p1_eff_misalign
                                    & ~p1_eff_addr_mmio
                                    & ~p1_any_fwd_hit
                                    & ~p1_partial_fwd_wait
                                    & ~flush_in.valid;
    assign dcache_load_req_addr[1]  = p1_eff_addr;
    assign dcache_load_req_size[1]  = p1_eff_data.mem_size;
    assign dcache_load_req_is_unsigned[1] = p1_eff_data.is_unsigned;

    assign spec_wakeup_valid[0] = dcache_load_req_valid[0] &
                                  !split_load_req_valid &
                                  ~load_issue_data[0].is_amo;
    assign spec_wakeup_tag[0]   = load_issue_data[0].pdst;
    assign spec_wakeup_valid[1] = dcache_load_req_valid[1] &
                                  ~p1_eff_data.is_amo;
    assign spec_wakeup_tag[1]   = p1_eff_data.pdst;

    // =========================================================================
    // Load data extraction and sign/zero extension
    // =========================================================================
    // D-cache returns 64-bit aligned data. Extract correct bytes based on
    // addr[2:0] and size, then sign/zero extend.  Separate extract paths:
    //   - Forwarding / misalign (same cycle as issue): uses _current_ metadata
    //   - D-cache hit (2 cycles after issue): uses _rr_ metadata
    // A mux below in load_wb selects between them.
    logic [63:0] load_extracted_fwd [0:1];  // same-cycle (forwarding/misalign)
    logic [63:0] load_extracted_dc  [0:1];  // 2-cycle delayed (dcache hit)
    logic [63:0] p1_extracted_fwd;

    generate
        for (li = 0; li < 2; li++) begin : gen_load_extract
            // ---- Forwarding / misalign path (current cycle) ----
            // Forwarding data is already byte-positioned in the memory dword
            // (byte b at position b*8 +: 8).  The extraction shifts right
            // by the load's byte offset to LSB-align the requested bytes.
            logic [63:0] fwd_raw;
            logic [63:0] fwd_shifted;
            always_comb begin
                if (li == 0 && p0_fwd_hit) begin
                    // Priority: same_cycle > SQ > CSB (youngest wins)
                    if (same_cycle_fwd_hit)
                        fwd_raw = same_cycle_fwd_data;
                    else if (sq_fwd_hit)
                        fwd_raw = sq_fwd_data;
                    else if (csb_enq_fwd_hit)
                        fwd_raw = csb_enq_fwd_data;
                    else
                        fwd_raw = csb_fwd_data;
                end else begin
                    fwd_raw = '0;
                end
                fwd_shifted = fwd_raw >> ({3'b0, load_eff_addr[li][2:0]} * 4'd8);
                case (load_issue_data[li].mem_size)
                    MEM_BYTE: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {56'b0, fwd_shifted[7:0]}
                                : {{56{fwd_shifted[7]}}, fwd_shifted[7:0]};
                    MEM_HALF: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {48'b0, fwd_shifted[15:0]}
                                : {{48{fwd_shifted[15]}}, fwd_shifted[15:0]};
                    MEM_WORD: load_extracted_fwd[li] = load_issue_data[li].is_unsigned
                                ? {32'b0, fwd_shifted[31:0]}
                                : {{32{fwd_shifted[31]}}, fwd_shifted[31:0]};
                    default:  load_extracted_fwd[li] = fwd_shifted;
                endcase
            end

            // ---- D-cache hit path (2 cycles after issue) ----
            // The dcache already extracts, sign/zero extends, and LSB-aligns
            // its response based on the load's size and byte offset.
            // Pass it through unchanged -- a second extraction here
            // would shift it again and corrupt non-dword-aligned loads.
            assign load_extracted_dc[li] = dcache_load_resp_data[li];
        end
    endgenerate

    always_comb begin
        logic [63:0] p1_fwd_shifted;

        p1_fwd_shifted =
            (sq_fwd_hit_p1 ? sq_fwd_data_p1
                            : (csb_enq_fwd_hit_p1 ? csb_enq_fwd_data_p1
                                                   : csb_fwd_data_p1))
            >> ({3'b0, p1_eff_addr[2:0]} * 4'd8);
        case (p1_eff_data.mem_size)
            MEM_BYTE: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {56'b0, p1_fwd_shifted[7:0]}
                        : {{56{p1_fwd_shifted[7]}}, p1_fwd_shifted[7:0]};
            MEM_HALF: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {48'b0, p1_fwd_shifted[15:0]}
                        : {{48{p1_fwd_shifted[15]}}, p1_fwd_shifted[15:0]};
            MEM_WORD: p1_extracted_fwd = p1_eff_data.is_unsigned
                        ? {32'b0, p1_fwd_shifted[31:0]}
                        : {{32{p1_fwd_shifted[31]}}, p1_fwd_shifted[31:0]};
            default:  p1_extracted_fwd = p1_fwd_shifted;
        endcase
    end

    // =========================================================================
    // Atomic memory operations
    // =========================================================================
    // AMOs are serialized at the load issue boundary and execute through a
    // small non-speculative read modify write engine.  The load side reads the
    // old value, this block computes the updated value, the store side writes
    // it back to D-cache, then the old value or SC status writes back to rd.
    logic        lr_valid_r;
    logic [63:0] lr_addr_r;
    logic [1:0]  lr_size_r;
    logic        lr_store_clear;
    logic        amo_sc_success;
    logic [63:0] amo_fill_dword;
    logic [63:0] amo_fill_shifted;
    logic [63:0] amo_fill_extracted;
    logic [63:0] amo_load_value;
    logic [31:0] amo_old_word;
    logic [31:0] amo_rs2_word;
    logic [31:0] amo_new_word;
    logic signed [31:0] amo_old_word_s;
    logic signed [31:0] amo_rs2_word_s;
    logic signed [63:0] amo_old_dword_s;
    logic signed [63:0] amo_rs2_dword_s;
    logic [63:0] amo_new_dword;
    logic [63:0] amo_store_data_calc;
    logic [7:0]  amo_store_mask_calc;
    logic [63:0] amo_sc_store_data_calc;
    logic [7:0]  amo_sc_store_mask_calc;

    assign amo_load_hit_fire =
        amo_wait_load_r &&
        dcache_load_resp_valid[0] &&
        load_issue_valid_r[0] &&
        load_issue_data_r[0].is_amo;
    assign amo_load_fill_fire =
        amo_wait_load_r &&
        !amo_load_hit_fire &&
        dcache_fill_valid &&
        (amo_addr_r[63:LINE_BITS] == dcache_fill_addr[63:LINE_BITS]);
    assign amo_store_ack_fire = amo_store_valid_r && dcache_store_ack;
    assign amo_sc_success =
        lr_valid_r &&
        (lr_addr_r[63:2] == load_mem_addr[0][63:2]) &&
        (lr_size_r == load_issue_data[0].mem_size);
    assign lr_store_clear =
        lr_valid_r &&
        dcache_store_req_valid &&
        dcache_store_ack &&
        (dcache_store_req_addr[63:2] == lr_addr_r[63:2]);

    always_comb begin
        amo_fill_dword   = dcache_fill_data[{amo_addr_r[5:3], 3'b000} * 8 +: 64];
        amo_fill_shifted = amo_fill_dword >> ({3'b0, amo_addr_r[2:0]} * 4'd8);
        case (amo_data_r.mem_size)
            MEM_WORD:  amo_fill_extracted = {{32{amo_fill_shifted[31]}}, amo_fill_shifted[31:0]};
            default:   amo_fill_extracted = amo_fill_shifted;
        endcase
    end

    assign amo_load_value = amo_load_hit_fire ? load_extracted_dc[0] : amo_fill_extracted;
    assign amo_old_word   = amo_load_value[31:0];
    assign amo_rs2_word   = amo_rs2_r[31:0];
    assign amo_old_word_s = amo_old_word;
    assign amo_rs2_word_s = amo_rs2_word;
    assign amo_old_dword_s = amo_load_value;
    assign amo_rs2_dword_s = amo_rs2_r;

    always_comb begin
        amo_new_word = amo_rs2_word;
        case (amo_data_r.amo_op)
            AMO_SWAP: amo_new_word = amo_rs2_word;
            AMO_ADD:  amo_new_word = amo_old_word + amo_rs2_word;
            AMO_XOR:  amo_new_word = amo_old_word ^ amo_rs2_word;
            AMO_AND:  amo_new_word = amo_old_word & amo_rs2_word;
            AMO_OR:   amo_new_word = amo_old_word | amo_rs2_word;
            AMO_MIN:  amo_new_word = (amo_old_word_s < amo_rs2_word_s) ? amo_old_word : amo_rs2_word;
            AMO_MAX:  amo_new_word = (amo_old_word_s > amo_rs2_word_s) ? amo_old_word : amo_rs2_word;
            AMO_MINU: amo_new_word = (amo_old_word < amo_rs2_word) ? amo_old_word : amo_rs2_word;
            AMO_MAXU: amo_new_word = (amo_old_word > amo_rs2_word) ? amo_old_word : amo_rs2_word;
            default:  amo_new_word = amo_rs2_word;
        endcase
    end

    always_comb begin
        amo_new_dword = amo_rs2_r;
        case (amo_data_r.amo_op)
            AMO_SWAP: amo_new_dword = amo_rs2_r;
            AMO_ADD:  amo_new_dword = amo_load_value + amo_rs2_r;
            AMO_XOR:  amo_new_dword = amo_load_value ^ amo_rs2_r;
            AMO_AND:  amo_new_dword = amo_load_value & amo_rs2_r;
            AMO_OR:   amo_new_dword = amo_load_value | amo_rs2_r;
            AMO_MIN:  amo_new_dword = (amo_old_dword_s < amo_rs2_dword_s) ? amo_load_value : amo_rs2_r;
            AMO_MAX:  amo_new_dword = (amo_old_dword_s > amo_rs2_dword_s) ? amo_load_value : amo_rs2_r;
            AMO_MINU: amo_new_dword = (amo_load_value < amo_rs2_r) ? amo_load_value : amo_rs2_r;
            AMO_MAXU: amo_new_dword = (amo_load_value > amo_rs2_r) ? amo_load_value : amo_rs2_r;
            default:  amo_new_dword = amo_rs2_r;
        endcase
    end

    always_comb begin
        case (amo_data_r.mem_size)
            MEM_WORD: begin
                amo_store_data_calc = {32'd0, amo_new_word};
                amo_store_mask_calc = 8'h0F;
            end
            default: begin
                amo_store_data_calc = amo_new_dword;
                amo_store_mask_calc = 8'hFF;
            end
        endcase
    end

    always_comb begin
        case (load_issue_data[0].mem_size)
            MEM_WORD: begin
                amo_sc_store_data_calc = {32'd0, load_rs2[0][31:0]};
                amo_sc_store_mask_calc = 8'h0F;
            end
            default: begin
                amo_sc_store_data_calc = load_rs2[0];
                amo_sc_store_mask_calc = 8'hFF;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_wait_load_r     <= 1'b0;
            amo_store_valid_r   <= 1'b0;
            amo_wb_valid_r      <= 1'b0;
            amo_data_r          <= '0;
            amo_addr_r          <= 64'd0;
            amo_rs2_r           <= 64'd0;
            amo_old_value_r     <= 64'd0;
            amo_store_data_r    <= 64'd0;
            amo_store_mask_r    <= 8'd0;
            amo_wb_rob_idx_r    <= '0;
            amo_wb_pdst_r       <= '0;
            amo_wb_lq_idx_r     <= '0;
            amo_wb_data_r       <= 64'd0;
            lr_valid_r          <= 1'b0;
            lr_addr_r           <= 64'd0;
            lr_size_r           <= MEM_DWORD;
        end else if (amo_flush_kill) begin
            amo_wait_load_r     <= 1'b0;
            amo_store_valid_r   <= 1'b0;
            amo_wb_valid_r      <= 1'b0;
            if (flush_in.full_flush)
                lr_valid_r <= 1'b0;
        end else begin
            if (amo_wb_valid_r)
                amo_wb_valid_r <= 1'b0;

            if (lr_store_clear)
                lr_valid_r <= 1'b0;

            if (amo_store_ack_fire) begin
                amo_store_valid_r <= 1'b0;
                amo_wb_valid_r    <= 1'b1;
                amo_wb_rob_idx_r  <= amo_data_r.rob_idx;
                amo_wb_pdst_r     <= amo_data_r.pdst;
                amo_wb_lq_idx_r   <= amo_data_r.lq_idx;
                amo_wb_data_r     <= (amo_data_r.amo_op == AMO_SC) ? 64'd0 : amo_old_value_r;
            end

            if (amo_load_hit_fire || amo_load_fill_fire) begin
                amo_wait_load_r <= 1'b0;
                amo_old_value_r <= amo_load_value;
                if (amo_data_r.amo_op == AMO_LR) begin
                    lr_valid_r       <= 1'b1;
                    lr_addr_r        <= amo_addr_r;
                    lr_size_r        <= amo_data_r.mem_size;
                    amo_wb_valid_r   <= 1'b1;
                    amo_wb_rob_idx_r <= amo_data_r.rob_idx;
                    amo_wb_pdst_r    <= amo_data_r.pdst;
                    amo_wb_lq_idx_r  <= amo_data_r.lq_idx;
                    amo_wb_data_r    <= amo_load_value;
                end else begin
                    amo_store_valid_r <= 1'b1;
                    amo_store_data_r  <= amo_store_data_calc;
                    amo_store_mask_r  <= amo_store_mask_calc;
                end
            end

            if (amo_sc_issue_fire) begin
                amo_data_r <= load_issue_data[0];
                amo_addr_r <= load_mem_addr[0];
                amo_rs2_r  <= load_rs2[0];
                lr_valid_r <= 1'b0;
                if (amo_sc_success) begin
                    amo_store_valid_r <= 1'b1;
                    amo_store_data_r  <= amo_sc_store_data_calc;
                    amo_store_mask_r  <= amo_sc_store_mask_calc;
                end else begin
                    amo_wb_valid_r   <= 1'b1;
                    amo_wb_rob_idx_r <= load_issue_data[0].rob_idx;
                    amo_wb_pdst_r    <= load_issue_data[0].pdst;
                    amo_wb_lq_idx_r  <= load_issue_data[0].lq_idx;
                    amo_wb_data_r    <= 64'd1;
                end
            end else if (amo_load_issue_fire) begin
                amo_wait_load_r <= 1'b1;
                amo_data_r      <= load_issue_data[0];
                amo_addr_r      <= load_mem_addr[0];
                amo_rs2_r       <= load_rs2[0];
            end
        end
    end

    // =========================================================================
    // Load Miss Buffer (LMB)
    // =========================================================================
    // When a load misses the D-cache, the cache currently never generates a
    // second (late) response; the fill eventually installs the line but the
    // original load is lost.  We track pending misses here and resolve them
    // by snooping the L2 → D-cache fill response directly.
    //
    // Each entry holds the load metadata and the line-aligned miss address.
    // When a fill arrives whose line matches an entry, we extract the
    // requested bytes from the fill data and generate a CDB writeback for
    // that load.  The LMB is a simple, free-list-allocated array.
    // =========================================================================
    localparam int LMB_DEPTH    = 32;
    localparam int LMB_IDX_BITS = $clog2(LMB_DEPTH);

    typedef struct packed {
        logic                       valid;
        logic                       ready;         // fill data captured, waiting for WB port
        logic [63:0]                line_addr;     // address aligned to LINE_SIZE
        logic [5:0]                 byte_offset;   // byte offset within the line
        logic [1:0]                 size;          // mem_size_e
        logic                       is_unsigned;
        logic [ROB_IDX_BITS-1:0]    rob_idx;
        logic [PHYS_REG_BITS-1:0]   pdst;
        logic [LQ_IDX_BITS-1:0]     lq_idx;
        logic [63:0]                data;
`ifdef SIMULATION
        logic [63:0]                pc;
`endif
    } lmb_entry_t;

    lmb_entry_t lmb [0:LMB_DEPTH-1];

    function automatic logic [63:0] lmb_extract_from_fill(
        input logic [LINE_SIZE*8-1:0] fill_data,
        input logic [5:0]             byte_offset,
        input logic [1:0]             size,
        input logic                   is_unsigned
    );
        logic [63:0] fill_dword;
        logic [63:0] fill_shifted;
        begin
            fill_dword = fill_data[{byte_offset[5:3], 3'b000} * 8 +: 64];
            fill_shifted = fill_dword >> ({3'b0, byte_offset[2:0]} * 4'd8);
            case (size)
                MEM_BYTE: lmb_extract_from_fill = is_unsigned
                            ? {56'b0, fill_shifted[7:0]}
                            : {{56{fill_shifted[7]}}, fill_shifted[7:0]};
                MEM_HALF: lmb_extract_from_fill = is_unsigned
                            ? {48'b0, fill_shifted[15:0]}
                            : {{48{fill_shifted[15]}}, fill_shifted[15:0]};
                MEM_WORD: lmb_extract_from_fill = is_unsigned
                            ? {32'b0, fill_shifted[31:0]}
                            : {{32{fill_shifted[31]}}, fill_shifted[31:0]};
                default:  lmb_extract_from_fill = fill_shifted;
            endcase
        end
    endfunction

    // Miss detection: a load issued 1 cycle ago whose cache path did not
    // produce a response this cycle and which wasn't handled via forwarding
    // or the misalign exception path.
    logic p0_miss_detect;
    logic p1_miss_detect;
    logic p0_miss_fill_hit;
    logic p1_miss_fill_hit;
    logic [LINE_SIZE*8-1:0] p0_miss_fill_data;
    logic [LINE_SIZE*8-1:0] p1_miss_fill_data;
    assign p1_miss_retry_req = !flush_in.valid
                             & load_issue_valid_r[1]
                             & ~load_nocache_r[1]
                             & ~load_issue_data_r[1].is_amo
                             & dcache_load_miss_retry[1];
    assign p0_miss_detect = !flush_in.valid
                          & load_issue_valid_r[0]
                          & ~load_nocache_r[0]
                          & ~load_issue_data_r[0].is_amo
                          & ~dcache_load_resp_valid[0];
    assign p1_miss_detect = !flush_in.valid
                          & load_issue_valid_r[1]
                          & ~load_nocache_r[1]
                          & ~load_issue_data_r[1].is_amo
                          & ~dcache_load_resp_valid[1]
                          & ~dcache_load_miss_retry[1];

    // D-cache can install a line before the two-cycle load-miss detection
    // stage sees that an older request missed.  Keep a tiny recent-fill
    // window so those late miss detections can capture the fill data instead
    // of allocating an LMB entry that will never see another fill.
    localparam int FILL_BYPASS_DEPTH = 4;
    logic fill_bypass_valid [0:FILL_BYPASS_DEPTH-1];
    logic [63:0] fill_bypass_addr [0:FILL_BYPASS_DEPTH-1];
    logic [LINE_SIZE*8-1:0] fill_bypass_data [0:FILL_BYPASS_DEPTH-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < FILL_BYPASS_DEPTH; i++) begin
                fill_bypass_valid[i] <= 1'b0;
                fill_bypass_addr[i]  <= 64'd0;
                fill_bypass_data[i]  <= '0;
            end
        end else begin
            for (int i = FILL_BYPASS_DEPTH-1; i > 0; i--) begin
                fill_bypass_valid[i] <= fill_bypass_valid[i-1];
                fill_bypass_addr[i]  <= fill_bypass_addr[i-1];
                fill_bypass_data[i]  <= fill_bypass_data[i-1];
            end
            fill_bypass_valid[0] <= dcache_fill_valid;
            fill_bypass_addr[0]  <= dcache_fill_addr;
            fill_bypass_data[0]  <= dcache_fill_data;
        end
    end

    always_comb begin
        p0_miss_fill_hit  = p0_miss_detect
                          & dcache_fill_valid
                          & (load_eff_addr_r[0][63:LINE_BITS]
                             == dcache_fill_addr[63:LINE_BITS]);
        p1_miss_fill_hit  = p1_miss_detect
                          & dcache_fill_valid
                          & (load_eff_addr_r[1][63:LINE_BITS]
                             == dcache_fill_addr[63:LINE_BITS]);
        p0_miss_fill_data = dcache_fill_data;
        p1_miss_fill_data = dcache_fill_data;

        for (int i = 0; i < FILL_BYPASS_DEPTH; i++) begin
            if (!p0_miss_fill_hit && p0_miss_detect &&
                fill_bypass_valid[i] &&
                (load_eff_addr_r[0][63:LINE_BITS] == fill_bypass_addr[i][63:LINE_BITS])) begin
                p0_miss_fill_hit  = 1'b1;
                p0_miss_fill_data = fill_bypass_data[i];
            end
            if (!p1_miss_fill_hit && p1_miss_detect &&
                fill_bypass_valid[i] &&
                (load_eff_addr_r[1][63:LINE_BITS] == fill_bypass_addr[i][63:LINE_BITS])) begin
                p1_miss_fill_hit  = 1'b1;
                p1_miss_fill_data = fill_bypass_data[i];
            end
        end
    end

    // Find a free LMB slot (lowest index).
    logic                     lmb_free_avail;
    logic [LMB_IDX_BITS-1:0]  lmb_free_idx;
    logic                     lmb_free2_avail;
    logic [LMB_IDX_BITS-1:0]  lmb_free2_idx;
    logic                     lmb_p1_alloc_avail;
    logic [LMB_IDX_BITS-1:0]  lmb_p1_alloc_idx;

    always_comb begin
        lmb_free_avail = 1'b0;
        lmb_free_idx   = '0;
        lmb_free2_avail = 1'b0;
        lmb_free2_idx   = '0;
        for (int i = 0; i < LMB_DEPTH; i++) begin
            if (!lmb[i].valid && !lmb_free_avail) begin
                lmb_free_avail = 1'b1;
                lmb_free_idx   = LMB_IDX_BITS'(i);
            end else if (!lmb[i].valid && !lmb_free2_avail) begin
                lmb_free2_avail = 1'b1;
                lmb_free2_idx   = LMB_IDX_BITS'(i);
            end
        end
        lmb_p1_alloc_avail = p0_miss_detect ? lmb_free2_avail : lmb_free_avail;
        lmb_p1_alloc_idx   = p0_miss_detect ? lmb_free2_idx   : lmb_free_idx;
    end

    // Match an incoming fill to an LMB entry (line-aligned compare).
    logic [LMB_DEPTH-1:0] lmb_fill_match;
    logic                 lmb_any_match;
    logic [LMB_IDX_BITS-1:0] lmb_match_idx;
    logic                 lmb_ready_any;
    logic [LMB_IDX_BITS-1:0] lmb_ready_idx;

    always_comb begin
        lmb_any_match = 1'b0;
        lmb_match_idx = '0;
        lmb_ready_any = 1'b0;
        lmb_ready_idx = '0;
        lmb_any_valid = 1'b0;
        for (int i = 0; i < LMB_DEPTH; i++) begin
            if (lmb[i].valid)
                lmb_any_valid = 1'b1;
            lmb_fill_match[i] = lmb[i].valid
                              & !lmb[i].ready
                              & dcache_fill_valid
                              & (lmb[i].line_addr[63:LINE_BITS]
                                 == dcache_fill_addr[63:LINE_BITS]);
            if (lmb_fill_match[i] && !lmb_any_match) begin
                lmb_any_match = 1'b1;
                lmb_match_idx = LMB_IDX_BITS'(i);
            end
            if (lmb[i].valid && lmb[i].ready && !lmb_ready_any) begin
                lmb_ready_any = 1'b1;
                lmb_ready_idx = LMB_IDX_BITS'(i);
            end
        end
    end

`ifdef SIMULATION
    logic lsu_stat_en;
    logic lsu_trace_lmb_hot;
    integer lsu_lmb_cyc;
    integer lsu_lmb_occ_now;
    integer lsu_lmb_max_occ;
    integer lsu_lmb_full_cyc;
    integer lsu_lmb_p0_miss_cnt;
    integer lsu_lmb_p1_miss_cnt;
    integer lsu_lmb_p0_alloc_cnt;
    integer lsu_lmb_p1_alloc_cnt;
    integer lsu_lmb_fill_match_cnt;
    integer lsu_lmb_ready_wb_cnt;
    integer lsu_lmb_drop_full_cnt;
    integer lsu_lmb_drop_dual_cnt;
    integer lsu_lmb_alloc_ready_cnt;
    integer lsu_fwd_hold_blocked_cnt;
    integer lsu_lmb_wb_blocked_cnt;

    initial lsu_stat_en =
        ($test$plusargs("PERF_PROFILE") || $test$plusargs("STAT_DUMP")) ? 1'b1 : 1'b0;
    initial lsu_trace_lmb_hot = $test$plusargs("TRACE_LMB_HOT") ? 1'b1 : 1'b0;

    function automatic logic lsu_hot_load_pc(input logic [63:0] pc);
        lsu_hot_load_pc = (pc == 64'h0000_0000_8000_35f6) ||
                          (pc == 64'h0000_0000_8000_32c2) ||
                          (pc == 64'h0000_0000_8000_3976);
    endfunction

    always_comb begin
        lsu_lmb_occ_now = 0;
        for (int i = 0; i < LMB_DEPTH; i++) begin
            if (lmb[i].valid)
                lsu_lmb_occ_now++;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsu_lmb_cyc            <= 0;
            lsu_lmb_max_occ        <= 0;
            lsu_lmb_full_cyc       <= 0;
            lsu_lmb_p0_miss_cnt    <= 0;
            lsu_lmb_p1_miss_cnt    <= 0;
            lsu_lmb_p0_alloc_cnt   <= 0;
            lsu_lmb_p1_alloc_cnt   <= 0;
            lsu_lmb_fill_match_cnt <= 0;
            lsu_lmb_ready_wb_cnt    <= 0;
            lsu_lmb_drop_full_cnt  <= 0;
            lsu_lmb_drop_dual_cnt  <= 0;
            lsu_lmb_alloc_ready_cnt <= 0;
            lsu_fwd_hold_blocked_cnt <= 0;
            lsu_lmb_wb_blocked_cnt <= 0;
        end else if (lsu_stat_en) begin
            lsu_lmb_cyc <= lsu_lmb_cyc + 1;

            if (lsu_lmb_occ_now > lsu_lmb_max_occ)
                lsu_lmb_max_occ <= lsu_lmb_occ_now;
            if (lsu_lmb_occ_now == LMB_DEPTH)
                lsu_lmb_full_cyc <= lsu_lmb_full_cyc + 1;

            if (!flush_in.valid) begin
                if (p0_miss_detect)
                    lsu_lmb_p0_miss_cnt <= lsu_lmb_p0_miss_cnt + 1;
                if (p1_miss_detect)
                    lsu_lmb_p1_miss_cnt <= lsu_lmb_p1_miss_cnt + 1;

                if (p0_miss_detect && lmb_free_avail)
                    lsu_lmb_p0_alloc_cnt <= lsu_lmb_p0_alloc_cnt + 1;
                else if (p0_miss_detect && !lmb_free_avail)
                    lsu_lmb_drop_full_cnt <= lsu_lmb_drop_full_cnt + 1;

                if (p1_miss_detect && lmb_p1_alloc_avail)
                    lsu_lmb_p1_alloc_cnt <= lsu_lmb_p1_alloc_cnt + 1;
                else if (p0_miss_detect && p1_miss_detect)
                    lsu_lmb_drop_dual_cnt <= lsu_lmb_drop_dual_cnt + 1;
                else if (p1_miss_detect && !lmb_p1_alloc_avail)
                    lsu_lmb_drop_full_cnt <= lsu_lmb_drop_full_cnt + 1;

                if ((p0_miss_fill_hit && lmb_free_avail) ||
                    (p1_miss_fill_hit && lmb_p1_alloc_avail))
                    lsu_lmb_alloc_ready_cnt <= lsu_lmb_alloc_ready_cnt +
                        ((p0_miss_fill_hit && lmb_free_avail) ? 1 : 0) +
                        ((p1_miss_fill_hit && lmb_p1_alloc_avail) ? 1 : 0);
            end

            if (lmb_any_match)
                lsu_lmb_fill_match_cnt <= lsu_lmb_fill_match_cnt + 1;
            if (lmb_wb_port_free && !lmb_any_match && lmb_ready_any)
                lsu_lmb_ready_wb_cnt <= lsu_lmb_ready_wb_cnt + 1;
            if (fwd_hold_blocked)
                lsu_fwd_hold_blocked_cnt <= lsu_fwd_hold_blocked_cnt + 1;
            if (!lmb_wb_port_free && (lmb_any_match || lmb_ready_any))
                lsu_lmb_wb_blocked_cnt <= lsu_lmb_wb_blocked_cnt + 1;
        end
    end

    final begin
        if (lsu_stat_en) begin
            $display("");
            $display("=== LSU LMB SUMMARY ===");
            $display("Cycles sampled:             %0d", lsu_lmb_cyc);
            $display("Max occupied/full cycles:   %0d / %0d", lsu_lmb_max_occ, lsu_lmb_full_cyc);
            $display("Miss detect p0/p1:          %0d / %0d", lsu_lmb_p0_miss_cnt, lsu_lmb_p1_miss_cnt);
            $display("Alloc p0/p1:                %0d / %0d", lsu_lmb_p0_alloc_cnt, lsu_lmb_p1_alloc_cnt);
            $display("Fill matches:               %0d", lsu_lmb_fill_match_cnt);
            $display("Ready drains:               %0d", lsu_lmb_ready_wb_cnt);
            $display("Alloc ready from same fill:  %0d", lsu_lmb_alloc_ready_cnt);
            $display("Dropped full/dual:          %0d / %0d", lsu_lmb_drop_full_cnt, lsu_lmb_drop_dual_cnt);
            $display("Fwd-hold blocked cycles:    %0d", lsu_fwd_hold_blocked_cnt);
            $display("LMB WB blocked cycles:      %0d", lsu_lmb_wb_blocked_cnt);
        end
    end

    always_ff @(posedge clk) begin
        if (lsu_trace_lmb_hot) begin
            if (p0_miss_detect && lsu_hot_load_pc(load_issue_data_r[0].pc)) begin
                $display("[LMB_HOT] cyc=%0d alloc_req p0 pc=%016h rob=%0d addr=%016h free=%b fillhit=%b flush=%b",
                    lsu_lmb_cyc, load_issue_data_r[0].pc, load_issue_data_r[0].rob_idx,
                    load_eff_addr_r[0], lmb_free_avail, p0_miss_fill_hit, flush_in.valid);
            end
            if (p1_miss_detect && lsu_hot_load_pc(load_issue_data_r[1].pc)) begin
                $display("[LMB_HOT] cyc=%0d alloc_req p1 pc=%016h rob=%0d addr=%016h free=%b fillhit=%b flush=%b",
                    lsu_lmb_cyc, load_issue_data_r[1].pc, load_issue_data_r[1].rob_idx,
                    load_eff_addr_r[1], lmb_p1_alloc_avail, p1_miss_fill_hit, flush_in.valid);
            end
            if (lmb_wb_port_free && lmb_any_match && lsu_hot_load_pc(lmb[lmb_match_idx].pc)) begin
                $display("[LMB_HOT] cyc=%0d fill_wb pc=%016h rob=%0d line=%016h fill=%016h",
                    lsu_lmb_cyc, lmb[lmb_match_idx].pc, lmb[lmb_match_idx].rob_idx,
                    lmb[lmb_match_idx].line_addr, dcache_fill_addr);
            end
            if (lmb_wb_port_free && !lmb_any_match && lmb_ready_any && lsu_hot_load_pc(lmb[lmb_ready_idx].pc)) begin
                $display("[LMB_HOT] cyc=%0d ready_wb pc=%016h rob=%0d line=%016h",
                    lsu_lmb_cyc, lmb[lmb_ready_idx].pc, lmb[lmb_ready_idx].rob_idx,
                    lmb[lmb_ready_idx].line_addr);
            end
            if (flush_in.valid && flush_in.full_flush) begin
                for (int i = 0; i < LMB_DEPTH; i++) begin
                    if (lmb[i].valid && lsu_hot_load_pc(lmb[i].pc)) begin
                        $display("[LMB_HOT] cyc=%0d flush_clear pc=%016h rob=%0d line=%016h ready=%b redirect=%016h",
                            lsu_lmb_cyc, lmb[i].pc, lmb[i].rob_idx,
                            lmb[i].line_addr, lmb[i].ready, flush_in.redirect_pc);
                    end
                end
            end
            if (p0_dcache_hit_valid && lsu_hot_load_pc(load_issue_data_r[0].pc)) begin
                $display("[LMB_HOT] cyc=%0d dcache_wb p0 pc=%016h rob=%0d addr=%016h flush=%b",
                    lsu_lmb_cyc, load_issue_data_r[0].pc, load_issue_data_r[0].rob_idx,
                    load_eff_addr_r[0], flush_in.valid);
            end
            if ((dcache_load_resp_valid[1] && load_issue_valid_r[1] && !load_nocache_r[1]) &&
                lsu_hot_load_pc(load_issue_data_r[1].pc)) begin
                $display("[LMB_HOT] cyc=%0d dcache_wb p1 pc=%016h rob=%0d addr=%016h flush=%b",
                    lsu_lmb_cyc, load_issue_data_r[1].pc, load_issue_data_r[1].rob_idx,
                    load_eff_addr_r[1], flush_in.valid);
            end
        end
    end
`endif

    // Extract bytes from the fill line based on the matched entry's offset.
    // The fill data is LINE_SIZE*8 bits (512 bits).  We extract a 64-bit
    // aligned dword using the entry's [5:3] index, then sign/zero extend
    // using [2:0] byte offset + size.
    logic [63:0] lmb_extracted;
    assign lmb_extracted = lmb_extract_from_fill(
        dcache_fill_data,
        lmb[lmb_match_idx].byte_offset,
        lmb[lmb_match_idx].size,
        lmb[lmb_match_idx].is_unsigned
    );

    // =========================================================================
    // LMB sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < LMB_DEPTH; i++) begin
                lmb[i].valid <= 1'b0;
                lmb[i].ready <= 1'b0;
            end
        end else if (flush_in.valid && flush_in.full_flush) begin
            // Full flush: drop all speculative pending misses.
            for (int i = 0; i < LMB_DEPTH; i++) begin
                lmb[i].valid <= 1'b0;
                lmb[i].ready <= 1'b0;
            end
        end else begin
            // Allocate on miss detection.  Both load ports can allocate in
            // the same cycle when two LMB slots are free; otherwise port 0
            // has priority.
            if (p0_miss_detect && lmb_free_avail) begin
                lmb[lmb_free_idx].valid        <= 1'b1;
                lmb[lmb_free_idx].ready        <= p0_miss_fill_hit;
                lmb[lmb_free_idx].line_addr    <=
                    {load_eff_addr_r[0][63:LINE_BITS], {LINE_BITS{1'b0}}};
                lmb[lmb_free_idx].byte_offset  <= load_eff_addr_r[0][5:0];
                lmb[lmb_free_idx].size         <= load_issue_data_r[0].mem_size;
                lmb[lmb_free_idx].is_unsigned  <= load_issue_data_r[0].is_unsigned;
                lmb[lmb_free_idx].rob_idx      <= load_issue_data_r[0].rob_idx;
                lmb[lmb_free_idx].pdst         <= load_issue_data_r[0].pdst;
                lmb[lmb_free_idx].lq_idx       <= load_issue_data_r[0].lq_idx;
                lmb[lmb_free_idx].data         <= p0_miss_fill_hit
                    ? lmb_extract_from_fill(
                        p0_miss_fill_data,
                        load_eff_addr_r[0][5:0],
                        load_issue_data_r[0].mem_size,
                        load_issue_data_r[0].is_unsigned)
                    : '0;
`ifdef SIMULATION
                lmb[lmb_free_idx].pc           <= load_issue_data_r[0].pc;
`endif
            end
            if (p1_miss_detect && lmb_p1_alloc_avail) begin
                lmb[lmb_p1_alloc_idx].valid        <= 1'b1;
                lmb[lmb_p1_alloc_idx].ready        <= p1_miss_fill_hit;
                lmb[lmb_p1_alloc_idx].line_addr    <=
                    {load_eff_addr_r[1][63:LINE_BITS], {LINE_BITS{1'b0}}};
                lmb[lmb_p1_alloc_idx].byte_offset  <= load_eff_addr_r[1][5:0];
                lmb[lmb_p1_alloc_idx].size         <= load_issue_data_r[1].mem_size;
                lmb[lmb_p1_alloc_idx].is_unsigned  <= load_issue_data_r[1].is_unsigned;
                lmb[lmb_p1_alloc_idx].rob_idx      <= load_issue_data_r[1].rob_idx;
                lmb[lmb_p1_alloc_idx].pdst         <= load_issue_data_r[1].pdst;
                lmb[lmb_p1_alloc_idx].lq_idx       <= load_issue_data_r[1].lq_idx;
                lmb[lmb_p1_alloc_idx].data         <= p1_miss_fill_hit
                    ? lmb_extract_from_fill(
                        p1_miss_fill_data,
                        load_eff_addr_r[1][5:0],
                        load_issue_data_r[1].mem_size,
                        load_issue_data_r[1].is_unsigned)
                    : '0;
`ifdef SIMULATION
                lmb[lmb_p1_alloc_idx].pc           <= load_issue_data_r[1].pc;
`endif
            end

            // A fill can satisfy multiple missed loads to the same line.
            // The first match is written back immediately only when the load
            // writeback port is free.  If the port is occupied by a normal
            // D-cache hit or forwarding skid, all fill matches capture data
            // and remain valid/ready for a later drain.
            for (int i = 0; i < LMB_DEPTH; i++) begin
                if (lmb_fill_match[i]) begin
                    if (lmb_wb_port_free && (LMB_IDX_BITS'(i) == lmb_match_idx)) begin
                        lmb[i].valid <= 1'b0;
                        lmb[i].ready <= 1'b0;
                    end else begin
                        lmb[i].ready <= 1'b1;
                        lmb[i].data  <= lmb_extract_from_fill(
                            dcache_fill_data,
                            lmb[i].byte_offset,
                            lmb[i].size,
                            lmb[i].is_unsigned
                        );
                    end
                end
            end

            if (lmb_wb_port_free && !lmb_any_match && lmb_ready_any) begin
                lmb[lmb_ready_idx].valid <= 1'b0;
                lmb[lmb_ready_idx].ready <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Store-to-load forwarding hold register
    // =========================================================================
    // Delay forwarding writeback by 1 cycle to break the combinational loop:
    //   CDB → bypass → IQ → issue → load_eff_addr → SQ fwd → load_wb → CDB
    // The consumer reads from PRF (written at the next edge from this CDB).
    logic [ROB_IDX_BITS-1:0] fwd_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] fwd_hold_pdst_r;
    logic [63:0] fwd_hold_data_r;
    mem_size_e fwd_hold_mem_size_r;
    logic [LQ_IDX_BITS-1:0] fwd_hold_lq_idx_r;

    logic fwd_hold_is_exc_r;
    logic [ROB_IDX_BITS-1:0] p1_fwd_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] p1_fwd_hold_pdst_r;
    logic [63:0] p1_fwd_hold_data_r;
    mem_size_e p1_fwd_hold_mem_size_r;

    // Port-1 misalign-exception hold register (mirrors the port-0 fwd_hold
    // pattern). Original same-cycle path at the writeback mux was a
    // combinational leak: load_eff_addr[1] -> load_addr_misaligned[1] ->
    // load_wb_pdst[1] -> load_wb sideband -> IQ readiness (via spec_wk) ->
    // load_issue_valid[1] -> back to load_eff_addr[1]. Loop-buffer-driven
    // dispatch pressure amplifies the transient into a non-converging
    // delta-cycle loop on dsim (CoreMark iter>=2 hits IterLimit at cyc 316,161).
    // Registering breaks the loop at the cost of 1 cycle latency on the
    // (rare) misalign exception path.
    logic                     p1_misalign_hold_valid_r;
    logic [ROB_IDX_BITS-1:0]  p1_misalign_hold_rob_idx_r;
    logic [PHYS_REG_BITS-1:0] p1_misalign_hold_pdst_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in.valid) begin
            fwd_hold_valid_r  <= 1'b0;
            fwd_hold_is_exc_r <= 1'b0;
            fwd_hold_mem_size_r <= MEM_DWORD;
        end else if (fwd_hold_blocked) begin
            // Retain the delayed port-0 forward/misalign result until a load
            // CDB slot can accept it.  Dropping this skid entry leaves the
            // corresponding ROB load permanently not-ready.
            fwd_hold_valid_r  <= fwd_hold_valid_r;
            fwd_hold_is_exc_r <= fwd_hold_is_exc_r;
        end else begin
            // Capture ANY same-cycle load writeback (fwd OR misalign)
            // to eliminate all same-cycle CDB loops from load port 0.
            fwd_hold_valid_r   <= load_issue_valid[0] && !flush_in.valid
                                  && ((p0_fwd_hit && !load_issue_data[0].is_amo) ||
                                      load_addr_misaligned[0]);
            fwd_hold_is_exc_r  <= load_addr_misaligned[0];
            fwd_hold_rob_idx_r <= load_issue_data[0].rob_idx;
            fwd_hold_pdst_r    <= load_issue_data[0].pdst;
            fwd_hold_data_r    <= load_addr_misaligned[0] ? 64'd0 : load_extracted_fwd[0];
            fwd_hold_mem_size_r <= load_issue_data[0].mem_size;
            fwd_hold_lq_idx_r  <= load_issue_data[0].lq_idx;
        end
    end

    // Port-1 misalign hold capture/drain.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in.valid) begin
            p1_misalign_hold_valid_r <= 1'b0;
        end else begin
            if (p1_misalign_hold_valid_r) begin
                // Drains via writeback this cycle; clear at next edge.
                p1_misalign_hold_valid_r <= 1'b0;
            end
            if (!p1_misalign_hold_valid_r
                && load_issue_valid[1] && load_addr_misaligned[1]
                && !flush_in.valid) begin
                p1_misalign_hold_valid_r   <= 1'b1;
                p1_misalign_hold_rob_idx_r <= load_issue_data[1].rob_idx;
                p1_misalign_hold_pdst_r    <= load_issue_data[1].pdst;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_in.valid) begin
            p1_fwd_hold_valid_r <= 1'b0;
            p1_fwd_hold_mem_size_r <= MEM_DWORD;
        end else begin
            if (p1_fwd_hold_valid_r &&
                !(p1_misalign_hold_valid_r ||
                   (dcache_load_resp_valid[1] && load_issue_valid_r[1] &&
                    !load_nocache_r[1]) ||
                   (fwd_hold_valid_r && dcache_load_resp_valid[0] &&
                    load_issue_valid_r[0] && !load_nocache_r[0]))) begin
                p1_fwd_hold_valid_r <= 1'b0;
            end

            if (!p1_fast_fwd_fire &&
                !p1_fwd_hold_valid_r &&
                p1_eff_valid &&
                !p1_eff_misalign &&
                p1_any_fwd_hit &&
                !p1_sq_order_wait_block &&
                !flush_in.valid) begin
                p1_fwd_hold_valid_r   <= 1'b1;
                p1_fwd_hold_rob_idx_r <= p1_eff_data.rob_idx;
                p1_fwd_hold_pdst_r    <= p1_eff_data.pdst;
                p1_fwd_hold_data_r    <= p1_extracted_fwd;
                p1_fwd_hold_mem_size_r <= p1_eff_data.mem_size;
            end
        end
    end

    // =========================================================================
    // Load writeback to CDB
    // =========================================================================
    // Priority (Port 0):
    //   1. Misalign exception (same-cycle, rare — doesn't oscillate)
    //   2. Forwarding hold (1-cycle delayed SQ/CSB fwd)
        //   3. D-cache hit response (1-cycle delayed metadata)
    //   4. LMB fill match (late miss response)
    // Priority (Port 1):
    //   1. Misalign exception (1-cycle-delayed registered hold — was a
    //      same-cycle CDB-loop leak; see p1_misalign_hold_valid_r above)
    //   2. D-cache hit response
    //   3. Port-0 forwarded spill
    //   4. SQ-forward hold
    //
    // Note: only port 0 is wired to the LMB for now (single-port fill match).
    // =========================================================================
    assign split_load_wb_fire =
        (split_load_state_r == SPLIT_LD_WB) &&
        !flush_in.valid &&
        !amo_wb_valid_r &&
        !p0_dcache_hit_valid &&
        !fwd_hold_valid_r;

    always_comb begin
        // Default LQ index selector (drives lq_result_idx_sel)
        lq_result_idx_sel = '0;
        mmio_load_wb_fire = 1'b0;
        load_wb_mem_size[0] = MEM_DWORD;
        load_wb_mem_size[1] = MEM_DWORD;

        // Port 0 — no same-cycle paths.  Misalign + fwd both go through
        // the hold register (1-cycle delayed) to eliminate CDB loops.
        if (flush_in.valid) begin
            load_wb_valid[0]         = 1'b0;
            load_wb_rob_idx[0]       = '0;
            load_wb_pdst[0]          = '0;
            load_wb_data[0]          = '0;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
        end else if (amo_wb_valid_r) begin
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = amo_wb_rob_idx_r;
            load_wb_pdst[0]          = amo_wb_pdst_r;
            load_wb_data[0]          = amo_wb_data_r;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = amo_wb_lq_idx_r;
        end else if (p0_dcache_hit_valid) begin
            // D-cache hit response — 1 cycle after issue.
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = load_issue_data_r[0].rob_idx;
            load_wb_pdst[0]          = load_issue_data_r[0].pdst;
            load_wb_data[0]          = load_extracted_dc[0];
            load_wb_mem_size[0]      = load_issue_data_r[0].mem_size;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = load_issue_data_r[0].lq_idx;
        end else if (fwd_hold_valid_r) begin
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = fwd_hold_rob_idx_r;
            load_wb_pdst[0]          = fwd_hold_pdst_r;
            load_wb_data[0]          = fwd_hold_data_r;
            load_wb_mem_size[0]      = fwd_hold_mem_size_r;
            load_wb_has_exception[0] = fwd_hold_is_exc_r;
            load_wb_exc_code[0]      = fwd_hold_is_exc_r ? 4'd4 : 4'd0;
            lq_result_idx_sel        = fwd_hold_lq_idx_r;
        end else if (split_load_wb_fire) begin
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = split_load_data_r.rob_idx;
            load_wb_pdst[0]          = split_load_data_r.pdst;
            load_wb_data[0]          = split_load_result;
            load_wb_mem_size[0]      = split_load_data_r.mem_size;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = split_load_data_r.lq_idx;
        end else if (lmb_wb_port_free && lmb_any_match) begin
            // Late miss response from LMB (fill arrived).
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = lmb[lmb_match_idx].rob_idx;
            load_wb_pdst[0]          = lmb[lmb_match_idx].pdst;
            load_wb_data[0]          = lmb_extracted;
            load_wb_mem_size[0]      = mem_size_e'(lmb[lmb_match_idx].size);
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = lmb[lmb_match_idx].lq_idx;
        end else if (lmb_wb_port_free && lmb_ready_any) begin
            // A previous fill satisfied this miss, but the single LMB WB
            // port was busy with an older same-line match in that cycle.
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = lmb[lmb_ready_idx].rob_idx;
            load_wb_pdst[0]          = lmb[lmb_ready_idx].pdst;
            load_wb_data[0]          = lmb[lmb_ready_idx].data;
            load_wb_mem_size[0]      = mem_size_e'(lmb[lmb_ready_idx].size);
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = lmb[lmb_ready_idx].lq_idx;
        end else if (mmio_resp_hold_valid_r) begin
            load_wb_valid[0]         = 1'b1;
            load_wb_rob_idx[0]       = mmio_resp_load_data_r.rob_idx;
            load_wb_pdst[0]          = mmio_resp_load_data_r.pdst;
            load_wb_data[0]          = mmio_resp_ext;
            load_wb_mem_size[0]      = mmio_resp_load_data_r.mem_size;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
            lq_result_idx_sel        = mmio_resp_load_data_r.lq_idx;
            mmio_load_wb_fire        = 1'b1;
        end else begin
            load_wb_valid[0]         = 1'b0;
            load_wb_rob_idx[0]       = '0;
            load_wb_pdst[0]          = '0;
            load_wb_data[0]          = '0;
            load_wb_has_exception[0] = 1'b0;
            load_wb_exc_code[0]      = '0;
        end

        // Port 1
        if (flush_in.valid) begin
            load_wb_valid[1]         = 1'b0;
            load_wb_rob_idx[1]       = '0;
            load_wb_pdst[1]          = '0;
            load_wb_data[1]          = '0;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else if (p1_misalign_hold_valid_r) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = p1_misalign_hold_rob_idx_r;
            load_wb_pdst[1]          = p1_misalign_hold_pdst_r;
            load_wb_data[1]          = '0;
            load_wb_has_exception[1] = 1'b1;
            load_wb_exc_code[1]      = 4'd4;
        end else if (dcache_load_resp_valid[1] && load_issue_valid_r[1]
                     && !load_nocache_r[1]) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = load_issue_data_r[1].rob_idx;
            load_wb_pdst[1]          = load_issue_data_r[1].pdst;
            load_wb_data[1]          = load_extracted_dc[1];
            load_wb_mem_size[1]      = load_issue_data_r[1].mem_size;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else if (p1_fast_fwd_fire) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = p1_eff_data.rob_idx;
            load_wb_pdst[1]          = p1_eff_data.pdst;
            load_wb_data[1]          = p1_extracted_fwd;
            load_wb_mem_size[1]      = p1_eff_data.mem_size;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else if (p0_fwd_spill_to_p1) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = fwd_hold_rob_idx_r;
            load_wb_pdst[1]          = fwd_hold_pdst_r;
            load_wb_data[1]          = fwd_hold_data_r;
            load_wb_mem_size[1]      = fwd_hold_mem_size_r;
            load_wb_has_exception[1] = fwd_hold_is_exc_r;
            load_wb_exc_code[1]      = fwd_hold_is_exc_r ? 4'd4 : 4'd0;
        end else if (p1_fwd_hold_valid_r) begin
            load_wb_valid[1]         = 1'b1;
            load_wb_rob_idx[1]       = p1_fwd_hold_rob_idx_r;
            load_wb_pdst[1]          = p1_fwd_hold_pdst_r;
            load_wb_data[1]          = p1_fwd_hold_data_r;
            load_wb_mem_size[1]      = p1_fwd_hold_mem_size_r;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end else begin
            load_wb_valid[1]         = 1'b0;
            load_wb_rob_idx[1]       = '0;
            load_wb_pdst[1]          = '0;
            load_wb_data[1]          = '0;
            load_wb_has_exception[1] = 1'b0;
            load_wb_exc_code[1]      = '0;
        end
    end

    // =========================================================================
    // Speculative wakeup cancel on cache miss
    // =========================================================================
    // Speculative load wakeup is emitted when the D-cache request is issued.
    // One cycle later, cancel it if the request did not produce a hit response.
    generate
        for (li = 0; li < 2; li++) begin : gen_spec_cancel
            always_comb begin
                spec_cancel_valid[li] = 1'b0;
                spec_cancel_tag[li]   = '0;
                if (load_issue_valid_r[li] && !load_nocache_r[li] &&
                    !dcache_load_resp_valid[li] && !flush_in.valid) begin
                    spec_cancel_valid[li] = 1'b1;
                    spec_cancel_tag[li]   = load_issue_data_r[li].pdst;
                end
            end
        end
    endgenerate

`ifdef LSU_DEBUG
    // ---- DEBUG traces — only compiled when +define+LSU_DEBUG is passed.
    integer dbg_cycle = 0;
    always_ff @(posedge clk) begin
        dbg_cycle <= dbg_cycle + 1;
        if (load_issue_valid[0]) begin
            $display("[%0d] LSU issue[0]: rob=%0d pdst=%0d addr=%016h size=%0d unsigned=%0d fwd_hit=%b misalign=%b partial=%b flush=%b",
                dbg_cycle, load_issue_data[0].rob_idx, load_issue_data[0].pdst,
                load_eff_addr[0], load_issue_data[0].mem_size, load_issue_data[0].is_unsigned,
                p0_fwd_hit, load_addr_misaligned[0], sq_fwd_partial, flush_in.valid);
        end
        if (load_issue_valid[1]) begin
            $display("[%0d] LSU issue[1]: rob=%0d pdst=%0d addr=%016h size=%0d unsigned=%0d misalign=%b flush=%b",
                dbg_cycle, load_issue_data[1].rob_idx, load_issue_data[1].pdst,
                load_eff_addr[1], load_issue_data[1].mem_size, load_issue_data[1].is_unsigned,
                load_addr_misaligned[1], flush_in.valid);
        end
        if (load_wb_valid[0]) begin
            $display("[%0d] LSU wb[0]:    rob=%0d pdst=%0d data=%016h exc=%b",
                dbg_cycle, load_wb_rob_idx[0], load_wb_pdst[0],
                load_wb_data[0], load_wb_has_exception[0]);
        end
        if (load_wb_valid[1]) begin
            $display("[%0d] LSU wb[1]:    rob=%0d pdst=%0d data=%016h exc=%b",
                dbg_cycle, load_wb_rob_idx[1], load_wb_pdst[1],
                load_wb_data[1], load_wb_has_exception[1]);
        end
        if (sta_issue_valid) begin
            $display("[%0d] LSU STA:      rob=%0d addr=%016h size=%0d flush=%b",
                dbg_cycle, sta_issue_data.rob_idx, sta_eff_addr, sta_issue_data.mem_size, flush_in.valid);
        end
        if (std_issue_valid) begin
            $display("[%0d] LSU STD:      rob=%0d data=%016h mask=%02h",
                dbg_cycle, std_issue_data.rob_idx, std_rs2, std_byte_mask);
        end
        if (p0_miss_detect && lmb_free_avail) begin
            $display("[%0d] LSU LMB alloc: rob=%0d pdst=%0d line=%016h off=%0d",
                dbg_cycle, load_issue_data_r[0].rob_idx, load_issue_data_r[0].pdst,
                {load_eff_addr_r[0][63:LINE_BITS], {LINE_BITS{1'b0}}},
                load_eff_addr_r[0][5:0]);
        end
        if (dcache_fill_valid) begin
            $display("[%0d] LSU fill snoop: addr=%016h", dbg_cycle, dcache_fill_addr);
        end
        if (lmb_any_match) begin
            $display("[%0d] LSU LMB match[%0d]: rob=%0d data=%016h",
                dbg_cycle, lmb_match_idx, lmb[lmb_match_idx].rob_idx, lmb_extracted);
        end
        if (dcache_store_req_valid) begin
            $display("[%0d] LSU store->dcache: addr=%016h data=%016h mask=%02h",
                dbg_cycle, dcache_store_req_addr, dcache_store_req_data, dcache_store_req_byte_mask);
        end
        if (flush_in.valid) begin
            $display("[%0d] LSU FLUSH:    rob_idx=%0d full=%b redirect=%016h",
                dbg_cycle, flush_in.rob_idx, flush_in.full_flush, flush_in.redirect_pc);
        end
        if (ordering_violation) begin
            $display("[%0d] LSU ORDERING VIOL: load_rob=%0d (sta_rob=%0d sta_addr=%016h)",
                dbg_cycle, violation_rob_idx, sta_issue_data.rob_idx, sta_eff_addr);
        end
    end
`endif

`ifndef SYNTHESIS
    bit trace_stack_store;
    initial trace_stack_store = $test$plusargs("TRACE_STACK_STORE");

    function automatic logic trace_calc_func_pc(input logic [63:0] pc);
        trace_calc_func_pc = (pc >= 64'h00000000800022d0) &&
                             (pc <  64'h00000000800023d0);
    endfunction

    function automatic logic trace_stack_addr(input logic [63:0] addr);
        trace_stack_addr = (addr[63:12] == 52'h800ff);
    endfunction

    always_ff @(posedge clk) begin
        if (trace_stack_store) begin
            if (sta_issue_valid &&
                (trace_calc_func_pc(sta_issue_data.pc) || trace_stack_addr(sta_eff_addr))) begin
                $display("[LSU_STA_ISSUE] t=%0t pc=%016h rob=%0d sq=%0d rs1p=%0d rs1=%016h imm=%0d addr=%016h size=%0d flush=%0b",
                         $time, sta_issue_data.pc, sta_issue_data.rob_idx,
                         sta_issue_data.sq_idx, sta_issue_data.rs1_phys,
                         sta_rs1, sta_issue_data.imm, sta_eff_addr,
                         sta_issue_data.mem_size, flush_in.valid);
            end
            if (std_issue_valid && trace_calc_func_pc(std_issue_data.pc)) begin
                $display("[LSU_STD_ISSUE] t=%0t pc=%016h rob=%0d sq=%0d rs2p=%0d data=%016h size=%0d mask=%02h flush=%0b",
                         $time, std_issue_data.pc, std_issue_data.rob_idx,
                         std_issue_data.sq_idx, std_issue_data.rs2_phys,
                         std_rs2, std_issue_data.mem_size,
                         std_byte_mask, flush_in.valid);
            end
        end
    end
`endif

endmodule

`endif
