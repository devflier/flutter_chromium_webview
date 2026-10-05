#ifndef FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <map>
#include <string>

// Forward declarations for CEF classes to avoid including CEF headers here
class CefBrowserHandler;
class CefRuntimeManager;
class CefKeyboard;

namespace flutter_chromium_webview {

class FlutterChromiumWebviewPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar,
                                    FlutterDesktopMessengerRef messenger);

  FlutterChromiumWebviewPlugin(flutter::PluginRegistrarWindows *registrar,
                               std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
                               FlutterDesktopMessengerRef messenger);

  virtual ~FlutterChromiumWebviewPlugin();

  // Disallow copy and assign.
  FlutterChromiumWebviewPlugin(const FlutterChromiumWebviewPlugin&) = delete;
  FlutterChromiumWebviewPlugin& operator=(const FlutterChromiumWebviewPlugin&) = delete;

 private:
  void CloseAll(std::function<void()> done = {});
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::PluginRegistrarWindows *registrar_;
  FlutterDesktopMessengerRef messenger_;
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  
  // A map of browser ID to handler
  std::map<int64_t, void*> browsers_; // Use void* to avoid CEF includes in header, cast to CefRefPtr<CefBrowserHandler>* in cpp
  
  std::string session_id_;
  bool resetting_ = false;
  int window_proc_id_ = -1;
  std::unique_ptr<CefKeyboard> keyboard_;
  std::shared_ptr<int> lifetime_ = std::make_shared<int>(0);
};

}  // namespace flutter_chromium_webview

#endif  // FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_H_
