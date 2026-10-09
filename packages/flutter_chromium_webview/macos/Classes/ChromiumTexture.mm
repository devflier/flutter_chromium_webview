#import "ChromiumTexture.h"
#include <cstring>
#include <mutex>
#import "Protocol.h"

@implementation ChromiumTexture {
  std::mutex _mutex;
  CVPixelBufferRef _frames[3];
  CVPixelBufferRef _activeFrame;
  uint32_t _generation;
  int32_t _activeSlot;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    for (int i = 0; i < 3; i++) _frames[i] = nullptr;
    _activeFrame = nullptr;
    _generation = 0;
    _activeSlot = -1;
    g_counters.activeFlutterTextures++;
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
  for (auto& frame : _frames) {
    if (frame) { CVPixelBufferRelease(frame); g_counters.activeIOSurfaces--; frame = nullptr; }
  }
  g_counters.activeIOSurfaces++;
  _frames[0] = next;
  if (_activeFrame) CVPixelBufferRelease(_activeFrame);
  _activeFrame = CVPixelBufferRetain(_frames[0]);
  return YES;
}

- (BOOL)updateWithIOSurface:(IOSurfaceRef)ioSurface slot:(uint32_t)slot width:(int)width height:(int)height generation:(uint32_t)generation {
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || slot >= 3) {
    if (ioSurface) CFRelease(ioSurface);
    return NO;
  }
  
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
  if (generation < _generation) { CVPixelBufferRelease(next); return NO; }
  if (generation > _generation) {
    for (auto& frame : _frames) {
      if (frame) { CVPixelBufferRelease(frame); g_counters.activeIOSurfaces--; frame = nullptr; }
    }
    if (_activeFrame) { CVPixelBufferRelease(_activeFrame); _activeFrame = nullptr; }
    _generation = generation;
  }
  if (_frames[slot]) { CVPixelBufferRelease(_frames[slot]); g_counters.activeIOSurfaces--; }
  g_counters.activeIOSurfaces++;
  _frames[slot] = next;
  
  if (generation >= _generation) {
    _generation = generation;
    if (_activeSlot == slot) {
       if (_activeFrame) CVPixelBufferRelease(_activeFrame);
       _activeFrame = _frames[slot] ? CVPixelBufferRetain(_frames[slot]) : nullptr;
    }
  }
  return YES;
}

- (void)selectSlot:(uint32_t)slot generation:(uint32_t)generation {
  std::lock_guard<std::mutex> lock(_mutex);
  if (generation < _generation) {
    return;
  }
  if (generation > _generation) {
    for (auto& frame : _frames) {
      if (frame) { CVPixelBufferRelease(frame); g_counters.activeIOSurfaces--; frame = nullptr; }
    }
    if (_activeFrame) { CVPixelBufferRelease(_activeFrame); _activeFrame = nullptr; }
  }
  _generation = generation;
  if (slot < 3) {
    _activeSlot = slot;
    if (_activeFrame) CVPixelBufferRelease(_activeFrame);
    _activeFrame = _frames[slot] ? CVPixelBufferRetain(_frames[slot]) : nullptr;
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  // A raster sample retains its immutable buffer independently of resize,
  // subsequent paints, texture unregistration and this object's destruction.
  return _activeFrame ? CVPixelBufferRetain(_activeFrame) : nullptr;
}
- (void)dealloc {
  for (int i = 0; i < 3; i++) {
    if (_frames[i]) { CVPixelBufferRelease(_frames[i]); g_counters.activeIOSurfaces--; }
  }
  if (_activeFrame) CVPixelBufferRelease(_activeFrame);
  g_counters.activeFlutterTextures--;
}
@end
