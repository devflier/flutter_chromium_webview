# macOS Native Validation Report (VERIFIED on Apple Silicon)

## Document Metadata
- **Package:** `devflier/flutter_chromium_webview`
- **Version:** `0.5.7` (0.5.6 release line, branch `exp/linux-cef-mtml-0.5.6`)
- **Working Branch:** `exp/linux-cef-mtml-0.5.6`
- **Verified Code Commit SHA:** `a16413f6cdad269139bcf78804321921ecb5770a` (superseding handoff SHA `849dd572d48a94bdce27119006ad1b0080540bec`)
- **Status Date:** November 21, 2026
- **Hardware & Toolchain:** Apple Silicon (`arm64`), macOS `27.0.1` (`26A434`), Xcode `27.0` (`27A266a`), Apple clang `21.0.0` (`clang-2100.3.34.2`), Flutter `3.47.7` (Dart `3.13.5`), CEF `149.0.4+g2f1bfd8+chromium-149.0.7827.156` (`macosarm64`).

## Platform Verification Matrix

| Platform | Validation Status | Evidence Summary |
|---|---|---|
| **Windows 11 (x64)** | **VERIFIED** | 283 MB idle baseline, native D3D11/buffer-pooled texture sharing, event-driven external message pump, persistent named profiles verified across restarts, Release build verified, zero CEF orphan processes, route-local accessibility preserved. |
| **Ubuntu Linux (x86_64)** | **VERIFIED** | `validate_linux.sh` PASS (analyzer, 83/83 package unit tests, 2/2 example widget tests, 7/7 Linux integration tests, Release build, 0% idle main-thread CPU); `test_linux_lifecycle.sh` PASS (14 scenarios + 10/10 repeats); `test_linux_stress_and_compat.sh` PASS (`fail_count=0`, 100 create/dispose cycles, 100 rapid resizes, 5-view multi-WebView, 20/20 startup/shutdown cycles, low-mem on/off web compat matrix, persistent named cookies & `localStorage` verified across process restarts, anonymous profile isolation, disposal during context init, adverse ELF/GLib checks, failure injection, 0 orphan CEF processes). |
| **Android** | **VERIFIED (CI)** | GitHub Actions run `44912421940` green (API 36 emulator checks + release APK). |
| **macOS (Apple Silicon `arm64`)** | **VERIFIED** | Persistent `cachePath` forwarding & `setRenderingActive` throttling implemented (`a16413f`); Host & Release example builds green; 83/83 Dart tests; 12/12 macOS integration suites (incl. 50-cycle `resource_stability_test` & 20-cycle `host_crash_test`), `texture_test`, `run_input_tests.sh`, `javascript_smoke.py`, `test_packaging.py`, `smoke_macos.py` all green; all 4 Apple-hardware acceptance scenarios verified with 0 leaked resources, 0 surviving processes after `Cmd+Q`, and 0 `.ips` crash reports; PPPlayer macOS Release bundle built (`423.1 MB`, `163.2 MB` idle RSS with lazy restore) and smoke-verified. |

---

## 1. Files Modified for macOS Persistence, Throttling & Shared Native Architecture

### Previous Cross-Platform Hardening (`849dd57`)
- `packages/flutter_chromium_webview/native/browser_settings.h` — persistent named profile context resolution (`ProfileCachePath` -> `<root_cache_path>/profile_<name>`) and `ContextReadyHandler`.
- `packages/flutter_chromium_webview/native/chromium_flags.h` — low-memory profile flags and `CEF_SYSTEM_MEDIA_CONTROLS=0` opt-out.
- `packages/flutter_chromium_webview/macos/Host/HostBrowserClient.mm` — `@autoreleasepool` around `finishCreate`, premature `IOSurface` allocation guard in `ResizeBrowser()`, and single active `source_metal_texture` cache in `OnAcceleratedPaint`.

### Resolved macOS Fixes (`a16413f`)
- `packages/flutter_chromium_webview/macos/Classes/ChromiumHostManager.h` & `.mm` — added `launchHostWithCachePath:keychainBehavior:completion:`, preserved `_cachePath` and `_keychainBehavior` across host crash restarts, forwarded `--cache-path=<path>` to `ChromiumWebViewHost`, and honored `CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1`.
- `packages/flutter_chromium_webview/macos/Classes/ChromiumBackend.mm` — passed caller `cache` into `ChromiumHostManager` from `Runtime::Initialize()`, and wired `setRenderingActive` over IPC.
- `packages/flutter_chromium_webview/macos/Host/main.mm` — parsed `--cache-path=`, ensured the directory exists and resolved symlinks for `settings.root_cache_path` / `settings.cache_path`, retaining a safe PID-scoped temporary fallback only when omitted or empty.
- `packages/flutter_chromium_webview/macos/Host/ChromiumHostApp.mm` — handled `setRenderingActive` IPC messages and honored `CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1` in `OnBeforeCommandLineProcessing`.
- `packages/flutter_chromium_webview/macos/Host/HostBrowserClient.h` & `.mm` — implemented `SetRenderingActive(browser_id, active)` using `SetWindowlessFrameRate(1)` when inactive (without calling `WasHidden(true)` so audio and JS bridge continue uninterrupted) and restoring `SetWindowlessFrameRate(60)` + `Invalidate(PET_VIEW)` when active.
- `packages/flutter_chromium_webview/macos/Host/build_host.sh` — added missing `NativeUi.mm` to standalone host link list.
- `packages/flutter_chromium_webview/macos/test/input_test.mm` — implemented mock `ChromiumHostManager` selectors to compile warning-free.

---

## 2. Automated Build & Test Evidence (Apple Silicon `arm64`)

| Suite / Command | Result | Key Details |
|---|---|---|
| `macos/Host/build_host.sh` | **PASS** | Compiled `arm64` `ChromiumWebViewHost.app` + embedded CEF `149.0.4` and 5 signed helpers |
| `example`: `flutter build macos --release` | **PASS** | Clean Release bundle build |
| `flutter analyze --no-fatal-infos` | **PASS** | 0 errors |
| `dart format --output=none --set-exit-if-changed` | **PASS** | 46 tracked `.dart` files, 0 formatting diffs |
| `flutter test --reporter expanded` | **PASS** | 83/83 Dart unit/widget tests passed |
| `bash macos/test/run_input_tests.sh` | **PASS** | `input_client_test`, warning-free `input_test`, 22/22 `input_smoke.py` checks |
| `macos/Host/javascript_smoke.py` | **PASS** | 9/9 JS bridge, isolation, cancellation, renderer crash recovery checks |
| `unittest discover -s macos/test -p 'test_*.py'` | **PASS** | 10/10 packaging & entitlement regression tests |
| `texture_test` (Debug native ownership test) | **PASS** | Exit 0, zero IOSurface / FlutterTexture leaks |
| `scripts/smoke_macos.py` (copied Release bundle) | **PASS** | Logged persistent `cachePath`, clean `Cmd+Q` exit (code 0), `[CEFHost] CefShutdown complete`, 0 survivors |
| `integration_test/plugin_integration_test.dart` | **PASS** | 20 create/dispose cycles, `browsers: 0, textures: 0` |
| `integration_test/input_scaling_test.dart` | **PASS** | Multi-DPR pointer/resize/wheel verification |
| `integration_test/native_ui_test.dart` | **PASS** | Dialogs, menus, dropdown disposal, isolation |
| `integration_test/javascript_bridge_test.dart` | **PASS** | Origin isolation, navigation, lifetime |
| `integration_test/html_loading_test.dart` | **PASS** | HTML base URL, relative resources, reload |
| `integration_test/browser_settings_test.dart` | **PASS** | User-agent & autoplay isolation |
| `integration_test/youtube_adapter_test.dart` | **PASS** | Adapter contract & player isolation |
| `integration_test/evaluate_javascript_test.dart` | **PASS** | Async JS evaluation & error propagation |
| `integration_test/host_crash_test.dart` | **PASS** | 20/20 `SIGKILL` host crash & recovery cycles on shared persistent `cachePath` |
| `integration_test/gpu_recovery_test.dart` | **PASS** | GPU crash & recovery |
| `integration_test/renderer_recovery_test.dart` | **PASS** | 2/2 renderer crash recovery cycles (`44` Metal frames resumed per cycle) |
| `integration_test/resource_stability_test.dart` | **PASS** | **50/50** create/dispose + multi-resolution resize cycles (`28s`), exact return to baseline counters (`activeBrowsers: 0`, `activeIOSurfaces: 0`, `activeMetalTextures: 0`, `activeFlutterTextures: 0`, `pendingIpcRequests: 0`, baseline Mach rights) |

---

## 3. Apple Hardware Verification Scenarios (Recorded Measurements)

### Scenario 1 — Cross-Restart Persistent Named Profile & Anonymous Isolation
- **Run 1 (`profile_write`):** Initialized with persistent `cachePath`, created browser with `profileName: 'ppplayer_youtube_session'`, wrote `HttpOnly` cookie `fcw_http=http_val_42`, JS-accessible cookie `fcw_js=js_val_42`, `document.cookie` `client_auth=user_token_999`, and `localStorage['session_status'] = 'logged_in_persistent'`. Confirmed `<cachePath>/profile_ppplayer_youtube_session` created directly under `root_cache_path`. Quit via `NSRunningApplication.terminate()` (`Cmd+Q`): exit code `0`, `[CEFHost] CefShutdown complete`, `0` surviving processes.
- **Run 2 (`profile_read` — brand-new process relaunch with same `cachePath`):**
  - Named profile (`ppplayer_youtube_session`) HTTP `Cookie` header received by server: `fcw_http=http_val_42; fcw_js=js_val_42; client_auth=user_token_999`
  - Named profile `document.cookie`: `fcw_js=js_val_42; client_auth=user_token_999`
  - Named profile `localStorage['session_status']`: `'logged_in_persistent'`
  - Anonymous profile (`profileName: null`): HTTP `Cookie` header `""`, `document.cookie` `""`, `localStorage['session_status']` `null` (zero leakage).
  - Clean `Cmd+Q` exit: exit code `0`, `[CEFHost] CefShutdown complete`, `0` surviving processes.

### Scenario 2 — Browser Disposal While Initializing (20 Iterations)
- Executed 20 iterations of `unawaited(controller.createBrowser())` immediately followed by `await controller.dispose()` across named profiles `fast_cancel_0..19`.
- **Result:** Zero crashes, zero dangling `ContextReadyHandler` callbacks.
- **Post-loop diagnostics:** `browsers: 0`, `textures: 0`, `focused: false`, `pumpRunning: true`.
- **Post-loop resource counters:** Exact match to pre-test baseline (`client`/`host`: `activeBrowsers: 0`, `activeIOSurfaces: 0`, `activeMetalTextures: 0`, `activeFlutterTextures: 0`, `pendingIpcRequests: 0`, `activeMachSendRights: 1/0`, `activeMachReceiveRights: 1/0`).

### Scenario 3 — Throttled Rendering (`setRenderingActive`) & Audio / JS Continuity
- **Active (2.0 s window):** `120` completed Metal frames (**60.0 FPS**), `0` failed Metal frames, `20` JS bridge heartbeats (10 Hz), audio `currentTime` delta `+1.987 s`.
- **Inactive (`setRenderingActive(false)`, 3.0 s window):** `2` completed Metal frames (**0.67 FPS** — ~90x GPU blit reduction), `pausedWhileInactive: false`, `30` JS bridge heartbeats (10 Hz uninterrupted), audio `currentTime` delta `+3.012 s`.
- **Restored (`setRenderingActive(true)`, 2.0 s window):** `91` completed Metal frames (immediate resume to 60 FPS), `0` failed Metal frames, audio `currentTime` delta `+1.988 s`.

### Scenario 4 — 1080p Metal Texture Ownership, RSS & Clean Shutdown
- Resized viewport to `1920x1080` and sampled `getResourceCounters` across 5 seconds of continuous 1080p animated rendering (`702` total completed Metal frames, `0` failed):
  - `host.activeMetalTextures`: `[4, 4, 4, 4, 4]` (strictly 1 active `source_metal_texture` + 3 `dest_metal_textures` ring; zero stale handle accumulation).
  - `host.activeIOSurfaces`: `[3, 3, 3, 3, 3]`.
- Post-disposal counters returned to exact baseline (`0` browsers, `0` IOSurfaces, `0` Metal textures, `0` Flutter textures).
- Debug probe process tree RSS before quit: Runner `206.4 MB`, Host `142.7 MB`, 4 Helpers `88.8 + 72.6 + 56.9 + 60.9 MB`.
- Clean `Cmd+Q` exit across all runs: `0` surviving `ChromiumWebViewHost` / `ChromiumWebView Helper` processes, `0` new `.ips` crash reports in `~/Library/Logs/DiagnosticReports`.

### PPPlayer macOS Release Validation
- Synchronized vendored snapshot (`147/147` tracked source hashes verified via `scripts/verify_chromium_snapshot.py`; `14/14` `scripts/test_*.py` checks including `test_macos_quit_handshake.py` passed).
- Built `PPPlayer.app` macOS Release (`423.1 MB`).
- Verified idle startup with desktop lazy restore: **1 process total (`0` Chromium Host/Helper processes spawned at idle), `163.2 MB` total RSS**, clean `Cmd+Q` exit (`0` survivors, `0` new `.ips` crash reports).
- Verified `PPPlayer.app`'s embedded Release `ChromiumWebViewHost` persists `profile_ppplayer_youtube_session` (`HttpOnly` cookie, `document.cookie`, and `localStorage`) across full host restarts, handles `setRenderingActive(false/true)`, and completes `[CEFHost] CefShutdown complete`.

---

## 4. Fallback Paths & Runtime Escape Hatches
- **Low-memory Chromium flags (`native/chromium_flags.h`):** Set `FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0` before launching to revert to stock Chromium feature flags for A/B comparison.
- **System media controls suppression:** Set `CEF_SYSTEM_MEDIA_CONTROLS=0` when the host owns `MPNowPlayingInfoCenter` directly; unset to restore Chromium's default media session handling.
- **Mock keychain override for tests:** Set `CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1` or `CEF_KEYCHAIN_BEHAVIOR=mock` (default) to avoid macOS Keychain prompts during automated runs.
