#include "circular9_schedule.h"
#include <assert.h>
#include <stdio.h>
int main(void){
 c9_diagnostic_schedule clock={0};uint32_t selected=0,skipped=0;
 assert(c9_diagnostic_due(&clock,160259,1,7,1,&selected,&skipped)&&selected==160256&&!skipped);
 c9_diagnostic_issued(&clock,selected,1,7,1);
 assert(!c9_diagnostic_due(&clock,240255,1,7,1,&selected,&skipped));
 assert(c9_diagnostic_due(&clock,240256,1,7,1,&selected,&skipped)&&selected==240256&&!skipped);
 c9_diagnostic_issued(&clock,selected,1,7,1);
 assert(c9_diagnostic_due(&clock,480500,1,7,1,&selected,&skipped)&&selected==480256&&skipped==2);
 c9_diagnostic_issued(&clock,selected,1,7,1);
 assert(!c9_diagnostic_due(&clock,480500,1,7,1,&selected,&skipped));
 assert(c9_diagnostic_due(&clock,500000,2,7,1,&selected,&skipped)&&selected==500000&&!skipped);
 assert(c9_diagnostic_due(&clock,500000,1,8,1,&selected,&skipped)&&selected==500000);
 assert(c9_diagnostic_due(&clock,500000,1,7,2,&selected,&skipped)&&selected==500000);
 c9_diagnostic_issued(&clock,0xffff0000u,1,7,1);
 assert(c9_diagnostic_due(&clock,0xffff0000u+80000u,1,7,1,&selected,&skipped));
 assert(selected==0xffff0000u+80000u&&!skipped);
 assert(!c9_diagnostic_due(&clock,0xfffeffffu,1,7,1,&selected,&skipped));
 puts("CIRCULAR9_SCHEDULE_PASS exact512ms_hop_latest_only_skip_wrap_era");
 return 0;
}
