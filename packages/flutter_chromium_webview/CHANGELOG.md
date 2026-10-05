## Unreleased

* Add Android API 24+ support through the system Chromium WebView and a native Flutter platform view.
* Preserve browser identity when attaching a view without a desktop texture.
* Add emulator validation for browser lifecycle, origin-restricted channels, HTML and playback settings.
* Keep WSL validation in a separate Linux checkout to protect Windows build metadata.

## 0.2.1

* Fix Windows packaging, stabilize integration tests and update version status.

## 0.2.0

* Add Windows (x64) backend support.
* Provide full integration with CEF sandboxed runner for Windows.

## 0.1.1

* Fix platform interface class exports for pub release.

## 0.1.0

* Initial release.
* Chromium Embedded Framework web view for Flutter desktop using off-screen rendering and Flutter textures.
* Experimental Linux x64 support: navigation, JavaScript execution and channels, mouse and keyboard input, resizing, popups, dialogs and context menus.
* `ChromiumWebView` accepts an optional `initialUrl`.
* Talks to native code through `flutter_chromium_webview_platform_interface`.

