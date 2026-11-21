## 0.5.7

* Dart: disable the 1-second `DebugHeartbeat` JavaScript timer by default in `ChromiumYoutubePlayerController` (opt-in via `enableDebugHeartbeat: true`), track and clear all JS interval timers on `pagehide`, `beforeunload`, reload, and disposal, and gate diagnostic logging to debug mode.
* Dart: reject pending and new `ChromiumYoutubePlayerController` commands immediately on browser detachment/disposal instead of waiting for the 5-second `commandTimeout`, fail pending `evaluateJavaScript` futures immediately on crash/detachment/disposal, deduplicate crash notifications per browser generation, and bound consecutive automatic crash recovery attempts (`maxAutoRecoveryAttempts = 3`).
* Android: emit `browserCrash` (instead of `loadError`) from `onRenderProcessGone` with duplicate-notification guard, unregister `Application.ActivityLifecycleCallbacks` on both Activity detach and engine teardown while preventing duplicate registrations across configuration changes, and remove unconditional Release `ChromiumBG` logging and commented experimental code.
* Windows: replace the fixed 10 ms `SetTimer` CEF polling loop with CEF's event-driven `external_message_pump` (`OnScheduleMessagePumpWork` via a hidden `HWND_MESSAGE` window), lowering idle CPU and eliminating unnecessary wakeups while preserving Win32 main-thread affinity and clean shutdown.
* Windows: optimize `FlutterChromiumTexture` with a bounded reusable frame buffer pool (eliminating per-frame 8+ MB allocations in steady state), runtime-detected SSSE3/SSE2 SIMD BGRA→RGBA conversion, and explicit buffer release (`Clear()`) on popup hide and browser close.
* Windows & Linux: implement `CefRequestHandler::OnRenderProcessTerminated` (deduplicated) so renderer crashes reliably emit `browserCrash` events to Dart across all supported platforms; deduplicate `OnRenderProcessTerminated` on macOS.
* Linux: add explicit, container-verified inner-sandbox opt-out (`FLUTTER_CHROMIUM_WEBVIEW_ALLOW_CONTAINER_NO_SANDBOX=1` restricted strictly to verified Snap or Flatpak confinement; ordinary Linux `.deb`/AppImage/desktop hosts always retain Chromium's native sandbox) with GoogleTest security-matrix unit tests.
* Linux: harden the MTML shutdown state machine with an 8-state lifecycle, `TID_UI` synchronization barrier, bounded GLib context drain, and 8 failure-injection GoogleTest cases.
* Windows, macOS & Linux: unify the validated opt-out low-memory Chromium feature profile (`FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0` to revert) and `CEF_SYSTEM_MEDIA_CONTROLS=0` duplicate media-session suppression via a shared native flags helper, and gate macOS Release per-IPC/per-frame `NSLog` and `Media.enable` DevTools attachment behind `#if DEBUG`.

## 0.5.6

* Linux: refactor CEF lifecycle to `multi_threaded_message_loop = true` (CEF 149.0.4), eliminating the 100% idle CPU spin (issue #12), removing `CefRunMessageLoop()` re-entry `SIGTRAP` crashes, and requiring zero global `GApplication` symbol interposition. Isolated idle main-thread CPU drops from ~99.9% to `0.0–0.2%` (`0.9%` full process tree on static idle page), and active navigation GTK main-thread CPU drops by ~47% (`8.38% → 4.41%`).
* Linux: enforce strict GTK main-thread vs CEF `TID_UI` thread affinity across browser creation, input/IME (`CefKeyboard`), dialogs, context menus, texture registration, coalesced `OnPaint` notifications, and condition-variable + `TID_UI` barrier shutdown across multi-window, `g_application_hold()` window reopen, and direct `g_application_quit()` flows.
* Linux: fix `libflutter_chromium_webview_plugin.so` `INSTALL_RPATH` to `$ORIGIN` so release bundles never embed absolute build-directory paths.
* Linux: reduce runtime memory footprint without disabling sandboxing or site isolation by disabling speculative spare renderers (`SpareRendererForSitePerProcess`) and unused desktop Chrome background services (opt-out via `FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0`), eliminating redundant frame copies and `retired_buffers` retention in `FlutterChromiumTexture`, releasing popup/browser buffers via `flutter_chromium_texture_clear`, calling `WasHidden(true)` on close, and invoking `malloc_trim(0)` on `TID_UI` in `OnBeforeClose`.
* Dart: handle `PlatformException(DETACHED)` cleanly in `ChromiumWebViewController` during host view detachment without swallowing unrelated errors, cancel periodic JS bridge timers on app exit/detach in the example app, and add lifecycle unit tests covering disposal during JS execution, double disposal, detachment during navigation, closing during initialization, multi-controller disposal, and late native callbacks.
* Tooling: add Linux lifecycle, stress/compatibility, CPU, and 12-scenario memory benchmark scripts (`scripts/test_linux_lifecycle.sh`, `scripts/test_linux_stress_and_compat.sh`, `scripts/benchmark_linux_cpu.sh`, `scripts/benchmark_linux_memory.sh`, `scripts/check_linux_idle_cpu.sh`) and Flutter 3.50 analyzer compatibility in `scripts/validate_linux.sh`.

## 0.5.5

* Allow macOS hosts with native media controls to disable Chromium's duplicate system media session with `CEF_SYSTEM_MEDIA_CONTROLS=0`.
* Find Homebrew and CMake.app installations when building from Xcode's restricted PATH; clarify missing CMake errors.
* Mark CEF preparation as intentionally running on every build.
* Support host-coordinated YouTube crash recovery and expose video playback quality diagnostics.
* Preserve Android autoplay media playback when its Activity is minimized.
* Bound the Metal texture cache to one source and three destinations, clean it up on resize/disposal, and drain paint autorelease pools.
* Allow macOS termination to finish after Flutter's asynchronous exit response.

## 0.5.4

* Add configurable `keychainBehavior` parameter (`ChromiumKeychainBehavior.mock` vs `.system`) to `ChromiumWebViewController.initialize`.
* Default to mock keychain on macOS to prevent unnecessary login keychain access prompts.
* Support `CEF_KEYCHAIN_BEHAVIOR` environment variable override (`mock` or `system`).
* Require `flutter_chromium_webview_platform_interface` ^0.1.7.

## 0.5.3

* Separate deterministic macOS core/local media RSS validation from explicitly invoked live YouTube reporting; preserve strict memory assertions and external blocked verdicts.
* Gate platform-interface publication on its API/example checks and consumer compatibility, independently of native/live services.

* Require platform interface 0.1.6, which publishes the JavaScript evaluation/cancellation, click-count and browser-crash APIs used by this plugin.

* Fix macOS Chromium host embedding and preserve native startup/failure diagnostics.
* Recover macOS browsers after renderer or GPU-process crashes through the existing browser recreation contract; arbitrary page state is not preserved.
* Improve macOS playback telemetry and independent validation-stage reporting.
* Preserve Android integration startup and crash diagnostics.
* Refresh installation, runnable examples, macOS setup and release documentation; correct the iOS support claim because the release pubspec does not register that backend.
* Exclude monorepo dependency overrides from publication and keep the bundled example's published dependency resolution independent of sibling checkouts.
* Document remaining macOS memory limits: proposed 8 GB support is unverified, historical strict RSS acceptance remains failed, and long-term memory boundedness is not established. No allocator fix or relaxed memory threshold is included.

## 0.5.2

* Fix JavaScript mocked player properties in integration test.
* Prevent git tracking of temporary and machine-specific profiling artifacts.

## 0.5.1

* Complete public API documentation audit. Documented all public classes, methods, and fields.
* Resolve analyzer warnings and info-level lints.
* Exclude large binary artifacts from publication to comply with package size limits.

## 0.5.0

* Add macOS CEF and YouTube playlist support.
* Fix macOS architecture configuration and linking issues.
* Require the latest platform interface version.


## 0.3.1

* Correct Linux pointer coordinates at fractional and high device pixel ratios.
* Require the platform interface version that includes named browser profiles.
* Fix automated publication authentication and validate release tag versions.

## 0.3.0

* Add macOS support using native CEF framework.
* Add iOS support using a headless WKWebView implementation.
* Add Android API 24+ support through the system Chromium WebView and a native Flutter platform view.
* Preserve browser identity when attaching a view without a desktop texture.
* Add emulator validation for browser lifecycle, origin-restricted channels, HTML and playback settings.
* Keep WSL validation in a separate Linux checkout to protect Windows build metadata.

## 0.2.1

* Fix Windows packaging, stabilize integration tests and update version status.

## 0.2.0

* Add Windows (x64) backend support.
* Provide full integration with CEF sandboxed runner for Windows.

## 0.1.1

* Fix platform interface class exports for pub release.

## 0.1.0

* Initial release.
* Chromium Embedded Framework web view for Flutter desktop using off-screen rendering and Flutter textures.
* Experimental Linux x64 support: navigation, JavaScript execution and channels, mouse and keyboard input, resizing, popups, dialogs and context menus.
* `ChromiumWebView` accepts an optional `initialUrl`.
* Talks to native code through `flutter_chromium_webview_platform_interface`.

