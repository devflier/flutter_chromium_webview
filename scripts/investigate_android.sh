#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/scripts/ensure_monorepo_overrides.py"
if [[ "${1:-android}" == android-html ]]; then
  cd "$root/packages/flutter_chromium_webview/example"
  flutter pub get
  python3 "$root/scripts/android_diagnostic_stage.py" --directory "$root/docs/validation/android-html" --device emulator-5554 flutter test integration_test/html_loading_test.dart -d emulator-5554 --no-pub -v
else
  pwsh -File "$root/scripts/validate_android.ps1" -Device emulator-5554
fi
