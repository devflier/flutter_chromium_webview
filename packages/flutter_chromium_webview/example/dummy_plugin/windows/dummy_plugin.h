#ifndef FLUTTER_PLUGIN_DUMMY_PLUGIN_H_
#define FLUTTER_PLUGIN_DUMMY_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace dummy_plugin {

class DummyPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  DummyPlugin();

  virtual ~DummyPlugin();

  // Disallow copy and assign.
  DummyPlugin(const DummyPlugin&) = delete;
  DummyPlugin& operator=(const DummyPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace dummy_plugin

#endif  // FLUTTER_PLUGIN_DUMMY_PLUGIN_H_
