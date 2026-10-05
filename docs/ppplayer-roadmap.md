# ppplayer integration work

Windows and WSLg are available now. Native macOS validation waits for a Mac.
The user's main ppplayer checkout is preserved. An isolated integration preview
is available at `C:/Users/User/Projects/ppplayer_chromium_preview`, branch
`codex/chromium-playback-adapter`, based on app commit
`93c4af527b238d237c2da3b9fab4d639f84177a9`. It is uncommitted and has not been
pushed or published.

## Completed from Windows/WSL

- Add immutable, browser-scoped JavaScript channel configuration to the Dart
  controller and a shared CEF renderer/browser policy for all desktop platforms.
- Permit exact HTTP(S) origins and main frames only, with a 64 KiB UTF-8 message
  limit. Capture the document security origin before page scripts run; reject
  opaque documents, including CSP-sandboxed documents.
- Cover channel/origin/browser isolation, Unicode, message limits, navigation,
  subframes and disposal in Dart and real Windows/WSLg renderer tests.
- Include the new native integration suite in all desktop validation scripts.
- Add HTML loading at an explicit HTTP(S) document URL with browser-local
  immutable responses, normal relative-resource loading, reload/replacement,
  validation and Windows/WSLg renderer tests.
- Add user-agent overrides applied before initial navigation and opt-in autoplay
  in private in-memory contexts. Verify HTTP/JavaScript values, reload, cookies,
  WAV playback progress and default-policy rejection on Windows/WSLg.
- Add the optional YouTube playback adapter: ready/state/error events, ordered
  commands, seek, volume, getters, reload restoration, timeout and disposal.
  Unit tests and real CEF fixture suites pass on Windows/WSLg.
- Verify live YouTube playback progression, pause, seek, volume and playback with
  a detached Flutter video widget on Windows/WSLg. Add a manual example page.
  See [the adapter guide and reports](youtube-adapter.md).

The macOS bridge uses this shared implementation but has not been compiled or
run on macOS. See [the package API](../packages/flutter_chromium_webview/README.md)
and `validation/windows-javascript-bridge.log` /
`validation/linux-javascript-bridge.log` for bridge verification, and
`validation/windows-html-loading.log` / `validation/linux-html-loading.log`
for HTML verification.
Settings results are in `validation/windows-browser-settings.log` and
`validation/linux-browser-settings.log`. Live YouTube controller/progress checks
are in `validation/windows-youtube-live.json` and `validation/linux-youtube-live.json`.
Audible speaker output, visual quality and minimized-window playback remain unverified.

## Current ppplayer tests

The main app at `C:/Users/User/Projects/ppplayermusic/app` and the preview share
commit `93c4af5`. The main checkout's local changes remain untouched.
The preview now has 107 passing native-engine/app playback regression tests and clean
analysis, including lazy Android service ownership and iOS command routing.
Its native integration scenario passes on Windows and WSLg using the real
Chromium browser, ppplayer facade and PlaybackView, plus MediaKit local-video
fallback. It verifies progress, pause/resume, seek, volume, widget detachment,
track replacement, prepared playback and stop. The browser timer uses a local
YouTube API fixture; this does not establish live YouTube or audible output.
Full app debug and release builds also pass on both platforms. See
`validation/ppplayer-windows-native.log`, `validation/ppplayer-linux-native.log`
and `validation/ppplayer-playback-regressions.log`. Release results are in
`validation/ppplayer-windows-release.log` and `validation/ppplayer-linux-release.log`.
Reproduction commands are in
the preview's `integration_test/CHROMIUM.md`.

The real PlayerScreen live YouTube test also passes on Windows and WSLg against
the configured `https://ppplayer.com/chromium/player.html` document origin. It
opens through PlayerNotifier, taps pause/resume and seek controls, verifies
paused position and confirms volume through the actual YouTube getter. Catalog
resolution and storage are fixtures; full catalog navigation remains untested.
See `validation/ppplayer-windows-live-ui.log` and
`validation/ppplayer-linux-live-ui.log`.

The existing Android local-video integration test also passes on the
`emulator-5554` Pixel_9_Pro device: app debug APK build/install, video-track
detection, play, pause, seek and disposal. See
`validation/ppplayer-android-native.log`. This tests ppplayer's existing MediaKit
path. The Android provider now opts into audio-only Chromium with
`PPPLAYER_CHROMIUM=true`. Its headless browser uses the existing foreground
service without allocating a second WebView; local files retain MediaKit.
The live PlayerScreen test passes on the emulator with the real AudioService,
PpPlayerAudioHandler, MediaSyncService and lazy hybrid fallback. After Home,
the activity is confirmed stopped while playback advances; system media pause
and play commands are confirmed through browser state and position, followed
by activity restoration. See `validation/ppplayer-android-live-ui.log`.
The opt-in full-app release APK also builds for ARM64 and x86_64; archive
inspection confirms both Flutter/Dart and metadata native libraries. See
`validation/ppplayer-android-release.log` and
`validation/ppplayer-android-release-abis.log`. This is a local build, not a
published or production-signing verification. Service cleanup leaves no running
ppplayer services after the test (`validation/ppplayer-android-service-cleanup.log`).
An earlier live startup probe failed to advance and is retained in
`validation/ppplayer-android-live-ui-startup-failure.log`; its cause is unresolved,
so repeatability of external-service startup remains a release check.
Visible Android video transitions still fail the package's detach test.

The preview fixes first-build ordering of MediaKit header extraction and WebView2
downloads on Windows. WSL's copied Cargokit shell scripts needed LF normalization;
the preview adds a Git line-ending rule for future shell-script checkouts.

### Screen-off and source-switch follow-up (upstream baseline)

The Android emulator screen-off phase passes: the activity stays stopped,
PowerManager reports the device non-interactive, and the live browser advances
from 19.37 to 39.33 seconds during a 20-second interval. System media pause/play
and activity restoration also pass. The upstream combined test failed when returning
to local video for the second time, so this is a phase result, not a passing
end-to-end Android suite. See
`validation/ppplayer-android-screen-off-sources.log` and its `.screen-off.txt`.

Windows passes three local-video/live-YouTube round trips through PlayerScreen
(`validation/ppplayer-windows-source-switch.log`). WSLg passes two consecutive
runs of three round trips using continuous native video frames
(`validation/ppplayer-linux-source-switch.log` and
`validation/ppplayer-linux-source-switch-repeat.log`). Earlier WSLg renderer
initialization failures remain in the validation archive.

Native session teardown had been executed twice; the preview now queues and
awaits it once before opening a replacement. All 107 native engine/app playback
regression tests pass, including exact-once cleanup and waiting for an already
detached session (`validation/ppplayer-playback-regressions-current.log`).
Analysis of the changed engine and integration test is clean.

With upstream native artifacts, Android repeated source switching failed. Host graphics report
`EGL_BAD_ATTRIBUTE` when creating MediaKit video output
(`validation/ppplayer-android-host-egl-errors.log`). Both SwiftShader and ANGLE
software emulator runs lost the device during live YouTube startup before source
switching. Those runs are inconclusive
(`validation/ppplayer-android-screen-off-swiftshader.log` and
`validation/ppplayer-android-screen-off-swangle.log`). The AVD's saved GPU
configuration has not been modified; the emulator is restored to host graphics.

The updated Android ARM64/x64 release APK builds successfully, with Flutter/Dart
and metadata libraries confirmed for both architectures
(`validation/ppplayer-android-release-current.log` and
`validation/ppplayer-android-release-current-abis.log`). Earlier desktop release
builds predate the cleanup change.

### Native startup progress and Android 15 comparison (upstream baseline)

The native startup watchdog no longer cancels on a playing acknowledgement alone.
Position must advance beyond the requested initial seek point. A zero-progress
playing session now reports a playback timeout rather than an inaccessible-file
error. The 107 regression tests include a stalled playing acknowledgement,
a seek without progress and successful progress beyond the seek point. See
`validation/ppplayer-native-progress-watchdog-tests.log` and
`validation/ppplayer-native-progress-watchdog-analysis.log`.

A separate emulator using the already installed Android 15/API 35 image
(`Codex_PPPlayer_API35`, port 5556) repeats the screen-off and media-command phases
successfully. The browser advances from 14.69 to 34.70 seconds with the screen off.
Its second local-video switch reproduces the EGL context failure; the watchdog
reports the stalled start after five seconds. The complete combined test fails.
See `validation/ppplayer-android-api35-live-sources.log` and
`validation/ppplayer-android-api35-egl-errors.log`.

Windows Application Error records confirm that both software-emulator exits were
host QEMU access violations (0xc0000005), separate from the app's runtime test
assertions (`validation/ppplayer-android-emulator-host-crashes.log`).
The earlier release APK and desktop runtime runs predate this watchdog change.
The package ownership strategy is in `media-package-strategy.md`. A local native
Android fork now exists at `C:/Users/User/Projects/ppplayer_native_media`, based on
upstream native-build v1.1.7. Its actual mpv EGL function regression test passes
with a fallback that omits optional context flags. Both ARM64 and x86_64 native
builds and packages pass export, dependency and 16 KiB alignment checks.
Complete live acceptance tests pass on Android 15 and Android 16, including all
three local-video/live-YouTube round trips and the six background/screen-off/
system-media phases. The new fallback runs in both logs. The installed debug
APK's x86_64 native library hashes match the local artifacts. All 107 playback
regression tests pass with the private override, and changed-file analysis is clean.
Android 16 runs with 16 KiB memory pages. Service cleanup leaves no ppplayer services.
See `validation/ppplayer-native-fork-status.md`,
`validation/ppplayer-native-fork-api35.log` and
`validation/ppplayer-native-fork-api36.log`. A fresh ARM64/x86_64 release APK builds
and its native hashes match both local artifacts. Release install and startup reach
the first-run notification permission request with MediaKit initialized; release
playback and production signing are not yet validated. See
`validation/ppplayer-native-fork-release.log` and
`validation/ppplayer-native-fork-release-apk.log`.
Nothing has been published or pushed.

## Next work available here

1. Validate the local native Android fork on a physical ARM64 device, then decide
   how to host and version its source and native artifacts. Android 15/16 emulator
   source-switch and background tests now pass with the fork. Windows and WSLg
   source round trips pass. Exercise full catalog navigation
   and playlist switching in the isolated
   ppplayer preview on Windows, WSLg and Android. Its
   opt-in `PPPLAYER_CHROMIUM` playback facade maps online video IDs into Chromium,
   preserves local/playlist fallback and the existing network-output wrapper,
   and handles stale-track events and host pause intent. Native facade tests and
   full app debug/release builds pass; live PlayerScreen controls also pass.
   The preview is not a complete youtube_player_iframe or WebViewPlatform API.
2. Use the example's YouTube test page for speaker/picture and minimize/restore
   checks; test production origin, playlists/catalog and authenticated playback.
3. Decide whether ppplayer needs persistent/shared playback cookies; the initial
   autoplay-enabled contexts are private and ephemeral.
4. Repeat Android audio-only playback on a physical device, with screen-off,
   interruptions and longer background sessions. Emulator Home/media-command
   checks pass; visible-video removal, playlist fallback switching and physical
   audio/battery behavior remain adoption gates.

## Continue on the Mac

Run `bash scripts/validate_macos.sh` first. Resolve native compile/runtime
failures, then test AppKit focus/IME, audio, background playback, app media
commands, signing and notarization. Decide how this initial direct-distribution
backend fits ppplayer's existing App Sandbox requirement before adoption.

The existing WebKit controller remains in ppplayer throughout this work.
