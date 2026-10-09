#import "ChromiumBackend.h"
#import "ChromiumHostManager.h"
#import "Protocol.h"
#include <cmath>
#include <string>
#include <set>
#include <vector>
#include <servers/bootstrap.h>

// Helper to extract values
static inline NSString* String(NSDictionary* dict, NSString* key, NSString* fallback = nil) {
  id value = dict[key]; return [value isKindOfClass:NSString.class] ? value : fallback;
}
static inline NSNumber* Num(NSDictionary* dict, NSString* key, NSNumber* fallback = @0) {
  id value = dict[key]; return [value isKindOfClass:NSNumber.class] ? value : fallback;
}
static inline double Number(NSDictionary* dict, NSString* key, double fallback = 0.0) {
  id value = dict[key]; return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback;
}
static inline FlutterError* Error(NSString* code, NSString* message) {
  return [FlutterError errorWithCode:code message:message details:nil];
}

@interface CoreDelegateWrapper : NSObject <ChromiumHostManagerDelegate>
@property (nonatomic, assign) chromium_macos::Core* core;
@end

@implementation CoreDelegateWrapper
- (void)onHostMessage:(const IPC::Message&)message {
    if (self.core) {
        int64_t browserId = [Num(message.payload, @"browserId") longLongValue];
        self.core->OnHostMessage(message.type, browserId, message.payload);
    }
}
- (void)onHostDisconnected {
    if (self.core) self.core->OnHostDisconnected();
}
@end

namespace chromium_macos {

class BrowserProxy {
 public:
  BrowserProxy(int64_t browser_id, id<FlutterTextureRegistry> textures, NSView* view, FlutterMethodChannel* channel)
      : id_(browser_id), textures_(textures), view_(view), channel_(channel) {
    main_ = [[ChromiumTexture alloc] init];
    popup_ = [[ChromiumTexture alloc] init];
    texture_id = [textures_ registerTexture:main_];
    popup_id = [textures_ registerTexture:popup_];
    dpr_ = view.window.backingScaleFactor ?: 1;
  }
  
  ~BrowserProxy() {
      Runtime::Shared().BrowserClosed();
      Unregister();
  }
  
  void Unregister() {
    if (texture_id) { [textures_ unregisterTexture:texture_id]; texture_id = 0; }
    if (popup_id) { [textures_ unregisterTexture:popup_id]; popup_id = 0; }
  }

  void Close(std::function<void()> done = {}) {
    if (closing_) { if (done) done(); return; }
    closing_ = true;
    channel_ = nil;
    Unregister();

    IPC::Message msg;
    msg.type = "closeBrowser";
    msg.browserId = std::to_string(id_);
    msg.payload = @{@"browserId": @(id_)};
    // The proxy may be destroyed before a reply (especially after host death).
    // Capture only the completion, never a raw BrowserProxy pointer.
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:^(const IPC::Message& response) {
        if (done) done();
    }];
  }

  void Event(NSString* name, NSDictionary* args = @{}) {
    if (closing_) return;
    FlutterMethodChannel* channel = channel_;
    if (channel) [channel invokeMethod:@"onBrowserEvent"
      arguments:@{@"browserId": @(id_), @"event": name, @"args": args}];
  }
  
  void OnFrameReady(const void* bytes, int width, int height, bool isPopup) {
    if (closing_) return;
    ChromiumTexture* target = isPopup ? popup_ : main_;
    if ([target updateBytes:bytes width:width height:height]) {
      [textures_ textureFrameAvailable:isPopup ? popup_id : texture_id];
    }
  }


  
  void OnSurfaceCreated(IOSurfaceRef surface, uint32_t slot, int width, int height, uint32_t generation, bool isPopup) {
    if (closing_) {
        CFRelease(surface);
        return;
    }
    ChromiumTexture* target = isPopup ? popup_ : main_;
    [target updateWithIOSurface:surface slot:slot width:width height:height generation:generation];
  }
  
  void OnSurfaceFrameReady(uint32_t slot, uint32_t generation, bool isPopup) {
    if (closing_) return;
    ChromiumTexture* target = isPopup ? popup_ : main_;
    [target selectSlot:slot generation:generation];
    [textures_ textureFrameAvailable:isPopup ? popup_id : texture_id];
  }
  int64_t id_;
  id<FlutterTextureRegistry> textures_;
  NSView* __weak view_;
  FlutterMethodChannel* __weak channel_;
  ChromiumTexture* main_;
  ChromiumTexture* popup_;
  int64_t texture_id = 0;
  int64_t popup_id = 0;
  double dpr_;
  bool closing_ = false;
};

static std::set<Core*> cores;
static int64_t next_browser_id = 1;

static mach_port_t g_surface_receive_port = MACH_PORT_NULL;

static void StartSurfacePortListener() {
    if (g_surface_receive_port != MACH_PORT_NULL) return;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_surface_receive_port);
    mach_port_insert_right(mach_task_self(), g_surface_receive_port, g_surface_receive_port, MACH_MSG_TYPE_MAKE_SEND);
    NSString *portName = [NSString stringWithFormat:@"dev.flier.chromiumwebview.surface.ipc.%d", getpid()];
    bootstrap_register(bootstrap_port, (char*)portName.UTF8String, g_surface_receive_port);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (true) {
            IPC::SurfacePortMessage msg = {0};
            // mach_msg needs enough space for the message + trailer
            msg.header.msgh_size = sizeof(msg);
            kern_return_t kr = mach_msg(&msg.header, MACH_RCV_MSG, 0, sizeof(msg) + MAX_TRAILER_SIZE, g_surface_receive_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (kr == KERN_SUCCESS) {
                mach_port_t surface_port = msg.port_desc.name;
                uint64_t browserId = msg.browserId;
                uint32_t width = msg.width;
                uint32_t height = msg.height;
                uint32_t slot = msg.surfaceSlot;
                bool isPopup = msg.isPopup;
                
                IOSurfaceRef surface = IOSurfaceLookupFromMachPort(surface_port);
                mach_port_deallocate(mach_task_self(), surface_port);
                
                if (!surface) {
                    NSLog(@"[ChromiumBackend] Failed to lookup IOSurface from mach port");
                    continue;
                }
                NSLog(@"[ChromiumBackend] Successfully looked up IOSurface %p for slot %u, browserId %llu", surface, slot, browserId);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (auto* core : cores) {
                        auto found = core->browsers_.find(browserId);
                        if (found != core->browsers_.end()) {
                            found->second->OnSurfaceCreated(surface, slot, width, height, msg.generation, isPopup);
                            return;
                        }
                    }
                    CFRelease(surface);
                });
            } else {
                NSLog(@"[ChromiumBackend] mach_msg failed: %x", kr);
            }
        }
    });
}

Runtime& Runtime::Shared() { static Runtime* runtime = new Runtime; return *runtime; }
void Runtime::Register(Core* core) { cores.insert(core); }
void Runtime::Unregister(Core* core) { cores.erase(core); }

void Runtime::Initialize(NSString* cache, std::function<void(bool, NSString*)> completion) {
  if (Ready()) {
      if (completion) completion(true, nil);
      return;
  }
  if (attempted_) { if (completion) completion(false, @"CEF initialization is terminal; restart the application"); return; }
  attempted_ = true;
  
  Runtime* _this = this;
  [[ChromiumHostManager sharedManager] launchHostWithCompletion:^(BOOL success, NSError *error) {
      if (success) {
          _this->ready_ = true;
          if (completion) completion(true, nil);
      } else {
          if (completion) completion(false, error ? [error localizedDescription] : @"Launch failed");
      }
  }];
}

void Runtime::RequestShutdown(std::function<void()> done) {
  if (quitting_) return;
  quitting_ = true;
  on_shutdown_ = std::move(done);
  for (auto* core : cores) core->Detach();
  [[ChromiumHostManager sharedManager] shutdown];
  FinishShutdown();
}

void Runtime::BrowserClosed() {
  if (browser_count > 0) browser_count--;
  FinishShutdown();
}

void Runtime::HostFailed() {
  ready_ = false;
  attempted_ = false;
  browser_count = 0;
  quitting_ = false;
}

void Runtime::FinishShutdown() {
  if (quitting_ && browser_count == 0 && on_shutdown_) {
    auto done = std::move(on_shutdown_);
    on_shutdown_ = nullptr;
    done();
  }
}

Core::Core(id<FlutterPluginRegistrar> registrar, FlutterMethodChannel* channel)
    : textures_([registrar textures]), view_([registrar view]), channel_(channel), lifetime_(std::make_shared<int>(0)) {
  input_ = [[ChromiumInput alloc] initWithFrame:NSZeroRect];
  [view_ addSubview:input_];
  Runtime::Shared().Register(this);
  
  CoreDelegateWrapper* wrapper = [[CoreDelegateWrapper alloc] init];
  wrapper.core = this;
  delegate_obj_ = wrapper;
  [ChromiumHostManager sharedManager].delegate = wrapper;
  StartSurfacePortListener();
}

Core::~Core() {
  [ChromiumHostManager sharedManager].delegate = nil;
  CoreDelegateWrapper* wrapper = delegate_obj_;
  wrapper.core = nullptr;
  delegate_obj_ = nil;
  Runtime::Shared().Unregister(this);
}

void Core::Detach() {
  detached_ = true; channel_ = nil;
  CloseAll();
}

void Core::CloseAll(std::function<void()> done) {
  [input_ setBrowserId:-1];
  auto browsers = std::move(browsers_); browsers_.clear();
  if (browsers.empty()) { if (done) done(); return; }
  auto count = std::make_shared<size_t>(browsers.size());
  for (auto& entry : browsers)
    entry.second->Close([count, done] { if (--*count == 0 && done) done(); });
}

void Core::OnHostMessage(const std::string& type, int64_t browserId, NSDictionary* payload) {
    auto found = browsers_.find(browserId);
    if (found == browsers_.end()) return;
    auto proxy = found->second;
    
    if (type == "surfaceCreated") {
        // Now handled entirely by Mach side channel (StartSurfacePortListener).
    } else if (type == "frameReady") {
        if (payload[@"surfaceGeneration"]) {
            uint32_t generation = [payload[@"surfaceGeneration"] unsignedIntValue];
            uint32_t slot = [payload[@"surfaceSlot"] unsignedIntValue];
            proxy->OnSurfaceFrameReady(slot, generation, false);
        } else if (payload[@"buffer"]) {
            NSData* buffer = payload[@"buffer"];
            int width = [payload[@"width"] intValue];
            int height = [payload[@"height"] intValue];
            proxy->OnFrameReady(buffer.bytes, width, height, false);
        }
    } else if (type == "javascriptMessage") {
        if ([payload[@"channel"] isKindOfClass:NSString.class] &&
            [payload[@"message"] isKindOfClass:NSString.class] &&
            [payload[@"origin"] isKindOfClass:NSString.class])
            proxy->Event(@"javascriptMessage", payload);
    } else if (type == "urlChanged" || type == "titleChanged" ||
               type == "loadingStateChanged" || type == "loadError") {
        proxy->Event([NSString stringWithUTF8String:type.c_str()], payload);
    } else if (type == "event") {
        proxy->Event(payload[@"name"], payload[@"args"]);
    }
}

void Core::OnHostDisconnected() {
    [input_ setBrowserId:-1];
    for (auto const& entry : browsers_) {
        [channel_ invokeMethod:@"browserCrash" arguments:@{@"browserId": @(entry.first)}];
    }
    CloseAll();
    Runtime::Shared().HostFailed();
}

void Core::Handle(FlutterMethodCall* call, FlutterResult result) {
  NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSString* method = call.method;
  auto& runtime = Runtime::Shared();
  if ([method isEqualToString:@"getPlatformVersion"]) {
    result([@"macOS " stringByAppendingString:NSProcessInfo.processInfo.operatingSystemVersionString]); return;
  }
  if (detached_) { result(Error(@"DETACHED", @"Flutter view detached")); return; }
  if ([method isEqualToString:@"getDiagnostics"]) {
    result(@{@"browsers": @(runtime.browser_count), @"textures": @(browsers_.size()),
      @"pumpRunning": @(runtime.PumpRunning()), @"focused": @([input_ focused])}); return;
  }
  if ([method isEqualToString:@"initialize"]) {
    NSString* cache = String(args, @"cachePath"), *session = String(args, @"sessionId");
    if (!cache.isAbsolutePath || !session.length) {
      result(Error(@"INVALID_ARGUMENT", @"An absolute cachePath and sessionId are required")); return;
    }
    if (resetting_) { result(Error(@"RESETTING", @"Previous session is closing")); return; }
    
    runtime.Initialize(cache, [this, session, result](bool success, NSString* error) {
        if (!success) { result(Error(@"INIT_FAILED", error)); return; }
        if ([session_ isEqualToString:session]) { result(@YES); return; }
        session_ = [session copy]; resetting_ = true;
        std::weak_ptr<int> alive = lifetime_;
        CloseAll([this, result, alive] {
          if (alive.expired()) return;
          resetting_ = false; result(@YES);
        });
    });
    return;
  }
  if (resetting_ || !runtime.Ready() || !session_) {
    result(Error(@"NOT_READY", @"Initialize this browser session first")); return;
  }
  
  if ([method isEqualToString:@"createBrowser"]) {
    if (!view_.window) { result(Error(@"NO_VIEW", @"A Flutter window is required")); return; }
    int64_t id = next_browser_id++;
    auto proxy = std::make_shared<BrowserProxy>(id, textures_, view_, channel_);
    if (!proxy->texture_id || !proxy->popup_id) {
      proxy->Close(); result(Error(@"TEXTURE_FAILED", @"Could not register Flutter textures")); return;
    }
    
    IPC::Message msg;
    msg.type = "createBrowser";
    msg.payload = @{
        @"browserId": @(id),
        @"url": String(args, @"initialUrl", @"about:blank"),
        @"width": @(1024), 
        @"height": @(768),
        @"deviceScaleFactor": @(proxy->dpr_),
        @"javascriptChannels": String(args, @"javascriptChannels", @"{}")
    };
    
    std::weak_ptr<int> alive = lifetime_;
    [[ChromiumHostManager sharedManager] ensureHostRunning:^(BOOL success, NSError *error) {
        if (!success) {
            proxy->Close();
            result(Error(@"HOST_FAILED", error.localizedDescription ?: @"Failed to start host"));
            return;
        }
        runtime.HostReady();
        [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:^(const IPC::Message& response) {
            if (alive.expired()) return;
            if (response.type == "error") {
                proxy->Close();
                result(Error(@"CREATE_FAILED", response.payload[@"message"] ?: @"CEF browser creation failed"));
                return;
            }
            browsers_[id] = proxy;
            runtime.browser_count++;
            result(@{@"browserId": @(id), @"textureId": @(proxy->texture_id), @"popupTextureId": @(proxy->popup_id)});
        }];
    }];
    return;
  }
  
  const int64_t id = static_cast<int64_t>(Number(args, @"browserId", -1));
  auto found = browsers_.find(id);
  if ([method isEqualToString:@"disposeBrowser"]) {
    if (found == browsers_.end()) { result(nil); return; }
    auto proxy = found->second;
    if ([input_ ownsBrowserId:id]) [input_ setBrowserId:-1];
    browsers_.erase(found);
    std::weak_ptr<int> alive = lifetime_;
    proxy->Close([result, alive] { if (!alive.expired()) result(nil); }); return;
  }
  
  if (found == browsers_.end()) {
    result(Error(@"BROWSER_NOT_FOUND", @"Browser has been disposed")); return;
  }
  auto proxy = found->second;
  
  IPC::Message msg;
  msg.browserId = std::to_string(id);
  msg.payload = [args mutableCopy];
  ((NSMutableDictionary*)msg.payload)[@"browserId"] = @(id);
  
  if ([method isEqualToString:@"setUserAgent"]) {
      // not implemented in HostBrowserClient yet
      result(nil); return;
  } else if ([method isEqualToString:@"loadRequest"]) {
    NSString* url = String(args, @"url");
    if (![url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
      result(Error(@"INVALID_URL", @"URL must not be empty")); return;
    }
    msg.type = "navigate";
    msg.payload = @{@"browserId": @(id), @"url": url};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"loadHtmlString"]) {
    NSString* html = String(args, @"html");
    NSString* baseUrl = String(args, @"baseUrl");
    std::system((std::string("echo 'ChromiumBackend loadHtmlString: ") + baseUrl.UTF8String + "' >> /tmp/cef_host_url.txt").c_str());
    if (!html) html = @"";
    if (!baseUrl) baseUrl = @"about:blank";
    msg.type = "loadHtmlString";
    msg.payload = @{@"browserId": @(id), @"html": html, @"baseUrl": baseUrl};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
    result(nil);
    return;
  } else if ([method isEqualToString:@"reload"]) {
      msg.type = "reload";
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"goBack"]) { 
      msg.type = "goBack";
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"goForward"]) {
      msg.type = "goForward";
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"executeJavaScript"] || [method isEqualToString:@"evaluateJavaScript"] ||
             [method isEqualToString:@"getJavaScriptDiagnostics"]) {
      NSString* source = String(args, @"js");
      const double timeout = Number(args, @"timeoutMs", 10000);
      const BOOL diagnostics = [method isEqualToString:@"getJavaScriptDiagnostics"];
      if (!diagnostics && (!source || [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024 ||
          !std::isfinite(timeout) || timeout < 1 || timeout > 60000)) {
          result(Error(@"invalid_argument", @"Expected JavaScript up to 1 MiB and timeout 1–60000 ms")); return;
      }
      msg.type = [method UTF8String];
      msg.payload = args;
      const BOOL discard = [method isEqualToString:@"executeJavaScript"];
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg timeout:timeout / 1000 + 1 responseCallback:^(const IPC::Message& response) {
          NSDictionary* error = [response.payload[@"error"] isKindOfClass:NSDictionary.class] ? response.payload[@"error"] : nil;
          if (response.type == "error" || error) {
              NSDictionary* details = error ?: response.payload;
              result([FlutterError errorWithCode:String(details, @"code", @"javascript_error")
                  message:String(details, @"message", @"JavaScript IPC request failed") details:details]);
          } else if (diagnostics) {
              result(response.payload);
          } else {
              result(discard ? nil : response.payload[@"value"]);
          }
      }];
      return;
  } else if ([method isEqualToString:@"cancelJavaScript"]) {
      msg.type = "cancelJavaScript";
      msg.payload = args;
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"setFocus"]) {
    if (Number(args, @"focused")) [input_ setBrowserId:id];
    else if ([input_ ownsBrowserId:id]) [input_ setBrowserId:-1];
    
    msg.type = "setFocus";
    msg.payload = @{@"browserId": @(id), @"focused": @(Number(args, @"focused") != 0)};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"closeJSDialog"]) {
    // not implemented
  } else if ([method isEqualToString:@"closeContextMenu"]) {
    // not implemented
  } else if ([method isEqualToString:@"updateBrowserSize"]) {
    const double width = Number(args, @"width"), height = Number(args, @"height"), dpr = Number(args, @"dpr", 1);
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(dpr) ||
        width < 1 || height < 1 || dpr <= 0 || width * dpr > 16384 || height * dpr > 16384 || width > 16384 || height > 16384) {
      result(Error(@"INVALID_SIZE", @"Dimensions must be finite and at most 16384 physical pixels")); return;
    }
    proxy->dpr_ = dpr;
    msg.type = "resizeBrowser";
    msg.payload = @{@"browserId": @(id), @"width": @(width), @"height": @(height), @"deviceScaleFactor": @(dpr)};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"sendPointerEvent"]) {
    const int type = static_cast<int>(Number(args, @"type", -1));
    const int button = static_cast<int>(Number(args, @"button"));
    const int clicks = static_cast<int>(Number(args, @"clickCount", 1));
    if (type < 0 || type > 4 || button < 0 || button > 3 || clicks < 1 || clicks > 3) {
      result(Error(@"INVALID_INPUT", @"Invalid pointer event type, button or click count")); return;
    }
    if (type == 0) [input_ setBrowserId:id]; // Focus IPC precedes the click IPC.
    // AppKit owns keyboard input while this responder is active, so Flutter's
    // HardwareKeyboard state may not contain currently held native modifiers.
    const int modifiers = static_cast<int>(Number(args, @"modifiers")) |
        [ChromiumInput cefModifiersForFlags:[NSEvent modifierFlags]];
    static const char* types[] = {"mouseDown", "mouseUp", "mouseMove", "scroll", "mouseLeave"};
    msg.type = types[type];
    msg.payload = @{@"browserId": @(id), @"x": Num(args, @"x"), @"y": Num(args, @"y"),
                    @"deviceScaleFactor": @(proxy->dpr_), @"modifiers": @(modifiers),
                    @"mouseButton": @(button), @"clickCount": @(clicks),
                    @"scrollDeltaX": Num(args, @"deltaX"), @"scrollDeltaY": Num(args, @"deltaY")};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else if ([method isEqualToString:@"sendKeyEvent"] || 
             [method isEqualToString:@"doCommand"] ||
             [method isEqualToString:@"imeCancelComposition"] ||
             [method isEqualToString:@"imeCommitText"] ||
             [method isEqualToString:@"imeSetComposition"]) {
    msg.type = [method UTF8String];
    msg.payload = [args mutableCopy];
    ((NSMutableDictionary*)msg.payload)[@"browserId"] = @(id);
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nil];
  } else { result(FlutterMethodNotImplemented); return; }
  
  result(nil);
}
}
