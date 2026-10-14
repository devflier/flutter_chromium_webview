# Android startup and macOS performance investigation

Preparation only, following candidate129e585 / run38566050605. No publishing,
merge, tag changes, memory threshold changes or product approvals.

## Focused execution

The existing unified workflow now accepts `validation_scope` (`all` by default,
`android-html`, `android`, `macos-performance`). Manual diagnostic scopes skip
unrelated jobs; tag/PR/default runs retain all required dependencies. Diagnostic
runs cannot publish. Use pinned Flutter3.47.4/Dart3.13.3 for final validation.

```
gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=android-html
gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=android
# Run sequentially: existing branch concurrency cancels overlapping runs.
gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=macos-performance
```

Android capture starts persistent ADB logcat and independent one-second process
observations before Flutter launch, and stops after post-command diagnostics.
It records UTC boundaries, original exit, collector exit, device properties,
crash buffer, Activity state, native crash Dropbox and tombstone availability.
Unavailable privileged evidence stays unavailable. It does not restart ADB or
silently retry the test. Diagnostic completeness is distinct from test success.

Local supplementary reproduction on installed Flutter3.44.8/Dart3.12.2 and
API36.1 arm64 emulator failed differently: installed activity was unavailable,
user state RUNNING_LOCKED, no unlock time; original CI had already attached a
VM service. This does not establish the original failure mechanism. Persistent
capture worked; no speculative production fix is justified by this result.

## Counter definitions and limitations

Fixture: unchanged generated VP9,640x360,30fps,4-second loop, silent. The matched
historical CI drop fraction is5330/8915=59.8%; paired local diagnostic is zero.
Counters are paired only within target/context/video identity, and reset or
incompatible intervals fail analysis. Raw historical captures are unchanged.

- `getVideoPlaybackQuality`: total includes frames displayed or dropped; drops
  are media-pipeline losses, not a count of Flutter texture updates. These
  counters cannot alone classify before-decode versus compositor losses.
- `requestVideoFrameCallback.presentedFrames`: frames submitted for Chromium
  composition. The existing `currentFps` is this counter's interval rate,
  **not display scanout FPS**.
- Completed Metal frames count GPU copies, including paints not uniquely linked
  to video frames. They cannot be subtracted from decoded counts to infer loss.
- Flutter FrameTiming describes engine build/raster/vsync; it has no correlated
  video-frame identity and does not prove physical presentation.

Sources: https://w3c.github.io/media-playback-quality/ and
https://wicg.github.io/video-rvfc/

Opt-in `PERFORMANCE_DIAGNOSTICS=true` adds bounded per-callback timestamps,
media times, compositor frame IDs and decode processing durations, plus Flutter
frame timings. A Debug-only diagnostic getter exposes the existing cumulative
GPU blit duration without changing rendering. Hardware/RAM/hypervisor, system
load, thermal and VM snapshots accompany the diagnostic. This instrumentation
adds overhead: results are diagnostic, not interchangeable with clean runs.
Missing events and bounded-buffer overflow remain explicit; actual display
presentation, IOSurface-to-video identity and end-to-end latency remain unknown.
CPU/RSS rows are retained independently. No thresholds are inferred from data.

## Pending product decisions

Historical RSS acceptance stays FAIL. New deterministic memory workload PASS
is separate; physical8GB qualification BLOCKED, allocator ownership INCONCLUSIVE
and long-term leak freedom not established. No accepted product policy has
replaced those requirements. Release cannot infer8GB support from an unspecified
runner, and cannot treat diagnostic performance output as approved acceptance.

Owner decisions required: supported hardware/architecture, concurrency,
resolution/audio matrix, foreground/background behavior, allowable playback
stall duration/frequency, compositor FPS relative to source, frame-pacing
percentiles, CPU/GPU envelope, audio synchronization and repeatability. Numeric
ceilings remain UNSET pending representative hardware evidence and approval.
Final-display FPS/end-to-end limits require additional presentation-level
instrumentation; current compositor/Flutter counters cannot certify them.

Interface API checks remain independent of native runtime diagnostics. Existing
unpublished interface tagf202e72 targets the old workflow; explicit owner approval
of source/tag strategy is required. Hosted0.1.6 remains a mandatory plugin gate.

## New evidence (2026-10-14)

Independent HTML loading PASS on release SDK in
https://github.com/devflier/flutter_chromium_webview/actions/runs/38603598173 .
Persistent capture starts17:07:31.595UTC, command finishes17:11:01.502UTC and
capture finishes17:11:03.090UTC;203 process observations, app observed during
launch/test before normal teardown. All eight post-command diagnostic commands
exit0, no identified fatal signal/exception in persistent log. The original
VM-service disconnect is not reproduced and its mechanism remains INCONCLUSIVE.
A separate failed diagnostic dispatch38603102853 never reached Flutter because
the emulator action executed multiline shell fragments separately. Fixed with
one standalone script; the failed invocation remains preserved.

Local instrumented macOS diagnostic PASS for evidence completeness and unchanged
RSS gate:302.175s,12 samples,RSS growth−133424KiB,zero matched drops over9021
frames,compositor rate≈29.94FPS. Callback interval average33.53ms,p95/p99 50.1ms;
Flutter raster average0.48ms,p99 0.91ms. Those are different measurements with no
shared frame ID; neither proves final physical presentation. Native shutdown
survivors empty. Older SDK/16GiB diagnostic only; no hardware qualification or
approved performance acceptance. Instrumentation may change workload overhead.
