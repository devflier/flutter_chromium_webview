#import "ChromiumTexture.h"
#include <cstring>
#include <mutex>

@implementation ChromiumTexture {
  std::mutex _mutex;
  CVPixelBufferRef _frames[3];
  uint32_t _currentSlot;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    for (int i = 0; i < 3; i++) _frames[i] = nullptr;
    _currentSlot = 0;
  }
  return self;
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
  if (_frames[0]) CVPixelBufferRelease(_frames[0]);
  _frames[0] = next;
  _currentSlot = 0;
  return YES;
}

- (BOOL)updateWithIOSurface:(IOSurfaceRef)ioSurface slot:(uint32_t)slot width:(int)width height:(int)height {
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || slot >= 3) return NO;
  
  if (!ioSurface) {
      NSLog(@"[ChromiumTexture] updateWithIOSurface called with null surface");
      return NO;
  }
  
  CVPixelBufferRef next = nullptr;
  CVReturn status = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault,
      ioSurface,
      NULL,
      &next
  );
  
  CFRelease(ioSurface); // We own next now, which retains ioSurface
  
  if (status != kCVReturnSuccess || !next) {
      NSLog(@"[ChromiumTexture] CVPixelBufferCreateWithIOSurface failed with %d", status);
      return NO;
  }
  
  std::lock_guard<std::mutex> lock(_mutex);
  if (_frames[slot]) CVPixelBufferRelease(_frames[slot]);
  _frames[slot] = next;
  return YES;
}

- (void)selectSlot:(uint32_t)slot {
  std::lock_guard<std::mutex> lock(_mutex);
  if (slot < 3) {
    _currentSlot = slot;
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  // A raster sample retains its immutable buffer independently of resize,
  // subsequent paints, texture unregistration and this object's destruction.
  return _frames[_currentSlot] ? CVPixelBufferRetain(_frames[_currentSlot]) : nullptr;
}
- (void)dealloc {
  for (int i = 0; i < 3; i++) {
    if (_frames[i]) CVPixelBufferRelease(_frames[i]);
  }
}
@end
