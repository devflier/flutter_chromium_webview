#import <Cocoa/Cocoa.h>
#include "include/cef_browser.h"

@interface ChromiumInput : NSView <NSTextInputClient>
- (void)setBrowser:(CefRefPtr<CefBrowser>)browser;
- (BOOL)ownsBrowser:(CefRefPtr<CefBrowser>)browser;
- (BOOL)focused;
@end
