# iOS Implementation Status — Source Only

This document describes the status of the iOS implementation in `flutter_chromium_webview`.

## Current Status: Unregistered Prototype (Source Only)

> [!WARNING]
> **iOS is NOT an advertised or supported platform in release `0.5.3`.**
> 
> The iOS codebase located in `packages/flutter_chromium_webview/ios/` is a preliminary, headless prototype. It is **not registered** in `pubspec.yaml` under `flutter.plugin.platforms`.

## Why iOS Differs from Desktop (CEF)

Chromium Embedded Framework (CEF) is designed for desktop operating systems (Windows, macOS, Linux). It cannot run on iOS because:
1. **Apple App Store Review Guidelines** (Guideline 2.5.2) restrict executable code generation (JIT) and require all web browsers to use the system WebKit framework.
2. **Architecture**: CEF relies on multi-process architectures, Mach ports, and helper executables that are incompatible with iOS sandbox restrictions.

Consequently, any webview implementation on iOS must be based on Apple's **`WKWebView`** (WebKit).

## What the iOS Source Code Contains

The repository contains an exploratory headless WKWebView implementation:
- `ios/flutter_chromium_webview/Sources/flutter_chromium_webview/FlutterChromiumWebviewPlugin.swift`: A Swift plugin providing headless webview management, JavaScript execution, and message channel handling via `WKWebView`.
- `ios/flutter_chromium_webview.podspec`: Podspec configuration for the prototype.
- `PrivacyInfo.xcprivacy`: Apple privacy manifest template.

## Limitations and Incomplete Functionality

The current iOS prototype has significant limitations:
- **No Visual Rendering**: It does not implement visual rendering into Flutter textures or hybrid composition platform views.
- **Unregistered**: Because it is omitted from `pubspec.yaml`, the Flutter build system will not register or compile the iOS plugin when building an iOS application.
- **No Test Coverage**: The prototype is not validated by CI and does not undergo regression testing.
- **Engine Differences**: WebKit JavaScript semantics, cookie isolation, and event lifecycles differ substantially from Chromium/CEF.

## Recommendation

For production applications requiring an iOS web view, use Flutter's official [`webview_flutter`](https://pub.dev/packages/webview_flutter) package (which wraps `WKWebView` on iOS) alongside `flutter_chromium_webview` for your desktop and Android targets.
