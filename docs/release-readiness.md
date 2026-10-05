# Windows, Linux and Android readiness

Updated: 2026-10-05. Desktop 0.2.1 has been published by the repository owner.
Android support in this checkout is an unreleased addition.
Do not infer runtime verification from the existence of an implementation.

## Environment

Ubuntu 26.04.1 LTS, WSL2 kernel 6.6.87.2, x86-64; Flutter 3.47.5 stable,
Dart 3.13.4; CMake 4.2.3. CEF 149.0.4 / Chromium 149.0.7827.156.
Only WSLg is available here. Native Linux desktop compatibility is unverified.
Windows validation uses Flutter 3.47.4 and the Visual Studio CMake toolchain.
Android validation uses the installed Pixel_9_Pro emulator (Android 16 x86-64),
system Chromium WebView 133.0.6943.137, AndroidX WebKit 1.16.0 and Java 17.
Android uses the system WebView rather than CEF. Windows and WSL use separate
checkouts to keep generated Flutter metadata independent.
The software baseline uses `LIBGL_ALWAYS_SOFTWARE=1`,
`GALLIUM_DRIVER=llvmpipe`, `GDK_BACKEND=x11`. CEF uses CPU off-screen rendering.

## Audit findings and corrections

- GObject memory did not construct the embedded C++ shared pointer. The context
  is now explicitly heap-constructed and owns a weak channel reference.
- Dialog/menu completion erased iterators after callbacks could re-enter CEF.
  Callback ownership is now taken before completion and drained before cancel.
- Closing browsers suppress new events and frame notifications.
- Invalid frame dimensions could overflow signed allocation arithmetic; they are
  rejected. Failed frame allocation preserves the previous frame.
- Previously returned raster allocations now survive resizing and remain owned
  by the texture until disposal; geometric growth limits retained allocations.
- Unknown native events no longer accumulate indefinitely in Dart. Early events
  are bounded and retained only while browser creation is pending.
- Widget-owned focus callbacks are detached when replacing/removing a widget.
- GTK application shutdown requests browser closure before runtime shutdown.
- Linux uses CEF's external message pump with a periodic main-thread timer.
  The nested GLib pump caused a busy UI thread in the copied release app; the
  external pump restores normal window events and shutdown.
- Windows uses the CEF M138+ sandbox bootstrap and a client runner DLL, with
  sandbox information passed to process dispatch and initialization. Its child
  Flutter HWND forwards keyboard/IME input while the browser owns focus.
- Windows raster samples own immutable frame leases; resize and disposal cannot
  invalidate a frame being read by Flutter. Texture deletion waits for unregister.
- Windows teardown checks the Flutter messenger before clearing channel handlers;
  engine shutdown had already destroyed the incoming dispatcher. The copied-bundle
  smoke check requires process exit code zero, not just a CEF completion log.
- Dropdown textures use a following Flutter overlay with browser-relative input
  outside the viewport. Example dialog/menu routes are cancelled per browser.
- GoogleTest uses installed dependencies only and is opt-in. The stale test
  reference to a removed platform-version helper was replaced.
- A clean WSL build restarted the VM; compilation is limited to two jobs and
  validation logs are persisted under `docs/validation`.

## Verification matrix

| Area | Status |
|---|---|
| Lifecycle/session reset, focus, resize/wheel and native dialog/menu/dropdown suites | Passed Windows and WSLg; see current logs in `docs/validation` |
| Windows native Unicode input (`aé😀`) and browser blur | Passed using real child HWND messages |
| Native frame/callback regression suite | Passed Linux CTest and Windows frame lease/concurrent paint regressions |
| Current Dart unit/widget tests and analyzer | Passed: 63 package tests, 2 example tests; analyzers clean |
| Sandbox-enabled debug/release startup | Passed on Windows and WSLg; confinement review still required |
| Release bundle outside checkout and normal close | Passed Windows and WSLg software/default graphics; shutdown complete and no surviving CEF subprocesses |
| Default host graphics | WSLg startup/close passed with DRI3 warnings; hardware acceleration not established |
| Native Linux desktop | Unavailable; physical desktop validation still needed; WSLg passes |
| HTML dropdown bounds/input outside widget | Widget hit tests passed at DPR 1 and 2; native popup selection passed; physical edge/multi-monitor checks remain |
| Dialog/menu disposal and navigation cancellation | Native integration and per-browser route/widget tests passed; manual clipboard/IME checks remain |
| Advanced IME and candidate positioning | Not verified / unsupported positioning |
| Publication dry run | Android Java/Gradle/manifest included; build/cache/local properties excluded; 1 uncommitted-tree warning and 1 local-dependency-override hint. Local interface library files match the published 0.1.1 source |
| CI | Dart/Linux/Windows workflows retained; Android emulator workflow added; remote execution not verified |
| macOS | Unverified work in progress, excluded from plugin registration and publication by the current repository configuration |
| JavaScript bridge | Shared desktop implementation; Windows/WSLg renderer tests pass for browser/channel/origin isolation, Unicode, navigation and disposal; macOS validation pending |
| HTML loading | Explicit HTTP(S) document URL/origin, relative assets, reload, replacement, empty documents and browser isolation pass on Windows/WSLg; macOS validation pending |
| Browser settings | Browser-specific HTTP/JavaScript user-agents, isolated autoplay contexts and unmuted WAV progress pass on Windows/WSLg; audible output remains unverified |
| YouTube adapter | Ordered commands, events, getters, reload, timeouts and disposal tested; real CEF fixture and live playback/pause/seek/volume/widget-detachment checks pass on Windows/WSLg; see `youtube-adapter.md` |
| Android browser | Native touch/view lifecycle, HTML, secure bridge, user-agent/autoplay profile isolation and adapter fixture suites pass. Full validation script and release APK build pass; see `validation/android-current-validation.log` and package `ANDROID.md` |
| Android release input/UI | Release startup, native ASCII keyboard input and JavaScript alert acceptance pass with hybrid composition; see `validation/android-release-smoke.log`. Emulator keyboard setup screens must be dismissed first |
| Android live playback | Foreground play/pause/seek/volume pass. Audio-only headless probe passes; an attached native view pauses on removal, so the full detach-progress probe fails. The ppplayer audio-only service integration passes separately below |
| ppplayer adoption | Isolated preview shares the main app commit; 107 native engine/app playback regression tests and changed-file analysis pass. Native fixture and live PlayerScreen controls pass on Windows/WSLg, including pause/resume, seek and confirmed volume; three local-video/live-YouTube round trips pass on both desktop platforms. Prior full app debug/release builds pass; see `ppplayer-roadmap.md` |
| ppplayer Android Chromium | With the private native fork, complete Android 15/16 emulator runs pass all three local-video/live-YouTube round trips, Home, 20-second screen-off progress, system pause/play and restoration. Both logs show the new EGL fallback. No ppplayer services remain after cleanup. Upstream failures remain archived. Physical-device audio, catalog navigation and visible Chromium video transitions remain gates; see `validation/ppplayer-native-fork-status.md` |
| ppplayer Android native fork | Local ARM64/x86_64 builds pass export/dependency and 16 KiB ELF alignment checks; installed emulator APK hashes match the fork. Android 16 runtime uses 16 KiB pages. Private dependency override is confined to the preview; 107 playback regression tests and changed-file analysis pass. No fork or binaries have been pushed or published |
| ppplayer Android baseline | Existing local-video native integration passes on Pixel_9_Pro emulator, including app APK build/install, video tracks, play/pause/seek and disposal. This is the existing MediaKit path, not Chromium media-service adoption; see `validation/ppplayer-android-native.log` |
| ppplayer Android release | Fresh opt-in APK builds with the native fork and startup watchdog for ARM64/x86_64; both packaged mpv/helper binary hashes match local verified artifacts. Installs and starts on Android 16, initializing MediaKit before the first-run notification permission request. Production signing and release playback remain unverified; see `validation/ppplayer-native-fork-release.log`, `validation/ppplayer-native-fork-release-apk.log` and `validation/ppplayer-native-fork-release-smoke.log` |

## Manual validation required

Use the example's local Input test page. Test select dropdowns near every edge,
resize and DPR changes while open, and clicks outside the main WebView bounds.
Exercise alert, confirm and prompt (accept/cancel), copy/cut/paste/select-all,
Unicode composition and focus transitions. Navigate or dispose while each popup,
dialog or menu is pending. Repeat with two browser instances and verify that the
other browser remains interactive. Verify focus and clipboard manually; automated
pointer injection is not proof of a physical IME or multi-monitor configuration.

Run debug and release under both default host graphics and the software baseline.
Close the window normally and require `[CEF] Shutdown complete`, no timeout, and
no surviving subprocesses. Repeat hot restart separately. Record failures rather
than disabling security to make a test pass.

## Release gate

Before adopting the package in ppplayer, exercise full catalog navigation,
source/playlist switching and repeated external-service startup; live PlayerScreen
controls now pass on Windows/WSLg. On Android, audio-only playback with the
existing media service passes emulator Home/media-command checks; address visible-view removal
before enabling video-view transitions. Confirm physical-device audio, keyboard
and background/foreground behavior; emulator playback progress alone does not
establish those outcomes. Choose a new package version for the Android addition
and run CI before publishing. This work has not published a package or Git release.
