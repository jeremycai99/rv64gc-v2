/* file: ptw.sv
 Description: Shared Sv39 and Sv48 page table walker for ITLB and DTLB misses.
 Author: Jeremy Cai
 Date: May 11, 2026
 Version: 1.0
*/
module ptw
    import rv64gc_pkg::*;
    import isa_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [63:0]             satp_i,

    input  logic                    dtlb_req_valid_i,
    input  logic [63:0]             dtlb_req_va_i,
    input  logic [ROB_IDX_BITS-1:0] dtlb_req_rob_idx_i,
    input  logic                    dtlb_req_is_store_i,
    output logic                    dtlb_req_ready_o,

    input  logic                    itlb_req_valid_i,
    input  logic [63:0]             itlb_req_va_i,
    output logic                    itlb_req_ready_o,

    output logic                    dtlb_fill_valid_o,
    output logic                    itlb_fill_valid_o,
    output logic [35:0]             fill_vpn_o,
    output logic [43:0]             fill_ppn_o,
    output logic [15:0]             fill_asid_o,
    output logic [1:0]              fill_page_size_o,
    output logic [7:0]              fill_perm_o,
    output logic [63:0]             fill_pte_pa_o,

    output logic                    fault_valid_o,
    output logic                    fault_is_itlb_o,
    output logic                    fault_is_store_o,
    output logic [ROB_IDX_BITS-1:0] fault_rob_idx_o,
    output logic [63:0]             fault_va_o,

    output logic                    l2_req_valid_o,
    output logic [63:0]             l2_req_addr_o,
    input  logic                    l2_req_ready_i,
    input  logic                    l2_req_accepted_i,
    input  logic                    l2_resp_valid_i,
    input  logic [63:0]             l2_resp_addr_i,
    input  logic [511:0]            l2_resp_data_i,

    input  logic                    flush_i,
    input  logic                    translation_flush_i
);

    typedef enum logic [2:0] {
        S_IDLE  = 3'd0,
        S_REQ   = 3'd1,
        S_WAIT  = 3'd2,
        S_FILL  = 3'd3,
        S_FAULT = 3'd4
    } ptw_state_e;

    ptw_state_e                state_r;
    logic [63:0]               walk_va_r;
    logic                      walk_is_store_r;
    logic                      walk_is_itlb_r;
    logic [ROB_IDX_BITS-1:0]   walk_rob_idx_r;
    logic [43:0]               walk_ppn_r;
    logic [1:0]                walk_level_r;
    logic [15:0]               walk_asid_r;
    logic [63:0]               pte_r;
    logic [63:0]               pte_addr_r;
    logic                      stale_resp_pending_r;

    logic [3:0]                satp_mode;
    logic                      satp_sv39;
    logic                      satp_sv48;
    logic [43:0]               satp_ppn;
    logic [15:0]               satp_asid;
    logic [63:0]               req_va_c;
    logic                      req_is_dtlb_c;
    logic                      req_is_itlb_c;
    logic                      req_is_store_c;
    logic [ROB_IDX_BITS-1:0]   req_rob_idx_c;
    logic                      req_sv39_canonical_c;
    logic                      req_sv48_canonical_c;
    logic                      req_canonical_c;
    logic [63:0]               pte_addr_c;
    logic [63:0]               pte_line_addr_c;
    logic [63:0]               pte_resp_c;
    logic                      pte_resp_match_c;
    logic                      pte_v_c;
    logic                      pte_r_c;
    logic                      pte_w_c;
    logic                      pte_x_c;
    logic                      pte_leaf_c;
    logic [43:0]               pte_ppn_c;
    logic                      pte_invalid_c;
    logic                      superpage_misalign_c;
    logic                      ptw_read_inflight_c;

    assign satp_mode = satp_i[63:60];
    assign satp_sv39 = (satp_mode == 4'd8);
    assign satp_sv48 = (satp_mode == 4'd9);
    assign satp_ppn  = satp_i[43:0];
    assign satp_asid = satp_i[59:44];

    assign req_is_dtlb_c  = dtlb_req_valid_i;
    assign req_is_itlb_c  = !dtlb_req_valid_i && itlb_req_valid_i;
    assign req_va_c       = dtlb_req_valid_i ? dtlb_req_va_i : itlb_req_va_i;
    assign req_is_store_c = dtlb_req_valid_i && dtlb_req_is_store_i;
    assign req_rob_idx_c  = dtlb_req_valid_i ? dtlb_req_rob_idx_i : '0;
    assign req_sv39_canonical_c = (req_va_c[63:39] == {25{req_va_c[38]}});
    assign req_sv48_canonical_c = (req_va_c[63:48] == {16{req_va_c[47]}});
    assign req_canonical_c      = satp_sv48 ? req_sv48_canonical_c :
                                  satp_sv39 ? req_sv39_canonical_c :
                                  1'b1;

    always_comb begin
        case (walk_level_r)
            2'd3:    pte_addr_c = {8'd0, walk_ppn_r, walk_va_r[47:39], 3'b000};
            2'd2:    pte_addr_c = {8'd0, walk_ppn_r, walk_va_r[38:30], 3'b000};
            2'd1:    pte_addr_c = {8'd0, walk_ppn_r, walk_va_r[29:21], 3'b000};
            default: pte_addr_c = {8'd0, walk_ppn_r, walk_va_r[20:12], 3'b000};
        endcase
    end

    assign pte_line_addr_c = {pte_addr_c[63:LINE_BITS], {LINE_BITS{1'b0}}};
    assign l2_req_addr_o   = pte_line_addr_c;
    assign fill_pte_pa_o   = pte_addr_r;

    always_comb begin
        case (pte_addr_r[5:3])
            3'd0:    pte_resp_c = l2_resp_data_i[63:0];
            3'd1:    pte_resp_c = l2_resp_data_i[127:64];
            3'd2:    pte_resp_c = l2_resp_data_i[191:128];
            3'd3:    pte_resp_c = l2_resp_data_i[255:192];
            3'd4:    pte_resp_c = l2_resp_data_i[319:256];
            3'd5:    pte_resp_c = l2_resp_data_i[383:320];
            3'd6:    pte_resp_c = l2_resp_data_i[447:384];
            default: pte_resp_c = l2_resp_data_i[511:448];
        endcase
    end

    assign pte_resp_match_c =
        l2_resp_valid_i &&
        (l2_resp_addr_i[63:LINE_BITS] == pte_addr_r[63:LINE_BITS]);
    assign pte_v_c       = pte_resp_c[0];
    assign pte_r_c       = pte_resp_c[1];
    assign pte_w_c       = pte_resp_c[2];
    assign pte_x_c       = pte_resp_c[3];
    assign pte_leaf_c    = pte_r_c || pte_x_c;
    assign pte_ppn_c     = pte_resp_c[53:10];
    assign pte_invalid_c = !pte_v_c || (pte_w_c && !pte_r_c);

    always_comb begin
        superpage_misalign_c = 1'b0;
        case (walk_level_r)
            2'd3:    superpage_misalign_c = (pte_ppn_c[26:0] != 27'd0);
            2'd2:    superpage_misalign_c = (pte_ppn_c[17:0] != 18'd0);
            2'd1:    superpage_misalign_c = (pte_ppn_c[8:0]  != 9'd0);
            default: superpage_misalign_c = 1'b0;
        endcase
    end

    always_comb begin
        ptw_read_inflight_c = 1'b0;
        case (state_r)
            S_WAIT: ptw_read_inflight_c = 1'b1;
            S_REQ:  ptw_read_inflight_c = l2_req_accepted_i;
            default: ;
        endcase
    end

    assign dtlb_req_ready_o =
        (state_r == S_IDLE) && !flush_i && !translation_flush_i &&
        !stale_resp_pending_r;
    assign itlb_req_ready_o =
        (state_r == S_IDLE) && !dtlb_req_valid_i && !flush_i &&
        !translation_flush_i && !stale_resp_pending_r;

    always_comb begin
        l2_req_valid_o     = 1'b0;
        dtlb_fill_valid_o  = 1'b0;
        itlb_fill_valid_o  = 1'b0;
        fault_valid_o      = 1'b0;
        fault_is_itlb_o    = walk_is_itlb_r;
        fault_is_store_o   = walk_is_store_r;
        fault_rob_idx_o    = walk_rob_idx_r;
        fault_va_o         = walk_va_r;
        fill_vpn_o         = walk_va_r[47:12];
        fill_ppn_o         = pte_r[53:10];
        fill_asid_o        = walk_asid_r;
        fill_page_size_o   = walk_level_r;
        fill_perm_o        = pte_r[7:0];

        case (state_r)
            S_REQ: begin
                l2_req_valid_o = 1'b1;
            end
            S_FILL: begin
                dtlb_fill_valid_o = !walk_is_itlb_r;
                itlb_fill_valid_o = walk_is_itlb_r;
            end
            S_FAULT: begin
                fault_valid_o = 1'b1;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r                <= S_IDLE;
            walk_va_r              <= 64'd0;
            walk_is_store_r        <= 1'b0;
            walk_is_itlb_r         <= 1'b0;
            walk_rob_idx_r         <= '0;
            walk_ppn_r             <= 44'd0;
            walk_level_r           <= 2'd0;
            walk_asid_r            <= 16'd0;
            pte_r                  <= 64'd0;
            pte_addr_r             <= 64'd0;
            stale_resp_pending_r   <= 1'b0;
        end else begin
            if (stale_resp_pending_r && l2_resp_valid_i)
                stale_resp_pending_r <= 1'b0;

            if (flush_i || translation_flush_i) begin
                if (ptw_read_inflight_c && !l2_resp_valid_i)
                    stale_resp_pending_r <= 1'b1;
                state_r    <= S_IDLE;
                pte_r      <= 64'd0;
                pte_addr_r <= 64'd0;
            end else begin
                case (state_r)
                    S_IDLE: begin
                        if (stale_resp_pending_r) begin
                            state_r <= S_IDLE;
                        end else if (req_is_dtlb_c || req_is_itlb_c) begin
                            walk_va_r       <= req_va_c;
                            walk_rob_idx_r  <= req_rob_idx_c;
                            walk_is_store_r <= req_is_store_c;
                            walk_is_itlb_r  <= req_is_itlb_c;
                            walk_ppn_r      <= satp_ppn;
                            walk_asid_r     <= satp_asid;
                            walk_level_r    <= satp_sv48 ? 2'd3 : 2'd2;
                            if (req_canonical_c)
                                state_r <= S_REQ;
                            else
                                state_r <= S_FAULT;
                        end
                    end

                    S_REQ: begin
                        if (l2_req_accepted_i) begin
                            pte_addr_r <= pte_addr_c;
                            state_r    <= S_WAIT;
                        end
                    end

                    S_WAIT: begin
                        if (pte_resp_match_c) begin
                            pte_r      <= pte_resp_c | {57'd0, walk_is_store_r, 1'b1, 5'd0};
                            if (pte_invalid_c) begin
                                state_r <= S_FAULT;
                            end else if (pte_leaf_c) begin
                                if (superpage_misalign_c)
                                    state_r <= S_FAULT;
                                else
                                    state_r <= S_FILL;
                            end else if (walk_level_r == 2'd0) begin
                                state_r <= S_FAULT;
                            end else begin
                                walk_ppn_r   <= pte_ppn_c;
                                walk_level_r <= walk_level_r - 2'd1;
                                state_r      <= S_REQ;
                            end
                        end
                    end

                    S_FILL: begin
                        state_r <= S_IDLE;
                    end

                    S_FAULT: begin
                        state_r <= S_IDLE;
                    end

                    default: begin
                        state_r <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
