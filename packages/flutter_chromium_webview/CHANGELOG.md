## 0.5.5

* Allow macOS hosts with native media controls to disable Chromium's duplicate system media session with `CEF_SYSTEM_MEDIA_CONTROLS=0`.
* Find Homebrew and CMake.app installations when building from Xcode's restricted PATH; clarify missing CMake errors.
* Mark CEF preparation as intentionally running on every build.
* Support host-coordinated YouTube crash recovery and expose video playback quality diagnostics.
* Preserve Android autoplay media playback when its Activity is minimized.
* Bound the Metal texture cache to one source and three destinations, clean it up on resize/disposal, and drain paint autorelease pools.
* Allow macOS termination to finish after Flutter's asynchronous exit response.

## 0.5.4

* Add configurable `keychainBehavior` parameter (`ChromiumKeychainBehavior.mock` vs `.system`) to `ChromiumWebViewController.initialize`.
* Default to mock keychain on macOS to prevent unnecessary login keychain access prompts.
* Support `CEF_KEYCHAIN_BEHAVIOR` environment variable override (`mock` or `system`).
* Require `flutter_chromium_webview_platform_interface` ^0.1.7.

## 0.5.3

* Separate deterministic macOS core/local media RSS validation from explicitly invoked live YouTube reporting; preserve strict memory assertions and external blocked verdicts.
* Gate platform-interface publication on its API/example checks and consumer compatibility, independently of native/live services.

* Require platform interface 0.1.6, which publishes the JavaScript evaluation/cancellation, click-count and browser-crash APIs used by this plugin.

* Fix macOS Chromium host embedding and preserve native startup/failure diagnostics.
* Recover macOS browsers after renderer or GPU-process crashes through the existing browser recreation contract; arbitrary page state is not preserved.
* Improve macOS playback telemetry and independent validation-stage reporting.
* Preserve Android integration startup and crash diagnostics.
* Refresh installation, runnable examples, macOS setup and release documentation; correct the iOS support claim because the release pubspec does not register that backend.
* Exclude monorepo dependency overrides from publication and keep the bundled example's published dependency resolution independent of sibling checkouts.
* Document remaining macOS memory limits: proposed 8 GB support is unverified, historical strict RSS acceptance remains failed, and long-term memory boundedness is not established. No allocator fix or relaxed memory threshold is included.

## 0.5.2

* Fix JavaScript mocked player properties in integration test.
* Prevent git tracking of temporary and machine-specific profiling artifacts.

## 0.5.1

* Complete public API documentation audit. Documented all public classes, methods, and fields.
* Resolve analyzer warnings and info-level lints.
* Exclude large binary artifacts from publication to comply with package size limits.

## 0.5.0

* Add macOS CEF and YouTube playlist support.
* Fix macOS architecture configuration and linking issues.
* Require the latest platform interface version.


## 0.3.1

* Correct Linux pointer coordinates at fractional and high device pixel ratios.
* Require the platform interface version that includes named browser profiles.
* Fix automated publication authentication and validate release tag versions.

## 0.3.0

* Add macOS support using native CEF framework.
* Add iOS support using a headless WKWebView implementation.
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

