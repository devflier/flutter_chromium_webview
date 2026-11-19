# Linux 0.5.6 Final Hardening Audit (partial)

Branch `fix/linux-cef-lifecycle-0.5.6` (uncommitted). Environment: Ubuntu 26.04.1 VM, Flutter 3.50.0, CEF 149.0.4, X11/XWayland.

## A. Executive Summary
Lifecycle and CPU behaviour reproduce: 72 unit + 2 example tests, 7/7 Linux integration suites, 18/18 lifecycle checks (10/10 repeats), idle CPU 1%, no orphans. **Verdict: NOT READY** because of the open High risk in section B and several phases not executed (section H).

## B. Architectural Findings
| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | `g_application_hold/release/quit` are interposed globally. Verified: works only when the plugin is linked before GIO (standard Flutter). With GIO first, or `dlopen(RTLD_LOCAL)`, the wrappers are bypassed and tracking silently stops. | OPEN |
| 2 | High | Counter ignores which `GApplication` and GIO-internal holds. | OPEN. A fix using `g_application_get_is_busy` plus an app filter was tried and caused 100% CPU spin in multi-window and held-reopen scenarios, so it was reverted. |
| 3 | High | Unbounded GLib drain in `Shutdown()`. | FIXED (1000 iterations / 500 ms cap). |
| 4 | Medium | `window-removed` handler never disconnected. | FIXED. |
| 5 | Medium | Plugin `RUNPATH` leaked build-tree paths. | FIXED (`$ORIGIN`, verified in release bundle). |
| 6 | Info | `cef_texture.cc` front-buffer lifetime. Flutter uploads synchronously on the same raster thread right after `copy_pixels`; only that thread frees the buffer. | Safe by disassembly. Not ASan/TSan tested. |

Alternative: CEF 149 `multi_threaded_message_loop` ran init, browser, paint, close, `CefShutdown`, exit 0 with plain GTK3 and no interposition (probe in VM `/tmp/fcw_mtml_probe`). Adopting it needs a refactor because CEF callbacks leave the GTK thread. Recommended path to close findings 1-2.

## C. Security Findings
NOT RUN (sandbox, site isolation, TLS, bridge origin, flags audit). Note: the VM needs `kernel.apparmor_restrict_unprivileged_userns=0` for the sandbox; production docs should recommend an AppArmor profile.

## D. CPU and Memory
- Idle CPU: 0-1% main thread (baseline ~99%).
- Memory (single runs, not repeated): `about:blank` PSS 487.5 MB vs 448.2 MB for b3458b6 (+39 MB, unexplained, one run). The 3-WebView "-51.8 MB" compares runs with different renderer counts and is not like-for-like. `rend=0` in `08_nav_20_pages` and `12_soak_t600s` is real (renderer freed before sampling).
- 3-repetition median/min/max and `malloc_trim(0)` A/B: NOT RUN.

## E. Compatibility Matrix
24-scenario functional matrix and flag-by-flag audit: NOT RUN.

## F. Lifecycle and Stress Results
Lifecycle 18/18 PASS, repeats 10/10. Stress suite (100 cycles etc.) NOT RUN.
Note: an `INIT_FAILED` seen in two validation runs was caused by launching without `DISPLAY`/`XAUTHORITY`; it did not recur with a display configured.

## G. Changes Implemented
Bounded shutdown drain, signal disconnect, `$ORIGIN` RUNPATH in `cef_runtime_manager.cc/.h` and `CMakeLists.txt`.

## H. Remaining Issues
Findings 1-2; unrun: security audit, compatibility matrix, repeated benchmarks, `malloc_trim` A/B, Ubuntu 24.04/Debian/Fedora and native Wayland, Dart lifecycle tests, stress suite, sanitizer runs.

## I. Release Decision
**NOT READY.** High findings remain open and required phases were not executed.

## J. Git Status
Uncommitted on `fix/linux-cef-lifecycle-0.5.6`. Nothing pushed, merged, tagged or published.
