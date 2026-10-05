# flutter_chromium_webview_platform_interface

`flutter_chromium_webview_platform_interface` defines the common platform contract for [`flutter_chromium_webview`](https://pub.dev/packages/flutter_chromium_webview) and is generally not intended to be used directly by application developers.

If you want to embed a Chromium (CEF) web view in your Flutter app, depend on
[`flutter_chromium_webview`](https://pub.dev/packages/flutter_chromium_webview) instead.

## What it contains

- `ChromiumWebViewPlatform` – the abstract contract implemented by platform packages (initialize, create/dispose browser, load URL/HTML, reload, back/forward, JavaScript execution, resize, focus, pointer input, dialog/menu responses and a browser event stream).
- `MethodChannelChromiumWebView` – the default implementation, which talks to native code over the `flutter_chromium_webview` method channel.
- Shared models: `BrowserCreationParams`, `BrowserCreationResult`, `PointerInput`, `PointerInputType`, `BrowserEvent` and `ChromiumWebViewException`.

This package contains no platform-specific (CEF, GTK, Windows, macOS) code.

## Implementing a platform

```dart
class MyPlatform extends ChromiumWebViewPlatform {
  // Override the methods you support.
}

ChromiumWebViewPlatform.instance = MyPlatform();
```

Implementations must `extend` `ChromiumWebViewPlatform`; `implements` is rejected by token verification.
