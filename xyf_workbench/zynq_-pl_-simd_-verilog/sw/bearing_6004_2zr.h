#ifndef BEARING_6004_2ZR_H
#define BEARING_6004_2ZR_H
/* Appendix A, page 1: 9 balls, d=6.35mm, Dp=31mm.
 * Inner ring rotating and zero contact angle are assumptions, not PDF claims.
 * These orders are not compatible with the archived 6205 classifier. */
#define BEARING6004_RPM_MIN 600u
#define BEARING6004_RPM_MAX 1800u
#define BEARING6004_MODEL_VALIDATED 0
static const double bearing6004_orders[4] = {
    0.3975806451612903, 2.338525527051054,
    3.578225806451613, 5.421774193548387
};
/* The legacy +/-2-bin peak window overlaps DC/adjacent components at low RPM.
 * This predicate is only a resolution warning, never a diagnostic validity test. */
static inline unsigned bearing6004_resolution_mask(double shaft_hz, double df)
{
    unsigned mask=0;
    for(unsigned i=0;i<4;i++) if(bearing6004_orders[i]*shaft_hz<=2.0*df)mask|=1u<<i;
    return mask;
}
#endif
