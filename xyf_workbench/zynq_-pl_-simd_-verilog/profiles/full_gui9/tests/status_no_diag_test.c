#include <assert.h>
#include "ps_ui_page.h"
void xil_printf(const char *fmt,...){(void)fmt;}
int main(void){
 struct ui_status s={0};static char json[61440];
 s.input_mode=2;s.input_channels=9;s.mics.valid=1;s.mics.channels=9;
 for(unsigned i=0;i<9;i++)s.mics.rms_ppm[i]=100+i;
 int n=ui_json(json,sizeof(json),&s);assert(n>0);
 assert(strstr(json,"\"have\":0")&&strstr(json,"\"mic_valid\":1"));
 assert(strstr(json,"\"mic_rms_ppm\":[100,101,102,103,104,105,106,107,108]"));
 assert(!strstr(json,"\"envelope\""));puts("STATUS_NO_DIAG_NINE_LEVELS_PASS");return 0;
}
