#import "../Classes/ChromiumTexture.h"
#include <cassert>
#include <thread>

int main() {
  @autoreleasepool {
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
