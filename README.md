# Flutter Chromium WebView

Chromium Embedded Framework (CEF) WebView for Flutter desktop with off-screen rendering and Flutter texture integration.

## Overview

Unlike standard webview plugins that embed native OS webviews (like Edge WebView2 on Windows or WebKit on macOS), this plugin brings a fully bundled Chromium browser to your Flutter application via the [Chromium Embedded Framework (CEF)](https://bitbucket.org/chromiumembedded/cef).

It uses **off-screen rendering (OSR)**. The web content is rendered to an off-screen pixel buffer and displayed inside the Flutter widget tree using a Flutter Texture.

### Features
* **Seamless Integration**: Because it uses Flutter Texture, the WebView acts like a normal Flutter widget. It supports scrolling, transformations, and overlays.
* **Consistent Behavior**: The browser engine is identical across platforms, ensuring your web content renders and behaves exactly the same way regardless of the host OS.
* **Full Desktop Input**: Includes deep integration for keyboard and mouse events natively routed from Flutter to CEF.

## Current Project Status
**Status: `0.2.1`.**

**Linux (x64)** and **Windows (x64)** are supported.
macOS support is planned but not fully implemented/tested yet.

## Monorepo Layout

This repository is a monorepo containing multiple packages:

* packages/flutter_chromium_webview: The main plugin package that you depend on in your application.
* packages/flutter_chromium_webview_platform_interface: The common platform interface used to federate the plugin across different OS implementations.

## Architecture

The plugin architecture bridges Flutter and CEF natively:

1. **CEF Browser**: A headless browser instance processes HTML/JS/CSS.
2. **OnPaint (OSR)**: CEF calls its OnPaint callback with a raw pixel buffer.
3. **Pixel Buffer**: The native plugin code transforms the raw BGRA buffer to RGBA.
4. **Flutter Texture**: The buffer is loaded into a GPU texture registered with Flutter.
5. **ChromiumWebView Widget**: Displays the Texture and listens to Flutter pointer/keyboard events, forwarding them back to the CEF browser via native channels.

## Quick Start

Add the dependency to your pubspec.yaml:

`yaml
dependencies:
  flutter_chromium_webview: ^0.2.1
`

Initialize the global CEF runtime once before using the widget:

`dart
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ChromiumWebViewController.initialize(cachePath: '/path/to/cache');
  runApp(MyApp());
}
`

Use the ChromiumWebView widget in your app:

`dart
final controller = ChromiumWebViewController(initialUrl: 'https://flutter.dev');

@override
Widget build(BuildContext context) {
  return ChromiumWebView(
    controller: controller,
  );
}
`

## CEF Requirements

Since this plugin embeds Chromium, it requires downloading the CEF runtime. During the native build process (e.g., via CMake on Linux), the plugin automatically downloads the appropriate pre-compiled CEF binaries from Spotify's public CEF builds.

Users running the application will need the CEF shared libraries (e.g., libcef.so) bundled with the application executable. The build scripts handle packaging these libraries into your Flutter output bundle.

## Roadmap

* **v0.1.x**: Linux support.
* **v0.2.x**: Windows support.
* **v0.3.x**: macOS support.
* **v1.0.0**: Stable, multi-platform release.

## Contributing

We welcome pull requests! Since this relies heavily on native C++ and CEF, you will need a C++ toolchain configured for your platform (e.g., GCC/Clang on Linux, MSVC on Windows).

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on setting up the local development environment.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Note: The Chromium Embedded Framework (CEF) and Chromium itself are subject to their own respective licenses (primarily BSD). When distributing an application using this plugin, you must adhere to the CEF licensing requirements.

