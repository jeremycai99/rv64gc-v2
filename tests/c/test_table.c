/* test_table.c -- mimic CoreMark's get_seed_32 jump table pattern.
 *
 * The function picks an entry from a static array using its argument as
 * an index, then loads a 32-bit offset and adds it to a base.  This
 * triggers the auipc / addi / sh2add / lw / add / jr sequence we observed
 * blowing up CoreMark.
 */
volatile int idx_in = 1;

static const int table[6] = { -3704, -3744, -3734, -3724, -3714, -3754 };

static int __attribute__((noinline)) lookup(int idx) {
    if (idx > 5) return 0;
    return table[idx] + 0x80004558;
}

int main(void) {
    int i = idx_in;
    int x = lookup(i);
    /* Expected: -3744 + 0x80004558 = 0x800036b8 */
    return (x == 0x800036b8) ? 0 : 1;
}
