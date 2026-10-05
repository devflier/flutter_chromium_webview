# Native Android fork validation

Date: 2026-10-05

The local fork is `C:/Users/User/Projects/ppplayer_native_media`, branch
`codex/android-egl-fallback`, based on upstream native-build v1.1.7 commit
`fe8c3ac1a91c09aa6fb1deccbc833f1bafa54768`. The isolated
`ppplayer_chromium_preview` uses its private dependency override. The main
`ppplayermusic/app` checkout and its pre-existing changes are preserved.

The patch retries failed GLES context creation without optional context flags.
The existing MediaKit Dart API and exact upstream JNI helper remain in use.
The ARM64 build also needs the compiler-attribute backport from
[Mbed TLS PR 7878](https://github.com/Mbed-TLS/mbedtls/pull/7878).
Gradle requires verified local JARs and a matching source lock.

| Check | Result | Evidence |
| --- | --- | --- |
| Actual pinned mpv function C regression | PASS; original reproduces flag rejection | [Function test](ppplayer-native-fork-egl-function.log) |
| ARM64 and x86_64 native builds/packages | PASS; required exports, system dependencies and 16 KiB alignment checked | Fork `sources.lock.json` and `artifacts/manifest.json` |
| App playback regressions with override | PASS, 107 tests | [Regression log](ppplayer-native-fork-regression.log) |
| Changed-file analysis | PASS | [Analysis](ppplayer-native-fork-analysis.log) |
| Installed debug APK native provenance | PASS, x86_64 binary hashes match | [APK check](ppplayer-native-fork-debug-apk.log) |
| Android 15/API 35 full live test | PASS, three source round trips and six background/media phases | [API 35](ppplayer-native-fork-api35.log) |
| Android 16/API 36 full live test | PASS, same checks on a 16 KiB-page system | [API 36](ppplayer-native-fork-api36.log) |
| Android service cleanup | PASS, no ppplayer services remain after test | [Services](ppplayer-native-fork-api36-services.log) |
| ARM64/x86_64 release APK build | PASS, 90.9 MB | [Release build](ppplayer-native-fork-release.log) |
| Release APK native provenance | PASS, both architectures match local artifact hashes | [Release APK check](ppplayer-native-fork-release-apk.log) |
| Release install/entry-point smoke | PASS; MediaKit initializes and app remains alive at first-run notification permission request | [Install/launch](ppplayer-native-fork-release-smoke.log), [Runtime](ppplayer-native-fork-release-runtime.log) |

Both live test logs show `Retrying GLES context without optional flags.` The
previous second-source stall no longer reproduces in these runs. Each run includes
20 seconds of confirmed non-interactive screen-off progress, system pause/play,
activity restoration, browser disposal and three local-video/live-YouTube switches.

Physical ARM64 playback, audible speaker output, visual quality, catalog navigation,
production signing and release-mode playback are not established by these tests.
macOS/iOS testing waits for a Mac. Desktop native packaging still uses upstream
MediaKit dependencies. The separate Chromium visible-view detach failure remains.
The existing `lavf: Failed to create file cache` diagnostic appears in both the
upstream baseline and these passing runs; disk-cache configuration needs a separate
follow-up. No GitHub CI run, push or publication was performed.
