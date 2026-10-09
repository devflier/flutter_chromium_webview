#import <FlutterMacOS/FlutterMacOS.h>

@interface ChromiumTexture : NSObject <FlutterTexture>
- (BOOL)updateBytes:(const void*)bytes width:(int)width height:(int)height;
- (BOOL)updateWithIOSurface:(IOSurfaceRef)ioSurface slot:(uint32_t)slot width:(int)width height:(int)height generation:(uint32_t)generation;
- (void)selectSlot:(uint32_t)slot generation:(uint32_t)generation;
@end
