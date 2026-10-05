#include "include/flutter_chromium_webview/flutter_chromium_webview_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_chromium_webview_plugin.h"
#include "include/cef_runtime_manager.h"

int FlutterChromiumWebviewExecuteProcess(void* sandbox_info) {
  return CefRuntimeManager::GetInstance()->ExecuteProcess(sandbox_info);
}

void FlutterChromiumWebviewPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_chromium_webview::FlutterChromiumWebviewPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar),
      FlutterDesktopPluginRegistrarGetMessenger(registrar));
}
