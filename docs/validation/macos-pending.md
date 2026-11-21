# macOS Native Validation Handoff (Pending)

## Document Metadata
- **Package:** `devflier/flutter_chromium_webview`
- **Version:** `0.5.6`
- **Working Branch:** `exp/linux-cef-mtml-0.5.6`
- **Target Commit SHA:** `d9634551b93b358141e079df8c8ec6c302c26c47`
- **Status Date:** November 21, 2026

## Platform Verification Matrix

| Platform | Validation Status | Evidence Summary |
|---|---|---|
| **Windows 11 (x64)** | **VERIFIED** | 283 MB idle baseline, native D3D11/buffer-pooled texture sharing, event-driven external message pump, persistent named profiles verified across restarts, Release build verified, zero CEF orphan processes, route-local accessibility preserved. |
| **Ubuntu Linux (x86_64)** | **VERIFIED** | `validate_linux.sh` PASS (analyzer, 83/83 package unit tests, 2/2 example widget tests, 7/7 Linux integration tests, Release build, 0% idle main-thread CPU); `test_linux_lifecycle.sh` PASS (14 scenarios + 10/10 repeats); `test_linux_stress_and_compat.sh` PASS (`fail_count=0`, 100 create/dispose cycles, 100 rapid resizes, 5-view multi-WebView, 20/20 startup/shutdown cycles, low-mem on/off web compat matrix, persistent named cookies & `localStorage` verified across process restarts, anonymous profile isolation, disposal during context init, adverse ELF/GLib checks, failure injection, 0 orphan CEF processes). |
| **macOS (Apple Silicon / Intel)** | **PENDING** | Native build and hardware execution pending handoff to Apple hardware. Cross-platform code review and static guards applied; do not claim native macOS verification until executed on macOS. |

---

## 1. Files Modified for macOS and Shared Native Architecture

The following files contain modifications affecting macOS and cross-platform native browser management:

- `packages/flutter_chromium_webview/native/browser_settings.h`
  - Added support for persistent named profile context creation, context caching, and sandboxing flags.
- `packages/flutter_chromium_webview/native/chromium_flags.h`
  - Added low-memory flags, software/accelerated frame budget limits, and headless rendering flags.
- `packages/flutter_chromium_webview/macos/Classes/ChromiumBackend.mm`
  - Added asynchronous browser creation handling and safe bridge lifecycle callbacks.
- `packages/flutter_chromium_webview/macos/Host/ChromiumHostApp.mm`
  - Host process initialization, signal handling, and shutdown lifecycle.
- `packages/flutter_chromium_webview/macos/Host/HostBrowserClient.h`
  - Header updates for session management, single source Metal texture tracking, and asynchronous callback safety.
- `packages/flutter_chromium_webview/macos/Host/HostBrowserClient.mm`
  - Wrapped `finishCreate` in `@autoreleasepool { ... }` to eliminate ARC autorelease pool accumulation during asynchronous browser initialization.
  - Guarded `ResizeBrowser()` against premature `IOSurface` allocation when invoked before the `CefBrowser` instance is ready.
  - Refactored `OnAcceleratedPaint` Metal texture cache: retains only the active source `MTLTexture` matching `IOSurfaceGetID(cefSurface)` rather than retaining every historical surface ID across the session lifetime.
- `packages/flutter_chromium_webview/macos/Host/JavaScriptRequests.mm`
  - PostMessage and script evaluation routing.

---

## 2. Known Risk & Architectural Constraint (Immediate Action Required on macOS)

> [!WARNING]
> **PID-Scoped Cache Path in macOS Host Process (`macos/Host/main.mm:87-89`)**
> 
> In `macos/Host/main.mm`, the CEF cache directory is currently constructed as:
> ```objc
> NSString* cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
>     [NSString stringWithFormat:@"cef_cache_%d", [[NSProcessInfo processInfo] processIdentifier]]];
> ```
> Because `[[NSProcessInfo processInfo] processIdentifier]` produces a unique PID on each application run:
> - **In-Session Persistence:** Multiple browser instances within the *same* application session share cookies and web storage for identical `profileName`s.
> - **Cross-Restart Persistence:** Cookies, `localStorage`, and session state do **not** survive across full application restarts because the cache directory changes on each launch.
> 
> **Resolution on macOS:** Forward the configured `cachePath` from `ChromiumWebViewController.initialize(cachePath: ...)` via the IPC bootstrap handshake to the Host process so it uses a persistent directory rather than a PID-scoped temporary path.

---

## 3. macOS Native Validation Plan

Execute the following steps on native macOS hardware (MacBook / Mac Studio):

### Step 3.1: Environment Verification
```bash
sw_vers
uname -m
flutter --version
clang++ --version
```
Ensure Xcode 15+ command line tools and Flutter 3.47+ are available.

### Step 3.2: Build the Host Subprocess and Example App
```bash
cd packages/flutter_chromium_webview/macos/Host
./build_host.sh

cd ../../example
flutter clean
flutter pub get
flutter build macos --release
```

### Step 3.3: Automated Test Execution
Run Dart unit and widget tests:
```bash
cd packages/flutter_chromium_webview
flutter test
```

Run macOS input and lifecycle verification scripts:
```bash
bash macos/test/run_input_tests.sh
```

### Step 3.4: Manual Scenario Verification

1. **Browser Lifecycle & Autorelease Memory Check:**
   - Launch `example` app under Xcode Instruments (Allocations & Leaks).
   - Create and dispose 50 browser instances.
   - Confirm that autoreleased Objective-C objects from `finishCreate` and blit blocks do not leak into the parent runloop.
2. **Accelerated Metal Blit & IOSurface Caching:**
   - Play a 1080p 60fps video.
   - Monitor GPU memory in Instruments / Activity Monitor.
   - Confirm `source_metal_texture` is replaced when surface ID changes without accumulating stale texture handles.
3. **Resize & Minimization:**
   - Resize window rapidly across various aspect ratios.
   - Minimize and restore the window; verify playback resumes cleanly without black frames or Metal synchronization assertions.
4. **CEF Profile-Persistence Test Scenarios (In-Session & Cross-Restart):**
   - Load a local HTTP page with a named profile (`profileName: 'ppplayer_youtube_session'`), set both HTTP cookies and `document.cookie` + `localStorage`.
   - Dispose the controller (`await controller.dispose()`), create a new controller with the same `profileName` in the same session, and verify cookies and `localStorage` are restored.
   - Open an anonymous controller (`profileName: null`) and verify zero leakage of the named profile's cookies or `localStorage`.
   - After fixing the PID-scoped cache path in `macos/Host/main.mm`, repeat the check across a full application restart (`Cmd+Q` -> relaunch).
5. **Browser Disposal While Initializing:**
   - Trigger `unawaited(controller.createBrowser())` for a named profile and immediately call `await controller.dispose()` before `OnRequestContextInitialized` fires.
   - Repeat 20 times and confirm zero dangling `ContextReadyHandler` callbacks, zero Objective-C/ARC crashes, and `0` active browsers/textures afterward.
6. **Throttled Rendering (`setRenderingActive`) Audio Verification:**
   - Start YouTube/HTML5 audio+video playback in a `ChromiumWebViewController`.
   - Call `await controller.setRenderingActive(false)` (or minimize/hide the player window) and confirm audio playback, JS bridge events, and subtitles continue without stutter or interruption.
   - Call `await controller.setRenderingActive(true)` (or restore the window) and verify smooth 60 FPS Metal texture rendering resumes immediately without stale frames.
7. **Clean Shutdown:**
   - Quit application via `Cmd+Q` while a browser is active and playing media.
   - Verify the host process terminates promptly with 0 orphan processes and no crash reports in `~/Library/Logs/DiagnosticReports`.

---

## 4. Fallback Paths & Runtime Escape Hatches

If any macOS regression is observed during native validation:
- **Low-memory Chromium flags (`native/chromium_flags.h`):** Set `FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0` before launching to revert to stock Chromium feature flags for A/B comparison.
- **System media controls suppression:** Set `CEF_SYSTEM_MEDIA_CONTROLS=0` only when the host owns `MPNowPlayingInfoCenter` directly; unset it to restore Chromium's default media session handling.
- **Custom context / named profiles (`native/browser_settings.h`):** Verify `CustomContext` compiles cleanly against the pinned macOS CEF binary headers (`CefRequestContext::CreateContext(settings, handler)` and `ContextReadyHandler::OnRequestContextInitialized`).
