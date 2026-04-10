/* test_inline.c - compute 5+3 inline, no function call. */
int main(void) {
    int a = 5;
    int b = 3;
    int x = a + b;
    return (x == 8) ? 0 : 1;
}
