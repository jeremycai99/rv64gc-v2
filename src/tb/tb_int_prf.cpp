// file: tb_int_prf.cpp
// Description: Verilator C++ driver for the 256x64 integer PRF testbench.
// Note: dut->eval() is the standard Verilator simulation API call, not a
//       JavaScript eval() -- it re-evaluates combinational logic in the model.
//
// Test cases:
//  1. Basic write/read-back from each copy's read port pair
//  2. Six simultaneous writes, all read back correctly
//  3. Write-first bypass: same-cycle write+read returns new data
//  4. p0 (physical register 0) always reads as 0, even after a write attempt
//  5. Multi-write conflict: highest-indexed write port wins

#include "Vtb_int_prf.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>
#include <cstring>

// Required by Verilator runtime when not using SystemC
double sc_time_stamp() { return 0; }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static Vtb_int_prf *dut;
static VerilatedVcdC *tfp;
static uint64_t sim_time = 0;
static int pass_count = 0;
static int fail_count = 0;

// Advance combinational logic without a clock edge (no VCD dump to avoid
// duplicate-timestamp warnings when followed immediately by tick()).
static void evaluate() {
    dut->clk = 0;
    dut->eval();
}

static void tick() {
    // Negedge
    dut->clk = 0;
    dut->eval();
    if (tfp) tfp->dump(sim_time++);

    // Posedge
    dut->clk = 1;
    dut->eval();
    if (tfp) tfp->dump(sim_time++);
}

// Drive all write ports to idle (wen = 0)
static void clear_writes() {
    dut->wen = 0;
    for (int i = 0; i < 6; i++) {
        dut->waddr[i] = 0;
        dut->wdata[i] = 0;
    }
}

// Drive all read ports to address 0
static void clear_reads() {
    for (int i = 0; i < 12; i++) {
        dut->raddr[i] = 0;
    }
}

static void check(const char *test_name, int port, uint64_t got, uint64_t expected) {
    if (got == expected) {
        pass_count++;
    } else {
        fail_count++;
        printf("FAIL [%s] port=%d  got=0x%016llx  expected=0x%016llx\n",
               test_name, port, (unsigned long long)got, (unsigned long long)expected);
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    dut = new Vtb_int_prf;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("obj_dir/test_int_prf/tb_int_prf.vcd");

    // Initialise
    dut->clk = 0;
    clear_writes();
    clear_reads();
    dut->eval();

    // Reset-like warmup: one idle tick
    tick();

    // =========================================================================
    // Test 1: Write one register, read back from all 6 copy-pairs
    // =========================================================================
    {
        const char *tname = "Test1_basic_write_read";
        // Write p10 = 0xDEADBEEFCAFEBABE via write port 0
        clear_writes();
        dut->wen      = 0x01;       // only port 0
        dut->waddr[0] = 10;
        dut->wdata[0] = 0xDEADBEEFCAFEBABEULL;
        // Read p10 from all 6 pairs (ports 0,2,4,6,8,10 -- even port of each pair)
        for (int i = 0; i < 12; i += 2) dut->raddr[i] = 10;
        // Odd ports read p1 (should be 0 since never written)
        for (int i = 1; i < 12; i += 2) dut->raddr[i] = 1;
        tick();   // write is committed on posedge

        // Now read the stored value (no bypass -- write ports idle)
        clear_writes();
        for (int i = 0; i < 12; i += 2) dut->raddr[i] = 10;
        for (int i = 1; i < 12; i += 2) dut->raddr[i] = 1;
        evaluate();   // combinational read

        for (int i = 0; i < 12; i += 2) {
            check(tname, i, dut->rdata[i], 0xDEADBEEFCAFEBABEULL);
        }
        // p1 should read 0 (never written)
        for (int i = 1; i < 12; i += 2) {
            check(tname, i, dut->rdata[i], 0x0ULL);
        }
        printf("[Test 1] basic write/read: %s\n", fail_count == 0 ? "PASS" : "partial FAIL");
    }

    // =========================================================================
    // Test 2: Six simultaneous writes, all read back
    // =========================================================================
    {
        const char *tname = "Test2_six_simultaneous_writes";
        int prev_fails = fail_count;

        clear_writes();
        dut->wen = 0x3F;  // all 6 write ports active
        for (int wp = 0; wp < 6; wp++) {
            dut->waddr[wp] = 20 + wp;   // p20..p25
            dut->wdata[wp] = 0xA000000000000000ULL | ((uint64_t)wp << 32) | (uint64_t)(wp * 0x11111111);
        }
        // Read addresses: read each newly written register from distinct read-port pair
        for (int rp = 0; rp < 6; rp++) {
            dut->raddr[rp * 2]     = 20 + rp;
            dut->raddr[rp * 2 + 1] = 20 + rp;
        }
        tick();   // commit writes

        // Now read back (no bypass)
        clear_writes();
        for (int rp = 0; rp < 6; rp++) {
            dut->raddr[rp * 2]     = 20 + rp;
            dut->raddr[rp * 2 + 1] = 20 + rp;
        }
        evaluate();

        for (int wp = 0; wp < 6; wp++) {
            uint64_t expected = 0xA000000000000000ULL | ((uint64_t)wp << 32) | (uint64_t)(wp * 0x11111111);
            check(tname, wp * 2,     dut->rdata[wp * 2],     expected);
            check(tname, wp * 2 + 1, dut->rdata[wp * 2 + 1], expected);
        }
        printf("[Test 2] six simultaneous writes: %s\n",
               (fail_count == prev_fails) ? "PASS" : "FAIL");
    }

    // =========================================================================
    // Test 3: Write-first bypass
    //   Same cycle: write p50 = 0x1234 via port 0, read p50 from all 6 pairs.
    //   All reads must return 0x1234 immediately (combinational bypass).
    // =========================================================================
    {
        const char *tname = "Test3_write_first_bypass";
        int prev_fails = fail_count;

        clear_writes();
        dut->wen      = 0x01;
        dut->waddr[0] = 50;
        dut->wdata[0] = 0x0000000000001234ULL;
        // Read p50 from all pairs in the same combinational window
        for (int i = 0; i < 12; i++) dut->raddr[i] = 50;
        evaluate();   // combinational evaluation -- bypass should kick in

        for (int i = 0; i < 12; i++) {
            check(tname, i, dut->rdata[i], 0x0000000000001234ULL);
        }
        tick();   // commit the write
        printf("[Test 3] write-first bypass: %s\n",
               (fail_count == prev_fails) ? "PASS" : "FAIL");
    }

    // =========================================================================
    // Test 4: p0 (physical register 0) always reads 0
    //   Attempt to write a non-zero value to p0 via all 6 write ports,
    //   then read it from all 12 read ports; must always return 0.
    // =========================================================================
    {
        const char *tname = "Test4_p0_hardwired_zero";
        int prev_fails = fail_count;

        // Write p0 with all ports in the same cycle (bypass path)
        dut->wen = 0x3F;
        for (int wp = 0; wp < 6; wp++) {
            dut->waddr[wp] = 0;
            dut->wdata[wp] = 0xFFFFFFFFFFFFFFFFULL;
        }
        for (int i = 0; i < 12; i++) dut->raddr[i] = 0;
        evaluate();  // bypass path check

        for (int i = 0; i < 12; i++) {
            check(tname, i, dut->rdata[i], 0x0ULL);
        }
        tick();   // commit (stores something, but reads must still return 0)

        // After write committed, re-read with no bypass
        clear_writes();
        for (int i = 0; i < 12; i++) dut->raddr[i] = 0;
        evaluate();

        for (int i = 0; i < 12; i++) {
            check(tname, i, dut->rdata[i], 0x0ULL);
        }
        printf("[Test 4] p0 hardwired zero: %s\n",
               (fail_count == prev_fails) ? "PASS" : "FAIL");
    }

    // =========================================================================
    // Test 5: Multi-write conflict -- highest-indexed port wins
    //   Write p100: port0=0xAA, port1=0xBB, port2=0xCC, port3=0xDD,
    //               port4=0xEE, port5=0xFF
    //   All 6 active => port5 wins => read must return 0xFF.
    //   Then enable only ports 0-3 => port3 wins => 0xDD.
    // =========================================================================
    {
        const char *tname = "Test5_multi_write_conflict";
        int prev_fails = fail_count;

        // Sub-test A: all 6 ports write to same address
        dut->wen = 0x3F;
        for (int wp = 0; wp < 6; wp++) {
            dut->waddr[wp] = 100;
            dut->wdata[wp] = (uint64_t)(0xAA + wp * 0x11);  // 0xAA,0xBB,...,0xFF
        }
        // Read via bypass (same cycle)
        for (int i = 0; i < 12; i++) dut->raddr[i] = 100;
        evaluate();

        // Bypass: highest-indexed active port (5) should win => 0xFF
        for (int i = 0; i < 12; i++) {
            check(tname, i, dut->rdata[i], 0xFFULL);
        }
        tick();   // commit port5's value

        // Sub-test B: only ports 0-3, highest active is port3 => 0xDD
        dut->wen = 0x0F;  // ports 0-3
        for (int wp = 0; wp < 6; wp++) {
            dut->waddr[wp] = 100;
            dut->wdata[wp] = (uint64_t)(0xAA + wp * 0x11);
        }
        for (int i = 0; i < 12; i++) dut->raddr[i] = 100;
        evaluate();   // bypass

        for (int i = 0; i < 12; i++) {
            check(tname, i, dut->rdata[i], 0xDDULL);
        }
        tick();

        printf("[Test 5] multi-write conflict: %s\n",
               (fail_count == prev_fails) ? "PASS" : "FAIL");
    }

    // =========================================================================
    // Summary
    // =========================================================================
    int total = pass_count + fail_count;
    printf("\n=== INT PRF TESTBENCH RESULTS ===\n");
    printf("  Checks passed : %d / %d\n", pass_count, total);
    printf("  Checks failed : %d / %d\n", fail_count, total);
    if (fail_count == 0) {
        printf("  ALL TESTS PASSED\n");
    } else {
        printf("  SOME TESTS FAILED\n");
    }

    tfp->close();
    delete tfp;
    delete dut;

    return (fail_count == 0) ? 0 : 1;
}
