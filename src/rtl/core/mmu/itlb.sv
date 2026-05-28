/* file: itlb.sv
 Description: Fully associative instruction TLB for Sv39 and Sv48.
 Author: Jeremy Cai
 Date: May 11, 2026
 Version: 1.0
*/
module itlb
    import rv64gc_pkg::*;
    import isa_pkg::*;
#(
    parameter int DEPTH = ITLB_DEPTH,
    parameter int IDX_BITS = $clog2(DEPTH)
)
(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 lookup_valid_i,
    input  wire [63:0]          va_i,
    input  wire [1:0]           priv_i,
    input  wire [15:0]          asid_i,

    output reg                 hit_o,
    output reg [63:0]          pa_o,
    output reg                 fault_o,
    output reg [3:0]           fault_code_o,

    input  wire                 fill_valid_i,
    input  wire [35:0]          fill_vpn_i,
    input  wire [43:0]          fill_ppn_i,
    input  wire [15:0]          fill_asid_i,
    input  wire [1:0]           fill_page_size_i,
    input  wire [7:0]           fill_perm_i,

    input  wire                 inv_all_i,
    input  wire                 inv_va_valid_i,
    input  wire [63:0]          inv_va_i,
    input  wire                 inv_asid_valid_i,
    input  wire [15:0]          inv_asid_i,

    input  wire                 flush_i
);

    logic [DEPTH-1:0]       valid_r;
    logic [35:0]            vpn_r [0:DEPTH-1];
    logic [43:0]            ppn_r [0:DEPTH-1];
    logic [15:0]            asid_r [0:DEPTH-1];
    logic [1:0]             page_size_r [0:DEPTH-1];
    logic [7:0]             perm_r [0:DEPTH-1];
    logic [IDX_BITS-1:0]    rr_ptr_r;

    logic [DEPTH-1:0]       match;
    logic                   match_found;
    logic [IDX_BITS-1:0]    match_idx;
    logic [35:0]            lookup_vpn;
    logic [63:0]            pa_assembled;
    logic                   perm_fault;

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
        perm_fault = 1'b0;
        if (match_found) begin
            if (!perm_r[match_idx][0])
                perm_fault = 1'b1;
            if (!perm_r[match_idx][3])
                perm_fault = 1'b1;
            if (perm_r[match_idx][4]) begin
                if (priv_i == PRIV_S)
                    perm_fault = 1'b1;
            end else begin
                if (priv_i == PRIV_U)
                    perm_fault = 1'b1;
            end
        end
    end

    assign hit_o        = lookup_valid_i && match_found;
    assign pa_o         = pa_assembled;
    assign fault_o      = lookup_valid_i && match_found && perm_fault;
    assign fault_code_o = EXC_INSN_PAGE_FAULT;

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
                rr_ptr_r              <= (rr_ptr_r == IDX_BITS'(DEPTH - 1))
                                       ? '0
                                       : rr_ptr_r + IDX_BITS'(1);
            end
        end
    end

endmodule
