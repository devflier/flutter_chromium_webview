# Flutter Chromium WebView

Chromium webview for Flutter using CEF on Windows, macOS and Linux, the system
WebView on Android. Headless WKWebView source exists for iOS but is not registered
in this release. Web is not implemented.

## Version 0.5.3

This patch includes macOS host embedding, renderer/GPU crash recovery and native
validation diagnostics, plus Android startup/crash diagnostics. It does not
include the uncommitted allocator/Metal experiments from memory investigations.

```yaml
dependencies:
  flutter_chromium_webview: ^0.5.3
```

See the [package README](packages/flutter_chromium_webview/README.md) for SDK
requirements and a complete `lib/main.dart` example. macOS needs additional
[Runner configuration](packages/flutter_chromium_webview/MACOS.md). The desktop
runtime uses off-screen rendering and Flutter textures: accelerated IOSurface /
Metal on macOS, software pixel buffers on Windows/Linux.

## Run the example

From `packages/flutter_chromium_webview/example`:

```sh
flutter pub get
flutter run -d macos
```

Use `-d windows`, `-d linux` or an Android device identifier for other platforms.
Read the [example guide](packages/flutter_chromium_webview/example/README.md) for
browser, YouTube and recovery checks. Live YouTube availability depends on the
network and YouTube's authentication policy.

## Validation limits

Functional playback, tracked cleanup and GPU/Metal checks have passed tested
macOS workloads. Proposed physical 8 GB support remains unverified, historical
strict RSS acceptance remains failed, and long-term leak freedom is not
established. Debug measurements are not Release memory certification. See
[release readiness](docs/release-readiness.md) and
[macOS validation](docs/macos-native-validation.md).

The unified workflow validates Dart, Linux, Windows and Android on normal main
pushes. macOS runs on manual dispatch and version tags; a green ordinary push
alone does not establish a macOS pass. Publishing requires all configured jobs.

## Repository and contribution

- `packages/flutter_chromium_webview`: application dependency.
- `packages/flutter_chromium_webview_platform_interface`: shared platform contract.

See [CONTRIBUTING.md](CONTRIBUTING.md), [architecture](docs/architecture.md),
[publishing](docs/publishing.md), and [LICENSE](LICENSE). CEF and Chromium's own
licenses also apply when distributing the bundled runtime.
