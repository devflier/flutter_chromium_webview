#import <FlutterMacOS/FlutterMacOS.h>
#include <functional>
#include <map>
#include <memory>
#include <string>
#import "ChromiumInput.h"
#import "ChromiumTexture.h"

namespace chromium_macos {
class BrowserProxy;
class Core;
class Runtime {
 public:
  static Runtime& Shared();
  void Initialize(NSString* cache, std::function<void(bool, NSString*)> completion);
  bool Ready() const { return ready_ && !quitting_; }
  bool PumpRunning() const { return ready_ && !quitting_; }
  int browser_count = 0;
  void RequestShutdown(std::function<void()> done);
  void BrowserClosed();
  void HostFailed();
  void HostReady() { ready_ = true; }
  void Register(Core* core);
  void Unregister(Core* core);
 private:
  bool attempted_ = false;
  bool ready_ = false;
  bool quitting_ = false;
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
  
  void OnHostMessage(const std::string& type, int64_t browserId, NSDictionary* payload);
  void OnHostDisconnected();
  
  std::map<int64_t, std::shared_ptr<BrowserProxy>> browsers_;
 private:
  id<FlutterTextureRegistry> __weak textures_;
  NSView* __weak view_;
  FlutterMethodChannel* __weak channel_;
  ChromiumInput* __strong input_;
  id __strong delegate_obj_;

  NSString* __strong session_ = nil;
  bool resetting_ = false;
  bool detached_ = false;
  std::shared_ptr<int> lifetime_ = std::make_shared<int>(0);
};
}
