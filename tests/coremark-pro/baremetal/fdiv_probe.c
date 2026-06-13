/* fdiv_probe — bisect the radix2 main-entry wedge: marker, FMUL/FADD, FDIV, sin(). */
#include <stdint.h>
double sin(double);
static inline void marker(unsigned long v){__asm__ volatile("csrw mscratch,%0"::"r"(v):"memory");}
static void halt(int c)__attribute__((noreturn));
static void halt(int c){volatile unsigned long*t=(volatile unsigned long*)0x80001000UL;*t=c==0?1UL:(unsigned long)((c<<1)|1);for(;;);}
volatile double g_a = 3.0, g_b = 7.0, g_s;
int main(void){
    marker(0xAABB0001UL);
    g_s = g_a * g_b + g_a;            /* FMUL/FADD */
    marker(0xAABB0002UL);
    g_s = g_a / g_b;                  /* FDIV.D */
    marker(0xAABB0003UL);
    g_s = sin(1.5);                   /* full libm path */
    marker(0xAABB0004UL);
    if (g_s > 0.99 && g_s < 1.0) halt(0);
    halt(2);
}
