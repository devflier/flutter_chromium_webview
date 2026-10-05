# Desktop v0.1.0 stabilization — open

Updated: 2026-10-05. This is a release candidate audit, not a published release.
Do not infer runtime verification from the existence of an implementation.

## Environment

Ubuntu 26.04.1 LTS, WSL2 kernel 6.6.87.2, x86-64; Flutter 3.47.5 stable,
Dart 3.13.4; CMake 4.2.3. CEF 149.0.4 / Chromium 149.0.7827.156.
Only WSLg is available here. Native Linux desktop compatibility is unverified.
Windows validation uses Flutter 3.47.4 and the Visual Studio CMake toolchain.
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
| Current Dart unit/widget tests and analyzer | Passed: 32 package tests, 2 example tests; analyzers clean |
| Sandbox-enabled debug/release startup | Passed on Windows and WSLg; confinement review still required |
| Release bundle outside checkout and normal close | Passed Windows and WSLg software/default graphics; shutdown complete and no surviving CEF subprocesses |
| Default host graphics | WSLg startup/close passed with DRI3 warnings; hardware acceleration not established |
| Native Linux desktop | Unavailable; release blocker |
| HTML dropdown bounds/input outside widget | Widget hit tests passed at DPR 1 and 2; native popup selection passed; physical edge/multi-monitor checks remain |
| Dialog/menu disposal and navigation cancellation | Native integration and per-browser route/widget tests passed; manual clipboard/IME checks remain |
| Advanced IME and candidate positioning | Not verified / unsupported positioning |
| Publication dry run | Scaffold/build exclusions verified; 2 warnings remain: uncommitted tree and missing repository/homepage |
| CI | Workflow added for Dart and Windows; remote run unavailable because no repository remote is configured |
| macOS | Initial backend and example runner implemented; compilation/runtime unverified on this Windows host |
| JavaScript bridge | Shared desktop implementation; Windows/WSLg renderer tests pass for browser/channel/origin isolation, Unicode, navigation and disposal; macOS validation pending |
| HTML loading | Explicit HTTP(S) document URL/origin, relative assets, reload, replacement, empty documents and browser isolation pass on Windows/WSLg; macOS validation pending |
| Browser settings | Browser-specific HTTP/JavaScript user-agents, isolated autoplay contexts and unmuted WAV progress pass on Windows/WSLg; audible output remains unverified |
| YouTube adapter | Ordered commands, events, getters, reload, timeouts and disposal tested; real CEF fixture and live playback/pause/seek/volume/widget-detachment checks pass on Windows/WSLg; see `youtube-adapter.md` |
| ppplayer macOS adoption | Initial adapter and shared desktop prerequisites implemented; app facade integration, storage requirements, native Mac validation and distribution-model decision remain; see package `MACOS.md` |

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

v0.1.0 remains open until the remaining matrix is resolved, native Linux testing is
performed, sandbox behavior and third-party notices are reviewed, package metadata
is validated with a publication dry run, and all required checks pass. No package
publication or Git release is authorized by this audit.
