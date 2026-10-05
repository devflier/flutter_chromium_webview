#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "../../native/javascript_bridge.h"

int main(int argc, char** argv) {
  // Initialize the helper sandbox before loading Chromium or touching Cocoa.
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc, argv), new chromium_bridge::RendererApp(), nullptr);
}
