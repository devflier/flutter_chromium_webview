#import "ChromiumTexture.h"
#include <cstring>
#include <mutex>

@implementation ChromiumTexture {
  std::mutex _mutex;
  CVPixelBufferRef _frame;
}
- (BOOL)updateBytes:(const void*)bytes width:(int)width height:(int)height {
  if (!bytes || width <= 0 || height <= 0 || width > 16384 || height > 16384) return NO;
  CVPixelBufferRef next = nullptr;
  NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                               (id)kCVPixelBufferMetalCompatibilityKey: @YES};
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                         kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes,
                         &next) != kCVReturnSuccess) return NO;
  if (CVPixelBufferLockBaseAddress(next, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(next);
    return NO;
  }
  const size_t sourceStride = static_cast<size_t>(width) * 4;
  const size_t stride = CVPixelBufferGetBytesPerRow(next);
  auto* output = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(next));
  for (int row = 0; row < height; ++row)
    std::memcpy(output + row * stride, static_cast<const uint8_t*>(bytes) + row * sourceStride, sourceStride);
  CVPixelBufferUnlockBaseAddress(next, 0);
  std::lock_guard<std::mutex> lock(_mutex);
  if (_frame) CVPixelBufferRelease(_frame);
  _frame = next;
  return YES;
}
- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  // A raster sample retains its immutable buffer independently of resize,
  // subsequent paints, texture unregistration and this object's destruction.
  return _frame ? CVPixelBufferRetain(_frame) : nullptr;
}
- (void)dealloc {
  if (_frame) CVPixelBufferRelease(_frame);
}
@end
