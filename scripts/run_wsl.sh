#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root/packages/flutter_chromium_webview/example"

if [[ "${1:-}" != "--no-build" ]]; then
  flutter build linux --release
fi

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export GDK_BACKEND=x11
exec ./build/linux/x64/release/bundle/flutter_chromium_webview_example
