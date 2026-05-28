/* file: mmio_platform.sv
 Description: Single hart uncached MMIO platform for UART, CLINT, and reserved PLIC range.
 Author: Jeremy Cai
 Date: May 10, 2026
 Version: 1.0
*/
module mmio_platform
    import rv64gc_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid_i,
    input  wire        req_we_i,
    input  wire [63:0] req_addr_i,
    input  wire [63:0] req_wdata_i,
    input  wire [7:0]  req_wmask_i,
    input  wire [1:0]  req_size_i,
    output logic        req_ready_o,
    output logic        resp_valid_o,
    output logic [63:0] resp_data_o,

    output logic [63:0] time_val_o,
    output logic        mtip_o,
    output logic        msip_o,
    output logic        meip_o,
    output logic        stip_o,
    output logic        ssip_o,
    output logic        seip_o,

    output logic        uart_tx_valid_o,
    output logic [7:0]  uart_tx_data_o
);

    logic        resp_valid_r;
    logic [63:0] resp_data_r;

    localparam int unsigned CLINT_MTIME_DIV_P = 100;

    wire req_fire_w = req_valid_i && req_ready_o;
    wire in_uart_w =
        (req_addr_i >= UART_BASE) && (req_addr_i < (UART_BASE + UART_SIZE));
    wire in_clint_w =
        (req_addr_i >= CLINT_BASE) && (req_addr_i < (CLINT_BASE + CLINT_SIZE));

    logic        uart_req_valid;
    logic [7:0]  uart_resp_data;
    logic        uart_irq;

    logic        clint_req_valid;
    logic [63:0] clint_resp_data;

    assign uart_req_valid  = req_fire_w && in_uart_w;
    assign clint_req_valid = req_fire_w && in_clint_w;

    uart_16550 u_uart (
        .clk          (clk),
        .rst_n        (rst_n),
        .req_valid_i  (uart_req_valid),
        .req_we_i     (req_we_i),
        .req_addr_i   (req_addr_i[2:0]),
        .req_wdata_i  (req_wdata_i[7:0]),
        .resp_rdata_o (uart_resp_data),
        .tx_valid_o   (uart_tx_valid_o),
        .tx_data_o    (uart_tx_data_o),
        .irq_o        (uart_irq)
    );

    clint #(
        .MTIME_DIV_P  (CLINT_MTIME_DIV_P)
    ) u_clint (
        .clk          (clk),
        .rst_n        (rst_n),
        .req_valid_i  (clint_req_valid),
        .req_we_i     (req_we_i),
        .req_addr_i   (req_addr_i[15:0]),
        .req_wdata_i  (req_wdata_i),
        .req_wmask_i  (req_wmask_i),
        .resp_rdata_o (clint_resp_data),
        .mtime_o      (time_val_o),
        .msip_o       (msip_o),
        .mtip_o       (mtip_o)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid_r <= 1'b0;
            resp_data_r  <= 64'd0;
        end else begin
            resp_valid_r <= req_fire_w;
            if (req_fire_w) begin
                if (in_uart_w) begin
                    resp_data_r <= {56'd0, uart_resp_data};
                end else if (in_clint_w) begin
                    resp_data_r <= clint_resp_data;
                end else begin
                    resp_data_r <= 64'd0;
                end
            end
        end
    end

    assign req_ready_o  = !resp_valid_r;
    assign resp_valid_o = resp_valid_r;
    assign resp_data_o  = resp_data_r;

    assign meip_o = 1'b0;
    assign stip_o = 1'b0;
    assign ssip_o = 1'b0;
    assign seip_o = 1'b0;

endmodule
