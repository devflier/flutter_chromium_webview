#import <Cocoa/Cocoa.h>

@interface ChromiumInput : NSView <NSTextInputClient>
+ (int)cefModifiersForFlags:(NSEventModifierFlags)flags;
- (void)setBrowserId:(int64_t)browserId;
- (BOOL)ownsBrowserId:(int64_t)browserId;
- (BOOL)focused;
@end
