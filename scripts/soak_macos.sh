#!/bin/bash
set -e
cd "$(dirname "$0")/../packages/flutter_chromium_webview"

echo "Running 30-minute (1800s) macOS allocation soak test..."
mkdir -p ../../docs/validation
CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 \
PROFILE_REPORT_PATH=../../docs/validation/allocation-profile-30m.json \
flutter test "example/integration_test/allocation_profile_test.dart" \
  -d macos \
  --dart-define=ALLOCATION_PROFILE=true \
  --dart-define=SOAK_SECONDS=1800

echo "30-minute soak test completed successfully. Report saved to docs/validation/allocation-profile-30m.json"
