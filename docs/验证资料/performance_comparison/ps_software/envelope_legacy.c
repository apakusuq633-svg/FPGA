/* Historical reference frontend; intentionally NOT equivalent to C9F2. */
#include "ps_features.h"
#include "bearing_6004_2zr.h"
void bench_legacy_envelope(const double *x,double hz,double features[18]){
 static int ready;
 if(!ready){fea_setup(39062.5,1400,4600);ready=1;}
 fea_frame18_orders(x,40000,hz,bearing6004_orders,features);fea_norm18(features);
}
