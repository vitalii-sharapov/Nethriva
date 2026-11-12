// Local bounded regression of the actual Cocoa bridge source; no connection or clipboard access.
#import <objc/runtime.h>
#import "../Vendor/NethrivaRDPBridge/MRDPView.m"
#include <assert.h>
static NSUInteger releasedObjects;
@interface NethrivaLifetimeProbe : NSObject
@end
@implementation NethrivaLifetimeProbe
- (void)dealloc { releasedObjects++; [super dealloc]; }
@end
static char probeKey;
static void track(id object) {
    NethrivaLifetimeProbe *probe = [NethrivaLifetimeProbe new];
    objc_setAssociatedObject(object, &probeKey, probe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [probe release];
}
int main(void) {
    @autoreleasepool {
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
        MRDPView *view = [[MRDPView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
        [view initializeView];
        mfContext context = {0}; rdpGdi gdi = {0};
        ((rdpContext*)&context)->gdi = &gdi; context.view = view;
        BYTE xorData[16*16*4] = {0}, andData[16*2] = {0};
        rdpPointer pointer = {0}; pointer.width=16; pointer.height=16; pointer.xorBpp=32;
        pointer.xorMaskData=xorData; pointer.lengthXorMask=sizeof(xorData);
        pointer.andMaskData=andData; pointer.lengthAndMask=sizeof(andData);
        assert(!mf_Pointer_New(NULL, &pointer));
        pointer.width=385; assert(!mf_Pointer_New((rdpContext*)&context, &pointer));
        pointer.width=16; pointer.height=0; assert(!mf_Pointer_New((rdpContext*)&context, &pointer));
        pointer.height=16;
        for (NSUInteger i=0;i<200;i++) {
            @autoreleasepool {
                assert(mf_Pointer_New((rdpContext*)&context, &pointer));
                MRDPCursor *owned = [[view valueForKey:@"cursors"] lastObject];
                track(owned); track(owned->bmiRep); track(owned->nsImage); track(owned->nsCursor);
                NSCursor *retained = [owned->nsCursor retain];
                NSBitmapImageRep *bitmap = [owned->bmiRep retain];
                [view setCursor:retained];
                mf_Pointer_Free((rdpContext*)&context, &pointer);
                assert([[view valueForKey:@"cursors"] count]==0);
                // AppKit-retained cursors must preserve their plane data after cache removal.
                assert([retained image]!=nil && [bitmap bitmapData]!=NULL);
                volatile BYTE pixel=[bitmap bitmapData][16*16*4-1]; (void)pixel;
                [view setCursor:[NSCursor arrowCursor]];
                [bitmap release]; [retained release];
            }
        }
        assert(releasedObjects==800);
        [view release];
        for (int i=0;i<5;i++) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        puts("PASS: 200 actual native cursor create/set/free cycles, 800 owned-object releases, retained bitmap validity and invalid dimensions under ASan/UBSan.");
    }
    return 0;
}
