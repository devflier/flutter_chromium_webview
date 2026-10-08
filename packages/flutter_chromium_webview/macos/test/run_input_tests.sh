#!/bin/bash
set -euo pipefail
MACOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/cef-input-tests.XXXXXX)"
clang++ -std=c++20 -fobjc-arc -framework Foundation "$MACOS/test/input_client_test.mm" "$MACOS/Classes/ChromiumIpcClient.mm" "$MACOS/Classes/Protocol.mm" -o "$OUT/input-client-test"
"$OUT/input-client-test"
clang++ -std=c++20 -fobjc-arc -framework Cocoa "$MACOS/test/input_test.mm" "$MACOS/Classes/ChromiumInput.mm" "$MACOS/Classes/ChromiumIpcClient.mm" "$MACOS/Classes/Protocol.mm" -o "$OUT/input-native-test"
"$OUT/input-native-test"
python3 "$MACOS/Host/input_smoke.py" --host "${1:-$MACOS/Host/ChromiumWebViewHost.app/Contents/MacOS/ChromiumWebViewHost}"
