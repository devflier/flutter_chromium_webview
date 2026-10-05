# Android

Android uses the device's system Chromium WebView, rather than CEF. The same
controller handles navigation, HTML, JavaScript channels, user-agent settings
and YouTube playback. `ChromiumWebView` uses hybrid composition to retain native
WebView keyboard and accessibility behavior;
`browserId` identifies the browser and desktop texture IDs remain null.

## Requirements and setup

- Android API 24 or newer; compile SDK 36 and Java 17.
- AndroidX WebKit 1.16.0, downloaded through the host Gradle build.
- An updated WebView provider with `WEB_MESSAGE_LISTENER` and
  `DOCUMENT_START_SCRIPT` support for JavaScript channels. Private autoplay
  browsers additionally require `MULTI_PROFILE` support. Unsupported capabilities
  fail explicitly when creating the browser.
- Initialize the controller before creating browsers, as on desktop. Android
  uses WebView-managed storage; the desktop `cachePath` is not its storage path.
- Internet permission is supplied by the plugin manifest. HTTPS is the default.
  Local HTTP test fixtures require a debug-only cleartext policy; the example
  supplies one without enabling cleartext in the release manifest.

For unpublished Android support, use this checkout as a path dependency. The
published 0.2.1 release is the desktop package.

```powershell
./scripts/validate_android.ps1 -Device emulator-5554
# Release startup, native keyboard and JavaScript alert:
./scripts/smoke_android.ps1 -Device emulator-5554
# Optional external-service playback check:
./scripts/validate_android.ps1 -Device emulator-5554 -LiveYoutube
# Audio-only controller, without creating an Android view:
./scripts/validate_android.ps1 -Device emulator-5554 -HeadlessYoutube
```

The script runs analysis, Dart tests, emulator integration suites and a release
APK build. Start an emulator first, or pass the ID of a connected Android device.
Complete or dismiss any first-run keyboard/stylus setup screen before the release
smoke test. It checks actual native key events and does not fill the input with
JavaScript or accessibility setters.

## Storage and rendering

Default browsers use Android's shared persistent profile. Setting
`mediaPlaybackRequiresUserGesture: false` creates a separate named WebView
profile per browser. It is disk-backed. Deletion is attempted after browser
destruction and retried while the provider releases its references. Profiles
still held by the provider are cleaned on initialization after a process restart.
They are never reused for a new browser. This differs from
the desktop CEF in-memory autoplay context. It is not a guarantee of secure
erasure or persistence across sessions.

HTML is served as an immutable response only for the browser's matching
main-frame HTTP(S) request. Relative resources, iframe requests and fetches use
normal network loading. Explicit network navigation clears the synthetic HTML.
Channels accept exact allowed origins and main frames only, reject opaque
origins, and enforce the shared 64 KiB UTF-8 message limit.

Keep a controller alive while hiding its view by using `disposeController:
false`; dispose it when playback ends. Navigation and JavaScript continue after
view removal, but the system WebView can pause media when an attached view is
detached. The full `-LiveYoutube` probe currently fails this detach-progress
requirement on the emulator, even though foreground play/pause/seek/volume pass.
It remains a ppplayer adoption blocker rather than a passing background check.
The separate headless probe tests a browser which never has an attached view.
Detaching a Flutter widget is distinct
from backgrounding the Android application. Background audio, foreground
services, system media controls and process suspension require host integration.

## Current boundaries

Android owns native selection menus and input. The desktop `sendPointerInput`
API reports `UNSUPPORTED_FEATURE`; normal native touch remains available.
JavaScript alerts, confirmations and prompts use the controller's dialog API.
Fullscreen custom views and web camera/microphone permission prompts are not
implemented. New-window requests are intercepted; their target URL may be empty
when Android does not expose it. Downloads and file chooser integration are not
implemented. These boundaries should be checked against the host application's
requirements before release.

Test speaker output, keyboard/IME, visual rendering, background/foreground
transitions and production playback origins on a physical device before shipping.
