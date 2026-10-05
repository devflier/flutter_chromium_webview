#import <FlutterMacOS/FlutterMacOS.h>

// Set the application's NSPrincipalClass to ChromiumWebViewApplication before
// NSApplicationMain creates the application. See MACOS.md for host setup.
@interface ChromiumWebViewApplication : NSApplication
@end

@interface FlutterChromiumWebviewPlugin : NSObject <FlutterPlugin>
@end
