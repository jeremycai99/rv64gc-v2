/* file: ibuffer.sv
 Description: Architectural IBuffer wrapper around the current fetch packet FIFO.
 Author: Jeremy Cai
 Date: May 06, 2026
 Version: 1.0
*/
module ibuffer
    import rv64gc_pkg::*;
    import uarch_pkg::*;
(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          flush,

    input  logic          enq_valid,
    input  fetch_packet_t enq_packet,
    output logic          enq_ready,
    output logic          enq_fire,

    input  logic          deq_ready,
    output logic          deq_valid,
    output fetch_packet_t deq_packet,
    output logic          deq_fire,
    output logic          deq_flowthrough,

    input  logic                          owner_valid,
    input  logic [FTQ_IDX_BITS-1:0]       owner_idx,
    input  logic [FTQ_EPOCH_BITS-1:0]     owner_epoch,
    input  logic [FTQ_ALLOC_TAG_BITS-1:0] owner_tag,
    output logic                          deq_owner_match,
    output logic                          deq_stale_owner,
    output logic                          deq_owner_complete,

    output logic          full,
    output logic          empty,
    output logic [3:0]    count
);

    fetch_packet_buffer u_fetch_packet_buffer (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush             (flush),
        .enq_valid         (enq_valid),
        .enq_packet        (enq_packet),
        .enq_ready         (enq_ready),
        .enq_fire          (enq_fire),
        .deq_ready         (deq_ready),
        .deq_valid         (deq_valid),
        .deq_packet        (deq_packet),
        .deq_fire          (deq_fire),
        .deq_flowthrough   (deq_flowthrough),
        .owner_valid       (owner_valid),
        .owner_idx         (owner_idx),
        .owner_epoch       (owner_epoch),
        .owner_tag         (owner_tag),
        .deq_owner_match   (deq_owner_match),
        .deq_stale_owner   (deq_stale_owner),
        .deq_owner_complete(deq_owner_complete),
        .full              (full),
        .empty             (empty),
        .count             (count)
    );

endmodule
