/* test_array.c -- array on stack with two back-to-back loops.
 *
 * Tests: array indexing, backwards branches, loads/stores to the stack.
 */
int main(void) {
    int arr[10];
    int sum = 0;
    for (int i = 0; i < 10; i++) arr[i] = i;
    for (int i = 0; i < 10; i++) sum += arr[i];
    return (sum == 45) ? 0 : 1;
}
