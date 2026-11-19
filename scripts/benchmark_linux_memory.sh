#!/usr/bin/env bash
# Benchmarks Linux RAM usage (RSS, PSS, USS/Private, Shared, Anon, Peak VmHWM)
# across all 12 memory scenarios using /proc/<pid>/smaps_rollup and /proc/<pid>/status.
# Usage: benchmark_linux_memory.sh [--output-dir DIR] [--plugin-so PATH] [--label NAME] [--soak-seconds N]
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ex_dir="$root/packages/flutter_chromium_webview/example"
release_bundle="$ex_dir/build/linux/x64/release/bundle"
output_dir="$root/docs/validation/memory_bench"
plugin_so=""
label="current"
soak_seconds=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    --plugin-so) plugin_so="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --soak-seconds) soak_seconds="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in flutter python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required dependency: $cmd" >&2; exit 2; }
done

mkdir -p "$output_dir"
work_dir="$(mktemp -d /tmp/fcw_mem_bench.XXXXXX)"
probe_dart="$ex_dir/lib/_fcw_mem_bench_tmp.dart"
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

void main(List<String> args) {
  final soakS = args.isNotEmpty ? (int.tryParse(args.first) ?? 0) : 0;
  runApp(MemBenchApp(soakSeconds: soakS));
}

class MemBenchApp extends StatefulWidget {
  const MemBenchApp({super.key, required this.soakSeconds});
  final int soakSeconds;
  @override
  State<MemBenchApp> createState() => _MemBenchAppState();
}

class _MemBenchAppState extends State<MemBenchApp> {
  final List<ChromiumWebViewController> _controllers = [];
  HttpServer? _server;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _waitLoaded(ChromiumWebViewController c, {Duration timeout = const Duration(seconds: 15)}) async {
    final done = Completer<void>();
    c.onLoadingStateChanged = (bool isLoading, bool _, bool __) {
      if (!isLoading && !done.isCompleted) done.complete();
    };
    await done.future.timeout(timeout, onTimeout: () {});
  }

  Future<void> _closeAll() async {
    final old = List<ChromiumWebViewController>.from(_controllers);
    setState(() => _controllers.clear());
    for (final c in old) {
      await c.dispose();
    }
  }

  Future<void> _run() async {
    final cacheDir = Directory('/tmp/fcw_mem_bench_cache')..createSync(recursive: true);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = _server!.port;
    _server!.listen((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write(
        '<!doctype html><html><head><title>Mem ${req.uri.path}</title></head>'
        '<body style="background:#fff;color:#111;font-family:sans-serif">'
        '<h1>Page ${req.uri.path}</h1><p>${"Benchmark static HTML payload. " * 200}</p>'
        '</body></html>',
      );
      req.response.close();
    });

    // Scenario 1: Flutter app without initializing CEF
    await Future.delayed(const Duration(seconds: 3));
    await _mark('MEM_SAMPLE:01_no_cef');

    // Scenario 2: CEF initialized, 0 WebViews
    await ChromiumWebViewController.initialize(cachePath: cacheDir.path);
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:02_cef_init_only');

    // Scenario 3: 1 WebView showing blank page
    var c1 = ChromiumWebViewController(initialUrl: 'about:blank');
    var w = _waitLoaded(c1);
    setState(() => _controllers.add(c1));
    await w;
    await Future.delayed(const Duration(seconds: 3));
    await _mark('MEM_SAMPLE:03_blank_page');

    // Scenario 4: 1 WebView showing local static HTML
    w = _waitLoaded(c1);
    await c1.loadRequest('http://127.0.0.1:$port/static');
    await w;
    await Future.delayed(const Duration(seconds: 3));
    await _mark('MEM_SAMPLE:04_static_html');

    // Scenario 5: 1 WebView showing remote website (https://example.com)
    w = _waitLoaded(c1);
    await c1.loadRequest('https://example.com');
    await w;
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:05_remote_website');

    // Reset to local static pages for multi-webview measurements
    w = _waitLoaded(c1);
    await c1.loadRequest('http://127.0.0.1:$port/view/1');
    await w;

    // Scenario 6: 3 simultaneous WebViews
    final c2 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/view/2');
    final c3 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/view/3');
    final w2 = _waitLoaded(c2), w3 = _waitLoaded(c3);
    setState(() => _controllers.addAll([c2, c3]));
    await Future.wait([w2, w3]);
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:06_three_webviews');

    // Scenario 7: 5 simultaneous WebViews
    final c4 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/view/4');
    final c5 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/view/5');
    final w4 = _waitLoaded(c4), w5 = _waitLoaded(c5);
    setState(() => _controllers.addAll([c4, c5]));
    await Future.wait([w4, w5]);
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:07_five_webviews');

    // Collapse back to 1 WebView before 20-page navigation test
    setState(() => _controllers.removeRange(1, 5));
    for (final c in [c2, c3, c4, c5]) { await c.dispose(); }
    await Future.delayed(const Duration(seconds: 2));

    // Scenario 8: Repeated navigation across 20 pages
    await _mark('MEM_PEAK_START:08_nav_20_pages');
    for (int i = 1; i <= 20; i++) {
      final wn = _waitLoaded(c1, timeout: const Duration(seconds: 4));
      await c1.loadRequest('http://127.0.0.1:$port/nav/$i');
      await wn;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await Future.delayed(const Duration(seconds: 3));
    await _mark('MEM_SAMPLE:08_nav_20_pages');

    // Scenario 9: All WebViews disposed
    await _closeAll();
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:09_all_disposed');

    // Scenario 10: WebView recreated after disposal
    final cRec = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/recreated');
    final wRec = _waitLoaded(cRec);
    setState(() => _controllers.add(cRec));
    await wRec;
    await Future.delayed(const Duration(seconds: 3));
    await _mark('MEM_SAMPLE:10_recreated_after_disposal');

    // Scenario 11: Repeated create/dispose cycles (10 cycles)
    await _closeAll();
    for (int i = 1; i <= 10; i++) {
      final ct = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/cycle/$i');
      final wt = _waitLoaded(ct, timeout: const Duration(seconds: 6));
      setState(() => _controllers.add(ct));
      await wt;
      setState(() => _controllers.clear());
      await ct.dispose();
    }
    await Future.delayed(const Duration(seconds: 4));
    await _mark('MEM_SAMPLE:11_after_10_create_dispose_cycles');

    // Scenario 12: Idle soak (optional, default 600s = 10 minutes with 1 static WebView)
    if (widget.soakSeconds > 0) {
      final cSoak = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/soak');
      final wSoak = _waitLoaded(cSoak);
      setState(() => _controllers.add(cSoak));
      await wSoak;
      await Future.delayed(const Duration(seconds: 5));
      await _mark('MEM_SAMPLE:12_soak_t0');
      int elapsed = 0;
      const step = 60;
      while (elapsed < widget.soakSeconds) {
        final sleepNow = (widget.soakSeconds - elapsed) < step ? (widget.soakSeconds - elapsed) : step;
        await Future.delayed(Duration(seconds: sleepNow));
        elapsed += sleepNow;
        await _mark('MEM_SAMPLE:12_soak_t${elapsed}s');
      }
      await _closeAll();
    }

    await _server?.close(force: true);
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _controllers.isEmpty
            ? const Center(child: Text('Memory Benchmark'))
            : Row(
                children: _controllers
                    .map((c) => Expanded(child: ChromiumWebView(controller: c, disposeController: false)))
                    .toList(),
              ),
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

python3 - "$work_dir/bundle" "$output_dir" "$label" "$soak_seconds" "$commit_sha" "$flutter_ver" "$cef_ver" <<'PY'
import csv, json, os, select, subprocess, sys, time

bundle, out_dir, label, soak_s, commit_sha, flutter_ver, cef_ver = sys.argv[1:8]

def classify(p, main_pid, cmd):
    if p == main_pid:
        return "browser_main"
    if "--type=renderer" in cmd:
        return "renderer"
    if "--type=gpu-process" in cmd:
        return "gpu_process"
    if "NetworkService" in cmd:
        return "utility_network"
    if "StorageService" in cmd:
        return "utility_storage"
    if "--type=zygote" in cmd or "--type=broker" in cmd:
        return "zygote_broker"
    return "other"

def sample_tree(main_pid):
    totals = {"rss_kb": 0, "pss_kb": 0, "uss_kb": 0, "shared_kb": 0, "anon_kb": 0, "vmhwm_kb": 0}
    roles = {}
    procs = []
    for e in sorted(os.listdir("/proc"), key=lambda x: int(x) if x.isdigit() else 999999):
        if not e.isdigit(): continue
        p = int(e)
        try:
            comm = open(f"/proc/{p}/comm").read().strip()
            cmd = open(f"/proc/{p}/cmdline").read().replace("\0", " ").strip()
            if p != main_pid and "flutter_chromiu" not in comm and "flutter_chromiu" not in cmd:
                continue
            if "python3" in cmd:
                continue
            vals = {}
            for ln in open(f"/proc/{p}/smaps_rollup"):
                if ":" in ln and "kB" in ln:
                    k, v = ln.split(":", 1)
                    vals[k.strip()] = int(v.strip().split()[0])
            vmhwm = 0
            for ln in open(f"/proc/{p}/status"):
                if ln.startswith("VmHWM:"):
                    vmhwm = int(ln.split()[1])
                    break
            rss = vals.get("Rss", 0)
            pss = vals.get("Pss", 0)
            uss = vals.get("Private_Clean", 0) + vals.get("Private_Dirty", 0)
            shared = vals.get("Shared_Clean", 0) + vals.get("Shared_Dirty", 0)
            anon = vals.get("Anonymous", 0)
            role = classify(p, main_pid, cmd)
            totals["rss_kb"] += rss
            totals["pss_kb"] += pss
            totals["uss_kb"] += uss
            totals["shared_kb"] += shared
            totals["anon_kb"] += anon
            totals["vmhwm_kb"] += vmhwm
            r = roles.setdefault(role, {"count": 0, "pss_kb": 0, "rss_kb": 0, "uss_kb": 0})
            r["count"] += 1; r["pss_kb"] += pss; r["rss_kb"] += rss; r["uss_kb"] += uss
            procs.append({"pid": p, "role": role, "rss_mb": round(rss/1024, 1), "pss_mb": round(pss/1024, 1), "uss_mb": round(uss/1024, 1)})
        except OSError:
            pass
    return {
        "process_count": len(procs),
        "rss_mb": round(totals["rss_kb"] / 1024.0, 1),
        "pss_mb": round(totals["pss_kb"] / 1024.0, 1),
        "uss_mb": round(totals["uss_kb"] / 1024.0, 1),
        "shared_mb": round(totals["shared_kb"] / 1024.0, 1),
        "anon_mb": round(totals["anon_kb"] / 1024.0, 1),
        "peak_vmhwm_mb": round(totals["vmhwm_kb"] / 1024.0, 1),
        "browser_main_pss_mb": round(roles.get("browser_main", {}).get("pss_kb", 0) / 1024.0, 1),
        "renderer_count": roles.get("renderer", {}).get("count", 0),
        "renderer_pss_mb": round(roles.get("renderer", {}).get("pss_kb", 0) / 1024.0, 1),
        "gpu_pss_mb": round(roles.get("gpu_process", {}).get("pss_kb", 0) / 1024.0, 1),
        "utility_pss_mb": round((roles.get("utility_network", {}).get("pss_kb", 0) + roles.get("utility_storage", {}).get("pss_kb", 0)) / 1024.0, 1),
        "zygote_pss_mb": round(roles.get("zygote_broker", {}).get("pss_kb", 0) / 1024.0, 1),
        "roles": {k: {kk: (round(vv/1024, 1) if kk.endswith("_kb") else vv) for kk, vv in v.items()} for k, v in roles.items()},
    }

env = os.environ.copy()
env["GDK_BACKEND"] = "x11"
p = subprocess.Popen(
    [os.path.join(bundle, "flutter_chromium_webview_example"), soak_s],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env,
)
pid = p.pid
samples = []
log_lines = []
peak_nav_pss = 0.0
peak_tracking = False

while True:
    r, _, _ = select.select([p.stdout], [], [], 0.5)
    if peak_tracking and p.poll() is None:
        cur = sample_tree(pid)
        if cur["pss_mb"] > peak_nav_pss:
            peak_nav_pss = cur["pss_mb"]
    if r:
        line = p.stdout.readline()
        if not line:
            break
        ln = line.rstrip("\n")
        log_lines.append(ln)
        if ln.startswith("MEM_PEAK_START:"):
            peak_tracking = True
            peak_nav_pss = 0.0
        elif ln.startswith("MEM_SAMPLE:"):
            name = ln.split(":", 1)[1].strip()
            s = sample_tree(pid)
            s["label"] = label
            s["scenario"] = name
            if name == "08_nav_20_pages":
                peak_tracking = False
                s["nav_peak_pss_mb"] = round(max(peak_nav_pss, s["pss_mb"]), 1)
            samples.append(s)
            print(f"MEM[{label}:{name}] procs={s['process_count']} rend={s['renderer_count']} PSS={s['pss_mb']}MB RSS={s['rss_mb']}MB USS={s['uss_mb']}MB Anon={s['anon_mb']}MB MainPSS={s['browser_main_pss_mb']}MB RendPSS={s['renderer_pss_mb']}MB GpuPSS={s['gpu_pss_mb']}MB PeakHWM={s['peak_vmhwm_mb']}MB", flush=True)
    elif p.poll() is not None:
        for line in p.stdout:
            log_lines.append(line.rstrip("\n"))
        break

p.wait(timeout=20)
meta = {
    "label": label,
    "commit_sha": commit_sha,
    "flutter_version": flutter_ver,
    "cef_version": cef_ver,
    "kernel": os.uname().release,
    "display_backend": "x11",
    "soak_seconds": int(soak_s),
    "exit_code": p.returncode,
    "shutdown_complete": any("[CEF] Shutdown complete" in l for l in log_lines),
    "scenarios": samples,
}
open(os.path.join(out_dir, f"memory_{label}.log"), "w").write("\n".join(log_lines) + "\n")
open(os.path.join(out_dir, f"memory_{label}.json"), "w").write(json.dumps(meta, indent=2) + "\n")
csv_fields = ["label", "scenario", "process_count", "renderer_count", "pss_mb", "rss_mb", "uss_mb", "shared_mb", "anon_mb", "peak_vmhwm_mb", "browser_main_pss_mb", "renderer_pss_mb", "gpu_pss_mb", "utility_pss_mb", "zygote_pss_mb"]
with open(os.path.join(out_dir, f"memory_{label}.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=csv_fields, extrasaction="ignore")
    w.writeheader()
    w.writerows(samples)
sys.exit(0 if p.returncode == 0 and meta["shutdown_complete"] else 1)
PY
