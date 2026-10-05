#ifndef FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_C_API_H_

#if defined(FLUTTER_PLUGIN_IMPL)
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif
#include <flutter_windows.h>

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterChromiumWebviewPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

// Call from RunWinMain before creating Flutter. Return nonnegative results.
FLUTTER_PLUGIN_EXPORT int FlutterChromiumWebviewExecuteProcess(void* sandbox_info);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_CHROMIUM_WEBVIEW_PLUGIN_C_API_H_
