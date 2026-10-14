# flutter_chromium_webview example — 0.5.3

The example consumes the parent package through `path: ../`; keep that local
reference when running this checkout. Repository-only platform-interface paths
live in `pubspec_overrides.yaml`, excluded from the published package. The
published example resolves the released interface instead. A consumer application uses
`flutter_chromium_webview: ^0.5.3` instead. Use an SDK satisfying the parent
package's Dart >=3.13.0 and Flutter >=3.44.0 constraints.

```sh
cd packages/flutter_chromium_webview/example
flutter pub get
flutter run -d macos
```

Use `-d windows`, `-d linux`, or an Android device ID as appropriate. For a new
macOS application, follow the package's [Runner setup](../MACOS.md). The bundled
example already supplies that setup; CEF must still download/build on first use.

Open **YouTube test** and press Play after the video is cued. Exercise pause,
resume, seek, volume, reload, resize and hide/show. Check media-time progression
and sound separately; a visible frame does not prove audible output. Leaving
the page disposes its player. Live YouTube can reject playback on CI networks;
retain those failures rather than treating a successful build as playback proof.
See the [adapter guide](../../../docs/youtube-adapter.md) for host integration.

For the local browser example, try navigation, JavaScript, keyboard focus and
resizing. macOS renderer/GPU recovery recreates the document, so arbitrary page
state is not preserved. Ownership cleanup does not certify memory boundedness.

From the repository root, `bash scripts/validate_macos.sh core` runs native suites,
release build, texture ownership and packaged shutdown checks. The `memory`
category runs a loopback VP9 video for 300-second RSS/video telemetry, retaining
the strict RSS assertion; `live` separately exercises real YouTube. Logs and exit statuses are preserved even after independent
stage failures. This validation does not establish physical 8 GB support or an
approved whole-application memory budget.
