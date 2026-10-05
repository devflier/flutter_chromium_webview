# Running the prototype on WSLg

This independent Flutter desktop plugin embeds CEF using off-screen CPU rendering and a Flutter pixel-buffer texture. The current example targets Linux x64 and is tested with Ubuntu under WSL2/WSLg.

## Why test under WSLg?

WSLg provides a convenient but constrained Linux graphics environment for testing desktop applications directly on Windows. It serves as an excellent testbed for verifying complex graphics pipelines. This plugin must coordinate several distinct rendering systems:

* **Flutter's graphics renderer**: The engine drawing the Flutter UI (e.g., Skia or Impeller).
* **Chromium's off-screen rendering (OSR)**: The CEF subprocess that renders HTML/CSS into raw memory buffers.
* **Software-rendered browser frames**: In our WSLg test configuration, Chromium is forced to use software rendering to guarantee consistent behavior across different host GPUs.
* **Flutter texture composition**: Flutter takes the CPU-rendered Chromium frames, uploads them to the GPU (if hardware-accelerated), and composites them into the Flutter scene.
* **WSLg's graphics environment**: Provides a Wayland/X11 compatibility layer backed by a virtualized GPU or software rendering (llvmpipe).

## Graphics Configurations

**Software Rendering Override (Recommended for WSLg Testing):**
To ensure consistent behavior and avoid host-specific WSLg hardware-acceleration bugs, you can force software rendering using environmental variables:
`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11`
This configuration is used in the `run_wsl.sh` launcher and the integration tests.

**Default Graphics Configuration:**
To test the default graphics configuration (using hardware acceleration if the host environment supports it), simply run the app without the environmental overrides:
`flutter run -d linux`
*(Note: Under WSLg, this may expose host-specific virtualization driver bugs depending on your Windows GPU).*

## Running the example

From Ubuntu, with the Linux Flutter SDK on PATH:

```bash
cd /mnt/c/Users/User/Projects/flutter_chromium_webview
bash scripts/run_wsl.sh
```

The launcher builds a release bundle, then runs with X11 and Mesa llvmpipe. The example selects Flutter's Skia renderer when `WSL_DISTRO_NAME` is present.
To reuse an existing bundle, run `bash scripts/run_wsl.sh --no-build`.
The initial page is https://example.com.

The build requires Flutter's Linux desktop dependencies (Clang, CMake, Ninja, pkg-config, and GTK3 development files). The first build downloads CEF and builds its wrapper. CEF is large; packaging on `/mnt/c` can take several minutes.

## Troubleshooting

* **Missing native libraries**: Ensure `libgtk-3-dev`, `build-essential`, `cmake`, `ninja-build`, and `pkg-config` are installed via `apt`.
* **CEF subprocess startup failures**: Often caused by deadlocks during standard library initialization. The build links CEF before `libc` in the runner to avoid the recursive `localtime` lookup deadlock.
* **Missing resource files**: CEF requires resources like `icudtl.dat` to function. Always launch the installed `bundle` executable, which bundles CEF resources correctly, rather than intermediary build-directory binaries which may fail ICU lookups.
* **Graphics-context errors**: If Flutter crashes on startup in WSLg with GLX/EGL errors, fall back to the software rendering overrides.
* **Browser initialization errors**: A process that has shut down CEF cannot initialize it again. Repeated initialization within one Dart isolate is handled harmlessly by the plugin, but restarting CEF after shutdown requires restarting the process.
* **Platform-channel threading warnings**: The plugin ensures native callbacks are dispatched to the Flutter platform thread.
* **Missing media codecs**: Standard open-source CEF builds do not include proprietary codecs like H.264.
* **Clipboard and input problems**: Native drag-and-drop and default OSR context menus remain unsupported; however, text selection by dragging is supported. Native GTK keyboard events and input method composition are implemented.

## Startup fixes (Implementation Notes)

- Link CEF before libc in the runner to avoid the recursive localtime lookup deadlock during initialization.
- Use a relocatable `libcef.so` dependency and `$ORIGIN` for the subprocess.
- Bundle CEF resources and locales alongside libcef.so, including ICU data.
- Return a transparent pixel until the first browser frame arrives. Retain a raster-thread snapshot so producer updates cannot invalidate returned pixels.
- Pass the initial URL at creation; implement navigation, reload, and JavaScript channel methods without a startup timer.

## Current scope

Page rendering, pointer forwarding, native GTK keyboard events, and GTK input method composition are implemented. The example's **Input test** button loads a local form for typing, selection, clipboard shortcuts, Tab, and composition. Click the Flutter URL field to test focus transfer out of the browser.

Browser creation is idempotent. Awaiting controller disposal waits for CEF's close acknowledgement. The widget owns its controller by default, including when the controller is replaced; use `disposeController: false` if the caller will dispose it. Calls after disposal are ignored. A new Dart isolate session closes the previous session's browsers without reinitializing CEF or adding another message pump.

On GTK application shutdown, all browsers are closed before CefShutdown. A five-second deadline prevents indefinite process shutdown; on timeout the plugin logs the remaining browser count and skips unsafe CefShutdown. HTML popups and Javascript dialogs are now properly dispatched to Flutter for rendering, preventing CEF from attempting to spawn native windows. Context menus are similarly forwarded.

IME candidate-window positioning and surrounding-text requests, and production sandbox configuration remain unfinished. The current audit keeps CEF sandboxing enabled and does not fall back to disabling it. Earlier test results used a different configuration and must be revalidated.
GTK locale and missing UPower service warnings can appear in WSL.

## Testing

Run the controller and method-channel tests with:

```bash
cd packages/flutter_chromium_webview
flutter test
```

Native lifecycle regression test (requires WSLg):

```bash
cd packages/flutter_chromium_webview/example
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11 \
  flutter test integration_test/plugin_integration_test.dart -d linux
```

The test checks repeated create/dispose, disposal while creating, multiple browsers, focus isolation, and the native transition used by hot restart.

Native input and resize regression test:

```bash
cd packages/flutter_chromium_webview/example
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11 \
  flutter test integration_test/input_scaling_test.dart -d linux
```

This checks DOM click coordinates, viewport size, browser pixel ratio, and wheel scrolling at DPR 1, 1.5, and 2 with two viewport widths. The package's widget tests also check Flutter's logical click, drag, and wheel coordinates at these ratios. These are simulated per-browser ratios, not a physical multi-monitor test.

Live WSLg checks confirmed interactive Flutter hot restart, keyboard focus moving between the Flutter URL field and Chromium, GTK Unicode composition (`Ctrl+Shift+U`, `e9`, Enter produces `é`), text drag selection, window resizing, and wheel scrolling.
