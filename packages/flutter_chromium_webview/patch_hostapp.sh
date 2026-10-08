cat << 'INNER_EOF' > macos/Host/ChromiumHostApp.mm
#import "ChromiumHostApp.h"
#import "IpcConnection.h"
#import "HostBrowserClient.h"

@interface ChromiumHostAppDelegate : NSObject <IpcServerDelegate, IpcConnectionDelegate, HostDelegateProtocol>
@property (nonatomic, strong) IpcServer* server;
@property (nonatomic, strong) IpcConnection* activeConnection;
@property (nonatomic, copy) NSString* expectedToken;
@property (nonatomic, assign) BOOL isHandshakeDone;
@property (nonatomic, assign) HostBrowserClient* browserClient;
@end

@implementation ChromiumHostAppDelegate

- (void)sendMessageToClient:(const IPC::Message&)message {
    if (self.activeConnection) {
        [self.activeConnection sendMessage:message];
    }
}

- (void)server:(IpcServer*)server didAcceptConnection:(IpcConnection*)connection {
    if (self.activeConnection) {
        [connection stop];
        return;
    }
    NSLog(@"[CEFHost] client connected");
    self.activeConnection = connection;
    connection.delegate = self;
    [connection start];
}

- (void)serverDidStop:(IpcServer*)server {
    NSLog(@"[CEFHost] server stopped");
}

- (void)connection:(IpcConnection*)connection didReceiveMessage:(const IPC::Message&)message {
    if (!self.isHandshakeDone) {
        if (message.type == "hello") {
            NSString* token = message.payload[@"token"];
            if ([token isEqualToString:self.expectedToken]) {
                NSLog(@"[CEFHost] handshake protocol=%u", message.protocolVersion);
                self.isHandshakeDone = YES;
                
                IPC::Message ack;
                ack.type = "helloAck";
                ack.requestId = message.requestId;
                ack.payload = @{
                    @"host": @"ChromiumWebViewHost",
                    @"pid": @(getpid()),
                    @"capabilities": @[@"osr"]
                };
                [connection sendMessage:ack];
                NSLog(@"[CEFHost] ready");
            } else {
                NSLog(@"[CEFHost] Invalid token");
                IPC::Message err;
                err.type = "error";
                err.requestId = message.requestId;
                err.payload = @{@"code": @"invalid_token"};
                [connection sendMessage:err];
                [connection stop];
            }
        } else {
            [connection stop];
        }
        return;
    }

    if (message.type == "shutdown") {
        IPC::Message ack;
        ack.type = "shutdownAck";
        ack.requestId = message.requestId;
        [connection sendMessage:ack];
        
        // Use CEF to quit message loop properly on UI thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[CEFHost] Shutdown requested by client.");
            CefQuitMessageLoop();
        });
    } else if (message.type == "createBrowser") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* url = message.payload[@"url"];
        int width = [message.payload[@"width"] intValue];
        int height = [message.payload[@"height"] intValue];
        double scale = [message.payload[@"deviceScaleFactor"] doubleValue];
        uint64_t reqId = message.requestId;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->CreateBrowser(browserId, [url UTF8String], width, height, scale, reqId);
        });
    } else if (message.type == "closeBrowser") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->CloseBrowser(browserId);
        });
    } else if (message.type == "resizeBrowser") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        int width = [message.payload[@"width"] intValue];
        int height = [message.payload[@"height"] intValue];
        double scale = [message.payload[@"deviceScaleFactor"] doubleValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->ResizeBrowser(browserId, width, height, scale);
        });
    } else if (message.type == "navigate") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* url = message.payload[@"url"];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                session->browser->GetMainFrame()->LoadURL([url UTF8String]);
            }
        });
    } else if (message.type == "reload") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                session->browser->Reload();
            }
        });
    } else if (message.type == "goBack") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser && session->browser->CanGoBack()) {
                session->browser->GoBack();
            }
        });
    } else if (message.type == "goForward") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser && session->browser->CanGoForward()) {
                session->browser->GoForward();
            }
        });
    } else if (message.type == "executeJavaScript") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* js = message.payload[@"js"];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                session->browser->GetMainFrame()->ExecuteJavaScript([js UTF8String], session->browser->GetMainFrame()->GetURL(), 0);
            }
        });
    } else if (message.type == "sendPointerEvent") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        int type = [message.payload[@"type"] intValue];
        int x = [message.payload[@"x"] intValue];
        int y = [message.payload[@"y"] intValue];
        int modifiers = [message.payload[@"modifiers"] intValue];
        int button = [message.payload[@"button"] intValue];
        int deltaX = [message.payload[@"deltaX"] intValue];
        int deltaY = [message.payload[@"deltaY"] intValue];

        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                CefMouseEvent event;
                event.x = x;
                event.y = y;
                event.modifiers = modifiers;
                
                auto host = session->browser->GetHost();
                if (type == 3) {
                    host->SendMouseWheelEvent(event, deltaX, deltaY);
                } else if (type == 2 || type == 4) { // move or enter/leave
                    host->SendMouseMoveEvent(event, type == 4);
                } else {
                    CefBrowserHost::MouseButtonType btn = MBT_LEFT;
                    if (button == 2) btn = MBT_RIGHT;
                    else if (button == 3) btn = MBT_MIDDLE;
                    host->SendMouseClickEvent(event, btn, type == 1, 1);
                }
            }
        });
    }
}

- (void)connectionDidClose:(IpcConnection*)connection {
    if (self.activeConnection == connection) {
        self.activeConnection = nil;
        self.isHandshakeDone = NO;
        NSLog(@"[CEFHost] client disconnected, initiating shutdown");
        dispatch_async(dispatch_get_main_queue(), ^{
            CefQuitMessageLoop();
        });
    }
}

- (void)connection:(IpcConnection*)connection didFailWithError:(NSError*)error {
    [self connectionDidClose:connection];
}

@end

ChromiumHostApp::ChromiumHostApp(NSString* socketPath, NSString* expectedToken, pid_t parentPid) {
    _socketPath = [socketPath copy];
    _expectedToken = [expectedToken copy];
    _parentPid = parentPid;
    
    ChromiumHostAppDelegate* delegate = [[ChromiumHostAppDelegate alloc] init];
    delegate.expectedToken = _expectedToken;
    _delegateWrapper = (__bridge_retained void*)delegate;
    
    // We instantiate the client here and hand it to the delegate
    delegate.browserClient = new HostBrowserClient(_delegateWrapper);
}

void ChromiumHostApp::OnContextInitialized() {
    NSLog(@"[CEFHost] OnContextInitialized");
    StartIpcServer();
}

void ChromiumHostApp::OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) {
    command_line->AppendSwitch("disable-gpu-compositing");
    command_line->AppendSwitchWithValue("disable-features", "Accessibility");
    command_line->AppendSwitch("disable-renderer-accessibility");
}

void ChromiumHostApp::StartIpcServer() {
    ChromiumHostAppDelegate* delegate = (__bridge ChromiumHostAppDelegate*)_delegateWrapper;
    delegate.server = [[IpcServer alloc] initWithSocketPath:_socketPath];
    delegate.server.delegate = delegate;
    
    NSError* error = nil;
    if ([delegate.server startAndReturnError:&error]) {
        NSLog(@"[CEFHost] socket listening on %@", _socketPath);
    } else {
        NSLog(@"[CEFHost] Failed to start IPC server: %@", error);
        CefQuitMessageLoop();
    }
}
INNER_EOF
