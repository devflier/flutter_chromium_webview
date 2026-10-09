# macOS resource stability

Start with ownership checks, then playback memory trends, then process failure
recovery and release validation. Passing churn does not prove a playback memory
plateau or absence of Chromium-internal leaks.

## Debug counters

The `flutter_chromium_webview` method channel accepts `getResourceCounters` in
Debug builds. The response contains separate `client` and `host` maps with:

| Counter | Ownership measured |
| --- | --- |
| activeBrowsers | Host browser sessions, including creation until CEF closes them |
| activeIOSurfaces | Host pool slots and client pixel-buffer slots backed by IOSurfaces |
| activeMachSendRights | Owned export/lookup references; client also retains one listener send right |
| activeMachReceiveRights | The client process-wide surface listener receive right |
| activeFlutterTextures | Live client ChromiumTexture objects, two per browser |
| activeMetalTextures | Live host-created Metal texture objects, including command-buffer retention |
| pendingIpcRequests | Client response callbacks and host JavaScript requests |
| activeIpcConnections | Connected client socket / accepted host connections |
| hostGeneration | Successful host handshakes observed by the client |

Read a snapshot after initializing the browser runtime:

```dart
const channel = MethodChannel('flutter_chromium_webview');
final counters = await channel.invokeMapMethod<String, dynamic>(
  'getResourceCounters',
);
```

Zero on a process that does not own a resource is expected. Surface counts
measure owned pool slots, rather than all CoreVideo/Flutter/CEF references to
those surfaces. Flutter raster leases can outlive slot replacement; the native
texture regression checks that those leases remain valid.

The client snapshot is taken before queuing the diagnostic IPC request, so that
request does not count itself. The maps are not an atomic cross-process sample.
Poll after asynchronous work settles. The client Mach listener and IPC
connection remain alive between browsers; compare them to the initialized
baseline. Browser sessions, surfaces, Flutter/Metal textures and pending
requests should return to zero. A changed hostGeneration means the workload
restarted the host and must not be counted as a clean uninterrupted run.

Counter updates and the snapshot endpoints are disabled outside Debug builds.
The embedding build phase compiles the host from current sources with the
Runner configuration before signing it, rather than using a stale executable.

## Automated browser and resize churn

From `packages/flutter_chromium_webview/example`:

```sh
flutter test integration_test/resource_stability_test.dart -d macos \
  --dart-define=RESOURCE_CYCLES=100
```

Each cycle loads an animated HTML canvas from a loopback HTTP server, waits
for a renderer readiness message, verifies its animation counter, renders for five seconds,
resizes through 640x360, 1280x720, 1920x1080 and 800x600, then disposes the browser.
It checks the three-surface host pool while active and polls both processes for
return to the initial baseline, allowing up to 15 seconds for deferred cleanup.
Any resource mismatch or unexpected host restart fails with both snapshots.

For a short development run, use `RESOURCE_CYCLES=3` and
`RESOURCE_DWELL_SECONDS=1`. The defaults are 100 cycles and five seconds;
500 cycles provide a longer run. The test uses a fresh temporary cache and
leaves it in the system temporary directory because the host may still use it
until the integration app exits.

The example's Resource Stress Test screen provides a separate manual YouTube
page churn workload. Start it explicitly; Stop waits for the current browser to
finish disposal before another run can start. Loading YouTube's home page is
not a video playback soak and this screen does not assert counters.

## Playback and allocation audit

Run a real YouTube video for 30–60 minutes independently of churn. Sample the
host and its helper processes' RSS, CPU, elapsed time and file descriptors.
Record the selected video, resolution, sample interval and timestamps. A cache
warm-up increase is expected; sustained growth after warm-up needs investigation.
Do not infer a memory plateau from ownership counters alone.

Use Instruments Allocations and Leaks on the same workload once churn is clean.
Inspect roots in HostBrowserClient, BrowserSession, IOSurface, MTLTexture,
ChromiumTexture and IPC/pending requests. Distinguish browser-owned allocations
from Chromium caches and process-wide services. Test renderer, GPU and total
host failures only after the resource baseline is established. No system RAM
exhaustion is required.

## Verification on 2026-10-09

- The final HTTP canvas workload passed 100 create/dispose cycles with five
  seconds of animation per cycle and 400 controlled resizes. Each cycle verified
  renderer readiness and a positive animation frame count before disposal.
- Both processes returned to their initial ownership baseline after every cycle:
  browser sessions, surface slots, Flutter/Metal textures and pending requests
  were zero. The client kept one send right, one receive right, one connection
  and hostGeneration 1; the host kept one connection. No host restart occurred.
- A separate three-cycle run with one-second dwell also passed.
- All 69 package tests and five macOS packaging tests passed. Focused analysis of
  the changed Dart files reported no issues. Full example analysis still reports
  findings in existing host_crash_test.dart and main.dart.
- The native Apple/Flutter texture ownership regression passed, including stale
  surface rejection, generation replacement and raster leases across disposal.
- Host sources compiled with Debug disabled, and a standalone Release counter
  check verified that updates have no effect. This is not a signed Release app
  or notarization validation.

The initial HTML-loading fixture did not establish script readiness in the
short smoke run. The final workload uses loopback HTTP and explicit readiness;
these results do not validate loadHtmlString behavior. No playback RSS/CPU soak,
Instruments audit, helper-failure campaign or release-hardening campaign was
performed in this first implementation step.
