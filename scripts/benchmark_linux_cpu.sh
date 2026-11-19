#!/usr/bin/env bash
# Benchmarks Linux CPU usage across idle CEF init, static page idle, active page
# navigation, and post-close idle, breaking down main thread, Flutter engine
# threads, browser process, renderer processes, GPU process, and all subprocesses.
# Usage: benchmark_linux_cpu.sh [--output-dir DIR] [--plugin-so PATH] [--label NAME]
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ex_dir="$root/packages/flutter_chromium_webview/example"
release_bundle="$ex_dir/build/linux/x64/release/bundle"
output_dir="$root/docs/validation/cpu_bench"
plugin_so=""
label="current"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    --plugin-so) plugin_so="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in flutter python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required dependency: $cmd" >&2; exit 2; }
done

mkdir -p "$output_dir"
work_dir="$(mktemp -d /tmp/fcw_cpu_bench.XXXXXX)"
probe_dart="$ex_dir/lib/_fcw_cpu_bench_tmp.dart"
cleanup() {
  rm -f "$probe_dart"
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ -z "${XAUTHORITY:-}" ]]; then
  for p in $(pgrep -u "$(id -u)" gnome-shell 2>/dev/null || true); do
    xa="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | awk -F= '/^XAUTHORITY=/{print $2; exit}' || true)"
    if [[ -n "$xa" ]]; then export XAUTHORITY="$xa"; break; fi
  done
fi
export DISPLAY="${DISPLAY:-:0}"

cat > "$probe_dart" <<'DART'
import 'dart:async';
import 'dart:io';
import 'dart:ui';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

Future<void> _mark(String msg) async {
  stderr.writeln(msg);
  await stderr.flush();
}

void main() => runApp(const CpuBenchApp());

class CpuBenchApp extends StatefulWidget {
  const CpuBenchApp({super.key});
  @override
  State<CpuBenchApp> createState() => _CpuBenchAppState();
}

class _CpuBenchAppState extends State<CpuBenchApp> {
  ChromiumWebViewController? _ctrl;
  HttpServer? _server;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _waitLoaded(ChromiumWebViewController c, {Duration timeout = const Duration(seconds: 10)}) async {
    final done = Completer<void>();
    c.onLoadingStateChanged = (bool isLoading, bool _, bool __) {
      if (!isLoading && !done.isCompleted) done.complete();
    };
    await done.future.timeout(timeout, onTimeout: () {});
  }

  Future<void> _run() async {
    final cacheDir = Directory('/tmp/fcw_cpu_bench_cache')..createSync(recursive: true);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = _server!.port;
    _server!.listen((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write(
        '<!doctype html><html><head><title>${req.uri.path}</title></head>'
        '<body style="background:#f8f8f8;color:#222;font-family:sans-serif">'
        '<h1>Page ${req.uri.path}</h1><p>${"Static content block. " * 120}</p>'
        '</body></html>',
      );
      req.response.close();
    });

    await ChromiumWebViewController.initialize(cachePath: cacheDir.path);
    await Future.delayed(const Duration(seconds: 3));
    await _mark('CPU_START:cef_init_only');
    await Future.delayed(const Duration(seconds: 10));
    await _mark('CPU_END:cef_init_only');

    final ctrl = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/static');
    final w1 = _waitLoaded(ctrl);
    setState(() => _ctrl = ctrl);
    await w1;
    await Future.delayed(const Duration(seconds: 3));
    await _mark('CPU_START:static_page_idle');
    await Future.delayed(const Duration(seconds: 10));
    await _mark('CPU_END:static_page_idle');

    await _mark('CPU_START:page_navigation');
    for (int i = 1; i <= 16; i++) {
      await ctrl.loadRequest('http://127.0.0.1:$port/nav/$i');
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await _mark('CPU_END:page_navigation');

    setState(() => _ctrl = null);
    await ctrl.dispose();
    await Future.delayed(const Duration(seconds: 3));
    await _mark('CPU_START:after_close_webviews');
    await Future.delayed(const Duration(seconds: 10));
    await _mark('CPU_END:after_close_webviews');

    await _server?.close(force: true);
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _ctrl == null
            ? const Center(child: Text('CPU Benchmark Idle'))
            : ChromiumWebView(controller: _ctrl!, disposeController: false),
      ),
    );
  }
}
DART

(cd "$ex_dir" && flutter build linux --release --no-pub -t "lib/$(basename "$probe_dart")" >/dev/null)
rm -f "$probe_dart"

mkdir -p "$work_dir/bundle/lib" "$work_dir/bundle/data"
cp -a "$release_bundle/flutter_chromium_webview_example" "$work_dir/bundle/"
cp -a "$release_bundle/data/." "$work_dir/bundle/data/"
for f in "$release_bundle/lib/"*; do
  bn="$(basename "$f")"
  if [[ "$bn" == "libcef.so" ]]; then
    ln -sf "$f" "$work_dir/bundle/lib/libcef.so"
  else
    cp -a "$f" "$work_dir/bundle/lib/"
  fi
done
if [[ -n "$plugin_so" ]]; then
  cp -f "$plugin_so" "$work_dir/bundle/lib/libflutter_chromium_webview_plugin.so"
fi

# Restore stock release bundle.
(cd "$ex_dir" && flutter build linux --release --no-pub >/dev/null)

commit_sha="$(git -C "$root" rev-parse HEAD)"
flutter_ver="$(flutter --version 2>/dev/null | head -n 1 || echo unknown)"
cef_ver="$(awk -F'"' '/set\(CEF_VERSION/{print $2; exit}' "$root/packages/flutter_chromium_webview/linux/DownloadCEF.cmake" || echo unknown)"

python3 - "$work_dir/bundle" "$output_dir" "$label" "$commit_sha" "$flutter_ver" "$cef_ver" <<'PY'
import csv, json, os, subprocess, sys, time

bundle, out_dir, label, commit_sha, flutter_ver, cef_ver = sys.argv[1:7]
clk = os.sysconf(os.sysconf_names["SC_CLK_TCK"])

def read_stat(path):
    s = open(path).read()
    rp = s.rfind(")")
    comm = s[s.find("(") + 1:rp]
    f = s[rp + 2:].split()
    return comm, int(f[1]), int(f[11]) + int(f[12])

def proc_role(p, main_pid, cmd):
    if p == main_pid:
        return "browser_main"
    if "--type=renderer" in cmd:
        return "renderer"
    if "--type=gpu-process" in cmd:
        return "gpu_process"
    if "--type=utility" in cmd:
        return "utility"
    if "--type=zygote" in cmd or "--type=broker" in cmd:
        return "zygote_broker"
    return "other_subproc"

def snapshot(main_pid):
    threads = {}
    tdir = f"/proc/{main_pid}/task"
    if os.path.isdir(tdir):
        for tid in os.listdir(tdir):
            try:
                comm, _, ticks = read_stat(f"{tdir}/{tid}/stat")
                threads[int(tid)] = (comm, ticks)
            except OSError:
                pass
    procs = {}
    for e in os.listdir("/proc"):
        if not e.isdigit(): continue
        p = int(e)
        try:
            comm, ppid, ticks = read_stat(f"/proc/{p}/stat")
            cmd = open(f"/proc/{p}/cmdline").read().replace("\0", " ").strip()
            if p == main_pid or ppid == main_pid or "flutter_chromiu" in comm:
                procs[p] = (proc_role(p, main_pid, cmd), comm, ticks)
        except OSError:
            pass
    return threads, procs

env = os.environ.copy()
env["GDK_BACKEND"] = "x11"
p = subprocess.Popen(
    [os.path.join(bundle, "flutter_chromium_webview_example")],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env,
)
pid = p.pid
active = None
s0 = None
t0 = None
phases = []
log_lines = []

for line in p.stdout:
    ln = line.rstrip("\n")
    log_lines.append(ln)
    if ln.startswith("CPU_START:"):
        active = ln.split(":", 1)[1].strip()
        s0 = snapshot(pid)
        t0 = time.monotonic()
    elif ln.startswith("CPU_END:") and active:
        s1 = snapshot(pid)
        dt = time.monotonic() - t0
        th0, pr0 = s0
        th1, pr1 = s1
        main_ticks = th1.get(pid, ("", 0))[1] - th0.get(pid, ("", 0))[1]
        main_pct = main_ticks * 100.0 / (dt * clk)
        flutter_pct = 0.0
        for tid, (comm, t_val) in th1.items():
            if comm.startswith("io.flutter.") or comm.startswith("llvmpipe"):
                flutter_pct += (t_val - th0.get(tid, (comm, t_val))[1]) * 100.0 / (dt * clk)
        by_role = {"browser_main": 0.0, "renderer": 0.0, "gpu_process": 0.0, "utility": 0.0, "zygote_broker": 0.0, "other_subproc": 0.0}
        for pp, (role, comm, t_val) in pr1.items():
            prev = pr0.get(pp, (role, comm, t_val))[2]
            by_role[role] = by_role.get(role, 0.0) + (t_val - prev) * 100.0 / (dt * clk)
        subprocs_pct = sum(v for k, v in by_role.items() if k != "browser_main")
        total_pct = by_role["browser_main"] + subprocs_pct
        row = {
            "label": label,
            "scenario": active,
            "duration_s": round(dt, 2),
            "main_pid": pid,
            "process_count": len(pr1),
            "main_thread_cpu_pct": round(main_pct, 2),
            "flutter_engine_threads_cpu_pct": round(flutter_pct, 2),
            "browser_process_cpu_pct": round(by_role["browser_main"], 2),
            "renderer_processes_cpu_pct": round(by_role["renderer"], 2),
            "gpu_process_cpu_pct": round(by_role["gpu_process"], 2),
            "all_subprocesses_cpu_pct": round(subprocs_pct, 2),
            "full_tree_cpu_pct": round(total_pct, 2),
        }
        phases.append(row)
        print(f"CPU[{label}:{active}] dur={row['duration_s']}s main={row['main_thread_cpu_pct']}% flutter={row['flutter_engine_threads_cpu_pct']}% browser={row['browser_process_cpu_pct']}% renderer={row['renderer_processes_cpu_pct']}% gpu={row['gpu_process_cpu_pct']}% subprocs={row['all_subprocesses_cpu_pct']}% total={row['full_tree_cpu_pct']}%", flush=True)
        active = None

p.wait(timeout=20)
meta = {
    "label": label,
    "commit_sha": commit_sha,
    "flutter_version": flutter_ver,
    "cef_version": cef_ver,
    "kernel": os.uname().release,
    "display_backend": "x11",
    "exit_code": p.returncode,
    "shutdown_complete": any("[CEF] Shutdown complete" in l for l in log_lines),
    "scenarios": phases,
}
open(os.path.join(out_dir, f"cpu_{label}.log"), "w").write("\n".join(log_lines) + "\n")
open(os.path.join(out_dir, f"cpu_{label}.json"), "w").write(json.dumps(meta, indent=2) + "\n")
csv_path = os.path.join(out_dir, f"cpu_{label}.csv")
if phases:
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(phases[0].keys()))
        w.writeheader()
        w.writerows(phases)
sys.exit(0 if p.returncode == 0 and meta["shutdown_complete"] else 1)
PY
