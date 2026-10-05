#import <FlutterMacOS/FlutterMacOS.h>

@interface ChromiumTexture : NSObject <FlutterTexture>
- (BOOL)updateBytes:(const void*)bytes width:(int)width height:(int)height;
@end
