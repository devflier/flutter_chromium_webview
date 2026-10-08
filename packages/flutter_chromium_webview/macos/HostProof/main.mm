#import <Cocoa/Cocoa.h>
#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_life_span_handler.h"

class SimpleClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefRenderHandler {
 public:
  SimpleClient() {}

  virtual CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
    return this;
  }
  virtual CefRefPtr<CefRenderHandler> GetRenderHandler() override {
    return this;
  }

  virtual void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    NSLog(@"[Host] Browser created.");
  }

  virtual void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    rect = CefRect(0, 0, 800, 600);
  }

  virtual void OnPaint(CefRefPtr<CefBrowser> browser,
                       PaintElementType type,
                       const RectList& dirtyRects,
                       const void* buffer,
                       int width,
                       int height) override {
    static int frame_count = 0;
    if (frame_count++ % 60 == 0) {
      NSLog(@"[Host] OnPaint received frame %d", frame_count);
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(SimpleClient);
};

class SimpleApp : public CefApp, public CefBrowserProcessHandler {
 public:
  SimpleApp() {}

  virtual CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  virtual void OnContextInitialized() override {
    NSLog(@"[Host] OnContextInitialized");
    
    CefWindowInfo window_info;
    window_info.windowless_rendering_enabled = true;
    
    CefBrowserSettings browser_settings;
    browser_settings.windowless_frame_rate = 30;

    CefRefPtr<SimpleClient> client(new SimpleClient());
    
    NSLog(@"[Host] Creating browser...");
    CefBrowserHost::CreateBrowser(window_info, client, "https://example.com", browser_settings, nullptr, nullptr);
  }
  
  virtual void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override {
      command_line->AppendSwitch("disable-gpu-compositing");
  }

 private:
  IMPLEMENT_REFCOUNTING(SimpleApp);
};

int main(int argc, char* argv[]) {
  NSLog(@"[Host] Starting standalone CEF host.");
  CefMainArgs main_args(argc, argv);
  CefRefPtr<SimpleApp> app(new SimpleApp);

  CefSettings settings;
  NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
  NSString* helperPath = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/ChromiumWebView Helper.app/Contents/MacOS/ChromiumWebView Helper"];
  
  CefString(&settings.browser_subprocess_path) = [helperPath UTF8String];
  settings.no_sandbox = false;
  settings.windowless_rendering_enabled = true;

  if (!CefInitialize(main_args, settings, app, nullptr)) {
    NSLog(@"[Host] CefInitialize failed.");
    return 1;
  }

  NSLog(@"[Host] CEF Initialized, running message loop.");
  CefRunMessageLoop();
  
  CefShutdown();
  return 0;
}
