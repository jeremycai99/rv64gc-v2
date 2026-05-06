/* file: tb_lsq_partial_flush.sv
 Description: Directed partial-flush coverage for load/store queues.
*/

module tb_lsq_partial_flush
    import rv64gc_pkg::*;
    import uarch_pkg::*;
();
    timeunit 1ns;
    timeprecision 1ps;

    logic clk;
    logic rst_n;

    logic [ROB_IDX_BITS-1:0] rob_head;
    logic                    flush_valid;
    logic                    flush_full;
    logic [ROB_IDX_BITS-1:0] flush_rob_tail;

    // Load queue signals
    logic [2:0] lq_alloc_count;
    logic [ROB_IDX_BITS-1:0] lq_alloc_rob_idx [0:PIPE_WIDTH-1];
    logic [LQ_IDX_BITS-1:0] lq_alloc_idx [0:PIPE_WIDTH-1];
    logic lq_full;
    logic lq_exec_valid;
    logic [LQ_IDX_BITS-1:0] lq_exec_idx;
    logic [ROB_IDX_BITS-1:0] lq_exec_rob_idx;
    logic [63:0] lq_exec_addr;
    logic [1:0] lq_exec_size;
    logic lq_exec_is_unsigned;
    logic lq_exec1_valid;
    logic [LQ_IDX_BITS-1:0] lq_exec1_idx;
    logic [ROB_IDX_BITS-1:0] lq_exec1_rob_idx;
    logic [63:0] lq_exec1_addr;
    logic [1:0] lq_exec1_size;
    logic lq_exec1_is_unsigned;
    logic lq_result_valid;
    logic [LQ_IDX_BITS-1:0] lq_result_idx;
    logic [63:0] lq_result_data;
    logic lq_st_addr_valid;
    logic [63:0] lq_st_addr;
    logic [1:0] lq_st_size;
    logic [ROB_IDX_BITS-1:0] lq_st_rob_idx;
    logic lq_ordering_violation;
    logic [ROB_IDX_BITS-1:0] lq_violation_rob_idx;
    logic [2:0] lq_commit_count;

    // Store queue signals
    logic [2:0] sq_alloc_count;
    logic [ROB_IDX_BITS-1:0] sq_alloc_rob_idx [0:PIPE_WIDTH-1];
    logic [SQ_IDX_BITS-1:0] sq_alloc_idx [0:PIPE_WIDTH-1];
    logic sq_full;
    logic sq_sta_valid;
    logic [SQ_IDX_BITS-1:0] sq_sta_idx;
    logic [ROB_IDX_BITS-1:0] sq_sta_rob_idx;
    logic [63:0] sq_sta_addr;
    logic [1:0] sq_sta_size;
    logic sq_std_valid;
    logic [SQ_IDX_BITS-1:0] sq_std_idx;
    logic [63:0] sq_std_data;
    logic [7:0] sq_std_byte_mask;
    logic sq_fwd_req_valid;
    logic [63:0] sq_fwd_req_addr;
    logic [1:0] sq_fwd_req_size;
    logic [ROB_IDX_BITS-1:0] sq_fwd_req_rob_idx;
    logic sq_fwd_hit;
    logic sq_fwd_partial;
    logic sq_fwd_wait;
    logic [63:0] sq_fwd_data;
    logic sq_wait_req_valid;
    logic [63:0] sq_wait_req_addr;
    logic [1:0] sq_wait_req_size;
    logic [ROB_IDX_BITS-1:0] sq_wait_req_rob_idx;
    logic sq_wait_fwd_hit;
    logic sq_wait_partial;
    logic sq_wait_wait;
    logic [63:0] sq_wait_data;
    logic sq_wait_hit;
    logic [2:0] sq_commit_count;
    logic sq_drain_valid;
    sq_entry_t sq_drain_entry;
    logic sq_drain_ready;

    load_queue u_lq (
        .clk                (clk),
        .rst_n              (rst_n),
        .alloc_count        (lq_alloc_count),
        .alloc_rob_idx      (lq_alloc_rob_idx),
        .alloc_idx          (lq_alloc_idx),
        .full               (lq_full),
        .exec_valid         (lq_exec_valid),
        .exec_idx           (lq_exec_idx),
        .exec_rob_idx       (lq_exec_rob_idx),
        .exec_addr          (lq_exec_addr),
        .exec_size          (lq_exec_size),
        .exec_is_unsigned   (lq_exec_is_unsigned),
        .exec1_valid        (lq_exec1_valid),
        .exec1_idx          (lq_exec1_idx),
        .exec1_rob_idx      (lq_exec1_rob_idx),
        .exec1_addr         (lq_exec1_addr),
        .exec1_size         (lq_exec1_size),
        .exec1_is_unsigned  (lq_exec1_is_unsigned),
        .result_valid       (lq_result_valid),
        .result_idx         (lq_result_idx),
        .result_data        (lq_result_data),
        .st_addr_valid      (lq_st_addr_valid),
        .st_addr            (lq_st_addr),
        .st_size            (lq_st_size),
        .st_rob_idx         (lq_st_rob_idx),
        .rob_head           (rob_head),
        .ordering_violation (lq_ordering_violation),
        .violation_rob_idx  (lq_violation_rob_idx),
        .commit_count       (lq_commit_count),
        .flush_valid        (flush_valid),
        .flush_rob_tail     (flush_rob_tail),
        .flush_full         (flush_full)
    );

    store_queue u_sq (
        .clk              (clk),
        .rst_n            (rst_n),
        .alloc_count      (sq_alloc_count),
        .alloc_rob_idx    (sq_alloc_rob_idx),
        .alloc_idx        (sq_alloc_idx),
        .full             (sq_full),
        .sta_valid        (sq_sta_valid),
        .sta_idx          (sq_sta_idx),
        .sta_rob_idx      (sq_sta_rob_idx),
        .sta_addr         (sq_sta_addr),
        .sta_size         (sq_sta_size),
        .std_valid        (sq_std_valid),
        .std_idx          (sq_std_idx),
        .std_data         (sq_std_data),
        .std_byte_mask    (sq_std_byte_mask),
        .fwd_req_valid    (sq_fwd_req_valid),
        .fwd_req_addr     (sq_fwd_req_addr),
        .fwd_req_size     (sq_fwd_req_size),
        .fwd_req_rob_idx  (sq_fwd_req_rob_idx),
        .fwd_hit          (sq_fwd_hit),
        .fwd_partial      (sq_fwd_partial),
        .fwd_wait         (sq_fwd_wait),
        .fwd_data         (sq_fwd_data),
        .wait_req_valid   (sq_wait_req_valid),
        .wait_req_addr    (sq_wait_req_addr),
        .wait_req_size    (sq_wait_req_size),
        .wait_req_rob_idx (sq_wait_req_rob_idx),
        .wait_fwd_hit     (sq_wait_fwd_hit),
        .wait_partial     (sq_wait_partial),
        .wait_wait        (sq_wait_wait),
        .wait_data        (sq_wait_data),
        .wait_hit         (sq_wait_hit),
        .rob_head         (rob_head),
        .commit_count     (sq_commit_count),
        .drain_valid      (sq_drain_valid),
        .drain_entry      (sq_drain_entry),
        .drain_ready      (sq_drain_ready),
        .flush_valid      (flush_valid),
        .flush_rob_tail   (flush_rob_tail),
        .flush_full       (flush_full)
    );

    always #5 clk = ~clk;

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $fatal(1);
        end
    endtask

    task automatic drive_idle;
        lq_alloc_count       = '0;
        lq_exec_valid        = 1'b0;
        lq_exec_idx          = '0;
        lq_exec_rob_idx      = '0;
        lq_exec_addr         = '0;
        lq_exec_size         = '0;
        lq_exec_is_unsigned  = 1'b0;
        lq_exec1_valid       = 1'b0;
        lq_exec1_idx         = '0;
        lq_exec1_rob_idx     = '0;
        lq_exec1_addr        = '0;
        lq_exec1_size        = '0;
        lq_exec1_is_unsigned = 1'b0;
        lq_result_valid      = 1'b0;
        lq_result_idx        = '0;
        lq_result_data       = '0;
        lq_st_addr_valid     = 1'b0;
        lq_st_addr           = '0;
        lq_st_size           = '0;
        lq_st_rob_idx        = '0;
        lq_commit_count      = '0;

        sq_alloc_count       = '0;
        sq_sta_valid         = 1'b0;
        sq_sta_idx           = '0;
        sq_sta_rob_idx       = '0;
        sq_sta_addr          = '0;
        sq_sta_size          = '0;
        sq_std_valid         = 1'b0;
        sq_std_idx           = '0;
        sq_std_data          = '0;
        sq_std_byte_mask     = '0;
        sq_fwd_req_valid     = 1'b0;
        sq_fwd_req_addr      = '0;
        sq_fwd_req_size      = '0;
        sq_fwd_req_rob_idx   = '0;
        sq_wait_req_valid    = 1'b0;
        sq_wait_req_addr     = '0;
        sq_wait_req_size     = '0;
        sq_wait_req_rob_idx  = '0;
        sq_commit_count      = '0;
        sq_drain_ready       = 1'b0;

        flush_valid          = 1'b0;
        flush_full           = 1'b0;
        flush_rob_tail       = '0;
        rob_head             = '0;

        for (int i = 0; i < PIPE_WIDTH; i++) begin
            lq_alloc_rob_idx[i] = '0;
            sq_alloc_rob_idx[i] = '0;
        end
    endtask

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic apply_reset;
        drive_idle();
        rst_n = 1'b0;
        repeat (2) tick();
        rst_n = 1'b1;
        tick();
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        apply_reset();

        // LQ: one same-cycle committed load retires; the older unexecuted
        // load survives; loads at/after flush_rob_tail are removed.
        rob_head = 8'd8;
        lq_alloc_count = 3'd4;
        lq_alloc_rob_idx[0] = 8'd10;
        lq_alloc_rob_idx[1] = 8'd11;
        lq_alloc_rob_idx[2] = 8'd12;
        lq_alloc_rob_idx[3] = 8'd13;
        tick();
        drive_idle();
        check(u_lq.count_r == 7'd4, "LQ allocate count");
        check(u_lq.queue[1].rob_idx == 8'd11, "LQ alloc ROB metadata");

        rob_head = 8'd8;
        flush_valid = 1'b1;
        flush_full = 1'b0;
        flush_rob_tail = 8'd12;
        lq_commit_count = 3'd1;
        lq_exec_valid = 1'b1;
        lq_exec_idx = 6'd1;
        lq_exec_rob_idx = 8'd11;
        lq_exec_addr = 64'h0000_0000_0000_1000;
        lq_exec_size = 2'd2;
        lq_exec_is_unsigned = 1'b1;
        lq_exec1_valid = 1'b1;
        lq_exec1_idx = 6'd2;
        lq_exec1_rob_idx = 8'd12;
        lq_exec1_addr = 64'h0000_0000_0000_2000;
        lq_exec1_size = 2'd2;
        tick();
        drive_idle();
        check(u_lq.head_r == 6'd1, "LQ partial head after same-cycle commit");
        check(u_lq.tail_r == 6'd2, "LQ partial tail keeps only one survivor");
        check(u_lq.count_r == 7'd1, "LQ partial count");
        check(!u_lq.queue[0].valid, "LQ committed entry cleared");
        check(u_lq.queue[1].valid, "LQ older load survives");
        check(u_lq.queue[1].executed, "LQ survivor same-cycle exec retained");
        check(u_lq.queue[1].addr == 64'h0000_0000_0000_1000, "LQ survivor address retained");
        check(!u_lq.queue[2].valid, "LQ entry at flush tail removed");
        check(!u_lq.queue[3].valid, "LQ younger entry removed");

        apply_reset();

        // SQ: committed store survives a partial flush; an older speculative
        // unaddressed store survives by allocation-time ROB metadata.
        rob_head = 8'd20;
        sq_alloc_count = 3'd4;
        sq_alloc_rob_idx[0] = 8'd20;
        sq_alloc_rob_idx[1] = 8'd21;
        sq_alloc_rob_idx[2] = 8'd22;
        sq_alloc_rob_idx[3] = 8'd23;
        tick();
        drive_idle();
        check(u_sq.count_r == 7'd4, "SQ allocate count");
        check(u_sq.queue[1].rob_idx == 8'd21, "SQ alloc ROB metadata");

        rob_head = 8'd20;
        sq_commit_count = 3'd1;
        sq_sta_valid = 1'b1;
        sq_sta_idx = 6'd0;
        sq_sta_rob_idx = 8'd20;
        sq_sta_addr = 64'h0000_0000_0000_3000;
        sq_sta_size = 2'd2;
        sq_std_valid = 1'b1;
        sq_std_idx = 6'd0;
        sq_std_data = 64'h0000_0000_cafe_babe;
        sq_std_byte_mask = 8'h0f;
        tick();
        drive_idle();
        check(u_sq.queue[0].committed, "SQ store0 committed");
        check(u_sq.queue[0].addr_valid && u_sq.queue[0].data_valid, "SQ store0 ready");

        rob_head = 8'd20;
        flush_valid = 1'b1;
        flush_full = 1'b0;
        flush_rob_tail = 8'd22;
        sq_std_valid = 1'b1;
        sq_std_idx = 6'd1;
        sq_std_data = 64'h1111_2222_3333_4444;
        sq_std_byte_mask = 8'hff;
        sq_sta_valid = 1'b1;
        sq_sta_idx = 6'd2;
        sq_sta_rob_idx = 8'd22;
        sq_sta_addr = 64'h0000_0000_0000_4000;
        sq_sta_size = 2'd2;
        tick();
        drive_idle();
        check(u_sq.head_r == 6'd0, "SQ partial head without drain");
        check(u_sq.tail_r == 6'd2, "SQ partial tail keeps committed plus older speculative");
        check(u_sq.count_r == 7'd2, "SQ partial survivor count");
        check(u_sq.queue[0].valid && u_sq.queue[0].committed, "SQ committed store survives");
        check(u_sq.queue[1].valid && !u_sq.queue[1].committed, "SQ older speculative survives");
        check(u_sq.queue[1].data_valid, "SQ survivor same-cycle STD retained");
        check(u_sq.queue[1].data == 64'h1111_2222_3333_4444, "SQ survivor STD data retained");
        check(!u_sq.queue[2].valid, "SQ entry at flush tail removed");
        check(!u_sq.queue[3].valid, "SQ younger entry removed");

        apply_reset();

        // SQ: same-cycle drain plus same-cycle commit plus partial flush
        // consumes the committed head while preserving the older store behind
        // it and marking that survivor committed.
        rob_head = 8'd30;
        sq_alloc_count = 3'd3;
        sq_alloc_rob_idx[0] = 8'd30;
        sq_alloc_rob_idx[1] = 8'd31;
        sq_alloc_rob_idx[2] = 8'd32;
        tick();
        drive_idle();

        rob_head = 8'd30;
        sq_commit_count = 3'd1;
        sq_sta_valid = 1'b1;
        sq_sta_idx = 6'd0;
        sq_sta_rob_idx = 8'd30;
        sq_sta_addr = 64'h0000_0000_0000_5000;
        sq_sta_size = 2'd2;
        sq_std_valid = 1'b1;
        sq_std_idx = 6'd0;
        sq_std_data = 64'h0000_0000_1234_5678;
        sq_std_byte_mask = 8'h0f;
        tick();
        drive_idle();
        check(sq_drain_valid, "SQ drain available before partial flush");

        rob_head = 8'd30;
        flush_valid = 1'b1;
        flush_full = 1'b0;
        flush_rob_tail = 8'd32;
        sq_drain_ready = 1'b1;
        sq_commit_count = 3'd1;
        tick();
        drive_idle();
        check(u_sq.head_r == 6'd1, "SQ partial head after drain");
        check(u_sq.tail_r == 6'd2, "SQ partial tail after drain");
        check(u_sq.commit_ptr_r == 6'd2, "SQ partial commit pointer after drain/commit");
        check(u_sq.count_r == 7'd1, "SQ partial count after drain");
        check(!u_sq.queue[0].valid, "SQ drained head cleared");
        check(u_sq.queue[1].valid, "SQ older store behind drained head survives");
        check(u_sq.queue[1].committed, "SQ same-cycle committed survivor marked");
        check(!u_sq.queue[2].valid, "SQ at-tail store flushed after drain");

        $display("tb_lsq_partial_flush PASS");
        $finish;
    end

endmodule
