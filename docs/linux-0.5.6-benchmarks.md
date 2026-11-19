# Linux 0.5.6 Stability, CPU & Memory Verification Report

## Environment

- **Host:** Windows (`Microsoft Windows NT 10.0.26200.0`), Intel Core i5-12500H, VirtualBox `7.2.16r174877`
- **Guest:** Ubuntu `26.04.1 LTS (Resolute Raccoon)` x86-64, kernel `7.0.0-38-generic`, 6 vCPUs, 7.2 GiB RAM, ext4 Linux-native checkout
- **Display Backend:** GNOME Wayland session (`WAYLAND_DISPLAY=wayland-0`) with XWayland (`DISPLAY=:0`, `GDK_BACKEND=x11`)
- **Toolchain:** Flutter `3.50.0` (stable, rev `ab2912035e`), Dart `3.14.0`, Ubuntu Clang `21.1.8`, CMake `4.2.3`, Ninja `1.13.2`, GTK `3.24.52`, GLib/GIO `2.88.0`
- **CEF SDK:** `149.0.4+g2f1bfd8+chromium-149.0.7827.156` (`linux64_minimal`, SHA-256 `6d43607675e47ed6bfa40d1cfce136d04e7720529f8f1c4435d4ba1dcd1839b2`, sandbox enabled)
- **Compared Revisions:**
  - `baseline_706ebc62`: `706ebc622919323c41c901e8d711e07ccde6aa9c` (`main` / `v0.5.5`, external pump + 10 ms timer)
  - `b3458b6`: `b3458b68a6b681e2983a867fe53157a445c3c9d2` (one-shot `CefRunMessageLoop()` + `window-removed` quit)
  - `fee3203`: `fee320322a39407e3210c513b32ef2e939329c7a` (`release/0.5.6` HEAD with `ResumeMessageLoop()`)
  - `optimized_056`: `fix/linux-cef-lifecycle-0.5.6` (one-shot `CefRunMessageLoop()` + `GApplication` hold/release/quit tracking + raster-safe single-buffer `FlutterChromiumTexture` + `WasHidden(true)` + `malloc_trim(0)` + Chromium low-memory embedder flags + Dart `DETACHED` guards)

---

## Resolved Regressions & Root Causes

1. **Critical `SIGTRAP` in `fee3203` (`KeepAliveRegistry::Register`):**
   - **Cause:** `fee3203` connected `GtkApplication::window-added` → `ResumeMessageLoop()` to re-enter `CefRunMessageLoop()` after `CefQuitMessageLoop()`. In CEF `149.0.4`, exiting `CefRunMessageLoop()` destroys `CefMainRunner`'s `ScopedKeepAlive(APP_CONTROLLER)` and sets `KeepAliveRegistry::is_shutting_down_ = true`. Re-entering `CefRunMessageLoop()` hits a fatal `CHECK` (`int3` at `libcef.so+0x3feba4a`, exit code `133`).
   - **Fix:** Keep `CefRunMessageLoop()` strictly one-shot and track `GApplication` hold/release/quit transitions so `CefRunMessageLoop()` remains running while the application is held alive (even with 0 windows) and quits once when the final hold/window is released or `g_application_quit()` is invoked.
2. **Why `external_message_pump = true` (Option A) was rejected on Linux:**
   - Disassembly of `libcef.so` (`MessagePumpFactoryForUI` at `0x2ef6fe5`) confirms `MessagePumpExternal` inherits from `base::MessagePumpGlib`. Its constructor attaches `MessagePumpGlib`'s `WorkSource` to `g_main_context_default()` with `state_ == nullptr`, causing `HandlePrepare()` to return a `0 ms` timeout on every GTK main-loop iteration (~100% CPU spin) even when `OnScheduleMessagePumpWork()` is implemented.
3. **Post-`CefShutdown()` `SIGTRAP` in `base::AtExitManager::RegisterCallback` (`libcef.so+0x827a749`):**
   - **Cause:** Disassembly of `g_application_run()` in `libgio-2.0.so.0` (`0xebb48..0xebb5c`) shows that unless `must_quit_now` (`g_application_quit()`) is set, GLib runs `while (g_main_context_iteration(context, FALSE));` *after* emitting `GApplication::shutdown` (and therefore after `CefShutdown()` has destroyed `base::AtExitManager`).
   - **Fix:** `CefRuntimeManager::Shutdown()` drains pending CEF/GLib callbacks while CEF is still active and invokes GIO's `g_application_quit()` immediately before `CefShutdown()`.
4. **Unhandled `PlatformException(DETACHED)` during shutdown:**
   - **Fix:** `ChromiumWebViewController` marks `_isDetached = true` on `PlatformException(code: 'DETACHED')`, stopping further platform calls while rethrowing all unrelated exceptions; the example app cancels periodic timers via `AppLifecycleListener`.

---

## CPU Benchmark Comparison (`scripts/benchmark_linux_cpu.sh`)

| Scenario (10 s isolated sample) | Metric | `baseline_706ebc62` | `b3458b6` | `optimized_056` |
| :--- | :--- | ---: | ---: | ---: |
| **CEF initialized, 0 WebViews** | Main thread CPU | 99.85% | 0.30% | **0.10%** |
| | Flutter engine threads | 0.00% | 0.00% | **0.00%** |
| | Full process-tree CPU | 99.85% | 0.50% | **0.00%** |
| **Static page idle (1 WebView)** | Main thread CPU | 99.48% | 0.30% | **0.30%** |
| | Flutter engine threads | 0.76% | 1.00% | **1.10%** |
| | Browser / Renderer / GPU | 100.33% / 0.00% / 0.19% | 1.49% / 0.00% / 0.10% | **1.60% / 0.10% / 0.20%** |
| | Full process-tree CPU | 100.51% | 1.59% | **1.99%** |
| **Active navigation (16 pages)** | Main thread CPU | 92.44% | 29.87% | **31.28%** |
| | Full process-tree CPU | 121.43% | 138.43% | **143.34%** |
| **After closing all WebViews** | Main thread CPU | 99.70% | 0.00% | **0.00%** |
| | Full process-tree CPU | 100.58% | 0.10% | **0.30%** |

---

## Memory Benchmark Comparison (`scripts/benchmark_linux_memory.sh`)

Physical memory is attributed via `/proc/<pid>/smaps_rollup` **PSS** (avoiding shared-mapping double counting across Chromium processes), alongside aggregate **RSS**, **USS** (`Private_Clean + Private_Dirty`), **Anon**, and **Peak `VmHWM`**.

### Controlled 3-Repetition A/B of Chromium Low-Memory Embedder Flags (`FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0` vs default)

| Scenario (3 reps each) | Flags OFF Mean PSS (min–max) | Flags ON Mean PSS (min–max) | PSS Delta | RSS Delta |
| :--- | ---: | ---: | ---: | ---: |
| CEF init only (0 WebViews) | 431.3 MB (427.8–434.7) | 424.5 MB (423.8–425.8) | -6.8 MB (-1.6%) | -4.5 MB |
| Static page idle (1 WebView) | 504.4 MB (502.0–505.8) | 494.7 MB (492.9–495.9) | -9.7 MB (-1.9%) | -74.8 MB |
| 3 simultaneous WebViews | 515.0 MB (512.0–518.7) | 502.8 MB (501.7–504.3) | -12.2 MB (-2.4%) | -80.9 MB |
| After closing all WebViews | 477.3 MB (473.7–480.6) | 452.9 MB (449.3–457.2) | **-24.4 MB (-5.1%)** | **-75.7 MB** |

### Full 12-Scenario Comparison (`b3458b6` vs `optimized_056`)

| Scenario | `b3458b6` PSS (RSS / USS / Rend) | `optimized_056` PSS (RSS / USS / Rend) | PSS Change |
| :--- | :--- | :--- | ---: |
| 01. Flutter app without CEF | 228.4 MB (319.7 / 202.3 / 0) | 233.0 MB (321.7 / 207.0 / 0) | +4.6 MB (+2.0%) |
| 02. CEF initialized, 0 WebViews | 418.2 MB (872.5 / 281.5 / 0) | 416.6 MB (871.6 / 279.4 / 0) | -1.6 MB (-0.4%) |
| 03. 1 WebView (`about:blank`) | 448.2 MB (998.7 / 300.8 / 2) | 487.5 MB (1020.7 / 330.4 / 1) | +39.3 MB *(warmed 1st renderer)* |
| 04. 1 WebView (local static HTML) | 495.4 MB (1133.5 / 321.0 / 2) | 494.0 MB (1036.2 / 330.2 / 1) | -1.4 MB (-0.3%) / -97.3 MB RSS |
| 05. 1 WebView (remote `example.com`) | 562.0 MB (1323.1 / 361.3 / 3) | 521.5 MB (1084.2 / 355.3 / 1) | **-40.5 MB (-7.2%)** / -238.9 MB RSS |
| 06. 3 simultaneous WebViews | 606.5 MB (1636.5 / 393.7 / 6) | 554.7 MB (1313.4 / 360.7 / 3) | **-51.8 MB (-8.5%)** / -323.1 MB RSS |
| 07. 5 simultaneous WebViews | 572.2 MB (1401.2 / 382.9 / 4) | 562.6 MB (1419.2 / 364.2 / 4) | -9.6 MB (-1.7%) / -18.7 MB USS |
| 08. After 20-page navigation | 530.3 MB (1037.3 / 382.9 / 1) | 485.2 MB (951.0 / 342.1 / 0) | **-45.1 MB (-8.5%)** |
| 09. All WebViews disposed | 523.7 MB (1031.0 / 376.3 / 1) | 483.8 MB (949.5 / 340.7 / 0) | **-39.9 MB (-7.6%)** / -35.6 MB USS |
| 10. Recreated after disposal | 541.7 MB (1056.5 / 395.8 / 1) | 539.5 MB (1084.2 / 375.1 / 1) | -2.2 MB (-0.4%) / -20.7 MB USS |
| 11. After 10 create/dispose cycles | 516.2 MB (978.1 / 376.4 / 0) | 488.2 MB (953.9 / 345.2 / 0) | **-28.0 MB (-5.4%)** / -30.6 MB MainPSS |

### 10-Minute Idle Soak (`optimized_056`, Scenario 12 — 1 Static WebView)

| Elapsed | Procs | Renderers | Total PSS | Total RSS | Total USS | Browser Main PSS | Renderer PSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 s | 9 | 1 | 547.8 MB | 1092.5 MB | 383.5 MB | 365.8 MB | 60.8 MB |
| 60 s | 9 | 1 | 548.3 MB | 1093.2 MB | 383.8 MB | 366.0 MB | 61.1 MB |
| 120 s | 9 | 1 | 548.5 MB | 1093.9 MB | 383.9 MB | 365.9 MB | 61.2 MB |
| 240 s | 9 | 1 | 548.5 MB | 1094.0 MB | 383.9 MB | 366.0 MB | 61.2 MB |
| 300 s | 9 | 1 | 548.6 MB | 1094.1 MB | 384.0 MB | 366.1 MB | 61.2 MB |
| 420 s | 9 | 1 | 548.6 MB | 1094.1 MB | 384.0 MB | 366.1 MB | 61.2 MB |
| 540 s | 9 | 1 | 548.6 MB | 1094.1 MB | 384.0 MB | 366.1 MB | 61.2 MB |
| 600 s | 8 | 0 *(idle renderer reclaimed)* | 510.5 MB | 979.6 MB | 365.4 MB | 375.3 MB | 0.0 MB |

Total PSS remained flat at **548.6 MB** from minute 5 through minute 9 (0.0 MB drift) with no evidence of unbounded growth.

---

## Lifecycle Matrix (`scripts/test_linux_lifecycle.sh` on `optimized_056`)

All **18/18 checks** (all 14 mandatory scenarios + 10 consecutive startup/shutdown runs) exited with `rc=0`, `init=1`, `shutdown=1`, zero unhandled Dart exceptions, and zero orphaned Chromium subprocesses:

- Scenarios 1–5 (single WebView, 3 concurrent WebViews, dispose 2 keep 1, dispose all, reopen + 12 rapid resize/paint cycles): **PASS** (`4.23 s`)
- Scenarios 6–8 (2 GTK windows, close 1st while 2nd active, close last): **PASS** (`10.30 s`, main-thread CPU `0.80%`)
- Scenario 9 (remove last window while `g_application_hold()` active, reopen GTK window with new WebView, then close & release): **PASS** (`15.41 s`, main-thread CPU `0.17%`, reopened WebView reached `STAY_ALIVE_READY`)
- Scenario 10 (10 rapid GTK window create/destroy cycles): **PASS** (`6.63 s`)
- Scenario 11 (WM close via `WM_DELETE_WINDOW`): **PASS** (`7.32 s`)
- Scenario 12a & 12b (`ServicesBinding.instance.exitApplication()` & `SystemNavigator.pop()`): **PASS** (`1.56 s`, `1.62 s`)
- Scenario 13 (direct `g_application_quit()` with window attached): **PASS** (`5.40 s`, `G_APPLICATION_RUN_RETURNED status=0`)
- Scenario 14 (10 consecutive startup & shutdown runs): **PASS (`10/10`)**
