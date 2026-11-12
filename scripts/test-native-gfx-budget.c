/* Executes production gfx.c, with a bounded allocator to make the pre-fix
 * 4GiB request observable without allocating it. Accepted cases allocate and
 * free their real byte counts; no synthetic accounting replaces app logic. */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static void* review_aligned_calloc(size_t count, size_t size, size_t alignment);
static void review_aligned_free(void* memory);
#define winpr_aligned_calloc review_aligned_calloc
#define winpr_aligned_free review_aligned_free
#ifndef GFX_REVIEW_SOURCE
#error "Define GFX_REVIEW_SOURCE as the verified patched production gfx.c"
#endif
#include GFX_REVIEW_SOURCE
#undef winpr_aligned_calloc
#undef winpr_aligned_free

typedef struct allocation { void* pointer; size_t bytes; struct allocation* next; } allocation;
static allocation* allocations;
static size_t bytes_live, calls, largest_request;
static gdiGfxSurface* surfaces[65536];
static UINT review_set(RdpgfxClientContext* context, UINT16 id, void* data)
{ (void)context; surfaces[id]=data; return CHANNEL_RC_OK; }
static void* review_get(RdpgfxClientContext* context, UINT16 id)
{ (void)context; return surfaces[id]; }
static UINT review_ids(RdpgfxClientContext* context, UINT16** out, UINT16* count)
{
    (void)context; UINT32 n=0; for (UINT32 i=0;i<65536;i++) if(surfaces[i])n++;
    assert(n<=65535); *count=(UINT16)n; *out=n?malloc(n*sizeof(UINT16)):NULL;
    UINT32 j=0; for(UINT32 i=0;i<65536;i++) if(surfaces[i])(*out)[j++]=(UINT16)i;
    return CHANNEL_RC_OK;
}
static void* review_aligned_calloc(size_t count, size_t size, size_t alignment)
{
    assert(size==0 || count<=SIZE_MAX/size); size_t total=count*size; calls++;
    if(total>largest_request)largest_request=total;
    /* This harness will never commit over512MiB, including on vulnerable code. */
    if(total>512ull*1024*1024 || total>512ull*1024*1024-bytes_live)return NULL;
    void* data=NULL; if(posix_memalign(&data,alignment,total)!=0)return NULL;
    memset(data,0,total); allocation* entry=malloc(sizeof(*entry)); assert(entry);
    *entry=(allocation){data,total,allocations};allocations=entry;bytes_live+=total;return data;
}
static void review_aligned_free(void* memory)
{
    if(!memory)return;allocation** previous=&allocations;
    while(*previous && (*previous)->pointer!=memory)previous=&(*previous)->next;
    assert(*previous);allocation* entry=*previous;*previous=entry->next;
    bytes_live-=entry->bytes;free(memory);free(entry);
}
static UINT create(RdpgfxClientContext* gfx,UINT16 id,UINT16 width,UINT16 height)
{ RDPGFX_CREATE_SURFACE_PDU pdu={0};pdu.surfaceId=id;pdu.width=width;pdu.height=height;pdu.pixelFormat=GFX_PIXEL_FORMAT_XRGB_8888;return gdi_CreateSurface(gfx,&pdu); }
static void remove_surface(RdpgfxClientContext* gfx,UINT16 id)
{ RDPGFX_DELETE_SURFACE_PDU pdu={0};pdu.surfaceId=id;assert(gdi_DeleteSurface(gfx,&pdu)==CHANNEL_RC_OK); }
static void clear(RdpgfxClientContext* gfx)
{for(UINT32 i=0;i<65536;i++)if(surfaces[i])remove_surface(gfx,(UINT16)i);assert(bytes_live==0 && !allocations);}
int main(void)
{
    rdpSettings* settings=freerdp_settings_new(0);assert(settings);
    assert(freerdp_settings_set_bool(settings,FreeRDP_DeactivateClientDecoding,TRUE));
    rdpContext context={0};context.settings=settings;rdpGdi gdi={0};gdi.context=&context;
    RdpgfxClientContext gfx={0};gfx.custom=&gdi;gfx.GetSurfaceIds=review_ids;gfx.GetSurfaceData=review_get;gfx.SetSurfaceData=review_set;
    InitializeCriticalSection(&gfx.mux);
#ifdef REVIEW_EXPECT_UNPATCHED
    assert(create(&gfx,1,32766,32766)!=CHANNEL_RC_OK);
    assert(largest_request>4ull*1024*1024*1024);assert(bytes_live==0);
    printf("Reproduced unpatched production4GiB allocation request (%zu bytes) with zero large allocations.\n",largest_request);
#else
    size_t before=calls;
    assert(create(&gfx,1,32766,32766)!=CHANNEL_RC_OK);
    assert(create(&gfx,1,8193,16)!=CHANNEL_RC_OK);
    assert(create(&gfx,1,16,0)!=CHANNEL_RC_OK);assert(calls==before);
    assert(create(&gfx,1,8192,8192)==CHANNEL_RC_OK);
    assert(bytes_live==(8192ull*4+16)*8192);before=calls;
    assert(create(&gfx,1,8192,8192)!=CHANNEL_RC_OK);assert(calls==before);
    assert(create(&gfx,2,8192,8192)!=CHANNEL_RC_OK);assert(calls==before);
    remove_surface(&gfx,1);assert(bytes_live==0);
    assert(create(&gfx,2,8192,8192)==CHANNEL_RC_OK);clear(&gfx);
    for(UINT16 i=0;i<3;i++)assert(create(&gfx,i,8192,4096)==CHANNEL_RC_OK);
    before=calls;assert(create(&gfx,3,8192,4096)!=CHANNEL_RC_OK);assert(calls==before);
    remove_surface(&gfx,1);assert(create(&gfx,3,8192,4096)==CHANNEL_RC_OK);clear(&gfx);
    for(UINT16 i=0;i<256;i++)assert(create(&gfx,i,16,16)==CHANNEL_RC_OK);
    before=calls;assert(create(&gfx,256,16,16)!=CHANNEL_RC_OK);assert(calls==before);
    remove_surface(&gfx,4);assert(create(&gfx,256,16,16)==CHANNEL_RC_OK);clear(&gfx);
    puts("PASS: actual production GFX oversized/dimension/duplicate limits, real8192x8192 allocation,512MiB aggregate,256surface count, deletion refunds and reuse (run with ASan+UBSan in the test script).");
#endif
    DeleteCriticalSection(&gfx.mux);freerdp_settings_free(settings);return 0;
}
