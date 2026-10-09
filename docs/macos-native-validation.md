# macOS native integration investigation — 2026-10-09

The original lifecycle failure was a missing embedded host executable. It was
not a LaunchServices foreground activation failure.

[Original failing macOS run](https://github.com/devflier/flutter_chromium_webview/actions/runs/37971064999)
reported `PlatformException(INIT_FAILED, Host executable not found, null, null)`
at `ChromiumWebViewController.initialize`. That exception proves that Runner,
the Dart VM, integration binding, test body, and MethodChannel were already
running. CEF could not initialize because the host executable was absent.

Commit `b5e548d` builds the host from source into Runner's Frameworks directory,
then embeds and signs its CEF framework/helpers. It avoids depending on an
ignored, locally prebuilt `ChromiumWebViewHost.app`. A new packaging regression
test exercises that clean-build path and checks the compiler input/output.

[The next macOS run](https://github.com/devflier/flutter_chromium_webview/actions/runs/37976173648)
passed lifecycle and input tests while still printing
`Failed to foreground app; open returned 1`. It then failed in native UI with a
JavaScript timeout. Local verbose lifecycle reproduction also returned zero
with that foreground warning. No GUI-session workaround is justified by this
evidence.

The native UI timeout exposed missing macOS CEF dialog/context-menu handlers
and stubbed `closeJSDialog` / `closeContextMenu` channel methods. Native callback
ownership now stays with the browser session, removes each callback before
completion, rejects responses for another browser, and cancels pending callbacks
on disposal/reset. Popup visibility/geometry events reach Dart. The original
native UI assertions remain enabled on macOS.

`executeJavaScript` now acknowledges validated dispatch through CEF's execution
API. Waiting for a script's result prevented a caller from navigating/disposal
while that script was blocked on a dialog. `evaluateJavaScript` retains its
result, error, promise, cancellation, navigation and timeout behavior.

The HTML suite additionally exposed an incorrect charset, a global URL-keyed
one-shot document store, and missing native argument validation. macOS now uses
the shared `chromium_html::Documents` handler: UTF-8 responses, one retained
document per browser, reload support, and interception restricted to main-frame
navigation. Explicit network navigation and disposal clear the stored document.
Invalid native HTML calls retain the previous valid document.

The settings path also dropped creation settings over IPC, and `setUserAgent`
was a stub. macOS now uses the existing shared
request-context/autoplay and user-agent helpers, retaining default gesture policy
and applying opt-in autoplay only to the requesting context. The unchanged settings
suite passes user-agent headers/JS, autoplay and cookie isolation, and reload.

The YouTube contract test subsequently stalled in a manually pumped frame while
Chromium heartbeats continued. The 35-second deadline loop could not progress.
The preserved VM stack showed an idle Dart isolate, and the same test passed in
three seconds after selecting Flutter's `benchmarkLive` policy. macOS integration
tests now use that policy, as the allocation harness already did. It respects
framework/engine frames and avoids waiting for artificial pump requests; it does
not simulate Chromium rendering or remove assertions. No fixed startup sleep or
LaunchServices workaround was added.

The final process audit also reproduced a host-restart race. A killed host's
NSTask termination callback could arrive after a replacement launched, mark that
replacement failed, and delete its socket directory. The IPC disconnect callback
could likewise target a new launch. Fourteen abandoned hosts were found with
`Failed to start IPC server: ... No such file or directory` followed by entry into
the CEF message loop. The stale hosts were recorded and cleaned up before retesting.
Manager callbacks now validate their task/client identity, each launch owns its
IPC client, and IPC startup failure prevents entry into the message loop while
still completing CEF shutdown. The diagnostic wrapper now fails a successful
command if newly created host/helper processes survive its shutdown deadline.

## Diagnostic artifacts

`scripts/validate_macos.sh` uses `macos_diagnostic_stage.py` to retain each native
stage's complete Flutter output, command, exit status, duration, process snapshots,
host log, CEF log, macOS application log and newly generated relevant crash reports.
The unified workflow uploads `docs/validation/macos/` even when validation fails.
Regression tests verify that collection preserves exit status 7 and both
stdout/stderr, archives earlier failures, and rejects a successful command
that leaves helper processes alive. Logs from repeated host launches append within one stage.

Ephemeral tests use `CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1`, avoiding Chromium Safe
Storage access to the user's login keychain. Production behavior is unchanged.
The allocation report path now uses the harness's actual `SOAK_REPORT` Dart
define; the previous `PROFILE_REPORT_PATH` environment variable was unused.

The copied release-bundle smoke test observes the current host handshake and
completed CEF shutdown, then requires all processes from the copied bundle to
exit. It no longer looks for obsolete in-process-backend log messages. The native
texture regression is compiled with DEBUG counters enabled and explicitly links
IOSurface (its previous command failed with undefined IOSurface symbols).

## Validation

The complete local `scripts/validate_macos.sh` sequence passed after the final
host-launch fix. Local Flutter is 3.44.8 / Dart 3.12.2, macOS 27.0.1, Xcode 27.0.
The local SDK constraint override is not included in the fix. CI pins Flutter
3.47.4; its dispatched macOS job must be assessed separately.

| Check | Local result |
| --- | --- |
| Independent verbose lifecycle test | Passed, including the foreground warning |
| Native suites: lifecycle, input, UI, JS bridge, HTML, settings, YouTube adapter, JS evaluation, host crash | All passed |
| Host crash recovery | 20 cycles passed independently and again in the full run; no surviving processes |
| Live YouTube playback and interaction | Passed |
| Browser/resource churn | 100 cycles / 400 resizes; baseline restored every cycle |
| Allocation workload | 300 seconds plus 60 seconds of disposal observation; passed existing assertions |
| Native texture ownership | DEBUG regression compiled and passed with IOSurface linked |
| Release build and copied-bundle startup/normal shutdown | Passed; CEF shutdown completed and bundle processes exited |
| Dart checks | Formatting of changed Dart files, package/example analysis, 69 package tests and 2 example tests passed |
| Python checks | 7 packaging tests and 2 diagnostic-wrapper regressions passed |

The final playback report recorded 9,159 completed Metal frames,
0 Metal failures, 0 software frames,
and 0 dropped video frames. All renderer PIDs exited after browser disposal,
and owned-resource counters returned to the idle baseline. Combined RSS changed
by 49.6 MiB between the first post-warm-up sample and the final sample.

Full local evidence is retained under `docs/validation/macos/` (one directory per
stage, plus allocation/playback JSON reports) and `docs/validation/macos-investigation/`
(original CI output, independent verbose reproduction, pre-fix orphan PIDs,
Instruments trace, VM map and leak scan). These generated artifacts are ignored
by Git; the unified workflow uploads its macOS stage artifacts on failure too.

A 30-second Instruments Allocations capture of the largest renderer completed.
It showed 436.88 KiB of persistent allocations created during that capture,
versus 15.74 MiB of total allocation churn. CEF stacks lack useful symbols, and
the `leaks`/`vmmap` tools could not examine PartitionAlloc completely. `leaks`
returned 1 and reported 144 bytes in six Objective-C proxy metadata allocations.
This is not a clean leak audit or complete attribution of renderer RSS.

The five-minute gate does not establish a 30–60-minute renderer memory plateau.
The earlier long-soak RSS slope remains open pending longer measurements and
symbolized Chromium/media allocation attribution. Static `example.com` and
animated local-page comparisons use the same profiling harness and retain
separate reports. No architecture change, assertion suppression, version bump,
or tag replacement is part of this fix.
