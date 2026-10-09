#import "../Classes/ChromiumTexture.h"
#include <cassert>
#import "../Classes/Protocol.h"
#include <thread>

int main() {
  @autoreleasepool {
    ChromiumTexture* pooled = [[ChromiumTexture alloc] init];
    auto surface = [] {
      return IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth: @2, (id)kIOSurfaceHeight: @2,
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)});
    };
    for (uint32_t slot = 0; slot < 3; ++slot)
      assert([pooled updateWithIOSurface:surface() slot:slot width:2 height:2 generation:1]);
    [pooled selectSlot:0 generation:1];
    CVPixelBufferRef oldLease = [pooled copyPixelBuffer];
    assert(oldLease);
    // A frame notification may precede the next Mach surface capability.
    [pooled selectSlot:0 generation:2];
    assert(![pooled copyPixelBuffer]);
#if DEBUG
    assert(g_counters.activeIOSurfaces.load() == 0);
#endif
    assert([pooled updateWithIOSurface:surface() slot:0 width:2 height:2 generation:2]);
    assert(![pooled updateWithIOSurface:surface() slot:1 width:2 height:2 generation:1]);
    CVPixelBufferRef newLease = [pooled copyPixelBuffer];
    assert(newLease);
    CVPixelBufferRelease(newLease);
    // Invalid inputs also consume the transferred surface reference.
    assert(![pooled updateWithIOSurface:surface() slot:3 width:2 height:2 generation:2]);
    pooled = nil;
    assert(CVPixelBufferGetWidth(oldLease) == 2);
    CVPixelBufferRelease(oldLease);
#if DEBUG
    assert(g_counters.activeIOSurfaces.load() == 0);
    assert(g_counters.activeFlutterTextures.load() == 0);
#endif
    ChromiumTexture* texture = [[ChromiumTexture alloc] init];
    const uint8_t first[] = {1, 2, 3, 255};
    assert([texture updateBytes:first width:1 height:1]);
    CVPixelBufferRef lease = [texture copyPixelBuffer];
    assert(lease);
    const uint8_t second[] = {4, 5, 6, 255, 7, 8, 9, 255};
    assert([texture updateBytes:second width:2 height:1]);
    assert(![texture updateBytes:nullptr width:2 height:1]);
    assert(![texture updateBytes:first width:16385 height:1]);
    CVPixelBufferLockBaseAddress(lease, kCVPixelBufferLock_ReadOnly);
    auto* pixel = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(lease));
    assert(pixel[0] == 1 && pixel[1] == 2 && pixel[2] == 3 && pixel[3] == 255);
    CVPixelBufferUnlockBaseAddress(lease, kCVPixelBufferLock_ReadOnly);
    std::thread painter([texture] {
      @autoreleasepool {
        for (int count = 0; count < 1000; ++count) {
          const uint8_t bytes[] = {42, 42, 42, 255};
          assert([texture updateBytes:bytes width:1 height:1]);
        }
      }
    });
    for (int count = 0; count < 1000; ++count) {
      CVPixelBufferRef sample = [texture copyPixelBuffer];
      assert(sample);
      CVPixelBufferLockBaseAddress(sample, kCVPixelBufferLock_ReadOnly);
      auto* bytes = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(sample));
      assert(bytes[3] == 255);
      CVPixelBufferUnlockBaseAddress(sample, kCVPixelBufferLock_ReadOnly);
      CVPixelBufferRelease(sample);
    }
    painter.join();
    texture = nil;
    assert(CVPixelBufferGetWidth(lease) == 1);
    CVPixelBufferRelease(lease);
  }
  return 0;
}
