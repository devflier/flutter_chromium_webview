# Real YouTube playback soak

This measures the existing process-isolated rendering design. It does not tune
startup, change rendering architecture or simulate video playback.

Run from `packages/flutter_chromium_webview/example`:

```sh
CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 flutter test \
  integration_test/playback_soak_test.dart -d macos \
  --dart-define=YOUTUBE_SOAK=true \
  --dart-define=SOAK_SECONDS=1800 \
  --dart-define=SOAK_REPORT=/absolute/path/soak.json
```

Use 3600 seconds for a 60-minute run. Create the report's parent directory first.
The mock Keychain uses the existing test-only launch option, avoiding real
Keychain access. Videos are muted to avoid playing audio throughout the test.
The test retains one real browser and switches between two real YouTube videos.

Each 3-minute interval pauses/resumes and seeks, plus a rotating interaction:
resize, fullscreen/restore, hide/show, or track change. Hide/show removes and
reattaches the Flutter widget without disposing its browser; this tests detached
playback, rather than minimizing the app or simulating document visibility.
Fullscreen toggles the native Flutter window through a DEBUG-only test hook.

Snapshots are written every 30 seconds, including approximately 0, 5, 15 and
30 minutes (and 60 for a longer run). They include:

- Both processes' resource counters and the host generation.
- Paint callback counts, completed/failed Metal blits and surface generation.
- YouTube playback position/state, heartbeat and active video ID.
- Host and descendant-process RSS, CPU, elapsed time and process types.
- `lsof` row count and numeric file-descriptor count for this host.
- Interaction results, native fullscreen state and post-disposal counters.

Process sampling starts from the host PID returned by native diagnostics and
includes only its descendants. IPC authentication tokens are redacted from
stored command lines. Samples and interactions are saved incrementally; an
interrupted or failed run leaves its evidence behind with `passed: false`.
The harness retains only the latest heartbeat and bounded interval snapshots.

The live gate verifies advancing playback, completed Metal blits, no failed
blits, no increase in software callbacks after warm-up, unchanged ownership
counts and host PID/generation, and return to idle resources after disposal.
Metal texture counts may fluctuate briefly while a command buffer owns them.
A passing gate alone does not establish an RSS/FD/helper-process plateau: inspect
those trends in the saved report after initial cache warm-up, correlating them
with seeks, resizes and track switches.

Actual dropped video frames are **unmeasured**. The YouTube iframe is a separate
origin, and the current adapter has no decoded/dropped-frame metric. Native
paint callbacks and completed blits are not equivalent to decoded video frames.
The old telemetry string's literal `droppedFrames=0` is not evidence; it now
reports `droppedFrames=unmeasured`. This limitation must remain in any result.

For harness preflight, use `SOAK_SECONDS=180`,
`SOAK_INTERACTION_SECONDS=15` and `SOAK_SAMPLE_SECONDS=15`; this exercises the
interaction sequence quickly and is not a replacement for sustained playback.
