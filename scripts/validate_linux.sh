#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/packages/flutter_chromium_webview"
flutter pub get
flutter analyze
flutter test
cd example
flutter pub get
flutter analyze
flutter test test
# Use a fresh desktop log reader for each process, see validate_windows.ps1.
for suite in plugin_integration_test input_scaling_test native_ui_test javascript_bridge_test html_loading_test browser_settings_test youtube_adapter_test; do
  flutter test "integration_test/$suite.dart" -d linux --no-pub
done
flutter build linux --release --no-pub
