# Sandboxed Windows runner

The Windows port uses CEF 149's prebuilt `bootstrap.exe`. The browser and every
CEF child process launch the same executable, which loads the Flutter runner as
a DLL. The example is configured this way. A stock generated Flutter runner must
be adapted before using this plugin; otherwise initialization fails explicitly.

1. In `windows/runner/CMakeLists.txt`, change the runner target from
   `add_executable(${BINARY_NAME} WIN32 ...)` to
   `add_library(${BINARY_NAME} SHARED ...)`. Keep its existing sources and links.
2. In `windows/CMakeLists.txt`, immediately after
   `include(flutter/generated_plugins.cmake)`, add
   `chromium_webview_enable_sandbox(${BINARY_NAME})`.
3. Include
   `<flutter_chromium_webview/flutter_chromium_webview_plugin_c_api.h>` in
   `windows/runner/main.cpp` and replace `wWinMain` with this exported entry point:

   ```cpp
   extern "C" __declspec(dllexport) int RunWinMain(
       HINSTANCE instance, wchar_t* command_line, int show_command,
       void* sandbox_info, void* version_info) {
     const int cef_exit = FlutterChromiumWebviewExecuteProcess(sandbox_info);
     if (cef_exit >= 0) return cef_exit;
     // Continue the existing browser-process runner body here.
     // Initialize COM and Flutter only after the CEF dispatch above.
   }
   ```

The helper copies the pinned bootstrap beside the runner DLL using the same base
name, so `flutter run`, `flutter test -d windows`, and the release bundle still
launch `${BINARY_NAME}.exe`. Bundle both the executable and DLL, the plugin, CEF
libraries/resources/locales, and Flutter's `data` directory. Locale PAKs are
installed beside the executable and the runtime resolves them there.

This integration follows [CEF's Windows sandbox requirements](https://raw.githubusercontent.com/chromiumembedded/cef/master/docs/sandbox_setup.md).
`USE_SANDBOX=OFF` in CEF's wrapper build bypasses its legacy static-library build
path; runtime sandbox information comes from the bootstrap. There is no runtime
`no_sandbox` setting or automatic fallback. Deployment confinement and signed
distribution remain release checks.

Run `powershell -File scripts/validate_windows.ps1` from the repository root.
It runs analysis, Dart/widget tests, each native integration suite in a separate
Flutter invocation, frame ownership regressions, and a release build. CEF logs
are written to `cef.log` in the configured cache directory. Initialization errors
include the CEF exit code.

Native keyboard messages are intercepted at Flutter's child HWND while a browser
owns focus. Basic Unicode, editing shortcuts and IME composition are forwarded.
Physical clipboard/IME behavior and candidate-window positioning still require
manual desktop validation. Browser blur does not clear a different browser's
focus. Disposal waits for CEF closure, and normal runner shutdown closes browsers
before calling `CefShutdown`.

To verify deployment after the release build, use a fresh absolute output path:

```powershell
./scripts/package_windows.ps1 -NoBuild -Destination C:\artifacts\chromium-webview
./scripts/smoke_windows.ps1 -Bundle C:\artifacts\chromium-webview -LogDirectory ./docs/validation
```

The smoke check launches the copied bundle, sends an ordinary window close,
requires exit code zero and CEF shutdown completion, and checks for surviving
subprocesses. CI runs this check after its release build.
