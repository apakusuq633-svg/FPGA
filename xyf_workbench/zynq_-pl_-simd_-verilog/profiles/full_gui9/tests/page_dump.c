#include "ps_ui_page.h"
void xil_printf(const char *fmt,...){(void)fmt;}
int main(int argc,char **argv){if(argc!=2)return 1;FILE *f=fopen(argv[1],"wb");if(!f)return 2;fwrite(UI_PAGE_HTML,1,sizeof(UI_PAGE_HTML)-1,f);fclose(f);return 0;}
