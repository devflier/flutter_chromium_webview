#import <FlutterMacOS/FlutterMacOS.h>
#include <functional>
#include <map>
#include <memory>
#include "include/cef_app.h"
#include "include/cef_client.h"
#import "ChromiumInput.h"
#import "ChromiumTexture.h"

namespace chromium_macos {
class Browser;
class Core;
class Runtime {
 public:
  static Runtime& Shared();
  bool Initialize(NSString* cache, NSString** error);
  bool Ready() const { return ready_ && !quitting_; }
  bool PumpRunning() const { return timer_ != nil; }
  int browser_count = 0;
  void RequestShutdown(std::function<void()> done);
  void BrowserClosed();
  void Register(Core* core);
  void Unregister(Core* core);
 private:
  bool attempted_ = false;
  bool ready_ = false;
  bool quitting_ = false;
  NSTimer* __strong timer_ = nil;
  std::function<void()> on_shutdown_;
  void FinishShutdown();
};

class Core {
 public:
  Core(id<FlutterPluginRegistrar> registrar, FlutterMethodChannel* channel);
  ~Core();
  void Handle(FlutterMethodCall* call, FlutterResult result);
  void CloseAll(std::function<void()> done = {});
  void Detach();
 private:
  id<FlutterTextureRegistry> __weak textures_;
  NSView* __weak view_;
  FlutterMethodChannel* __weak channel_;
  ChromiumInput* __strong input_;
  std::map<int64_t, CefRefPtr<Browser>> browsers_;
  NSString* __strong session_ = nil;
  bool resetting_ = false;
  bool detached_ = false;
  std::shared_ptr<int> lifetime_ = std::make_shared<int>(0);
};
}
