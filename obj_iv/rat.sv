/* file: rat.sv
 Description: Register alias table mapping arch to physical registers.
 Author: Jeremy Cai
 Date: Apr. 09, 2026
 Version: 2.0
*/
module rat
    import rv64gc_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // 6-wide source read (rs1/rs2 lookup)
    input logic [ARCH_REG_BITS-1:0] rs1_arch [0:PIPE_WIDTH-1],
    input logic [ARCH_REG_BITS-1:0] rs2_arch [0:PIPE_WIDTH-1],
    output logic [PHYS_REG_BITS-1:0] rs1_phys [0:PIPE_WIDTH-1],
    output logic [PHYS_REG_BITS-1:0] rs2_phys [0:PIPE_WIDTH-1],

    // 6-wide destination write (rename result)
    input logic [PIPE_WIDTH-1:0] wr_en,
    input logic [ARCH_REG_BITS-1:0] wr_arch [0:PIPE_WIDTH-1],
    input logic [PHYS_REG_BITS-1:0] wr_phys [0:PIPE_WIDTH-1],

    // Old mapping output (for ROB old_pdst)
    output logic [PHYS_REG_BITS-1:0] old_phys [0:PIPE_WIDTH-1],

    // Commit update to committed RAT (from commit unit)
    input logic [PIPE_WIDTH-1:0]          commit_wr_en,
    input logic [ARCH_REG_BITS-1:0]       commit_arch [0:PIPE_WIDTH-1],
    input logic [PHYS_REG_BITS-1:0]       commit_phys [0:PIPE_WIDTH-1],

    // Checkpoint save
    input logic ckpt_save,
    input logic [CHECKPOINT_BITS-1:0] ckpt_save_id,
    // Checkpoint restore
    input logic ckpt_restore,
    input logic [CHECKPOINT_BITS-1:0] ckpt_restore_id,
    // Full flush: restore from committed RAT
    input logic flush
);

    // -------------------------------------------------------------------------
    // RAT table: 32 entries, each PHYS_REG_BITS wide
    // -------------------------------------------------------------------------
    logic [PHYS_REG_BITS-1:0] rat_table [0:31];

    // -------------------------------------------------------------------------
    // Committed RAT (CRAT): tracks the architecturally committed mapping.
    // Updated when instructions retire at commit. Used to restore the
    // speculative RAT on a full flush.
    // -------------------------------------------------------------------------
    logic [PHYS_REG_BITS-1:0] committed_rat [0:31];

    // -------------------------------------------------------------------------
    // Checkpoint storage: NUM_CHECKPOINTS copies of the full table
    // -------------------------------------------------------------------------
    logic [PHYS_REG_BITS-1:0] ckpt_table [0:NUM_CHECKPOINTS-1][0:31];

    // -------------------------------------------------------------------------
    // Intra-group bypass for rs1, rs2, and old_phys
    //
    // For slot i, start with the table value, then check slots 0..i-1.
    // The latest matching write (highest j < i) wins.
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // Base table lookup
            rs1_phys[i] = rat_table[rs1_arch[i]];
            rs2_phys[i] = rat_table[rs2_arch[i]];
            old_phys[i] = rat_table[wr_arch[i]];

            // Scan earlier slots for bypass
            for (int j = 0; j < i; j++) begin
                if (wr_en[j] && (wr_arch[j] == rs1_arch[i])) begin
                    rs1_phys[i] = wr_phys[j];
                end
                if (wr_en[j] && (wr_arch[j] == rs2_arch[i])) begin
                    rs2_phys[i] = wr_phys[j];
                end
                if (wr_en[j] && (wr_arch[j] == wr_arch[i])) begin
                    old_phys[i] = wr_phys[j];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential: table update, checkpoint save/restore, flush
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Identity mapping: arch reg i -> phys reg i
            for (int i = 0; i < 32; i++) begin
                rat_table[i] <= PHYS_REG_BITS'(i);
            end
        end else if (flush) begin
            // Full flush: restore from committed RAT.
            // Also apply any same-cycle commit updates so that the
            // mispredicting instruction's mapping is captured.
            for (int i = 0; i < 32; i++) begin
                rat_table[i] <= committed_rat[i];
            end
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_wr_en[i] && (commit_arch[i] != '0)) begin
                    rat_table[commit_arch[i]] <= commit_phys[i];
                end
            end
        end else if (ckpt_restore) begin
            // Checkpoint restore overrides normal writes
            for (int i = 0; i < 32; i++) begin
                rat_table[i] <= ckpt_table[ckpt_restore_id][i];
            end
        end else begin
            // Normal rename writes, guard x0
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (wr_en[i] && (wr_arch[i] != '0)) begin
                    rat_table[wr_arch[i]] <= wr_phys[i];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Committed RAT update: updated every cycle from commit signals.
    // The committed RAT tracks the architecturally visible mapping.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) begin
                committed_rat[i] <= PHYS_REG_BITS'(i);
            end
        end else begin
            for (int i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_wr_en[i] && (commit_arch[i] != '0)) begin
                    committed_rat[commit_arch[i]] <= commit_phys[i];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Checkpoint save (independent of table update)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < NUM_CHECKPOINTS; c++) begin
                for (int i = 0; i < 32; i++) begin
                    ckpt_table[c][i] <= PHYS_REG_BITS'(i);
                end
            end
        end else if (ckpt_save) begin
            for (int i = 0; i < 32; i++) begin
                ckpt_table[ckpt_save_id][i] <= rat_table[i];
            end
        end
    end

endmodule
