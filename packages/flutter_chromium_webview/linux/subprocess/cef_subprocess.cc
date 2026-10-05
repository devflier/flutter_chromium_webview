#include "include/cef_app.h"
#include "../../native/javascript_bridge.h"

int main(int argc, char* argv[]) {
  // Provide CEF with command-line arguments.
  CefMainArgs main_args(argc, argv);

  // CEF applications have multiple sub-processes (render, plugin, GPU, etc)
  // that share the same executable. This function checks the command-line and,
  // if this is a sub-process, executes the appropriate logic.
  int exit_code = CefExecuteProcess(main_args, new chromium_bridge::RendererApp(), nullptr);
  if (exit_code >= 0) {
    // The sub-process has completed so return here.
    return exit_code;
  }

  // If we reach here, it means this was called as the browser process,
  // which shouldn't happen because we have a dedicated subprocess executable.
  // The main Flutter app executable should be the browser process.
  return 0;
}
