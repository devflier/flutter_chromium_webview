# macOS CEF backend — setup and validation limits

The backend targets macOS 13+ with separate Apple Silicon (`arm64`) and Intel
(`x86_64`) builds. It uses the shared Dart controller and texture widget.
Functional playback, tracked cleanup and GPU/Metal checks have passed tested
Apple Silicon workloads. Intel support is an implementation target, not a claim
that the memory investigation validated that architecture.

Proposed physical 8 GB support is **unverified**. Historical strict RSS acceptance
remains **FAIL**, exact allocator ownership is inconclusive, and long-term leak
freedom is not established. No approved whole-application memory ceilings exist.
Debug diagnostic results do not certify Release-mode memory usage. See
[validation history](../../docs/macos-native-validation.md).

## Native design

- CEF 149.0.4 / Chromium 149.0.7827.156 is pinned. Both distribution SHA-256
  checksums are pinned and every cached archive is verified before preparation.
- CocoaPods builds the C++ wrapper and helper through CMake. CEF is loaded
  dynamically, rather than linked into the application, as its sandbox requires.
- A versioned CEF framework and five helper app variants are embedded and signed
  inside the app. Helper sandbox initialization precedes CEF loading. No runtime
  sandbox-disabling fallback is provided.
- Accelerated CEF frames arrive through `OnAcceleratedPaint` and IOSurfaces;
  Metal delivers textures to Flutter. Native ownership retains surfaces/textures
  for in-flight frames and releases browser-owned resources on disposal.
- Renderer/GPU crashes use the existing browser-crash/recreation contract.
  Recovery creates a new document; restore application state explicitly.
  Repeated GPU crashes may trigger Chromium's software fallback policy.
- An AppKit text-input responder forwards keys, Cmd editing shortcuts and IME
  composition while its browser owns focus. Precise IME candidate placement and
  widget-to-screen offsets still need work and native validation.
- Browser disposal/session reset waits for CEF closure. Application Quit closes
  browsers, keeps pumping until closure, then runs CEF shutdown before Cocoa exit.

The loader/application/helper structure follows [CEF's macOS application example](https://github.com/chromiumembedded/cef/blob/master/tests/cefsimple/cefsimple_mac.mm)
and [sandbox documentation](https://chromiumembedded.github.io/cef/sandbox_setup).

## Host setup

Install Xcode (including its command-line tools), CMake, Python 3 and CocoaPods.
Use a native architecture build initially. Universal binaries and cross-architecture
CEF cache reuse are deliberately rejected; use separate checkouts for ARM/Intel.

1. Add the package dependency and opt this application into CocoaPods:

   ```yaml
   flutter:
     config:
       enable-swift-package-manager: false
   ```

2. Set `NSPrincipalClass` in `macos/Runner/Info.plist` to
   `ChromiumWebViewApplication`. Preserve the existing `FlutterAppDelegate` and
   window implementation. This class must be selected before `NSApplicationMain`;
   the plugin reports a setup error for a stock `NSApplication`.

3. Set the Runner deployment target to 13.0 and `ARCHS = $(NATIVE_ARCH_ACTUAL)`.
   Disable Xcode's build-script sandbox for this Runner so its embedding phase
   can read the downloaded CEF files. This is a build permission, separate from
   Chromium's runtime sandbox.

4. In the Podfile, after `flutter_install_all_macos_pods` has created plugin
   symlinks, prepare this development pod explicitly. CocoaPods does not run
   `prepare_command` for path/development pods:

   ```ruby
   cef_plugin = File.join(__dir__, 'Flutter/ephemeral/.symlinks/plugins/flutter_chromium_webview/macos')
   cef_arch = ENV.fetch('CHROMIUM_WEBVIEW_MACOS_ARCH') { `uname -m`.strip }
   raise 'CEF preparation failed' unless system('python3', File.join(cef_plugin, 'scripts/prepare_cef.py'), '--arch', cef_arch)
   ```

   In the existing `post_install`, after Flutter's additional build settings,
   set each pod configuration's `ARCHS` to `cef_arch`. See the example Podfile.

5. Add this command to a Runner build phase **after Flutter embedding**, before
   final application signing:

   ```sh
   python3 "$PROJECT_DIR/Flutter/ephemeral/.symlinks/plugins/flutter_chromium_webview/macos/scripts/embed_cef.py"
   ```

6. **Disable App Sandbox**: This initial backend targets **direct distribution**, outside Apple's App
   Sandbox. The `embed_cef.py` script intentionally halts the build if it detects that Apple's "App Sandbox" is enabled. 
   This happens because `flutter_chromium_webview` uses its own robust Chromium sandbox architecture, and running it inside Apple's App Sandbox requires very specific entitlements and configuration that this CEF backend doesn't automatically manage yet.
   
   To fix this, update both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements` to change:
   `<key>com.apple.security.app-sandbox</key>` to `<false/>`.

Run on a Mac from the repository root:

```sh
bash scripts/validate_macos.sh core    # deterministic native, ownership, release/shutdown
bash scripts/validate_macos.sh memory  # local VP9 video, 300s RSS and completeness
bash scripts/validate_macos.sh live    # independently reported real YouTube
```

This runs package/example analysis and tests, lifecycle/scaling/native-UI
integration suites, a release build, a native pixel-buffer ownership regression,
and copied-bundle startup/normal Quit validation. Logs are written to
`docs/validation`. The unified GitHub Actions workflow runs the same script on manual dispatch and
version tags. The redesigned workflow validates deterministic macOS core and memory jobs on
plugin PR/main/tag runs. Real YouTube is explicitly invoked independently. Check the actual job and
all stage results before claiming validation; build success alone is insufficient.

## Historical ppplayer integration planning

The following records earlier compatibility planning, not current release
verification of ppplayer. See the validation history above for later plugin tests.


ppplayer was inspected at commit
[`93c4af5`](https://github.com/ppplayer-labs/app/tree/93c4af527b238d237c2da3b9fab4d639f84177a9).
Its patched [YouTube controller](https://github.com/ppplayer-labs/app/blob/93c4af527b238d237c2da3b9fab4d639f84177a9/lib/core/playback/packages/youtube_player_iframe_macos_patch/package/lib/src/controller/youtube_player_controller.dart)
uses `webview_flutter`, JavaScript message channels, HTML/base-origin loading,
custom user-agent configuration, and media playback without a user gesture.
Its [release entitlements](https://github.com/ppplayer-labs/app/blob/93c4af527b238d237c2da3b9fab4d639f84177a9/macos/Runner/Release.entitlements)
currently enable Apple's App Sandbox.

This package is **not a drop-in replacement for that controller**. The optional
YouTube adapter and its fixture/live playback probes pass on Windows/WSLg;
see [the adapter guide](../../docs/youtube-adapter.md). macOS adoption still
requires a native Mac build/runtime pass. Remaining work includes:

1. Native validation of browser-specific user-agent and playback settings,
   implemented and tested on Windows/WSLg. Autoplay-enabled browsers currently
   use private in-memory contexts; decide ppplayer's storage requirements.
   HTML loading with an explicit HTTP(S) document URL/origin is now implemented
   and tested on Windows/WSLg; verify its native macOS behavior too.
   Browser-scoped JavaScript string channels with exact origin allowlists are
   now implemented and tested on Windows/WSLg. Validate the same bridge on macOS.
2. Connect the initial adapter's ready/state/error contract, host play/pause
   intent, seek, volume, reload and disposal to ppplayer's playback facade.
   Playlists, fullscreen and native app media command integration remain pending.
3. Embedded YouTube/audio/video checks with the stock CEF distribution, including
   actual sound output, codecs, background playback, seek and app media commands.
   No proprietary codec or DRM support is promised by this implementation.
   Windows/WSLg live tests verify playback progression, pause, seek, volume and
   playback after removing the Flutter video widget; physical output and native
   macOS behavior remain unverified.
4. A distribution decision compatible with ppplayer's signing, notarization and
   Apple App Sandbox requirements, before replacing its existing WebKit backend.

ppplayer's repository was read for compatibility planning; no app files, playback
dependencies or release settings were modified.

## Hosts with native media controls

Chromium publishes system media controls by default. If your app owns
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, set
`CEF_SYSTEM_MEDIA_CONTROLS=0` in the app process before the first
`ChromiumWebViewController.initialize` call. The host inherits this environment
variable and disables Chromium's system media session and hardware media-key
handling before CEF starts. This prevents duplicate Now Playing entries from
embedded players, including cross-origin iframes. Audio/video playback remains available. Restart the app after changing
this setting.

For a Swift macOS runner, call `setenv("CEF_SYSTEM_MEDIA_CONTROLS", "0", 1)`
in `applicationDidFinishLaunching` before starting playback.
