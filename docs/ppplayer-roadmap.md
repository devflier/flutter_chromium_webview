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
The preview now has 43 passing playback/media-command regression tests and clean
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

## Next work available here

1. Exercise full catalog navigation and source/playlist switching in the isolated
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
