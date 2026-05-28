/* file: uart_16550.sv
 Description: Synthesizable NS16550A compatible UART register block.
 Author: Jeremy Cai
 Date: May 10, 2026
 Version: 1.0
*/
module uart_16550 (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       req_valid_i,
    input  wire       req_we_i,
    input  wire [2:0] req_addr_i,
    input  wire [7:0] req_wdata_i,
    output logic [7:0] resp_rdata_o,

    output logic       tx_valid_o,
    output logic [7:0] tx_data_o,
    output logic       irq_o
);

    logic [7:0] ier_r;
    logic [7:0] lcr_r;
    logic [7:0] mcr_r;
    logic [7:0] scr_r;
    logic [7:0] dll_r;
    logic [7:0] dlm_r;
    logic [7:0] fcr_r;

    wire dlab_w = lcr_r[7];
    wire [7:0] lsr_w = 8'b0110_0000;
    wire [7:0] msr_w = 8'h00;
    wire [7:0] iir_w = 8'h01;

    always_comb begin
        resp_rdata_o = 8'h00;
        if (req_valid_i && !req_we_i) begin
            case (req_addr_i)
                3'd0: resp_rdata_o = dlab_w ? dll_r : 8'h00;
                3'd1: resp_rdata_o = dlab_w ? dlm_r : ier_r;
                3'd2: resp_rdata_o = iir_w;
                3'd3: resp_rdata_o = lcr_r;
                3'd4: resp_rdata_o = mcr_r;
                3'd5: resp_rdata_o = lsr_w;
                3'd6: resp_rdata_o = msr_w;
                3'd7: resp_rdata_o = scr_r;
                default: resp_rdata_o = 8'h00;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ier_r      <= 8'h00;
            lcr_r      <= 8'h00;
            mcr_r      <= 8'h00;
            scr_r      <= 8'h00;
            dll_r      <= 8'h01;
            dlm_r      <= 8'h00;
            fcr_r      <= 8'h00;
            tx_valid_o <= 1'b0;
            tx_data_o  <= 8'h00;
        end else begin
            tx_valid_o <= 1'b0;
            if (req_valid_i && req_we_i) begin
                case (req_addr_i)
                    3'd0: begin
                        if (dlab_w) begin
                            dll_r <= req_wdata_i;
                        end else begin
                            tx_valid_o <= 1'b1;
                            tx_data_o  <= req_wdata_i;
                        end
                    end
                    3'd1: begin
                        if (dlab_w)
                            dlm_r <= req_wdata_i;
                        else
                            ier_r <= req_wdata_i;
                    end
                    3'd2: fcr_r <= req_wdata_i;
                    3'd3: lcr_r <= req_wdata_i;
                    3'd4: mcr_r <= req_wdata_i;
                    3'd7: scr_r <= req_wdata_i;
                    default: ;
                endcase
            end
        end
    end

    assign irq_o = 1'b0;

endmodule
