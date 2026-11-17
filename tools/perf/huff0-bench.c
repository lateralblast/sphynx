/* Compare the compressors SSH could use for 32 KiB packets with no dictionary:
 * zlib's Huffman-only mode (what Compression yes uses), zlib level 6 (for reference,
 * it has a dictionary) and huff0, zstd's Huffman coder, with a fresh table per packet.
 * huff0 is internal to zstd, so this builds against the zstd source tree.
 *
 * usage: hb FILE   (FILE is read whole; its size is cut to a multiple of 32 KiB)
 * build, with Z=path/to/zstd-1.5.7/lib:
 *   cc -O2 -DZSTD_DISABLE_ASM -I$Z -I$Z/common -I$Z/compress -I$Z/decompress huff0-bench.c \
 *      $Z/common/entropy_common.c $Z/common/error_private.c $Z/common/fse_decompress.c \
 *      $Z/compress/huf_compress.c $Z/compress/hist.c $Z/compress/fse_compress.c \
 *      $Z/decompress/huf_decompress.c -lz -o hb
 * The huff0 decompress time includes a memcmp against the input. A packet that huff0
 * cannot shrink is kept as it is, so its decode is not timed (random data).
 */
#define ZSTD_STATIC_LINKING_ONLY
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>
#include "huf.h"
#define CH 32768
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
int main(int argc,char**argv){
 FILE*f=fopen(argv[1],"rb");fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);
 unsigned char*in=malloc(n);if(fread(in,1,n,f)!=(size_t)n)return 1;fclose(f);
 n-=n%CH; long nch=n/CH;
 unsigned char*out=malloc(n+n/10+4096*nch), *dec=malloc(CH);
 size_t*len=malloc(nch*sizeof*len);
 int reps=3;
 for(int mode=0;mode<2;mode++){
  double best=1e9,bestd=1e9;size_t tot=0;
  for(int r=0;r<reps;r++){
   z_stream z;memset(&z,0,sizeof z);
   if(mode==0)deflateInit2(&z,Z_BEST_SPEED,Z_DEFLATED,15,8,Z_HUFFMAN_ONLY);else deflateInit(&z,6);
   double t=now();tot=0;unsigned char*o=out;
   for(long i=0;i<nch;i++){z.next_in=in+i*CH;z.avail_in=CH;z.next_out=o;z.avail_out=CH*2;deflate(&z,Z_SYNC_FLUSH);len[i]=CH*2-z.avail_out;o+=len[i];tot+=len[i];}
   double e=now()-t;if(e<best)best=e;deflateEnd(&z);
   z_stream y;memset(&y,0,sizeof y);inflateInit(&y);o=out;t=now();
   for(long i=0;i<nch;i++){y.next_in=o;y.avail_in=len[i];y.next_out=dec;y.avail_out=CH;inflate(&y,Z_SYNC_FLUSH);if(y.avail_out)return 2;o+=len[i];}
   e=now()-t;if(e<bestd)bestd=e;inflateEnd(&y);
  }
  printf("%-22s ratio %5.1f%%  compress %7.0f MB/s  decompress %7.0f MB/s\n",mode?"zlib level 6 (dict)":"zlib huffman-only",100.0*tot/n,n/best/1e6,n/bestd/1e6);
 }
 {
  size_t ws=HUF_WORKSPACE_SIZE; void*w=malloc(ws+16);
  HUF_CElt ct[256+1];HUF_DTable*dt=malloc(sizeof(HUF_DTable)*(1+(1<<12)));
  double best=1e9,bestd=1e9;size_t tot=0;
  for(int r=0;r<reps;r++){
   double t=now();tot=0;unsigned char*o=out;
   for(long i=0;i<nch;i++){HUF_repeat rep=HUF_repeat_none;
    size_t c=HUF_compress4X_repeat(o,CH,in+i*CH,CH,255,11,w,ws,ct,&rep,0);
    if(HUF_isError(c)||c==0||c==1){memcpy(o,in+i*CH,CH);c=CH;}
    len[i]=c;o+=c;tot+=c;}
   double e=now()-t;if(e<best)best=e;
   o=out;t=now();
   for(long i=0;i<nch;i++){if(len[i]<CH){dt[0]=(HUF_DTable)(12*0x01000001); /* the table's max log, as HUF_CREATE_STATIC_DTABLEX1 sets it */
   size_t d=HUF_decompress4X_hufOnly_wksp((HUF_DTable*)dt,dec,CH,o,len[i],w,ws,0);if(HUF_isError(d)){fprintf(stderr,"dec err %s\n",HUF_getErrorName(d));return 3;}if(memcmp(dec,in+i*CH,CH)){fprintf(stderr,"MISMATCH\n");return 4;}}o+=len[i];}
   e=now()-t;if(e<bestd)bestd=e;
  }
  printf("%-22s ratio %5.1f%%  compress %7.0f MB/s  decompress %7.0f MB/s (incl. verify)\n","huff0 4X per packet",100.0*tot/n,n/best/1e6,n/bestd/1e6);
 }
 return 0;}
