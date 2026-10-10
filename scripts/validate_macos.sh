#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" = Darwin ]] || { echo 'macOS validation requires a Mac with Xcode.' >&2; exit 1; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/packages/flutter_chromium_webview"
diagnostics="$root/docs/validation/macos"
mkdir -p "$diagnostics"
export CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1
{
  flutter --version
  dart --version
  sw_vers
  xcodebuild -version
  xcrun --show-sdk-version
} > "$diagnostics/versions.txt" 2>&1
source "$root/scripts/macos_validation_stages.sh"
export CHROMIUM_WEBVIEW_MACOS_ARCH="$(uname -m)"
command -v cmake >/dev/null
command -v pod >/dev/null
cd "$package"
run_stage diagnostic-wrapper-tests python3 -m unittest discover -s "$root/scripts" -p test_macos_diagnostics.py -v
run_stage packaging-tests python3 -m unittest discover -s macos/test -p 'test_*.py' -v
flutter pub get
run_stage package-analysis flutter analyze
run_stage package-tests flutter test
cd example
flutter pub get
run_stage example-analysis flutter analyze
run_stage example-tests flutter test test
for suite in plugin_integration_test input_scaling_test native_ui_test javascript_bridge_test html_loading_test browser_settings_test youtube_adapter_test evaluate_javascript_test host_crash_test; do
  run_stage "$suite" flutter test "integration_test/$suite.dart" -d macos --no-pub -v
done
run_stage youtube-live flutter test integration_test/youtube_live_test.dart -d macos --no-pub -v --dart-define=YOUTUBE_LIVE=true --dart-define="YOUTUBE_REPORT=$diagnostics/youtube-live.json"
run_stage resource-stability flutter test integration_test/resource_stability_test.dart -d macos --no-pub -v --dart-define=RESOURCE_DWELL_SECONDS=0
run_stage allocation-profile env CEF_PROFILE_DEBUG_PORT=9229 flutter test "integration_test/allocation_profile_test.dart" -d macos --no-pub -v --dart-define=ALLOCATION_PROFILE=true --dart-define=SOAK_SECONDS=300 --dart-define="SOAK_REPORT=$diagnostics/allocation-profile.json"
run_stage release-build flutter build macos --release --no-pub

# Compile the texture ownership regression against genuine Apple/Flutter SDKs.
flutter_bin="$(command -v flutter)"
flutter_root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$flutter_bin")"
flutter_framework="$(find "$flutter_root/bin/cache/artifacts/engine" -type d -name FlutterMacOS.framework -print -quit)"
[[ -n "$flutter_framework" ]] || { echo 'Flutter macOS SDK framework not found' >&2; exit 1; }
mkdir -p build/macos/native-tests
run_stage texture-build xcrun clang++ -DDEBUG=1 -std=c++20 -fobjc-arc -mmacosx-version-min=13.0 \
  -F "$(dirname "$flutter_framework")" -framework Cocoa -framework CoreVideo -framework IOSurface \
  "$package/macos/test/texture_test.mm" "$package/macos/Classes/ChromiumTexture.mm" \
  -o build/macos/native-tests/texture_test
run_stage texture-ownership build/macos/native-tests/texture_test
run_stage packaged-smoke python3 "$root/scripts/smoke_macos.py" "$PWD/build/macos/Build/Products/Release/flutter_chromium_webview_example.app"
finish_stage_validation
