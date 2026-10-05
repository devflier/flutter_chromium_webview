# ppplayer media package ownership

A focused maintained fork is the recommended starting point. The existing
pp_playback_engine already owns the app-facing playback API and source routing.
Keep that interface stable while taking ownership of the specific native fixes.

## Layers

- App facade: existing pp_playback_engine plus Chromium source routing.
- Flutter bridge: media_kit for commands/events; media_kit_video for surfaces.
- Native playback: packaged mpv/FFmpeg libraries and platform build pipelines.

Copying the Dart package alone does not address a native EGL context failure.
The current Android video dependency downloads native artifacts from
media-kit/libmpv-android-video-build v1.1.7. A native fix must reach those artifacts
and be verified on both ARM64 and x64 before adoption.

## First experiment

1. Preserve the existing API and isolate a dependency override in the preview.
2. Build a pinned Android native artifact with the relevant upstream EGL fallback.
3. Require three local-video/live-browser round trips on the Android 15 and 16
   emulators, plus a physical device; keep screen-off and system media checks.
4. Verify Windows/WSLg regression tests and add macOS/iOS verification on a Mac.
5. Publish under the project's namespace only after the build and runtime gates pass.

The upstream mpv EGL helper now retries context creation without optional context
flags when the first call fails. This is a candidate fix, not a confirmed diagnosis
of the bundled binary. Record the exact native version and reproduced failure
before selecting a patch or updated native revision.

The two earlier software-emulator runs crashed the Windows emulator process
(access violation 0xc0000005); they did not establish an app-level workaround.
That host failure is separate from the observed MediaKit EGL output failure.

## Current implementation work

A local native fork is now in `C:/Users/User/Projects/ppplayer_native_media` on
`codex/android-egl-fallback`, starting from upstream v1.1.7 commit
`fe8c3ac1a91c09aa6fb1deccbc833f1bafa54768`. Its private Flutter plugin preserves
the dependency name for local compatibility and disables pub publishing.
Pinned sources, tracked patches, verified artifacts and a build-only CI workflow
are included. The main ppplayer checkout remains unchanged.

The regression test compiles the actual pinned mpv context function. It reproduces
optional-flag rejection in the original and passes fallback, supported-driver,
terminal-failure and missing-config checks in the patched function. Both ARM64 and
x86_64 builds pass export, dependency and 16 KiB alignment checks. Complete Android
15 and Android 16 emulator tests now pass all three local-video/live-YouTube round
trips, screen-off progress and system media commands. Both logs show the new EGL
fallback. The installed debug APK's native hashes match our local emulator binary.
Physical ARM64 testing remains required. See `validation/ppplayer-native-fork-status.md`.

The preview's native startup watchdog now waits for real position progress past
the requested seek point. A playing acknowledgement alone no longer disables
startup failure detection. The 107 native-engine/app regression tests and changed
file analysis pass. A prepared seek position does not count as playback progress.
A fresh native-fork release APK now builds for ARM64/x86_64 and its bundled native
hashes match both local artifacts. The previous APK remains historical evidence.
Release playback and production signing remain unverified.

## Scope of a full replacement

A replacement would require ownership of platform audio/video output, decoding,
seeking, subtitles, device interruptions, media commands and native releases.
Retaining tested native libraries keeps the initial fork's scope manageable.

## Primary references

- MediaKit package split: https://github.com/media-kit/media-kit/blob/main/README.md
- Matching emulator issue: https://github.com/media-kit/media-kit/issues/1343
- Current upstream EGL fallback: https://github.com/mpv-player/mpv/blob/master/video/out/opengl/egl_helpers.c
- Native artifact release: https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7
