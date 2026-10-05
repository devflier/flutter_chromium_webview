#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:?Usage: package_linux.sh /absolute/new/output-directory}"
[[ "$destination" = /* ]] || { echo 'Output directory must be absolute.' >&2; exit 1; }
[[ ! -e "$destination" ]] || { echo 'Output directory already exists; choose a new directory.' >&2; exit 1; }
cd "$root/packages/flutter_chromium_webview/example"
flutter pub get --enforce-lockfile
flutter build linux --release
mkdir -p "$destination"
cp -a build/linux/x64/release/bundle/. "$destination/"
cp "$root/LICENSE" "$destination/LICENSE.flutter_chromium_webview"
cp "$root/docs/security.md" "$destination/SECURITY.md"
cp "$root/docs/release-readiness.md" "$destination/RELEASE-STATUS.md"
test -x "$destination/lib/flutter_chromium_webview_subprocess"
test -s "$destination/lib/LICENSE.txt"
if ldd "$destination/flutter_chromium_webview_example" | grep -q 'not found'; then
  echo 'Missing runtime dependencies.' >&2; exit 1
fi
cd "$destination"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
printf 'Bundle created: %s\nLaunch with: %s/flutter_chromium_webview_example\n' "$destination" "$destination"
