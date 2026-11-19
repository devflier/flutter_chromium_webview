#!/usr/bin/env bash
# Verifies that the Linux release example neither spins the main thread while
# idle nor hangs, logs unhandled Dart exceptions, or leaves orphan CEF
# subprocesses on window close.
# Usage: check_linux_idle_cpu.sh [bundle_dir]
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:-$root/packages/flutter_chromium_webview/example/build/linux/x64/release/bundle}"
max_cpu="${MAX_IDLE_CPU_PERCENT:-25}"
warmup_s="${WARMUP_SECONDS:-12}"
sample_s="${SAMPLE_SECONDS:-8}"

if [[ ! -x "$bundle/flutter_chromium_webview_example" ]]; then
  echo "FAIL: example binary not found at $bundle/flutter_chromium_webview_example" >&2
  exit 1
fi

log="$(mktemp)"
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

GDK_BACKEND=x11 "$bundle/flutter_chromium_webview_example" >"$log" 2>&1 &
pid=$!
sleep "$warmup_s"

if ! kill -0 "$pid" 2>/dev/null; then
  echo "FAIL: example process exited prematurely during warmup" >&2
  cat "$log" >&2
  exit 1
fi

ticks() {
  awk -F') ' '{split($2, f, " "); print f[12]+f[13]}' "/proc/$pid/task/$pid/stat"
}
t0=$(ticks)
sleep "$sample_s"
t1=$(ticks)
clk_tck=$(getconf CLK_TCK)
cpu=$(( (t1 - t0) * 100 / (sample_s * clk_tck) ))
echo "Idle main-thread CPU: ${cpu}% (limit ${max_cpu}%, sample=${sample_s}s, pid=${pid})"
if (( cpu > max_cpu )); then
  echo "FAIL: main thread is spinning (${cpu}% > ${max_cpu}%)" >&2
  cat "$log" >&2
  exit 1
fi

python3 "$root/scripts/close_linux_window.py" "$pid"
for _ in $(seq 1 100); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
  echo "FAIL: app did not exit after window close" >&2
  cat "$log" >&2
  exit 1
fi
wait "$pid" || {
  rc=$?
  echo "FAIL: app exited with non-zero status ${rc}" >&2
  cat "$log" >&2
  exit 1
}
pid=""

if ! grep -q "\[CEF\] Shutdown complete" "$log"; then
  echo "FAIL: CEF shutdown incomplete" >&2
  cat "$log" >&2
  exit 1
fi

if grep -q "Unhandled Exception:" "$log"; then
  echo "FAIL: unhandled Dart exception observed during lifecycle/shutdown" >&2
  cat "$log" >&2
  exit 1
fi

sleep 0.5
orphans="$(pgrep -x flutter_chromiu 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  echo "FAIL: orphaned CEF/Flutter subprocesses remained after exit: $orphans" >&2
  exit 1
fi

echo "PASS: idle CPU (${cpu}%), clean shutdown, zero unhandled exceptions, zero orphans"
