// Stubs for 128-bit float (quad precision) functions not available on iOS
// These are needed because Zig may emit f128 operations
// We approximate using long double (80-bit on x86, 64-bit on ARM)

#include <math.h>
#include <stdint.h>

typedef long double fp128;

// Division
fp128 __divtf3(fp128 a, fp128 b) {
    return a / b;
}

// Comparison functions
int __eqtf2(fp128 a, fp128 b) {
    return !(a == b);
}

int __netf2(fp128 a, fp128 b) {
    return a != b;
}

int __lttf2(fp128 a, fp128 b) {
    if (a < b) return -1;
    if (a == b) return 0;
    return 1;
}

int __gttf2(fp128 a, fp128 b) {
    if (a > b) return 1;
    if (a == b) return 0;
    return -1;
}

int __getf2(fp128 a, fp128 b) {
    if (a >= b) return 0;
    return -1;
}

int __letf2(fp128 a, fp128 b) {
    if (a <= b) return 0;
    return 1;
}

// Multiplication
fp128 __multf3(fp128 a, fp128 b) {
    return a * b;
}

// Conversion functions
fp128 __extendsftf2(float a) {
    return (fp128)a;
}

float __trunctfsf2(fp128 a) {
    return (float)a;
}

int __fixtfsi(fp128 a) {
    return (int)a;
}

unsigned int __fixunstfsi(fp128 a) {
    return (unsigned int)a;
}

fp128 __floatuntitf(uint64_t a) {
    return (fp128)a;
}

// Trunc function
long double truncq(long double x) {
    return truncl(x);
}
