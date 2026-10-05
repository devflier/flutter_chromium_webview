# flutter_chromium_webview

A Chromium web view for Flutter on Windows, Linux and Android.

Windows and Linux bundle a pinned Chromium engine through
[CEF](https://bitbucket.org/chromiumembedded/cef). Android uses the installed
system Chromium WebView; its engine version follows the device's WebView updates.

Desktop pages use CEF **off-screen rendering (OSR)**. Each frame is
delivered to native code, copied into a pixel buffer and shown in Flutter
through a **Flutter `Texture`**. This lets the web view behave like any other
widget: it can be clipped, transformed, stacked and overlaid. Android renders
through a native Flutter platform view with native touch and keyboard input.

> Published desktop version: **`0.2.1`**. Android support is an unreleased change
> in this checkout; use a local path dependency until the next release.

## Platform support

| Platform | Status |
| --- | --- |
| Linux x64 | Supported, validated on Ubuntu / WSLg |
| Windows x64 | Supported, sandboxed CEF implementation |
| Android API 24+ | System Chromium WebView; see [Android requirements](ANDROID.md) |
| macOS | Not supported yet (work in progress in the repository) |
| iOS, Web | Not implemented |

## Installation

```yaml
dependencies:
  flutter_chromium_webview: ^0.2.1
```

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

Initialize the CEF runtime once, before creating any browser:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cache = await getApplicationSupportDirectory();
  await ChromiumWebViewController.initialize(cachePath: cache.path);
  runApp(const MyApp());
}
```

Then place a `ChromiumWebView` in your widget tree:

```dart
class _MyAppState extends State<MyApp> {
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

- macOS is not supported yet.
- Rendering uses the CPU (software compositing). GPU acceleration is disabled.
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
- **1.0.0** – stable multi-platform release.

## Contributing & license

See [CONTRIBUTING.md](https://github.com/devflier/flutter_chromium_webview/blob/main/CONTRIBUTING.md).
Released under the MIT license; CEF and Chromium are covered by their own
(BSD-style) licenses, which you must honor when distributing an app.
