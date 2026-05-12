/* file: dtlb.sv
 Description: Fully associative data TLB for Sv39 and Sv48.
 Author: Jeremy Cai
 Date: May 11, 2026
 Version: 1.0
*/
module dtlb
    import rv64gc_pkg::*;
    import isa_pkg::*;
#(
    parameter int DEPTH = DTLB_DEPTH,
    parameter int IDX_BITS = $clog2(DEPTH)
)
(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 lookup_valid_i,
    input  logic [63:0]          va_i,
    input  logic                 is_store_i,
    input  logic [1:0]           priv_i,
    input  logic [15:0]          asid_i,
    input  logic                 sum_i,
    input  logic                 mxr_i,

    output logic                 hit_o,
    output logic [63:0]          pa_o,
    output logic                 fault_o,
    output logic [3:0]           fault_code_o,

    input  logic                 fill_valid_i,
    input  logic [35:0]          fill_vpn_i,
    input  logic [43:0]          fill_ppn_i,
    input  logic [15:0]          fill_asid_i,
    input  logic [1:0]           fill_page_size_i,
    input  logic [7:0]           fill_perm_i,
    input  logic [63:0]          fill_pte_pa_i,

    output logic                 dirty_wb_valid_o,
    output logic [63:0]          dirty_wb_pte_pa_o,
    output logic [63:0]          dirty_wb_pte_value_o,
    input  logic                 dirty_wb_ready_i,

    input  logic                 inv_all_i,
    input  logic                 inv_va_valid_i,
    input  logic [63:0]          inv_va_i,
    input  logic                 inv_asid_valid_i,
    input  logic [15:0]          inv_asid_i,

    input  logic                 flush_i
);

    logic [DEPTH-1:0]       valid_r;
    logic [35:0]            vpn_r [0:DEPTH-1];
    logic [43:0]            ppn_r [0:DEPTH-1];
    logic [15:0]            asid_r [0:DEPTH-1];
    logic [1:0]             page_size_r [0:DEPTH-1];
    logic [7:0]             perm_r [0:DEPTH-1];
    logic [63:0]            pte_pa_r [0:DEPTH-1];
    logic [IDX_BITS-1:0]    rr_ptr_r;

    logic [DEPTH-1:0]       match;
    logic                   match_found;
    logic [IDX_BITS-1:0]    match_idx;
    logic [35:0]            lookup_vpn;
    logic [63:0]            pa_assembled;
    logic                   perm_fault;
    logic [3:0]             perm_fault_code;
    logic                   dirty_upgrade_req;
    logic                   dirty_upgrade_now;

    assign lookup_vpn = va_i[47:12];

    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            logic vpn_match;

            case (page_size_r[i])
                2'd3:    vpn_match = (lookup_vpn[35:27] == vpn_r[i][35:27]);
                2'd2:    vpn_match = (lookup_vpn[35:18] == vpn_r[i][35:18]);
                2'd1:    vpn_match = (lookup_vpn[35:9]  == vpn_r[i][35:9]);
                default: vpn_match = (lookup_vpn == vpn_r[i]);
            endcase

            match[i] = valid_r[i] && vpn_match &&
                       (perm_r[i][5] || (asid_r[i] == asid_i));
        end
    end

    always_comb begin
        match_found = 1'b0;
        match_idx   = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (!match_found && match[i]) begin
                match_found = 1'b1;
                match_idx   = IDX_BITS'(i);
            end
        end
    end

    always_comb begin
        case (page_size_r[match_idx])
            2'd3:    pa_assembled = {8'd0, ppn_r[match_idx][43:27], va_i[38:0]};
            2'd2:    pa_assembled = {8'd0, ppn_r[match_idx][43:18], va_i[29:0]};
            2'd1:    pa_assembled = {8'd0, ppn_r[match_idx][43:9],  va_i[20:0]};
            default: pa_assembled = {8'd0, ppn_r[match_idx],         va_i[11:0]};
        endcase
    end

    always_comb begin
        perm_fault      = 1'b0;
        perm_fault_code = is_store_i ? EXC_STORE_PAGE_FAULT : EXC_LOAD_PAGE_FAULT;

        if (match_found) begin
            if (!perm_r[match_idx][0])
                perm_fault = 1'b1;
            if (!perm_r[match_idx][6])
                perm_fault = 1'b1;
            if (is_store_i && !perm_r[match_idx][2])
                perm_fault = 1'b1;
            if (!is_store_i && !perm_r[match_idx][1] &&
                !(mxr_i && perm_r[match_idx][3]))
                perm_fault = 1'b1;

            if (perm_r[match_idx][4]) begin
                if ((priv_i == PRIV_S) && !sum_i)
                    perm_fault = 1'b1;
            end else begin
                if (priv_i == PRIV_U)
                    perm_fault = 1'b1;
            end
        end
    end

    assign dirty_upgrade_req =
        lookup_valid_i && match_found && is_store_i &&
        !perm_r[match_idx][7] && perm_r[match_idx][0] && !perm_fault;
    assign dirty_upgrade_now = dirty_upgrade_req && dirty_wb_ready_i;

    assign dirty_wb_valid_o     = dirty_upgrade_now;
    assign dirty_wb_pte_pa_o    = pte_pa_r[match_idx];
    assign dirty_wb_pte_value_o = {10'd0, ppn_r[match_idx], 2'd0,
                                   perm_r[match_idx] | 8'h80};

    assign hit_o        = lookup_valid_i && match_found &&
                          !(dirty_upgrade_req && !dirty_wb_ready_i);
    assign pa_o         = pa_assembled;
    assign fault_o      = lookup_valid_i && match_found && perm_fault;
    assign fault_code_o = perm_fault_code;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_i) begin
            valid_r  <= '0;
            rr_ptr_r <= '0;
        end else begin
            if (inv_all_i) begin
                valid_r <= '0;
            end else if (inv_va_valid_i || inv_asid_valid_i) begin
                for (int i = 0; i < DEPTH; i++) begin
                    logic inv_match;

                    inv_match = 1'b0;
                    if (inv_va_valid_i && inv_asid_valid_i) begin
                        inv_match = (vpn_r[i] == inv_va_i[47:12]) &&
                                    (asid_r[i] == inv_asid_i) &&
                                    !perm_r[i][5];
                    end else if (inv_va_valid_i) begin
                        inv_match = (vpn_r[i] == inv_va_i[47:12]);
                    end else begin
                        inv_match = (asid_r[i] == inv_asid_i) &&
                                    !perm_r[i][5];
                    end

                    if (inv_match)
                        valid_r[i] <= 1'b0;
                end
            end

            if (fill_valid_i && !(inv_all_i || inv_va_valid_i || inv_asid_valid_i)) begin
                valid_r[rr_ptr_r]     <= 1'b1;
                vpn_r[rr_ptr_r]       <= fill_vpn_i;
                ppn_r[rr_ptr_r]       <= fill_ppn_i;
                asid_r[rr_ptr_r]      <= fill_asid_i;
                page_size_r[rr_ptr_r] <= fill_page_size_i;
                perm_r[rr_ptr_r]      <= fill_perm_i;
                pte_pa_r[rr_ptr_r]    <= fill_pte_pa_i;
                rr_ptr_r              <= (rr_ptr_r == IDX_BITS'(DEPTH - 1))
                                       ? '0
                                       : rr_ptr_r + IDX_BITS'(1);
            end

            if (dirty_upgrade_now)
                perm_r[match_idx][7] <= 1'b1;
        end
    end

endmodule
