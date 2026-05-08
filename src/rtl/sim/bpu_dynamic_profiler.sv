/* file: bpu_dynamic_profiler.sv
 Description: Simulation-only dynamic BPU hot-PC profiler.
 Author: Jeremy Cai
 Date: May 08, 2026
 Version: 1.0
*/
`ifdef SIMULATION
module bpu_dynamic_profiler #(
    parameter int TOP_N = 128
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        update_valid,
    input  logic [63:0] update_pc,
    input  logic [63:0] update_target,
    input  logic        update_taken,
    input  logic        update_mispredict,
    input  logic        upd_loop_hit,
    input  logic        upd_any_hit,
    input  logic [1:0]  upd_provider,
    input  logic        upd_loop_backward
);

    logic   sim_bpu_dyn_en;
    integer total_updates;
    integer total_misp;
    integer total_taken;
    integer total_not_taken;
    integer total_backward;
    integer total_forward;
    integer total_loop_hit;
    integer total_tage_hit;
    integer total_provider [0:3];
    integer total_untracked_misp;

    logic [63:0] top_pc [0:TOP_N-1];
    logic        top_valid [0:TOP_N-1];
    integer      top_updates [0:TOP_N-1];
    integer      top_misp [0:TOP_N-1];
    integer      top_taken [0:TOP_N-1];
    integer      top_not_taken [0:TOP_N-1];
    integer      top_backward [0:TOP_N-1];
    integer      top_forward [0:TOP_N-1];
    integer      top_loop_hit [0:TOP_N-1];
    integer      top_tage_hit [0:TOP_N-1];
    integer      top_provider [0:TOP_N-1][0:3];

    initial begin
        sim_bpu_dyn_en = 1'b0;
        if ($test$plusargs("PERF_PROFILE") ||
            $test$plusargs("STAT_DUMP") ||
            $test$plusargs("TRACE_BPU_DYNAMIC")) begin
            sim_bpu_dyn_en = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_updates <= 0;
            total_misp <= 0;
            total_taken <= 0;
            total_not_taken <= 0;
            total_backward <= 0;
            total_forward <= 0;
            total_loop_hit <= 0;
            total_tage_hit <= 0;
            total_untracked_misp <= 0;
            for (int p = 0; p < 4; p++) begin
                total_provider[p] <= 0;
            end
            for (int i = 0; i < TOP_N; i++) begin
                top_pc[i] <= 64'd0;
                top_valid[i] <= 1'b0;
                top_updates[i] <= 0;
                top_misp[i] <= 0;
                top_taken[i] <= 0;
                top_not_taken[i] <= 0;
                top_backward[i] <= 0;
                top_forward[i] <= 0;
                top_loop_hit[i] <= 0;
                top_tage_hit[i] <= 0;
                for (int p = 0; p < 4; p++) begin
                    top_provider[i][p] <= 0;
                end
            end
        end else if (sim_bpu_dyn_en && update_valid) begin
            int hit_idx;
            int empty_idx;
            int min_idx;
            int use_idx;
            integer min_misp;

            hit_idx = -1;
            empty_idx = -1;
            min_idx = 0;
            min_misp = top_valid[0] ? top_misp[0] : 0;
            for (int i = 0; i < TOP_N; i++) begin
                if (top_valid[i] && (top_pc[i] == update_pc)) begin
                    hit_idx = i;
                end
                if (!top_valid[i] && (empty_idx < 0)) begin
                    empty_idx = i;
                end
                if (!top_valid[i]) begin
                    min_idx = i;
                    min_misp = 0;
                end else if ((empty_idx < 0) && (top_misp[i] < min_misp)) begin
                    min_idx = i;
                    min_misp = top_misp[i];
                end
            end

            total_updates <= total_updates + 1;
            if (update_mispredict) begin
                total_misp <= total_misp + 1;
            end
            if (update_taken) begin
                total_taken <= total_taken + 1;
            end else begin
                total_not_taken <= total_not_taken + 1;
            end
            if (upd_loop_backward) begin
                total_backward <= total_backward + 1;
            end else if (update_target != 64'd0) begin
                total_forward <= total_forward + 1;
            end
            if (upd_loop_hit) begin
                total_loop_hit <= total_loop_hit + 1;
            end
            if (upd_any_hit) begin
                total_tage_hit <= total_tage_hit + 1;
                total_provider[upd_provider] <= total_provider[upd_provider] + 1;
            end

            if (hit_idx >= 0) begin
                top_updates[hit_idx] <= top_updates[hit_idx] + 1;
                if (update_mispredict) begin
                    top_misp[hit_idx] <= top_misp[hit_idx] + 1;
                end
                if (update_taken) begin
                    top_taken[hit_idx] <= top_taken[hit_idx] + 1;
                end else begin
                    top_not_taken[hit_idx] <= top_not_taken[hit_idx] + 1;
                end
                if (upd_loop_backward) begin
                    top_backward[hit_idx] <= top_backward[hit_idx] + 1;
                end else if (update_target != 64'd0) begin
                    top_forward[hit_idx] <= top_forward[hit_idx] + 1;
                end
                if (upd_loop_hit) begin
                    top_loop_hit[hit_idx] <= top_loop_hit[hit_idx] + 1;
                end
                if (upd_any_hit) begin
                    top_tage_hit[hit_idx] <= top_tage_hit[hit_idx] + 1;
                    top_provider[hit_idx][upd_provider] <=
                        top_provider[hit_idx][upd_provider] + 1;
                end
            end else if (update_mispredict) begin
                if (empty_idx >= 0) begin
                    use_idx = empty_idx;
                end else begin
                    use_idx = min_idx;
                    total_untracked_misp <= total_untracked_misp + top_misp[min_idx];
                end

                top_pc[use_idx] <= update_pc;
                top_valid[use_idx] <= 1'b1;
                top_updates[use_idx] <= 1;
                top_misp[use_idx] <= 1;
                top_taken[use_idx] <= update_taken ? 1 : 0;
                top_not_taken[use_idx] <= update_taken ? 0 : 1;
                top_backward[use_idx] <= upd_loop_backward ? 1 : 0;
                top_forward[use_idx] <= (!upd_loop_backward && (update_target != 64'd0)) ? 1 : 0;
                top_loop_hit[use_idx] <= upd_loop_hit ? 1 : 0;
                top_tage_hit[use_idx] <= upd_any_hit ? 1 : 0;
                for (int p = 0; p < 4; p++) begin
                    top_provider[use_idx][p] <= (upd_any_hit && (upd_provider == 2'(p))) ? 1 : 0;
                end
            end
        end
    end

    final begin
        if (sim_bpu_dyn_en) begin
            $display("=== BPU DYNAMIC PROFILE ===");
            $display("bpu_dyn_total updates=%0d misp=%0d taken=%0d not_taken=%0d backward=%0d forward=%0d loop_hit=%0d tage_hit=%0d untracked_misp_replaced=%0d provider0=%0d provider1=%0d provider2=%0d provider3=%0d",
                     total_updates,
                     total_misp,
                     total_taken,
                     total_not_taken,
                     total_backward,
                     total_forward,
                     total_loop_hit,
                     total_tage_hit,
                     total_untracked_misp,
                     total_provider[0],
                     total_provider[1],
                     total_provider[2],
                     total_provider[3]);
            $display("bpu_dyn_tracked pc updates misp taken not_taken backward forward loop_hit tage_hit provider0 provider1 provider2 provider3");
            for (int i = 0; i < TOP_N; i++) begin
                if (top_valid[i] && (top_misp[i] != 0)) begin
                    $display("bpu_dyn_pc %016h %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                             top_pc[i],
                             top_updates[i],
                             top_misp[i],
                             top_taken[i],
                             top_not_taken[i],
                             top_backward[i],
                             top_forward[i],
                             top_loop_hit[i],
                             top_tage_hit[i],
                             top_provider[i][0],
                             top_provider[i][1],
                             top_provider[i][2],
                             top_provider[i][3]);
                end
            end
        end
    end

endmodule

bind tage_sc_l bpu_dynamic_profiler u_bpu_dynamic_profiler (
    .clk(clk),
    .rst_n(rst_n),
    .update_valid(update_valid),
    .update_pc(update_pc),
    .update_target(update_target),
    .update_taken(update_taken),
    .update_mispredict(update_mispredict),
    .upd_loop_hit(upd_loop_hit),
    .upd_any_hit(upd_any_hit),
    .upd_provider(upd_provider),
    .upd_loop_backward(upd_loop_backward)
);
`endif
