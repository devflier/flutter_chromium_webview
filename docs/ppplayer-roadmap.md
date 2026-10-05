# ppplayer integration work

Windows and WSLg are available now. Native macOS validation waits for a Mac.
ppplayer's app repository has been inspected but has not been modified.

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

## Next work available here

1. Map the adapter into ppplayer's actual playback facade, preserving its native
   media commands and existing controls. The prototype is not a complete
   youtube_player_iframe or WebViewPlatform implementation.
2. Use the example's YouTube test page for speaker/picture and minimize/restore
   checks; test production origin, playlists/catalog and authenticated playback.
3. Decide whether ppplayer needs persistent/shared playback cookies; the initial
   autoplay-enabled contexts are private and ephemeral.

## Continue on the Mac

Run `bash scripts/validate_macos.sh` first. Resolve native compile/runtime
failures, then test AppKit focus/IME, audio, background playback, app media
commands, signing and notarization. Decide how this initial direct-distribution
backend fits ppplayer's existing App Sandbox requirement before adoption.

The existing WebKit controller remains in ppplayer throughout this work.
