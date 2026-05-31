#ifndef RV64GC_BENCH_MMIO_H
#define RV64GC_BENCH_MMIO_H

/*
 * Simulation-only benchmark result block.
 *
 * The simulation testbench snoops committed stores to this range and prints
 * [BENCH_RESULT] lines. Keep the block on a line separate from tohost.
 */
#define RV64GC_BENCH_BASE      0x80001080UL
#define RV64GC_BENCH_MAGIC     0x525642454e434831UL /* "RVBENCH1" */

#define RV64GC_BENCH_ID_COREMARK   1UL
#define RV64GC_BENCH_ID_DHRYSTONE  2UL
#define RV64GC_BENCH_ID_SPEC       3UL

#define RV64GC_BENCH_REG_MAGIC     0
#define RV64GC_BENCH_REG_ID        1
#define RV64GC_BENCH_REG_ITER      2
#define RV64GC_BENCH_REG_CYCLES    3
#define RV64GC_BENCH_REG_INSTRET   4
#define RV64GC_BENCH_REG_CHECKSUM  5
#define RV64GC_BENCH_REG_FLAGS     6
#define RV64GC_BENCH_REG_CONTROL   7

#define RV64GC_BENCH_CTRL_START    1UL
#define RV64GC_BENCH_CTRL_STOP     2UL

#define RV64GC_BENCH_FLAG_ERROR       1UL
#define RV64GC_BENCH_FLAG_UNVALIDATED 2UL

#define RV64GC_NOINLINE __attribute__((noinline))

static inline unsigned long rv64gc_read_mcycle(void)
{
    unsigned long value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
}

static inline unsigned long rv64gc_read_minstret(void)
{
    unsigned long value;
    __asm__ volatile("csrr %0, minstret" : "=r"(value));
    return value;
}

static RV64GC_NOINLINE void rv64gc_bench_write(unsigned long index,
                                               unsigned long value)
{
    volatile unsigned long *regs = (volatile unsigned long *)RV64GC_BENCH_BASE;
    regs[index] = value;
}

static RV64GC_NOINLINE void rv64gc_bench_report(unsigned long bench_id,
                                                unsigned long iterations,
                                                unsigned long cycles,
                                                unsigned long instret,
                                                unsigned long checksum,
                                                unsigned long flags)
{
    __asm__ volatile("" ::: "memory");
    rv64gc_bench_write(RV64GC_BENCH_REG_MAGIC, RV64GC_BENCH_MAGIC);
    rv64gc_bench_write(RV64GC_BENCH_REG_ID, bench_id);
    rv64gc_bench_write(RV64GC_BENCH_REG_ITER, iterations);
    rv64gc_bench_write(RV64GC_BENCH_REG_CYCLES, cycles);
    rv64gc_bench_write(RV64GC_BENCH_REG_INSTRET, instret);
    rv64gc_bench_write(RV64GC_BENCH_REG_CHECKSUM, checksum);
    rv64gc_bench_write(RV64GC_BENCH_REG_FLAGS, flags);
}

static RV64GC_NOINLINE void rv64gc_bench_begin(unsigned long bench_id,
                                               unsigned long iterations)
{
    __asm__ volatile("" ::: "memory");
    rv64gc_bench_write(RV64GC_BENCH_REG_MAGIC, RV64GC_BENCH_MAGIC);
    rv64gc_bench_write(RV64GC_BENCH_REG_ID, bench_id);
    rv64gc_bench_write(RV64GC_BENCH_REG_ITER, iterations);
    rv64gc_bench_write(RV64GC_BENCH_REG_CONTROL, RV64GC_BENCH_CTRL_START);
}

static RV64GC_NOINLINE void rv64gc_bench_end(unsigned long checksum,
                                             unsigned long flags)
{
    __asm__ volatile("" ::: "memory");
    rv64gc_bench_write(RV64GC_BENCH_REG_CONTROL, RV64GC_BENCH_CTRL_STOP);
    rv64gc_bench_write(RV64GC_BENCH_REG_CHECKSUM, checksum);
    rv64gc_bench_write(RV64GC_BENCH_REG_FLAGS, flags);
}

static RV64GC_NOINLINE void rv64gc_bench_stop(void)
{
    __asm__ volatile("" ::: "memory");
    rv64gc_bench_write(RV64GC_BENCH_REG_CONTROL, RV64GC_BENCH_CTRL_STOP);
}

#endif
