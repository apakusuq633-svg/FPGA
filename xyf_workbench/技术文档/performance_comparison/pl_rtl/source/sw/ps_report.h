/* What xil_printf can format: no %f at all, and no width or padding modifiers (%-12s / %10u /
 * %08x all print garbage). Doubles and hex therefore have to be written out by hand. These two
 * formatters are the display layer the PS-side apps share, so a fix lands in all of them.
 */

#ifndef PS_REPORT_H
#define PS_REPORT_H

#include <stdint.h>
#include "xil_printf.h"

static void print_hex32(uint32_t v)
{
    static const char digits[] = "0123456789abcdef";
    char s[9];
    for (int i = 7; i >= 0; i--) {
        s[i] = digits[v & 0xFu];
        v >>= 4;
    }
    s[8] = '\0';
    xil_printf("%s", s);
}

/* xil_printf has no floating-point support at all -- %f prints the literal characters. Twelve
 * fractional digits is more than enough to see a deviation of 1e-6 and is all a double with a
 * magnitude near 1 carries before the digits stop meaning anything. Display only: every
 * comparison below is done on the doubles themselves, never on this text. */
static void print_f64(double v)
{
    char     buf[48];
    char     tmp[24];
    uint64_t ip;
    int      n = 0, m = 0, i;
    double   frac;

    if (v < 0.0) {
        buf[n++] = '-';
        v = -v;
    }
    ip = (uint64_t)v;
    if (ip == 0u) {
        tmp[m++] = '0';
    }
    while (ip > 0u) {
        tmp[m++] = (char)('0' + (int)(ip % 10u));
        ip /= 10u;
    }
    while (m > 0) {
        buf[n++] = tmp[--m];
    }
    buf[n++] = '.';

    frac = v - (double)(uint64_t)v;
    for (i = 0; i < 12; i++) {
        int d;
        frac *= 10.0;
        d = (int)frac;
        if (d < 0) { d = 0; }
        if (d > 9) { d = 9; }
        buf[n++] = (char)('0' + d);
        frac -= (double)d;
    }
    buf[n] = '\0';
    xil_printf("%s", buf);
}
#endif /* PS_REPORT_H */
