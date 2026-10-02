/* zlib-ng (native zng_ API, gzip wrapper) per body, one long-lived stream
 * re-armed with zng_deflateReset, against libdeflate-6 in the same binary
 * as a cross-check of the Zig harness. Thread CPU time, interleaved. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "zlib-ng.h"
#include "libdeflate.h"
static double cpu_ns(void){struct timespec t;clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t);return t.tv_sec*1e9+t.tv_nsec;}
static unsigned char *slurp(const char *p,size_t *n){FILE*f=fopen(p,"rb");fseek(f,0,SEEK_END);*n=ftell(f);rewind(f);unsigned char*b=malloc(*n);fread(b,1,*n,f);fclose(f);return b;}
int main(void){
  const char *names[]={"arena-25","arena-40","arena-50","bench-25","bench-400","bench-6400"};
  int levels[]={1,6,9};
  zng_stream s[3]; struct libdeflate_compressor *ld=libdeflate_alloc_compressor(6);
  for(int l=0;l<3;l++){memset(&s[l],0,sizeof s[l]); if(zng_deflateInit2(&s[l],levels[l],Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY)!=Z_OK) return 1;}
  unsigned char *out=malloc(8<<20);
  printf("rep,body,in,codec,out,cpu_us\n");
  for(int rep=0;rep<7;rep++) for(int b=0;b<6;b++){
    char path[256]; snprintf(path,sizeof path,"bodies/%s.json",names[b]); size_t n; unsigned char*in=slurp(path,&n);
    for(int l=0;l<4;l++){
      size_t olen=0; int rounds = n>500000?20:(n>50000?300:4000);
      for(int w=0;w<rounds/10+1;w++){ if(l<3){zng_deflateReset(&s[l]); s[l].next_in=in;s[l].avail_in=n;s[l].next_out=out;s[l].avail_out=8<<20; zng_deflate(&s[l],Z_FINISH); olen=s[l].total_out;} else olen=libdeflate_gzip_compress(ld,in,n,out,8<<20);}
      double t0=cpu_ns();
      for(int r=0;r<rounds;r++){ if(l<3){zng_deflateReset(&s[l]); s[l].next_in=in;s[l].avail_in=n;s[l].next_out=out;s[l].avail_out=8<<20; if(zng_deflate(&s[l],Z_FINISH)!=Z_STREAM_END) return 2;} else libdeflate_gzip_compress(ld,in,n,out,8<<20);}
      double us=(cpu_ns()-t0)/rounds/1000.0;
      if(l<3) printf("%d,%s,%zu,zlib-ng-%d,%zu,%.2f\n",rep,names[b],n,levels[l],olen,us);
      else printf("%d,%s,%zu,libdeflate-6(c),%zu,%.2f\n",rep,names[b],n,olen,us);
    }
    free(in);
  }
  return 0;
}
