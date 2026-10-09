# Renderer memory attribution

Run the opt-in integration harness from `packages/flutter_chromium_webview/example`:

```sh
CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 CEF_PROFILE_DEBUG_PORT=9229 \
flutter test integration_test/allocation_profile_test.dart -d macos \
  --dart-define=ALLOCATION_PROFILE=true \
  --dart-define=PROFILE_WORKLOAD=youtube \
  --dart-define=SOAK_SECONDS=1200 \
  --dart-define=SOAK_INTERACTION_SECONDS=120 \
  --dart-define=PROFILE_DISPOSAL_SECONDS=60 \
  --dart-define=SOAK_REPORT=/absolute/path/youtube.json
```

Create the report directory first. Workloads are `static` (real example.com),
`animated` (a loopback canvas animation), and `youtube` (the existing real iframe
adapter). Use fresh application launches for each. The test verifies content
loaded, accelerated rendering, resource stability, and disposal counters.
Static content is allowed to stop generating paint callbacks.

The harness uses wall-clock waits and the Flutter `benchmarkLive` frame policy
so interval observation does not depend on every requested test frame completing.
The native renderer still runs normally; this does not simulate video playback.
YouTube interactions include seeks, pause/resume, resizes, native window
fullscreen, widget detach/reattach, and track changes. Interval snapshots retain
each host descendant PID separately; commands redact IPC tokens.

After disposing the browser, the host remains alive for 60 seconds. The report
records descendant PIDs, RSS and resource counters every five seconds. Compare
renderer exits and aggregate memory to the pre-browser process snapshot. Do not
require all Chromium utility processes or caches to disappear with one browser.

`CEF_PROFILE_DEBUG_PORT` is opt-in and compiled only in DEBUG; use the local
DevTools endpoint for these test sessions. The renderer Debug helper includes
`get-task-allow` for Instruments attachment. Release/Profile helpers keep the
normal JIT entitlement without debugger access. No sandbox or system-security
settings are changed.

The evidence directory contains Python scripts for interval CDP sampling,
separate Instruments windows, VM summaries and report generation. CDP samples
per-target JS heap sizes, backing storage, embedder heap sizes, DOM counters and
live allocation stacks. These measure different things from RSS. Sampling and
native profilers add overhead, so compare their time windows and retain the
original unprofiled soak as a reference.

Frame telemetry is read in the actual YouTube iframe context through DevTools:
`getVideoPlaybackQuality()` supplies total and dropped frames,
`webkitDecodedFrameCount` supplies Chromium's decoded count, and
`requestVideoFrameCallback` supplies the compositor's presented count. The
presented-count delta divided by elapsed wall time is the interval average FPS;
seeks/pauses and detached periods affect it. Resolution is the video element's
intrinsic width/height. Frame counts can reset across track changes: exclude
negative/reset deltas, and do not equate compositor presentation with final
physical display scanout. No cross-origin restrictions are disabled.

References: [Chromium DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/),
[video playback quality](https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/getVideoPlaybackQuality),
[frame presentation callbacks](https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback).

A native profiler failing to attach is an unavailable result, not a clean report.
Preserve warnings from `leaks` and `vmmap`, especially incomplete PartitionAlloc
introspection. A zero count from a restricted scan cannot establish leak freedom.
