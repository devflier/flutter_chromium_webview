# Linux CEF Backend — Setup and Architecture

The Linux backend for `flutter_chromium_webview` uses the Chromium Embedded Framework (CEF) through Off-Screen Rendering (OSR) and Flutter textures.

## Requirements and System Libraries

### Operating System & Architecture
- **OS**: Linux desktop distributions (Ubuntu 20.04+, Debian 11+, Fedora 36+, Arch Linux, etc.)
- **Architecture**: `x64` (AMD64)
- **Display Server**: X11 display (or Wayland via XWayland). The plugin explicitly configures CEF for the X11 windowing backend.

### Development & Build Tools
Building a Flutter app with CEF on Linux requires:
- **Clang / LLVM** C++ compiler (supporting C++17)
- **CMake** 3.19 or newer
- **Ninja** (`ninja-build`)
- **pkg-config**
- **GTK 3** development libraries (`libgtk-3-dev`)
- **PulseAudio** or **ALSA** for audio playback (`libpulse-dev` / `pulseaudio`)

On Ubuntu / Debian systems:
```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev pulseaudio pulseaudio-utils
```

### Unprivileged User Namespaces and Sandbox Configuration
Chromium keeps sandboxing enabled by default; the plugin never silently disables sandboxing on ordinary Linux installations (`.deb`, AppImage, local builds).

- **Debian/Ubuntu `.deb` (recommended):** Ship a narrowly scoped AppArmor profile under `/etc/apparmor.d/<your-app>` permitting `userns,` specifically for your app executable and `lib/flutter_chromium_webview_subprocess`, preserving Chromium's native sandbox without relaxing system-wide kernel settings.
- **Snap and Flatpak containers:** Strict Snap confinement (AppArmor + seccomp) and Flatpak (`bwrap`) block Chromium's nested inner user-namespace sandbox. When shipping inside a verified Snap (`$SNAP` + `$SNAP_NAME` + existing `$SNAP` directory) or Flatpak (`$FLATPAK_ID` + `/.flatpak-info`), the host package may explicitly opt out of the inner Chromium sandbox by setting `FLUTTER_CHROMIUM_WEBVIEW_ALLOW_CONTAINER_NO_SANDBOX=1` in the Snap/Flatpak manifest environment.
  - **Security tradeoff:** Disabling Chromium's inner sandbox relies on Snap/Flatpak's outer container confinement rather than per-renderer kernel user/PID/seccomp isolation. Site isolation and renderer process separation remain enabled. This environment variable has **no effect** on standard non-containerized Linux hosts.
- **Local development / CI on Ubuntu 24.04+ / 26.04:** If running unpackaged binaries on a host where AppArmor restricts unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`), you can temporarily permit user namespaces for local testing with:
```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

### Media Controls, Password Store, and Crash Notifications
- Set `CEF_SYSTEM_MEDIA_CONTROLS=0` before `ChromiumWebViewController.initialize()` if the host owns MPRIS/media keys and wants to suppress Chromium's duplicate media session.
- Renderer terminations are reported via `CefRequestHandler::OnRenderProcessTerminated` as `browserCrash` events to Dart.
- **Password store (strictly opt-in, testing only):** By default, Chromium uses the host desktop's native keyring (`detect`). For headless or CI environments without an unlocked keyring daemon, `FLUTTER_CHROMIUM_WEBVIEW_PASSWORD_STORE` may be explicitly set to one of `basic`, `gnome-libsecret`, `kwallet`, `kwallet5`, `kwallet6`, or `detect`. Setting `FLUTTER_CHROMIUM_WEBVIEW_PASSWORD_STORE=basic` stores cookie/credential encryption keys less securely than an OS keyring and must **not** be enabled by default in production deployments.

## CEF Distribution and Automatic Download

CEF is a large binary (~100 MB compressed, ~1 GB uncompressed). The plugin does not bundle CEF inside the pub.dev package archive.

Instead, during your **first build**, CMake automatically:
1. Downloads the pinned, SHA-256 verified CEF `minimal` distribution:
   - Version: `149.0.4+g2f1bfd8+chromium-149.0.7827.156`
   - Archive: `cef_binary_149.0.4+g2f1bfd8+chromium-149.0.7827.156_linux64_minimal.tar.bz2`
2. Extracts it to the build cache directory.
3. Compiles `libcef_dll_wrapper` using Ninja.

### Offline Builds
To build without an internet connection, pre-download the tarball and pass the path to CMake via the `CEF_TARBALL` variable:
```bash
flutter build linux --dart-define=CEF_TARBALL=/path/to/cef_binary_..._linux64_minimal.tar.bz2
```

## Architecture and Rendering Pipeline

```mermaid
graph LR
    Flutter[GTK / Flutter Main Thread] -->|MethodChannel| Plugin[flutter_chromium_webview_plugin.cc]
    Plugin -->|CefPostTask TID_UI| CEF[CEF Dedicated UI Thread]
    CEF -->|OnPaint OSR| Texture[CefTexture Mutex Buffer]
    CEF -->|g_idle_add_full| Flutter
    Texture -->|copy_pixels| Engine[Flutter Raster Thread]
```

1. **Off-Screen Rendering (OSR)**: CEF renders pages into memory buffers without creating top-level native X11 windows.
2. **Pixel Buffer Flow & Ownership**: Frames delivered via `CefRenderHandler::OnPaint` on CEF's `TID_UI` thread convert BGRA→RGBA into an exact-sized staging buffer in `FlutterChromiumTexture` and post a coalesced notification to the GTK main thread (`fl_texture_registrar_mark_texture_frame_available`). On Flutter's raster thread (`copy_pixels`), the staging buffer is swapped into the raster-owned front buffer in $O(1)$ without a second copy, and the previous staging buffer is immediately released so idle WebViews retain only a single exact-sized frame buffer. Closing a popup (`OnPopupShow(false)`) or disposing a browser marks buffers for raster-safe release (`flutter_chromium_texture_clear`), calls `WasHidden(true)`, and invokes `malloc_trim(0)` on `TID_UI` in `OnBeforeClose` to return freed heap pages to the OS without blocking the GTK main thread.
3. **Flutter Texture**: The texture is registered with the Flutter Engine's texture registry (`FlTextureRegistrar`) strictly on the GTK main thread, making the webview an ordinary Flutter widget that can be positioned, clipped, transformed, and layered.
4. **Message Loop & GTK Lifecycle Integration (`multi_threaded_message_loop = true`)**:
   - CEF runs its browser-process UI message loop on its own dedicated thread (`settings.multi_threaded_message_loop = true`, `settings.external_message_pump = false`). GTK's `g_application_run()` runs completely unmodified with zero global symbol interposition (`g_application_hold`/`release`/`quit` resolve directly to `libgio-2.0.so.0`), zero ELF link-order constraints, and `< 1%` idle CPU (`0.0%` main thread after init/close, `0.2%` main thread / `0.9%` full tree on a static idle page).
   - **Thread affinity**: GTK3, `FlMethodChannel`, `FlTextureRegistrar`, `CefInitialize()`, and `CefShutdown()` run exclusively on the GTK/Flutter main thread. All `CefBrowserHost`, `CefBrowser`, `CefRequestContext`, and `PendingCallbacks` operations run exclusively on CEF's `TID_UI` thread via `CefRuntimeManager::PostToCefUi()`. CEF events and frame notifications marshal back to GTK via `CefRuntimeManager::PostToGtkMain()` (`g_idle_add_full`) with cancellation through `GtkBrowserBridge` and never capture `CefRefPtr` handles in GLib callbacks.
   - **Clean shutdown order**: On `GApplication::shutdown`, each plugin closes its browsers (`CloseAll` unregisters textures synchronously on GTK and posts `CloseBrowser(true)` to `TID_UI`). `CefRuntimeManager::Shutdown()` waits via a condition variable for all pending and open browsers to finish `OnBeforeClose` on `TID_UI`, runs a `TID_UI` task barrier so all queued tasks release their `CefRefPtr` handles, and executes `CefShutdown()` on the GTK main thread.
5. **Memory Profile Opt-out**: By default on Linux, `SoftwareRenderingApp` disables speculative spare renderer creation (`SpareRendererForSitePerProcess`) and unused desktop Chrome background features (`OptimizationHints`, `MediaRouter`, `Translate`, `BackForwardCache`, component updater, extensions, sync) while keeping sandboxing, site isolation, TLS validation, and multi-process architecture fully enabled. Set `FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0` in the environment to revert to stock Chromium feature defaults.

## Input and Keyboard Handling

- **Mouse / Pointer Events**: Flutter pointer events (`PointerDownEvent`, `PointerMoveEvent`, `PointerUpEvent`, `PointerScrollEvent`) are transformed according to device pixel ratio and forwarded as CEF mouse events.
- **Keyboard & Focus**: Focus is managed between Flutter and CEF. When the widget has focus, key events are forwarded via X11 keycodes.
- **Context Menus & Dialogs**: CEF delegates JavaScript dialogs (`alert`, `confirm`, `prompt`) and context menus to Flutter widgets via `onJSDialog` and `onContextMenu`.

## Validation and Benchmarking

To run the complete Linux validation suite (analysis, unit tests, all 7 integration suites, release build, and idle-CPU/shutdown gate):
```bash
bash scripts/validate_linux.sh
```

Additional Linux verification and benchmark scripts:
- `bash scripts/check_linux_idle_cpu.sh` — verifies idle main-thread CPU, clean window close, `[CEF] Shutdown complete`, zero unhandled Dart exceptions, and zero orphan subprocesses.
- `bash scripts/test_linux_lifecycle.sh` — executes the 14-scenario GTK/WebView lifecycle matrix (multi-WebView, multi-window, held-application window reopen, rapid open/close, `exitApplication()`, `SystemNavigator.pop()`, direct `g_application_quit()`, and 10 consecutive launch/shutdown cycles).
- `bash scripts/benchmark_linux_cpu.sh` — measures per-thread and per-subprocess CPU across idle init, static page idle, active navigation, and post-close idle (JSON/CSV output).
- `bash scripts/benchmark_linux_memory.sh` — measures process-tree RSS, PSS, USS, shared, anonymous, and peak `VmHWM` across 12 scenarios including a configurable idle soak (JSON/CSV output).

See `docs/linux-0.5.6-benchmarks.md` for measured `0.5.6` CPU and RAM benchmark results.

Under WSLg (Windows Subsystem for Linux with GUI):
```bash
bash scripts/run_wsl.sh
```

## Known Limitations

- **Software Compositing**: Linux uses software pixel buffer copying between CEF (`--disable-gpu`, `--disable-gpu-compositing`) and the Flutter Engine.
- **Display Backend (`GDK_BACKEND=x11`)**: CEF is configured with `--ozone-platform=x11`. On Wayland desktops (especially virtualized graphics such as VirtualBox VMSVGA, where native Wayland subsurface initialization can time out), launch with `GDK_BACKEND=x11` to use XWayland.
- **Codecs**: Standard CEF builds include open-source codecs (VP8, VP9, AV1, Opus, Vorbis). Proprietary codecs (H.264, AAC) are not licensed or included.
- **Process Lifetime**: Once `CefShutdown()` is called, CEF cannot be re-initialized in the same process; restarting the app is required.
