#import "ChromiumBackend.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <set>
#include "PendingCallbacks.h"
#include "../../native/javascript_bridge.h"
#include "../../native/html_document.h"
#include "../../native/browser_settings.h"

namespace chromium_macos {
namespace {
std::set<Core*> cores;
std::unique_ptr<CefScopedLibraryLoader> loader;
int64_t next_browser_id = 1;
NSString* Text(const CefString& text) { return [NSString stringWithUTF8String:text.ToString().c_str()] ?: @""; }
CefString CefText(NSString* text) { return CefString(text.UTF8String ?: ""); }
NSString* String(NSDictionary* args, NSString* key, NSString* fallback = @"") {
  return [args[key] isKindOfClass:NSString.class] ? args[key] : fallback;
}
double Number(NSDictionary* args, NSString* key, double fallback = 0) {
  return [args[key] isKindOfClass:NSNumber.class] ? [args[key] doubleValue] : fallback;
}
FlutterError* Error(NSString* code, NSString* message) {
  return [FlutterError errorWithCode:code message:message details:nil];
}
NSArray* Menu(CefRefPtr<CefMenuModel> model) {
  NSMutableArray* items = [NSMutableArray array];
  for (size_t index = 0; index < model->GetCount(); ++index) {
    NSMutableDictionary* item = [@{@"commandId": @(model->GetCommandIdAt(index)),
      @"label": Text(model->GetLabelAt(index)), @"type": @(model->GetTypeAt(index)),
      @"isEnabled": @(model->IsEnabledAt(index)), @"isChecked": @(model->IsCheckedAt(index))} mutableCopy];
    if (auto submenu = model->GetSubMenuAt(index)) item[@"subMenu"] = Menu(submenu);
    [items addObject:item];
  }
  return items;
}
class App : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    command->AppendSwitch("disable-gpu"); command->AppendSwitch("use-mock-keychain"); command->AppendSwitch("password-store=basic");
    command->AppendSwitch("disable-gpu-compositing");
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};
}

class Browser : public CefClient, public CefRenderHandler, public CefLifeSpanHandler,
                public CefDisplayHandler, public CefLoadHandler, public CefJSDialogHandler,
                public CefContextMenuHandler, public CefFocusHandler {
 public:
  Browser(int64_t browser_id, id<FlutterTextureRegistry> textures, NSView* view, FlutterMethodChannel* channel)
      : id_(browser_id), textures_(textures), view_(view), channel_(channel) {
    main_ = [[ChromiumTexture alloc] init];
    popup_ = [[ChromiumTexture alloc] init];
    texture_id = [textures_ registerTexture:main_];
    popup_id = [textures_ registerTexture:popup_];
    dpr_ = view.window.backingScaleFactor ?: 1;
  }
  int64_t texture_id = 0, popup_id = 0;
  chromium_bridge::Policy javascript_policy;
  CefRefPtr<chromium_settings::UserAgent> user_agent = new chromium_settings::UserAgent();
  CefRefPtr<chromium_html::Documents> html_documents = new chromium_html::Documents();
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return html_documents; }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() != chromium_bridge::kMessage) return false;
    if (closing_ || !browser_ || !browser_->IsSame(browser)) return true;
    if (auto value = javascript_policy.Receive(frame, source, message))
      Event(@"javascriptMessage", @{@"channel": Text(CefString(value->channel)),
        @"message": Text(CefString(value->message)), @"origin": Text(CefString(value->origin))});
    return true;
  }
  CefRefPtr<CefBrowser> GetBrowser() { return closing_ ? nullptr : browser_; }
  void Event(NSString* name, NSDictionary* args = @{}) {
    if (closing_) return;
    FlutterMethodChannel* channel = channel_;
    if (channel) [channel invokeMethod:@"onBrowserEvent"
      arguments:@{@"browserId": @(id_), @"event": name, @"args": args}];
  }
  void Unregister() {
    if (!registered_) return;
    registered_ = false;
    if (texture_id) [textures_ unregisterTexture:texture_id];
    if (popup_id) [textures_ unregisterTexture:popup_id];
  }
  void Close(std::function<void()> done = {}) {
    user_agent->Cancel();
    html_documents->Clear();
    if (done) close_callbacks_.push_back(std::move(done));
    if (closing_ && browser_) return;
    closing_ = true;
    channel_ = nil;
    Unregister();
    OnResetDialogState(nullptr);
    if (browser_) {
      browser_->GetHost()->SetFocus(false);
      browser_->GetHost()->CloseBrowser(true);
    } else { CompleteClose(); }
  }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    ++Runtime::Shared().browser_count;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    user_agent->Cancel();
    html_documents->Clear();
    closing_ = true;
    channel_ = nil;
    Unregister();
    OnResetDialogState(nullptr);
    browser_ = nullptr;
    Runtime::Shared().BrowserClosed();
    CompleteClose();
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
      const CefString& url, const CefString& name, WindowOpenDisposition disposition,
      bool gesture, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    Event(@"newWindowRequested", @{@"url": Text(url), @"targetFrameName": Text(name),
      @"targetDisposition": @(disposition), @"userGesture": @(gesture)});
    return true;
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = CefRect(0, 0, width_, height_); }
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    NSScreen* screen = view_.window.screen ?: NSScreen.mainScreen;
    if (!screen) return false;
    info.device_scale_factor = dpr_;
    // CEF's macOS screen coordinates use Cocoa's bottom-left origin.
    NSRect frame = screen.frame, work = screen.visibleFrame;
    info.rect = CefRect(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    info.available_rect = CefRect(work.origin.x, work.origin.y, work.size.width, work.size.height);
    return true;
  }
  bool GetScreenPoint(CefRefPtr<CefBrowser>, int x, int y, int& sx, int& sy) override {
    NSView* view = view_;
    if (!view.window) return false;
    NSPoint point = NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y);
    point = [view.window convertPointToScreen:[view convertPoint:point toView:nil]];
    sx = point.x; sy = point.y;
    return true;
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* bytes, int width, int height) override {
    if (closing_ || !registered_) return;
    ChromiumTexture* target = type == PET_POPUP ? popup_ : main_;
    if ([target updateBytes:bytes width:width height:height])
      [textures_ textureFrameAvailable:type == PET_POPUP ? popup_id : texture_id];
  }
  void OnPopupShow(CefRefPtr<CefBrowser>, bool show) override { Event(@"popupShow", @{@"show": @(show)}); }
  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
    Event(@"popupSize", @{@"x": @(rect.x), @"y": @(rect.y), @"width": @(rect.width), @"height": @(rect.height)});
  }
  void Resize(int width, int height, double dpr) {
    width_ = width; height_ = height; dpr_ = dpr;
    if (auto browser = GetBrowser()) {
      browser->GetHost()->NotifyScreenInfoChanged();
      browser->GetHost()->WasResized();
    }
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) Event(@"urlChanged", @{@"url": Text(url)});
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override { Event(@"titleChanged", @{@"title": Text(title)}); }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    Event(@"loadingStateChanged", @{@"isLoading": @(loading), @"canGoBack": @(back), @"canGoForward": @(forward)});
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
      const CefString& text, const CefString& url) override {
    if (frame->IsMain() && code != ERR_ABORTED)
      Event(@"loadError", @{@"errorCode": @(code), @"errorText": Text(text), @"failedUrl": Text(url)});
  }
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&, JSDialogType type,
      const CefString& message, const CefString& prompt, CefRefPtr<CefJSDialogCallback> callback, bool&) override {
    if (closing_) { callback->Continue(false, ""); return true; }
    const int id = dialogs_.Add(callback);
    Event(@"jsDialog", @{@"dialogId": @(id), @"type": @(type), @"message": Text(message), @"defaultPrompt": Text(prompt)});
    return true;
  }
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    auto dialogs = dialogs_.Drain(); auto menus = menus_.Drain();
    if (!dialogs.empty() || !menus.empty()) Event(@"transientUiDismissed");
    for (auto& entry : dialogs) entry.second->Continue(false, "");
    for (auto& entry : menus) entry.second->Cancel();
  }
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    if (closing_) { callback->Cancel(); return true; }
    const int id = menus_.Add(callback);
    Event(@"contextMenuRequested", @{@"menuId": @(id), @"x": @(params->GetXCoord()),
      @"y": @(params->GetYCoord()), @"items": Menu(model)});
    return true;
  }
  void OnContextMenuDismissed(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>) override {
    menus_.Clear(); Event(@"transientUiDismissed");
  }
  void OnTakeFocus(CefRefPtr<CefBrowser>, bool next) override { Event(@"takeFocus", @{@"next": @(next)}); }
  void Dialog(int id, bool success, NSString* input) {
    if (auto callback = dialogs_.Take(id)) callback->Continue(success, CefText(input));
  }
  void ContextMenu(int id, int command) {
    if (auto callback = menus_.Take(id)) {
      if (command < 0) callback->Cancel(); else callback->Continue(command, EVENTFLAG_NONE);
    }
  }
 private:
  void CompleteClose() {
    auto callbacks = std::move(close_callbacks_);
    for (auto& callback : callbacks) callback();
  }
  int64_t id_;
  id<FlutterTextureRegistry> __weak textures_;
  NSView* __weak view_;
  FlutterMethodChannel* __weak channel_;
  ChromiumTexture* __strong main_;
  ChromiumTexture* __strong popup_;
  CefRefPtr<CefBrowser> browser_;
  int width_ = 1, height_ = 1;
  double dpr_ = 1;
  bool closing_ = false, registered_ = true;
  PendingCallbacks<CefRefPtr<CefJSDialogCallback>> dialogs_;
  PendingCallbacks<CefRefPtr<CefRunContextMenuCallback>> menus_;
  std::vector<std::function<void()>> close_callbacks_;
  IMPLEMENT_REFCOUNTING(Browser);
};

Runtime& Runtime::Shared() { static Runtime* runtime = new Runtime; return *runtime; }
void Runtime::Register(Core* core) { cores.insert(core); }
void Runtime::Unregister(Core* core) { cores.erase(core); }
bool Runtime::Initialize(NSString* cache, NSString** error) {
  if (Ready()) return true;
  if (attempted_) { *error = @"CEF initialization is terminal; restart the application"; return false; }
  if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)]) {
    *error = @"Set NSPrincipalClass to ChromiumWebViewApplication before launching the app"; return false;
  }
  NSString* framework = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
  NSString* helper = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"ChromiumWebView Helper.app/Contents/MacOS/ChromiumWebView Helper"];
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
    *error = @"CEF helper bundles are missing; run macos/scripts/embed_cef.py in the Runner build phase"; return false;
  }
  attempted_ = true;
  loader = std::make_unique<CefScopedLibraryLoader>();
  if (!loader->LoadInMain()) { *error = @"Could not load the bundled CEF framework"; return false; }
  NSArray<NSString*>* arguments = NSProcessInfo.processInfo.arguments;
  std::vector<std::string> strings;
  for (NSString* arg in arguments) strings.emplace_back(arg.UTF8String);
  std::vector<char*> argv;
  for (auto& arg : strings) argv.push_back(arg.data());
  argv.push_back(nullptr);
  CefMainArgs main_args(static_cast<int>(strings.size()), argv.data());
  CefSettings settings;
  settings.windowless_rendering_enabled = true;
  settings.external_message_pump = true;
  CefString(&settings.cache_path) = CefText(cache);
  CefString(&settings.root_cache_path) = CefText(cache);
  CefString(&settings.browser_subprocess_path) = CefText(helper);
  CefString(&settings.framework_dir_path) = CefText(framework);
  CefString(&settings.main_bundle_path) = CefText(NSBundle.mainBundle.bundlePath);
  CefString(&settings.log_file) = CefText([cache stringByAppendingPathComponent:@"cef.log"]); settings.log_severity = LOGSEVERITY_VERBOSE;
  std::cerr << "[CEF] Initializing macOS runtime" << std::endl;
  ready_ = CefInitialize(main_args, settings, new App, nullptr);
  if (!ready_) {
    *error = [NSString stringWithFormat:@"CEF initialization failed (exit code %d)", CefGetExitCode()];
    return false;
  }
  timer_ = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*) { CefDoMessageLoopWork(); }];
  [NSRunLoop.mainRunLoop addTimer:timer_ forMode:NSRunLoopCommonModes];
  std::cerr << "[CEF] Initialization result: 1" << std::endl;
  return true;
}
void Runtime::RequestShutdown(std::function<void()> done) {
  if (quitting_) return;
  quitting_ = true;
  on_shutdown_ = std::move(done);
  for (auto* core : cores) core->Detach();
  dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (browser_count) std::cerr << "[CEF] Shutdown timed out; refusing unsafe termination" << std::endl;
  });
}
void Runtime::BrowserClosed() {
  --browser_count;
  if (quitting_ && browser_count == 0)
    dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
}
void Runtime::FinishShutdown() {
  if (!quitting_ || browser_count != 0 || !on_shutdown_) return;
  [timer_ invalidate]; timer_ = nil;
  if (ready_) { CefShutdown(); ready_ = false; }
  // Keep the CEF loader alive through all plugin/client destruction.
  std::cerr << "[CEF] Shutdown complete" << std::endl;
  auto done = std::move(on_shutdown_); done();
}

Core::Core(id<FlutterPluginRegistrar> registrar, FlutterMethodChannel* channel)
    : textures_(registrar.textures), view_(registrar.view), channel_(channel) {
  input_ = [[ChromiumInput alloc] initWithFrame:NSZeroRect];
  [view_ addSubview:input_];
  Runtime::Shared().Register(this);
}
Core::~Core() {
  Detach();
  lifetime_.reset();
  [input_ removeFromSuperview];
  Runtime::Shared().Unregister(this);
}
void Core::Detach() {
  detached_ = true; channel_ = nil;
  CloseAll();
}
void Core::CloseAll(std::function<void()> done) {
  [input_ setBrowser:nullptr];
  auto browsers = std::move(browsers_); browsers_.clear();
  if (browsers.empty()) { if (done) done(); return; }
  auto count = std::make_shared<size_t>(browsers.size());
  for (auto& entry : browsers)
    entry.second->Close([count, done] { if (--*count == 0 && done) done(); });
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
    NSString* error = nil;
    if (!runtime.Initialize(cache, &error)) { result(Error(@"INIT_FAILED", error)); return; }
    if ([session_ isEqualToString:session]) { result(@YES); return; }
    session_ = [session copy]; resetting_ = true;
    std::weak_ptr<int> alive = lifetime_;
    CloseAll([this, result, alive] {
      if (alive.expired()) return;
      resetting_ = false; result(@YES);
    });
    return;
  }
  if (resetting_ || !runtime.Ready() || !session_) {
    result(Error(@"NOT_READY", @"Initialize this browser session first")); return;
  }
  if ([method isEqualToString:@"createBrowser"]) {
    if (!view_.window) { result(Error(@"NO_VIEW", @"A Flutter window is required")); return; }
    int64_t id = next_browser_id++;
    CefRefPtr<Browser> handler = new Browser(id, textures_, view_, channel_);
    handler->javascript_policy.Configure(String(args, @"javascriptChannels", @"{}").UTF8String);
    if (!handler->texture_id || !handler->popup_id) {
      handler->Close(); result(Error(@"TEXTURE_FAILED", @"Could not register Flutter textures")); return;
    }
    CefWindowInfo info;
    info.SetAsWindowless((__bridge CefWindowHandle)view_);
    CefBrowserSettings settings; settings.windowless_frame_rate = 60;
    const bool requires_gesture = Number(args, @"mediaPlaybackRequiresUserGesture", 1) != 0;
    auto context = chromium_settings::CustomContext(requires_gesture, "");
    if (!requires_gesture && !context) {
      handler->Close(); result(Error(@"SETTINGS_FAILED", @"Could not create a private autoplay context")); return;
    }
    auto browser = CefBrowserHost::CreateBrowserSync(info, handler,
      CefText(String(args, @"initialUrl", @"about:blank")), settings, nullptr, context);
    if (!browser) { handler->Close(); result(Error(@"CREATE_FAILED", @"CEF browser creation failed")); return; }
    std::string settings_error;
    if (!requires_gesture && !chromium_settings::AllowAutoplay(browser, settings_error)) {
      handler->Close(); result(Error(@"SETTINGS_FAILED", Text(CefString(settings_error)))); return;
    }
    browsers_[id] = handler;
    result(@{@"browserId": @(id), @"textureId": @(handler->texture_id), @"popupTextureId": @(handler->popup_id)});
    return;
  }
  const int64_t id = static_cast<int64_t>(Number(args, @"browserId", -1));
  auto found = browsers_.find(id);
  if ([method isEqualToString:@"disposeBrowser"]) {
    if (found == browsers_.end()) { result(nil); return; }
    auto handler = found->second;
    if ([input_ ownsBrowser:handler->GetBrowser()]) [input_ setBrowser:nullptr];
    browsers_.erase(found);
    std::weak_ptr<int> alive = lifetime_;
    handler->Close([result, alive] { if (!alive.expired()) result(nil); }); return;
  }
  if (found == browsers_.end() || !found->second->GetBrowser()) {
    result(Error(@"BROWSER_NOT_FOUND", @"Browser has been disposed")); return;
  }
  auto handler = found->second; auto browser = handler->GetBrowser(); auto host = browser->GetHost();
  if ([method isEqualToString:@"setUserAgent"]) {
    const std::weak_ptr<int> alive = lifetime_;
    handler->user_agent->Set(browser, String(args, @"userAgent").UTF8String,
      [result, alive](bool success, const std::string& error) {
        if (alive.expired()) return;
        if (success) result(nil); else result(Error(@"SETTINGS_FAILED", Text(CefString(error))));
      }); return;
  } else if ([method isEqualToString:@"loadRequest"]) {
    NSString* url = String(args, @"url");
    if (![url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
      result(Error(@"INVALID_URL", @"URL must not be empty")); return;
    }
    handler->html_documents->Clear();
    browser->GetMainFrame()->LoadURL(CefText(url));
  } else if ([method isEqualToString:@"loadHtmlString"]) {
    std::string url;
    if (!handler->html_documents->Set(String(args, @"html").UTF8String,
        String(args, @"baseUrl").UTF8String, url)) {
      result(Error(@"INVALID_HTML", @"HTML must be within 4 MiB and baseUrl must be an HTTP(S) URL without credentials or a fragment")); return;
    }
    browser->GetMainFrame()->LoadURL(url);
  } else if ([method isEqualToString:@"reload"]) browser->Reload();
  else if ([method isEqualToString:@"goBack"]) { if (browser->CanGoBack()) browser->GoBack(); }
  else if ([method isEqualToString:@"goForward"]) { if (browser->CanGoForward()) browser->GoForward(); }
  else if ([method isEqualToString:@"executeJavaScript"]) {
    browser->GetMainFrame()->ExecuteJavaScript(CefText(String(args, @"js")), browser->GetMainFrame()->GetURL(), 0);
  } else if ([method isEqualToString:@"setFocus"]) {
    if (Number(args, @"focused")) [input_ setBrowser:browser];
    else if ([input_ ownsBrowser:browser]) [input_ setBrowser:nullptr];
  } else if ([method isEqualToString:@"closeJSDialog"]) {
    handler->Dialog(Number(args, @"dialogId"), Number(args, @"success"), String(args, @"userInput"));
  } else if ([method isEqualToString:@"closeContextMenu"]) {
    handler->ContextMenu(Number(args, @"menuId"), Number(args, @"commandId", -1));
  } else if ([method isEqualToString:@"updateBrowserSize"]) {
    const double width = Number(args, @"width"), height = Number(args, @"height"), dpr = Number(args, @"dpr", 1);
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(dpr) ||
        width < 1 || height < 1 || dpr <= 0 || width * dpr > 16384 || height * dpr > 16384 || width > 16384 || height > 16384) {
      result(Error(@"INVALID_SIZE", @"Dimensions must be finite and at most 16384 physical pixels")); return;
    }
    handler->Resize(width, height, dpr);
  } else if ([method isEqualToString:@"sendPointerEvent"]) {
    CefMouseEvent event; event.x = Number(args, @"x"); event.y = Number(args, @"y"); event.modifiers = Number(args, @"modifiers");
    const int type = Number(args, @"type");
    if (type == 3) host->SendMouseWheelEvent(event, Number(args, @"deltaX"), Number(args, @"deltaY"));
    else if (type == 2 || type == 4) host->SendMouseMoveEvent(event, type == 4);
    else {
      const int button = Number(args, @"button");
      if (button < 1 || button > 3) { result(Error(@"INVALID_BUTTON", @"Expected left, right or middle mouse button")); return; }
      host->SendMouseClickEvent(event, button == 2 ? MBT_RIGHT : button == 3 ? MBT_MIDDLE : MBT_LEFT, type == 1, 1);
    }
  } else { result(FlutterMethodNotImplemented); return; }
  result(nil);
}
}
