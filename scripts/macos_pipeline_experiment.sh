#!/usr/bin/env bash
# Diagnostic-only counterbalanced runs; never a replacement release gate.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${PIPELINE_EVIDENCE_DIR:-$root/docs/validation/macos-pipeline-experiment}"
mkdir -p "$out"
flutter --version > "$out/versions.txt"
xcodebuild -version >> "$out/versions.txt"
sw_vers >> "$out/versions.txt"
cd "$root/packages/flutter_chromium_webview/example"
flutter pub get
index=0
# Predetermined reverse ordering; no GC, forced restart, flags or hidden page.
# Each independent browser/test launch has normal shutdown, not a memory reset
# inside a repeated-session acceptance run.
for mode in cef-only native-only full control control full native-only cef-only; do
  index=$((index + 1))
  name="$(printf '%02d' "$index")-$mode"
  pipeline="$mode"
  enabled=true
  if [[ "$mode" == control ]]; then pipeline=full; enabled=false; fi
  PERFORMANCE_DIAGNOSTICS="$enabled" CEF_DIAGNOSTIC_PIPELINE="$pipeline" CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 \
  python3 "$root/scripts/macos_diagnostic_stage.py" --directory "$out" "$name" \
    env CEF_PROFILE_DEBUG_PORT=9229 flutter test integration_test/allocation_profile_test.dart -d macos --no-pub -v \
    --dart-define=ALLOCATION_PROFILE=true --dart-define=PROFILE_WORKLOAD=local-video \
    --dart-define=SOAK_SECONDS=60 --dart-define=SOAK_SAMPLE_SECONDS=10 \
    --dart-define=PROFILE_DISPOSAL_SECONDS=60 --dart-define=PIPELINE_MODE="$pipeline" \
    --dart-define=PERFORMANCE_DIAGNOSTICS="$enabled" --dart-define=SOAK_REPORT="$out/$name.json"
  python3 "$root/scripts/macos_performance_report.py" --report "$out/$name.json" --directory "$out/$name-summary"
done

python3 "$root/scripts/macos_pipeline_comparison.py" "$out"
