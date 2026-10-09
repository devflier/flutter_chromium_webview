#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" = Darwin ]] || { echo 'macOS validation requires a Mac with Xcode.' >&2; exit 1; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/packages/flutter_chromium_webview"
export CHROMIUM_WEBVIEW_MACOS_ARCH="$(uname -m)"
command -v cmake >/dev/null
command -v pod >/dev/null
cd "$package"
python3 -m unittest discover -s macos/test -p 'test_*.py' -v
flutter pub get
flutter analyze
flutter test
cd example
flutter pub get
flutter analyze
flutter test test
for suite in plugin_integration_test input_scaling_test native_ui_test javascript_bridge_test html_loading_test browser_settings_test youtube_adapter_test; do
  flutter test "integration_test/$suite.dart" -d macos --no-pub
done
mkdir -p ../docs/validation
CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 PROFILE_REPORT_PATH=../docs/validation/allocation-profile.json flutter test "integration_test/allocation_profile_test.dart" -d macos --no-pub --dart-define=ALLOCATION_PROFILE=true --dart-define=SOAK_SECONDS=300
flutter build macos --release --no-pub

# Compile the texture ownership regression against genuine Apple/Flutter SDKs.
flutter_bin="$(command -v flutter)"
flutter_root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$flutter_bin")"
flutter_framework="$(find "$flutter_root/bin/cache/artifacts/engine" -type d -name FlutterMacOS.framework -print -quit)"
[[ -n "$flutter_framework" ]] || { echo 'Flutter macOS SDK framework not found' >&2; exit 1; }
mkdir -p build/macos/native-tests
xcrun clang++ -std=c++20 -fobjc-arc -mmacosx-version-min=13.0 \
  -F "$(dirname "$flutter_framework")" -framework Cocoa -framework CoreVideo \
  "$package/macos/test/texture_test.mm" "$package/macos/Classes/ChromiumTexture.mm" \
  -o build/macos/native-tests/texture_test
build/macos/native-tests/texture_test
python3 "$root/scripts/smoke_macos.py" "$PWD/build/macos/Build/Products/Release/flutter_chromium_webview_example.app"
