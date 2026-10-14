#!/usr/bin/env bash
# Run in a disposable checkout; restore development overrides on all exits.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$root/docs/validation/public-dependencies"
mkdir -p "$logs"
exec > >(tee "$logs/checks.log") 2>&1
backup="$(mktemp -d)"
restore() {
  for package in packages/flutter_chromium_webview packages/flutter_chromium_webview/example; do
    name="${package//\//_}"
    if [[ -f "$backup/$name" ]]; then cp "$backup/$name" "$root/$package/pubspec_overrides.yaml"; fi
  done
}
trap restore EXIT
for package in packages/flutter_chromium_webview packages/flutter_chromium_webview/example; do
  name="${package//\//_}"
  if [[ -f "$root/$package/pubspec_overrides.yaml" ]]; then
    cp "$root/$package/pubspec_overrides.yaml" "$backup/$name"
    rm "$root/$package/pubspec_overrides.yaml"
  fi
  cd "$root/$package"
  flutter pub get
  python3 "$root/scripts/verify_hosted_interface.py" .dart_tool/package_config.json
  flutter analyze
  if [[ "$package" == */example ]]; then flutter test test; else flutter test; dart pub publish --dry-run; fi
  cp .dart_tool/package_config.json "$logs/$name-package-config.json"
done
