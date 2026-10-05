# YouTube adapter for ppplayer

The optional `chromium_youtube_player.dart` library implements the first playback
adapter against ppplayer's patched YouTube controller contract, inspected at
app commit `93c4af527b238d237c2da3b9fab4d639f84177a9`. ppplayer itself has not been
modified. This is a controller prototype, not a replacement WebViewPlatform or
the complete youtube_player_iframe API.

## Host integration

```dart
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

await ChromiumWebViewController.initialize(cachePath: appCachePath);
final player = ChromiumYoutubePlayerController(
  documentUrl: playerDocumentUrl,
);
final subscription = player.events.listen(handlePlayerEvent);
await player.initialize();
await player.cueVideoById(videoId: 'M7lc1UVf-VE');

// Render in the widget tree. The adapter owns the native browser.
ChromiumWebView(controller: player.webViewController, disposeController: false);

// On host shutdown:
await subscription.cancel();
await player.dispose();
```

Choose an HTTP(S) player document URL controlled by the host. The HTML loader
supplies this URL's document origin and ordinary browser referrer; the adapter
passes the origin to YouTube and does not override request headers. A loopback
HTTP document is used by the tests. Confirm production client identification
with the actual ppplayer document URL before adoption. YouTube documents error
153 for missing referrer/client identification in its
[IFrame API reference](https://developers.google.com/youtube/iframe_api_reference).

Autoplay is enabled in a fresh private CEF context. Cookies/storage are neither
shared nor persisted. No custom user-agent is needed for the live tests; a host
can supply one through the constructor when necessary.

## Supported contract

- Initialization, load/cue by video ID, play/pause, seek, volume, current time,
  duration and video metadata.
- `Ready`, `StateChange`, `PlayerError`, `VideoState` (JSON string), playback
  quality/rate, autoplay-blocked and API-change events with `playerId`.
- Ordered commands, bounded readiness/command waits and a 128-command queue
  limit. Command completion acknowledges SDK dispatch; observe state/progress
  events to establish actual playback.
- Reload rebuilds the player and restores the last reported position, selected
  video, end time, volume and host play/pause intent. Position is not a precisely
  synchronized bookmark. Prior-document events and responses are discarded.
- Idempotent close/disposal rejects pending operations. After failed initialization,
  dispose and construct a fresh controller.

The generated page loads the official YouTube SDK. Commands use a fixed method
allowlist and JSON arguments, with correlated responses over the existing
origin-restricted main-frame channel. There is no incoming message-to-eval path.
`MediaCapabilities` is an additional diagnostic event, and `ApiLoadError` reports
SDK script loading failure. Codec advertisements are not proof of decoding a
particular stream. `iframeApiUrl` is a fixture hook marked visibleForTesting.

Playlists, fullscreen/UI parity, mute/rate controls, ppplayer's native media
commands and app background lifecycle have not been ported. Host intent records
commands submitted through this adapter; iframe controls can independently change
observed player state. Use the event stream for observed playback.

## Reproduce

Run from `packages/flutter_chromium_webview/example`:

```powershell
flutter test integration_test/youtube_adapter_test.dart -d windows --no-pub
flutter test integration_test/youtube_live_test.dart -d windows --no-pub --dart-define=YOUTUBE_LIVE=true --dart-define=YOUTUBE_REPORT=C:/absolute/path/youtube-report.json
```

In WSL, use the Linux Flutter SDK, a checkout on the Linux filesystem and WSLg:

```bash
export PATH=/home/user/development/flutter/bin:$PATH
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11
flutter test integration_test/youtube_adapter_test.dart -d linux --no-pub
flutter test integration_test/youtube_live_test.dart -d linux --no-pub --dart-define=YOUTUBE_LIVE=true --dart-define=YOUTUBE_REPORT=/absolute/path/youtube-report.json
```

The fixture suite is included in desktop validation scripts. The live probe is
opt-in, requires external YouTube access and writes a report even on failure.
Its absence from offline CI is explicit; no skipped live test is counted as a
successful playback check. Native macOS execution remains pending.

For manual picture, speaker output and minimize/restore checks, run the example
with `flutter run -d windows` (or `-d linux` / `-d macos`), open **YouTube test**
and press **Play**. The page also provides video ID, pause, seek, volume, reload
and hide/show controls. It closes the player when leaving the page.

## Results — 2026-10-05

Windows and WSLg software-graphics runs both passed the fixture suite and live
YouTube probe with the stock CEF 149 build and default user-agent. Reports:
[Windows](validation/windows-youtube-live.json) and
[WSLg](validation/linux-youtube-live.json). Both reached playing state and
advanced beyond two seconds without a player error, paused with a zero position
delta over one second, sought to 10 seconds and reported volume 35. With the
Flutter video widget removed, playback advanced another 2.15 seconds on Windows
and 2.33 seconds on WSLg while retaining its browser controller. Metadata reported
the expected Google for Developers video and a duration of 1343.661 seconds.

Both advertised VP9, AV1 and Opus as `probably` playable and H.264/AAC as
unavailable. These advertisements do not identify the selected stream codecs.
The probe establishes service playback and controller behavior; it does not
establish audible device output, visual quality, minimized-window behavior,
sleep/resume or macOS background playback. No production ppplayer origin,
authenticated session, playlist or broader video catalog was tested.
