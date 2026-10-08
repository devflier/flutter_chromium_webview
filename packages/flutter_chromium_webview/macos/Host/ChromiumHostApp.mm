#import "ChromiumHostApp.h"
#import "IpcConnection.h"
#import "HostBrowserClient.h"

@interface ChromiumHostAppDelegate : NSObject <IpcServerDelegate, IpcConnectionDelegate>
@property (nonatomic, strong) IpcServer* server;
@property (nonatomic, strong) IpcConnection* activeConnection;
@property (nonatomic, copy) NSString* expectedToken;
@property (nonatomic, assign) BOOL isHandshakeDone;
- (void)setBrowserClient:(CefRefPtr<HostBrowserClient>)client;
- (CefRefPtr<HostBrowserClient>)browserClient;
@end

@implementation ChromiumHostAppDelegate {
    CefRefPtr<HostBrowserClient> _browserClient;
}

- (void)setBrowserClient:(CefRefPtr<HostBrowserClient>)client {
    _browserClient = client;
}

- (CefRefPtr<HostBrowserClient>)browserClient {
    return _browserClient;
}

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
    NSLog(@"[CEFHost] Received message of type: %s", message.type.c_str());
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
                    @"capabilities": @[@"osr", @"input", @"javascript"]
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
        NSString* jsChannels = message.payload[@"javascriptChannels"] ?: @"{}";
        uint64_t reqId = message.requestId;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->CreateBrowser(browserId, [url UTF8String], width, height, scale, reqId, [jsChannels UTF8String]);
        });
    } else if (message.type == "closeBrowser") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        uint64_t requestId = message.requestId;
        std::string envelopeId = message.browserId;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->CloseBrowser(browserId);
            IPC::Message ack;
            ack.type = "closeBrowserAck";
            ack.requestId = requestId;
            ack.browserId = envelopeId;
            [connection sendMessage:ack];
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
    } else if (message.type == "loadHtmlString") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* html = message.payload[@"html"];
        NSString* baseUrl = message.payload[@"baseUrl"];
        
        std::string html_str = html ? [html UTF8String] : "";
        std::string baseUrl_str = baseUrl ? [baseUrl UTF8String] : "";
        
        NSLog(@"[CEFHost] Calling LoadHtmlString with baseUrl: %s", baseUrl_str.c_str());
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->LoadHtmlString(browserId, html_str, baseUrl_str);
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
    } else if (message.type == "executeJavaScript" || message.type == "evaluateJavaScript") {
        IPC::Message request = message;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->EvaluateJavaScript(request);
        });
    } else if (message.type == "cancelJavaScript") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* operation = message.payload[@"operationId"];
        if (![operation isKindOfClass:NSString.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.browserClient->CancelJavaScript(browserId, [operation UTF8String]);
        });
    } else if (message.type == "getJavaScriptDiagnostics") {
        IPC::Message request = message;
        dispatch_async(dispatch_get_main_queue(), ^{
            IPC::Message response;
            response.type = "javascriptDiagnostics";
            response.requestId = request.requestId;
            response.payload = @{@"pendingJavaScript": @(self.browserClient->PendingJavaScriptCount())};
            [self sendMessageToClient:response];
        });
    } else if (message.type == "sendPointerEvent" || message.type == "mouseMove" ||
               message.type == "mouseDown" || message.type == "mouseUp" ||
               message.type == "mouseLeave" || message.type == "scroll") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        int type = message.type == "sendPointerEvent" ? [message.payload[@"type"] intValue] :
            message.type == "mouseDown" ? 0 : message.type == "mouseUp" ? 1 :
            message.type == "mouseMove" ? 2 : message.type == "scroll" ? 3 : 4;
        int x = [message.payload[@"x"] intValue];
        int y = [message.payload[@"y"] intValue];
        int modifiers = [message.payload[@"modifiers"] intValue];
        int button = [(message.payload[@"mouseButton"] ?: message.payload[@"button"]) intValue];
        int clickCount = message.payload[@"clickCount"] ? [message.payload[@"clickCount"] intValue] : 1;
        if (type < 0 || type > 4 || button < 0 || button > 3 || clickCount < 1 || clickCount > 3) return;
        int deltaX = [(message.payload[@"scrollDeltaX"] ?: message.payload[@"deltaX"]) intValue];
        int deltaY = [(message.payload[@"scrollDeltaY"] ?: message.payload[@"deltaY"]) intValue];

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
                    host->SendMouseClickEvent(event, btn, type == 1, clickCount);
                }
            }
        });
    } else if (message.type == "setFocus") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        bool focused = [message.payload[@"focused"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                session->focused = focused;
                session->browser->GetHost()->SetFocus(focused);
            }
        });
    } else if (message.type == "sendKeyEvent" || message.type == "keyDown" ||
               message.type == "keyUp" || message.type == "textInput") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        int type = message.type == "sendKeyEvent" ? [message.payload[@"type"] intValue] :
            message.type == "keyDown" ? KEYEVENT_RAWKEYDOWN : message.type == "keyUp" ? KEYEVENT_KEYUP : KEYEVENT_CHAR;
        if (type < KEYEVENT_RAWKEYDOWN || type > KEYEVENT_CHAR) return;
        int windows_key_code = [(message.payload[@"keyCode"] ?: message.payload[@"windows_key_code"]) intValue];
        int native_key_code = [(message.payload[@"scanCode"] ?: message.payload[@"native_key_code"]) intValue];
        int modifiers = [message.payload[@"modifiers"] intValue];
        bool is_system_key = [message.payload[@"is_system_key"] boolValue];
        char16_t character = [message.payload[@"character"] intValue];
        char16_t unmodified_character = [message.payload[@"unmodified_character"] intValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                CefKeyEvent event;
                event.type = (cef_key_event_type_t)type;
                event.windows_key_code = windows_key_code;
                event.native_key_code = native_key_code;
                event.modifiers = modifiers;
                event.is_system_key = is_system_key;
                event.character = character;
                event.unmodified_character = unmodified_character;
                session->browser->GetHost()->SendKeyEvent(event);
            }
        });
    } else if (message.type == "doCommand") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* command = message.payload[@"command"];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                auto frame = session->browser->GetFocusedFrame();
                if (!frame) frame = session->browser->GetMainFrame();
                if (frame) {
                    if ([command isEqualToString:@"copy"]) frame->Copy();
                    else if ([command isEqualToString:@"cut"]) frame->Cut();
                    else if ([command isEqualToString:@"paste"]) frame->Paste();
                    else if ([command isEqualToString:@"selectAll"]) frame->SelectAll();
                    else if ([command isEqualToString:@"undo"]) frame->Undo();
                    else if ([command isEqualToString:@"redo"]) frame->Redo();
                }
            }
        });
    } else if (message.type == "imeCancelComposition") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                session->browser->GetHost()->ImeCancelComposition();
            }
        });
    } else if (message.type == "imeCommitText") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* text = message.payload[@"text"];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                std::u16string str(text.length, 0);
                if (text.length) [text getCharacters:reinterpret_cast<unichar*>(str.data()) range:NSMakeRange(0, text.length)];
                session->browser->GetHost()->ImeCommitText(str, CefRange::InvalidRange(), 0);
            }
        });
    } else if (message.type == "imeSetComposition") {
        int64_t browserId = [message.payload[@"browserId"] longLongValue];
        NSString* text = message.payload[@"text"];
        int start = [message.payload[@"selectionStart"] intValue];
        int end = [message.payload[@"selectionEnd"] intValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            auto session = self.browserClient->GetSession(browserId);
            if (session && session->browser) {
                std::u16string str(text.length, 0);
                if (text.length) [text getCharacters:reinterpret_cast<unichar*>(str.data()) range:NSMakeRange(0, text.length)];
                std::vector<CefCompositionUnderline> underlines;
                if (str.length()) {
                    CefCompositionUnderline u;
                    u.range = CefRange(0, static_cast<uint32_t>(str.length()));
                    u.color = 0xFF000000;
                    underlines.push_back(u);
                }
                session->browser->GetHost()->ImeSetComposition(str, underlines, CefRange::InvalidRange(), CefRange(start, end));
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
    __weak ChromiumHostAppDelegate* weakDelegate = delegate;
    delegate.browserClient = new HostBrowserClient([weakDelegate](const IPC::Message& msg) {
        [weakDelegate sendMessageToClient:msg];
    });
}

void ChromiumHostApp::OnContextInitialized() {
    NSLog(@"[CEFHost] OnContextInitialized");
    StartIpcServer();
}

void ChromiumHostApp::OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) {
    // Ephemeral integration fixtures must not prompt for a user's Keychain.
    // Production launches continue using the normal encrypted credential store.
    const char* inputTest = getenv("CEF_INPUT_TEST_USE_MOCK_KEYCHAIN");
    if (inputTest && std::string(inputTest) == "1") {
        command_line->AppendSwitch("use-mock-keychain");
    }
    command_line->AppendSwitchWithValue("disable-features", "Accessibility");
    command_line->AppendSwitch("disable-renderer-accessibility");
    command_line->AppendSwitch("ignore-gpu-blocklist");
    command_line->AppendSwitch("enable-gpu");
    command_line->AppendSwitch("enable-gpu-compositing");
    command_line->AppendSwitch("force-gpu-rasterization");
    command_line->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
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
