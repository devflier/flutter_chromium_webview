#import <Cocoa/Cocoa.h>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "ChromiumHostApp.h"

@interface ChromiumHostApplication : NSApplication <CefAppProtocol>
@end

@implementation ChromiumHostApplication {
    BOOL _handlingSendEvent;
}
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { _handlingSendEvent = handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event {
    CefScopedSendingEvent scoped_sending_event;
    [super sendEvent:event];
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        [ChromiumHostApplication sharedApplication];
        NSString* socketPath = nil;
        NSString* expectedToken = nil;
        pid_t parentPid = 0;
        
        for (int i = 1; i < argc; ++i) {
            NSString* arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg hasPrefix:@"--ipc-socket="]) {
                socketPath = [arg substringFromIndex:@"--ipc-socket=".length];
            } else if ([arg hasPrefix:@"--ipc-token="]) {
                expectedToken = [arg substringFromIndex:@"--ipc-token=".length];
            } else if ([arg hasPrefix:@"--parent-pid="]) {
                parentPid = [[arg substringFromIndex:@"--parent-pid=".length] intValue];
            }
        }
        
        if (!socketPath || !expectedToken) {
            NSLog(@"[CEFHost] Missing --ipc-socket or --ipc-token");
            return 1;
        }

        NSLog(@"[CEFHost] launch pid=%d", getpid());
        
        CefMainArgs main_args(argc, argv);
        CefRefPtr<ChromiumHostApp> app(new ChromiumHostApp(socketPath, expectedToken, parentPid));

        CefSettings settings;
#if DEBUG
        // Opt-in local diagnostics for allocation and video-quality profiling.
        NSString* diagnosticPort = [[[NSProcessInfo processInfo] environment]
            objectForKey:@"CEF_PROFILE_DEBUG_PORT"];
        if (diagnosticPort.length > 0) {
            NSScanner* scanner = [NSScanner scannerWithString:diagnosticPort];
            int port = 0;
            if ([scanner scanInt:&port] && scanner.isAtEnd && port >= 1024 && port <= 65535) {
                settings.remote_debugging_port = port;
            }
        }
#endif
        
        // Ensure we have the path to ChromiumWebViewHost.app, not the parent flutter app
        NSString* exePath = [[NSProcessInfo processInfo] arguments][0];
        NSString* bundlePath = [[[exePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        
        NSLog(@"[CEFHost] NSBundle mainBundle: %@", [[NSBundle mainBundle] bundlePath]);
        NSLog(@"[CEFHost] Resolved bundlePath: %@", bundlePath);
        
        NSString* helperPath = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/ChromiumWebView Helper.app/Contents/MacOS/ChromiumWebView Helper"];
        NSString* fwPath = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework"];
        NSString* resPath = [fwPath stringByAppendingPathComponent:@"Resources"];
        
        NSLog(@"[CEFHost] helperPath: %@", helperPath);
        NSLog(@"[CEFHost] fwPath: %@", fwPath);
        NSLog(@"[CEFHost] resPath: %@", resPath);

        CefString(&settings.main_bundle_path) = [bundlePath UTF8String];
        CefString(&settings.framework_dir_path) = [fwPath UTF8String];
        CefString(&settings.resources_dir_path) = [resPath UTF8String];
        CefString(&settings.locales_dir_path) = [resPath UTF8String];
        CefString(&settings.browser_subprocess_path) = [helperPath UTF8String];
        
        settings.no_sandbox = false;
        settings.windowless_rendering_enabled = true;
        
        // Prevent process singleton behavior from causing CefInitialize to return false
        NSString* cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"cef_cache_%d", getpid()]];
        CefString(&settings.root_cache_path) = [cachePath UTF8String];
        CefString(&settings.cache_path) = [cachePath UTF8String];
        NSString* logPath = NSProcessInfo.processInfo.environment[@"CEF_LOG_FILE"] ?: @"/tmp/cef.log";
        CefString(&settings.log_file) = [logPath UTF8String];
        settings.log_severity = LOGSEVERITY_VERBOSE;

        if (!CefInitialize(main_args, settings, app, nullptr)) {
            NSLog(@"[CEFHost] CefInitialize failed.");
            return 1;
        }

        NSLog(@"[CEFHost] CefInitialize succeeded");
        NSLog(@"[CEFHost] Before CefRunMessageLoop");
        // OnContextInitialized may run inside CefInitialize. A quit request
        // before entering the loop cannot be relied on to stop that loop.
        if (!app->StartupFailed()) CefRunMessageLoop();
        NSLog(@"[CEFHost] After CefRunMessageLoop");
        
        CefShutdown();
        NSLog(@"[CEFHost] CefShutdown complete");
        return app->StartupFailed() ? 1 : 0;
    }
}
