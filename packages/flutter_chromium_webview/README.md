# flutter_chromium_webview

A high-performance Chromium web view plugin for Flutter on **Windows**, **macOS**, **Linux**, and **Android**.

Desktop platforms bundle a pinned Chromium engine through [CEF (Chromium Embedded Framework)](https://bitbucket.org/chromiumembedded/cef) with Off-Screen Rendering (OSR) directly into Flutter textures. Android integrates the system Chromium WebView using Flutter's hybrid composition platform view.

> **Target Release: `0.5.3`**  
> Companion platform interface: [`flutter_chromium_webview_platform_interface: ^0.1.6`](https://pub.dev/packages/flutter_chromium_webview_platform_interface)

---

## Table of Contents

- [Platform Support & Status](#platform-support--status)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
  - [SDK Requirements](#sdk-requirements)
  - [OS & Toolchain Requirements](#os--toolchain-requirements)
- [Installation & Setup](#installation--setup)
  - [macOS Configuration](#macos-configuration)
  - [Windows Configuration](#windows-configuration)
  - [Linux Configuration](#linux-configuration)
  - [Android Configuration](#android-configuration)
- [Quick Start](#quick-start)
- [Core Features & Usage](#core-features--usage)
  - [Lifecycle Management](#lifecycle-management)
  - [Navigation & HTML Loading](#navigation--html-loading)
  - [JavaScript Evaluation & Execution](#javascript-evaluation--execution)
  - [Two-Way JavaScript Bridge](#two-way-javascript-bridge)
  - [Cookies, Storage & Named Profiles](#cookies-storage--named-profiles)
  - [Multiple Simultaneous WebViews](#multiple-simultaneous-webviews)
  - [Input, Focus & Keyboard](#input-focus--keyboard)
  - [JavaScript Dialogs & Context Menus](#javascript-dialogs--context-menus)
  - [New Window Interception](#new-window-interception)
  - [YouTube & Video Playback Integration](#youtube--video-playback-integration)
  - [Crash Recovery & Fault Tolerance](#crash-recovery--fault-tolerance)
- [Troubleshooting & Known Limitations](#troubleshooting--known-limitations)
- [Packages in this Repository](#packages-in-this-repository)
- [Contributing & License](#contributing--license)

---

## Platform Support & Status

| Platform | Engine | Rendering Path | Status | Guide |
|---|---|---|---|---|
| **macOS 13+** | CEF 149 (Chromium 149) | Accelerated IOSurface via Metal | Supported (Apple Silicon `arm64` & Intel `x86_64`) | [MACOS.md](MACOS.md) |
| **Windows 10+** | CEF 149 (Chromium 149) | Software pixel buffer to Texture | Supported (`x64`, sandboxed bootstrap runner) | [WINDOWS.md](WINDOWS.md) |
| **Linux** | CEF 149 (Chromium 149) | Software pixel buffer to Texture | Supported (`x64`, X11 / XWayland via GTK3) | [LINUX.md](LINUX.md) |
| **Android (API 24+)** | System Chromium WebView | Native Platform View (Hybrid Composition) | Supported (ARM64, ARM32, x86_64) | [ANDROID.md](ANDROID.md) |
| **iOS** | WebKit (`WKWebView`) | Headless prototype | Source only; **not registered or supported** | [IOS.md](IOS.md) |
| **Web** | N/A | N/A | Not implemented | N/A |

---

## Architecture Overview

On desktop operating systems, `flutter_chromium_webview` uses **Off-Screen Rendering (OSR)**:
1. Chromium renders web contents completely off-screen in background helper processes.
2. Rendered frames are passed to native host callbacks:
   - On **macOS**, frames are delivered as hardware-accelerated **IOSurface** handles and bound to **Metal** textures.
   - On **Windows** and **Linux**, pixel buffers are copied into a retained frame buffer and registered with the Flutter Engine's texture registry.
3. The browser appears in your Flutter widget tree as a regular Flutter `Texture`. It can be seamlessly clipped (e.g. `ClipRRect`), transformed, stacked, animated, or overlaid with other Flutter widgets.
4. On **Android**, rendering uses Flutter's native platform view mechanism (Hybrid Composition), providing native Android touch handling, accessibility, and virtual keyboard interaction.

---

## Requirements

### SDK Requirements

- **Dart SDK**: `>=3.12.0 <4.0.0`
- **Flutter SDK**: `>=3.44.0`

The package is engineered to be compatible with Dart `>=3.12.0`, allowing applications using Flutter 3.44+ (such as PPPlayer) to consume the published package without version conflicts. CI strictly tests across Flutter 3.47.4 / Dart 3.13.3.

### OS & Toolchain Requirements

- **macOS**: macOS 13 (Ventura) or newer, Xcode 15+, CMake 3.19+, Python 3, CocoaPods.
- **Windows**: Windows 10/11 x64, Visual Studio 2022 (with C++ desktop development tools), CMake 3.19+.
- **Linux**: Linux x64 with GTK 3, Clang, CMake 3.19+, Ninja, pkg-config, X11 or XWayland, PulseAudio.
- **Android**: Android API 24+ (Android 7.0 Nougat), Android compile SDK 36, Java 17.

---

## Installation & Setup

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_chromium_webview: ^0.5.3
```

Because desktop platforms require native runtime bootstrapping, follow the platform-specific instructions below:

### macOS Configuration

macOS requires host embedding and runner configuration outside Apple's App Sandbox. For complete instructions, see [MACOS.md](MACOS.md).

1. In `pubspec.yaml`, disable Swift Package Manager for macOS:
   ```yaml
   flutter:
     config:
       enable-swift-package-manager: false
   ```
2. In `macos/Runner/Info.plist`, set `NSPrincipalClass` to `ChromiumWebViewApplication`.
3. In `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`, set `com.apple.security.app-sandbox` to `<false/>`.
4. Add the CEF preparation step to your `macos/Podfile` and the embedding script to your Xcode Runner build phase as detailed in [MACOS.md](MACOS.md).

### Windows Configuration

Windows uses CEF's sandboxed bootstrap executable runner. For complete instructions, see [WINDOWS.md](WINDOWS.md).

1. In `windows/runner/CMakeLists.txt`, change the runner target to a shared library (`add_library(${BINARY_NAME} SHARED ...)`).
2. In `windows/CMakeLists.txt`, add `chromium_webview_enable_sandbox(${BINARY_NAME})`.
3. In `windows/runner/main.cpp`, export `RunWinMain` as described in [WINDOWS.md](WINDOWS.md).

### Linux Configuration

Ensure system packages are installed:
```bash
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev pulseaudio
```
On first build, CMake automatically downloads and verifies the pinned CEF Linux distribution. See [LINUX.md](LINUX.md).

### Android Configuration

Ensure your `android/app/build.gradle` has `minSdkVersion 24` and Java 17 compatibility. Internet permission is included automatically by the plugin manifest. See [ANDROID.md](ANDROID.md).

---

## Quick Start

Initialize the CEF runtime once in `main()` before creating any browser:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize CEF runtime on desktop. On Android, this initializes the WebView provider.
  final cache = await getApplicationSupportDirectory();
  final initialized = await ChromiumWebViewController.initialize(
    cachePath: cache.path,
  );
  if (!initialized) {
    throw StateError('Failed to initialize Chromium runtime');
  }

  runApp(const MaterialApp(home: WebViewDemo()));
}

class WebViewDemo extends StatefulWidget {
  const WebViewDemo({super.key});

  @override
  State<WebViewDemo> createState() => _WebViewDemoState();
}

class _WebViewDemoState extends State<WebViewDemo> {
  final controller = ChromiumWebViewController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chromium WebView')),
      body: ChromiumWebView(
        controller: controller,
        initialUrl: 'https://flutter.dev',
      ),
    );
  }
}
```

---

## Core Features & Usage

### Lifecycle Management

By default, the `ChromiumWebView` widget automatically disposes its controller when removed from the widget tree. If you want to keep the controller alive while navigating between tabs or screens, pass `disposeController: false`:

```dart
ChromiumWebView(
  controller: controller,
  disposeController: false, // You manage disposal explicitly
  initialUrl: 'https://flutter.dev',
);
```

When you are done with the controller:
```dart
await controller.dispose();
```

### Navigation & HTML Loading

```dart
// Load an arbitrary URL
await controller.loadUrl('https://dart.dev');

// Load raw HTML with an explicit base URL for origin and relative assets
await controller.loadHtmlString(
  '<h1>Hello from Flutter!</h1><p>Running on Chromium.</p>',
  baseUrl: 'https://example.com/app/',
);

// Navigation controls
if (controller.canGoBack) await controller.goBack();
if (controller.canGoForward) await controller.goForward();
await controller.reload();
await controller.stopLoading();
```

The controller extends `ChangeNotifier`, notifying listeners on URL changes, title changes, and progress updates:

```dart
ListenableBuilder(
  listenable: controller,
  builder: (context, _) {
    return Text(controller.pageTitle ?? controller.currentUrl ?? 'Loading...');
  },
);
```

### JavaScript Evaluation & Execution

Execute fire-and-forget scripts or evaluate expressions and receive structured results:

```dart
// Fire-and-forget
await controller.executeJavaScript("console.log('Hello from Dart');");

// Evaluate expression with returned value
try {
  final result = await controller.evaluateJavaScript('document.title');
  print('Page title: $result');

  // Objects and arrays are returned as parsed JSON structures
  final dimensions = await controller.evaluateJavaScript('''
    ({
      width: window.innerWidth,
      height: window.innerHeight,
      userAgent: navigator.userAgent
    })
  ''');
  print('Window info: $dimensions');
} catch (e) {
  print('JavaScript execution error: $e');
}
```

### Two-Way JavaScript Bridge

Communicate securely from web content back to Flutter using origin-restricted `JavaScriptChannel`s:

```dart
final channel = JavaScriptChannel(
  name: 'FlutterBridge',
  allowedOrigins: {'https://flutter.dev', 'https://dart.dev'},
  onMessageReceived: (JavaScriptMessage msg) {
    print('Received message: ${msg.message}');
  },
);

final controller = ChromiumWebViewController(
  javaScriptChannels: [channel],
);
```

In the webpage JavaScript:
```javascript
// Send a message to Flutter
FlutterBridge.postMessage(JSON.stringify({ event: 'button_clicked', id: 42 }));
```

Messages are protected by strict origin allowlists and capped at a maximum of 64 KiB UTF-8 to prevent buffer exhaustion.

### Cookies, Storage & Named Profiles

Configure isolation, cookies, user-agent, and media gesture policies at controller construction:

```dart
final controller = ChromiumWebViewController(
  profileName: 'isolated_user_profile', // Dedicated storage partition
  userAgent: 'MyCustomApp/1.0 (Flutter Desktop)',
  mediaPlaybackRequiresUserGesture: false, // Enable autoplay
  backgroundColor: const Color(0xFF1E1E1E), // Dark canvas during navigation
);
```

- When `profileName` is omitted, the browser shares the global cache and cookie store.
- Setting `mediaPlaybackRequiresUserGesture: false` creates an ephemeral private context suitable for media playback without polluting persistent sessions.

### Multiple Simultaneous WebViews

You can run multiple independent WebView instances simultaneously. Each has its own texture, controller, and event dispatching:

```dart
Row(
  children: [
    Expanded(child: ChromiumWebView(controller: controllerA, initialUrl: 'https://flutter.dev')),
    const VerticalDivider(),
    Expanded(child: ChromiumWebView(controller: controllerB, initialUrl: 'https://dart.dev')),
  ],
)
```

### Input, Focus & Keyboard

- **Mouse / Pointer**: Coordinates, high-DPI device pixel ratios, scroll wheels, and multi-click counts (double-clicks, triple-clicks) are forwarded automatically to the native browser.
- **Keyboard & Shortcuts**: Key events, Cmd/Ctrl editing shortcuts (Copy, Cut, Paste, Select All), and IME composition are handled natively.

### JavaScript Dialogs & Context Menus

Customize the presentation of JavaScript dialogs (`alert`, `confirm`, `prompt`) and right-click context menus using Flutter UI:

```dart
controller.onJSDialog = (JSDialogRequest request) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(request.type.name.toUpperCase()),
      content: Text(request.message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
      ],
    ),
  );
  return JSDialogResponse(success: confirmed ?? false);
};

controller.onContextMenu = (List<ContextMenuItem> items) {
  // Render Flutter popup or context menu using the provided command IDs
};
```

### New Window Interception

Intercept `window.open` or target `_blank` links:

```dart
controller.onNewWindowRequested = (NewWindowRequest request) {
  print('Requested popup URL: ${request.url}');
  // Open in a new tab, dialog, or external browser
};
```

### YouTube & Video Playback Integration

For video playback, the plugin includes a dedicated `ChromiumYoutubePlayerController` that wraps YouTube's IFrame API with native telemetry, autoplay support, and state synchronization:

```dart
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';

final player = ChromiumYoutubePlayerController(
  documentUrl: 'https://example.com/player',
  readyTimeout: const Duration(seconds: 15),
);

// In your widget:
ChromiumWebView(
  controller: player.webViewController,
  disposeController: false,
);

// Control playback:
await player.loadVideoById('dQw4w9WgXcQ');
await player.play();
await player.pause();
await player.seekTo(Duration(seconds: 45));
```

Supported open video codecs: **VP8**, **VP9**, **AV1**, **Vorbis**, **Opus**. Standard CEF does not include proprietary codecs like H.264 or AAC.

### Crash Recovery & Fault Tolerance

If the Chromium renderer or GPU subprocess crashes, `flutter_chromium_webview` detects the failure and fires `onBrowserCrashed`:

```dart
controller.onBrowserCrashed = () {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Browser process crashed. Reloading...')),
  );
  controller.reload();
};
```

---

## Troubleshooting & Known Limitations

- **Proprietary Codecs**: Stock CEF builds distributed by the project do not include H.264 or AAC codecs due to patent and licensing restrictions. Media encoded with VP8, VP9, or AV1 is recommended.
- **Apple App Sandbox**: The macOS CEF backend currently requires direct distribution outside Apple's App Sandbox. See [MACOS.md](MACOS.md).
- **Process Shutdown**: Once CEF has shut down via `CefShutdown()`, CEF cannot be reinitialized in the same process without restarting the host application.
- **macOS Memory Bounds**: Extended validation confirms clean tracked resource disposal and zero surviving processes on shutdown. However, long-term leak freedom and physical 8 GB qualification remain open product items.
- **Application Bundle Size**: Bundling Chromium and CEF increases the application distribution size by approximately 100–130 MB.

---

## Packages in this Repository

- **[`flutter_chromium_webview`](https://pub.dev/packages/flutter_chromium_webview)**: The main Flutter plugin consumed by applications.
- **[`flutter_chromium_webview_platform_interface`](https://pub.dev/packages/flutter_chromium_webview_platform_interface)**: The platform interface and method channel contracts.

---

## Contributing & License

Contributions are welcome! Please review [CONTRIBUTING.md](https://github.com/devflier/flutter_chromium_webview/blob/main/CONTRIBUTING.md) and [docs/architecture.md](https://github.com/devflier/flutter_chromium_webview/blob/main/docs/architecture.md).

This project is licensed under the **MIT License**.  
Chromium and CEF are covered by their respective BSD-style licenses.
