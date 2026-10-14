# flutter_chromium_webview

A Chromium web view for Flutter on Windows, macOS, Linux, and Android.

Windows, macOS, and Linux bundle a pinned Chromium engine through
[CEF](https://bitbucket.org/chromiumembedded/cef). Android uses the installed
system Chromium WebView; its engine version follows the device's WebView updates.
Headless WKWebView source is included for iOS, but the plugin is not registered
for iOS in this release and is not advertised as supported.

Desktop pages use CEF **off-screen rendering (OSR)** and a Flutter `Texture`.
macOS imports accelerated IOSurface frames through Metal; Windows and Linux
use the software pixel-buffer path. This lets the web view behave like any other
widget: it can be clipped, transformed, stacked and overlaid. Android renders
through a native Flutter platform view with native touch and keyboard input.

> Package version: **`0.5.3`**.

## Platform support

| Platform | Status |
| --- | --- |
| Linux x64 | Supported, validated on Ubuntu / WSLg |
| Windows x64 | Supported, sandboxed CEF implementation |
| macOS 13+ | Native CEF/Metal backend; see [setup and validation limits](MACOS.md) |
| Android API 24+ | System Chromium WebView; see [Android requirements](ANDROID.md) |
| iOS | Source only; not registered or validated for this release |
| Web | Not implemented |

## Installation

```yaml
dependencies:
  flutter_chromium_webview: ^0.5.3
```

### SDK requirements

The package requires Dart >=3.13.0 and Flutter >=3.44.0; both constraints must
be satisfied by the installed Flutter SDK. CI uses Flutter 3.47.4 / Dart 3.13.3.
Do not lower the SDK requirement to use the release on an older SDK.

### Requirements (macOS)

Use Xcode, CMake, Python 3 and CocoaPods. Configure the Runner application class,
CEF embedding/signing, native architecture and entitlements as described in
[MACOS.md](MACOS.md); adding the dependency alone is insufficient. The current
backend targets direct distribution outside Apple's App Sandbox. Swift Package
Manager and universal builds are not supported by the current setup.

### Requirements (Linux)

- Flutter with Linux desktop support enabled.
- A Linux x64 toolchain: Clang, CMake (3.19+), Ninja, `pkg-config`, GTK 3
  development files.
- Network access during the **first build**. The plugin does not ship CEF in
  the pub.dev package; its CMake build downloads a pinned, SHA-256 verified CEF
  `minimal` distribution (~100 MB) and builds the CEF wrapper library. Pre-download the
  archive and point the `CEF_TARBALL` CMake cache variable at it for offline
  builds.
- An X11 display (the plugin selects the X11 backend).

## Usage

Initialize the CEF runtime once, before creating any browser. For this complete
`lib/main.dart` example, add `path_provider` to your application with
`flutter pub add path_provider`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cache = await getApplicationSupportDirectory();
  final initialized = await ChromiumWebViewController.initialize(
    cachePath: cache.path,
  );
  if (!initialized) throw StateError('Chromium initialization failed');
  runApp(const BrowserApp());
}

class BrowserApp extends StatefulWidget {
  const BrowserApp({super.key});

  @override
  State<BrowserApp> createState() => _BrowserAppState();
}

class _BrowserAppState extends State<BrowserApp> {
  final controller = ChromiumWebViewController();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ChromiumWebView(
          controller: controller,
          initialUrl: 'https://flutter.dev',
        ),
      ),
    );
  }
}
```

The widget disposes its controller when removed from the tree. Pass
`disposeController: false` if you manage the controller's lifetime yourself.

The controller offers `loadRequest`, `loadHtmlString`, `reload`, `goBack`,
`goForward`, `executeJavaScript`, and exposes `currentUrl`, `pageTitle`,
`isLoading`, `canGoBack` and `canGoForward` (it is a `ChangeNotifier`). It also
supports origin-restricted JavaScript channels, new-window requests, JavaScript
dialogs and context menus that you render with Flutter widgets.

You never need to deal with CEF handlers, GTK, native textures or pixel buffers.

## Example

See [`example/`](example) for a small browser with back, forward, reload, an
address bar, a JavaScript execution button, and layout-driven resizing.

```sh
cd example
flutter run -d linux
```

## Limitations

- Windows/Linux use software compositing; macOS uses accelerated Metal rendering.
- macOS GPU/renderer recovery recreates the browser document. Applications must
  restore their own page state. Repeated GPU crashes can trigger Chromium's
  software fallback policy.
- macOS 8 GB support has not been verified on physical target hardware. Historical
  strict RSS memory acceptance remains failed; tracked resource cleanup and
  successful playback do not establish long-term memory boundedness. No numeric
  whole-application memory budget has been approved.
- Standard CEF builds have no proprietary codecs (for example H.264).
- Native drag and drop and IME candidate-window positioning are unfinished.
- Once CEF is shut down the process must be restarted to use it again.
- The binary size of an app grows by the size of Chromium.

## Packages

- [`flutter_chromium_webview`](https://pub.dev/packages/flutter_chromium_webview): this package.
- [`flutter_chromium_webview_platform_interface`](https://pub.dev/packages/flutter_chromium_webview_platform_interface):
  the shared platform contract. Not intended for direct use by applications.

## Roadmap

- **0.1.x** – stabilize Linux, improve tests and documentation.
- **0.2.x** – Windows backend.
- **0.3.x** – macOS backend.
- **Next Release** – SPM (Swift Package Manager) support for macOS.
- **1.0.0** – stable multi-platform release.

## Contributing & license

See [CONTRIBUTING.md](https://github.com/devflier/flutter_chromium_webview/blob/main/CONTRIBUTING.md).
Released under the MIT license; CEF and Chromium are covered by their own
(BSD-style) licenses, which you must honor when distributing an app.
