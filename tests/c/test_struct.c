/* test_struct.c -- struct + linked-list walk over globals.
 *
 * Tests: global variable access, struct field access via pointer,
 * pointer chase (data-dependent loads).
 */
struct node { int val; struct node *next; };
struct node a, b, c;

int main(void) {
    a.val = 1; b.val = 2; c.val = 3;
    a.next = &b; b.next = &c; c.next = 0;
    int sum = 0;
    for (struct node *p = &a; p; p = p->next) sum += p->val;
    return (sum == 6) ? 0 : 1;
}
