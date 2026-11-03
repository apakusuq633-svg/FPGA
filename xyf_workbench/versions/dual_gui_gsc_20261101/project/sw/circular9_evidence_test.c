#define main archived_candidate_fixture
#include "evidence_signal_fixture.c"
#undef main
int main(void){
 make_lut();first_tone=600;tone_step=175;echo_gain=0;
 c9_candidate cs[3]={{.grid=528,.score=1000},{0},{0}};
 c9_search_context ctx={.session=1,.epoch=1,.first_sample=80000,.end_sample=80000+C9_SEARCH_RAW_FRAMES,.geometry_version=1,.geometry_confirmed=1};
 const double angles[]={0,15,30,40,50,60};
 for(unsigned a=0;a<6;a++){
  synthesize(cs,1,angles[a]-2.812, -2.812);c9_search_feedback f;
  CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&ctx,&f),"search");
  CHECK(workspace.debug.first==ctx.first_sample&&workspace.debug.end==ctx.end_sample,"exact raw window");
  unsigned selected=0;
  for(unsigned i=0;i<9;i++)if(workspace.debug.count&(1u<<i)){
   c9_debug_peak *p=&workspace.debug.peaks[i];CHECK(p->band==i/3,"band identity");
   if(p->selected){unsigned k=p->selected-1;selected++;CHECK(k<f.count,"output index");CHECK(p->grid==f.candidates[k].grid,"raw peak retained");CHECK(p->az==f.candidates[k].azimuth_mdeg&&p->el==f.candidates[k].elevation_mdeg,"no debug angle conversion");}
  }
  CHECK(selected==f.count,"one evidence record per output");
  printf("EVIDENCE truth=%.1f count=%u",angles[a],f.count);
  for(unsigned k=0;k<f.count;k++)printf(" az=%d el=%d bands=%u",f.candidates[k].azimuth_mdeg,f.candidates[k].elevation_mdeg,f.band_mask[k]);
  puts("");
 }
 if(fail)return 1;printf("EVIDENCE_PASS bytes_workspace=%u bytes_debug=%u\n",(unsigned)sizeof(workspace),(unsigned)sizeof(c9_search_debug));return 0;
}
