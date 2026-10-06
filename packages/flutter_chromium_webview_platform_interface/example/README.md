# Platform interface example

This Flutter application demonstrates a backend that extends
`ChromiumWebViewPlatform`, registers itself, and emits browser events. It runs
entirely in memory: URLs are recorded, not fetched; profiles are recorded, not
persisted; no native browser or texture is created.

From this directory:

```sh
flutter pub get
flutter run -d chrome
```

Use **Create browser**, **Navigate to dart.dev**, and **Dispose browser** to
observe the lifecycle events. Creating another browser demonstrates distinct
browser identifiers. When the widget is removed, it closes its event stream and
restores the previous registered backend.

Verification:

```sh
flutter analyze
flutter test
flutter build web
```

For an actual Chromium WebView, use the
[`flutter_chromium_webview` example](https://github.com/devflier/flutter_chromium_webview/tree/main/packages/flutter_chromium_webview/example).
