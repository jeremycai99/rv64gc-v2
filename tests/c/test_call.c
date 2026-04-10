/* test_call.c  -- simplest possible C function call.
 *
 * Tests: function prologue/epilogue, JAL + RET, integer arg passing,
 * and a basic compare.  We mark add() noinline so the call actually
 * happens (GCC would otherwise fold it away at -O2).
 */
int add(int a, int b) __attribute__((noinline));

int add(int a, int b) {
    return a + b;
}

int main(void) {
    int x = add(5, 3);
    return (x == 8) ? 0 : 1;
}
