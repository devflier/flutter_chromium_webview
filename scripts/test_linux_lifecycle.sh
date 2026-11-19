#!/usr/bin/env bash
# Runs the 14-scenario Linux CEF/GTK window & WebView lifecycle verification
# suite against the compiled release bundle.
# Usage: test_linux_lifecycle.sh [--output-dir DIR] [--plugin-so PATH] [--repeats N]
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ex_dir="$root/packages/flutter_chromium_webview/example"
release_bundle="$ex_dir/build/linux/x64/release/bundle"
output_dir="$root/docs/validation/lifecycle"
plugin_so=""
repeats=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    --plugin-so) plugin_so="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in flutter clang++ pkg-config python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required dependency: $cmd" >&2; exit 2; }
done

mkdir -p "$output_dir"
work_dir="$(mktemp -d /tmp/fcw_lifecycle.XXXXXX)"
probe_dart="$ex_dir/lib/_fcw_lifecycle_probe_tmp.dart"
cleanup() {
  rm -f "$probe_dart"
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Auto-detect XAUTHORITY from active GNOME session if missing.
if [[ -z "${XAUTHORITY:-}" ]]; then
  for p in $(pgrep -u "$(id -u)" gnome-shell 2>/dev/null || true); do
    xa="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | awk -F= '/^XAUTHORITY=/{print $2; exit}' || true)"
    if [[ -n "$xa" ]]; then export XAUTHORITY="$xa"; break; fi
  done
fi
export DISPLAY="${DISPLAY:-:0}"

if [[ ! -x "$release_bundle/flutter_chromium_webview_example" ]]; then
  echo "Building example release bundle first..."
  (cd "$ex_dir" && flutter build linux --release --no-pub)
fi

# 1. Build a self-contained probe bundle with the verification Dart modes.
cat > "$probe_dart" <<'DART'
import 'dart:async';
import 'dart:io';
import 'dart:ui';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

const _channel = MethodChannel('flutter_chromium_webview');
void _log(String msg) { stderr.writeln('[PROBE] $msg'); }

void main(List<String> args) {
  final mode = args.isNotEmpty ? args.first : 'stay_alive';
  _log('START mode=$mode pid=$pid');
  runApp(LifecycleProbeApp(mode: mode));
}

class LifecycleProbeApp extends StatefulWidget {
  const LifecycleProbeApp({super.key, required this.mode});
  final String mode;
  @override
  State<LifecycleProbeApp> createState() => _LifecycleProbeAppState();
}

class _LifecycleProbeAppState extends State<LifecycleProbeApp> {
  final List<ChromiumWebViewController> _controllers = [];
  HttpServer? _server;
  double _width = 640;
  double _height = 480;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<Map<Object?, Object?>> _diag() async =>
      (await _channel.invokeMethod<Map<Object?, Object?>>('getDiagnostics')) ?? {};

  Future<void> _waitLoaded(ChromiumWebViewController ctrl, {Duration timeout = const Duration(seconds: 15)}) async {
    final c = Completer<void>();
    ctrl.onLoadingStateChanged = (bool isLoading, bool _, bool __) {
      if (!isLoading && !c.isCompleted) c.complete();
    };
    await c.future.timeout(timeout, onTimeout: () {});
  }

  Future<void> _run() async {
    try {
      final cacheDir = Directory('/tmp/fcw_lifecycle_cache')..createSync(recursive: true);
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = _server!.port;
      _server!.listen((req) {
        req.response.headers.contentType = ContentType.html;
        req.response.write(
          '<!doctype html><html><head><title>${req.uri.path}</title></head>'
          '<body><h1>${req.uri.path}</h1><p>Lifecycle test page</p></body></html>',
        );
        req.response.close();
      });

      final ok = await ChromiumWebViewController.initialize(cachePath: cacheDir.path);
      _log('INIT_RESULT=$ok diag=${await _diag()}');
      if (!ok) {
        await ServicesBinding.instance.exitApplication(AppExitType.required);
        return;
      }

      if (widget.mode == 'webview_matrix') {
        // Scenarios 1-5 + resize stress:
        // 1: 1 WebView -> 2: 3 WebViews -> 3: dispose 2 keep 1 -> 4: dispose all -> 5: reopen WebView -> resize stress
        final c0 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/s1');
        final w0 = _waitLoaded(c0);
        setState(() => _controllers.add(c0));
        await w0;
        _log('SCENARIO_1_SINGLE_OK diag=${await _diag()}');

        final c1 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/s2_1');
        final c2 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/s2_2');
        final w1 = _waitLoaded(c1);
        final w2 = _waitLoaded(c2);
        setState(() => _controllers.addAll([c1, c2]));
        await Future.wait([w1, w2]);
        _log('SCENARIO_2_THREE_OK diag=${await _diag()}');

        setState(() => _controllers.removeRange(0, 2));
        await c0.dispose();
        await c1.dispose();
        final wKeep = _waitLoaded(c2, timeout: const Duration(seconds: 5));
        await c2.loadRequest('http://127.0.0.1:$port/s3_still_alive');
        await wKeep;
        _log('SCENARIO_3_KEEP1_OK diag=${await _diag()}');

        setState(() => _controllers.clear());
        await c2.dispose();
        await Future.delayed(const Duration(milliseconds: 500));
        _log('SCENARIO_4_DISPOSE_ALL_OK diag=${await _diag()}');

        final c3 = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/s5_reopened');
        final w3 = _waitLoaded(c3);
        setState(() => _controllers.add(c3));
        await w3;
        await c3.executeJavaScript('document.body.style.background = "#eef";');
        // Rapid resize & paint stress to verify texture buffer swap safety.
        for (int i = 0; i < 12; i++) {
          setState(() {
            _width = (i % 2 == 0) ? 900 : 320;
            _height = (i % 2 == 0) ? 620 : 240;
          });
          await c3.loadRequest('http://127.0.0.1:$port/resize/$i');
          await Future.delayed(const Duration(milliseconds: 120));
        }
        _log('SCENARIO_5_REOPEN_AND_RESIZE_OK diag=${await _diag()}');

        setState(() => _controllers.clear());
        await c3.dispose();
        await _server?.close(force: true);
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      } else if (widget.mode == 'exit_application' || widget.mode == 'system_navigator_pop') {
        final ctrl = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/exit');
        final w = _waitLoaded(ctrl);
        setState(() => _controllers.add(ctrl));
        await w;
        await Future.delayed(const Duration(milliseconds: 500));
        _log('LOADED_BEFORE_EXIT diag=${await _diag()}');
        await _server?.close(force: true);
        if (widget.mode == 'exit_application') {
          await ServicesBinding.instance.exitApplication(AppExitType.required);
        } else {
          await SystemNavigator.pop();
        }
      } else {
        final ctrl = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/stay');
        final w = _waitLoaded(ctrl);
        setState(() => _controllers.add(ctrl));
        await w;
        await ctrl.executeJavaScript('document.title = "ALIVE";');
        _log('STAY_ALIVE_READY diag=${await _diag()}');
      }
    } catch (e, st) {
      _log('ERROR: $e\n$st');
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) { unawaited(c.dispose()); }
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _controllers.isEmpty
            ? const Center(child: Text('No WebView'))
            : SizedBox(
                width: _width,
                height: _height,
                child: Row(
                  children: _controllers
                      .map((c) => Expanded(child: ChromiumWebView(controller: c, disposeController: false)))
                      .toList(),
                ),
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

# Rebuild the stock example binary cleanly so release_bundle stays intact for repeat tests.
(cd "$ex_dir" && flutter build linux --release --no-pub >/dev/null)
mkdir -p "$work_dir/example_bundle/lib" "$work_dir/example_bundle/data"
cp -a "$release_bundle/flutter_chromium_webview_example" "$work_dir/example_bundle/"
cp -a "$release_bundle/data/." "$work_dir/example_bundle/data/"
for f in "$release_bundle/lib/"*; do
  bn="$(basename "$f")"
  if [[ "$bn" == "libcef.so" ]]; then
    ln -sf "$f" "$work_dir/example_bundle/lib/libcef.so"
  else
    cp -a "$f" "$work_dir/example_bundle/lib/"
  fi
done
if [[ -n "$plugin_so" ]]; then
  cp -f "$plugin_so" "$work_dir/example_bundle/lib/libflutter_chromium_webview_plugin.so"
fi

# 2. Compile the native GTK multi-window / hold / g_application_quit harness.
cat > "$work_dir/gtk_harness.cc" <<'CPP'
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <cstdio>
#include <string>
#include "flutter_chromium_webview/flutter_chromium_webview_plugin.h"

struct ProbeState {
  GtkApplication* app = nullptr;
  std::string mode;
  GtkWindow* win1 = nullptr;
  GtkWindow* win2 = nullptr;
  int ticks = 0;
  int rapid_iter = 0;
  bool held = false;
};
static ProbeState g_s;

static GtkWindow* make_flutter_win(GtkApplication* app, const char* title) {
  GtkWindow* w = GTK_WINDOW(gtk_application_window_new(app));
  gtk_window_set_title(w, title);
  gtk_window_set_default_size(w, 640, 480);
  g_autoptr(FlDartProject) proj = fl_dart_project_new();
  char* args[] = { const_cast<char*>("stay_alive"), nullptr };
  fl_dart_project_set_dart_entrypoint_arguments(proj, args);
  FlView* view = fl_view_new(proj);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(w), GTK_WIDGET(view));
  gtk_widget_realize(GTK_WIDGET(view));
  gtk_widget_show(GTK_WIDGET(w));
  g_autoptr(FlPluginRegistrar) reg =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "FlutterChromiumWebviewPlugin");
  flutter_chromium_webview_plugin_register_with_registrar(reg);
  return w;
}

static GtkWindow* make_plain_win(GtkApplication* app, const char* title) {
  GtkWindow* w = GTK_WINDOW(gtk_application_window_new(app));
  gtk_window_set_title(w, title);
  gtk_window_set_default_size(w, 320, 200);
  gtk_container_add(GTK_CONTAINER(w), gtk_label_new(title));
  gtk_widget_show_all(GTK_WIDGET(w));
  return w;
}

static gboolean heartbeat(gpointer) {
  g_s.ticks++;
  if (g_s.ticks % 4 == 0) {
    fprintf(stderr, "[GTK] HEARTBEAT tick=%d windows=%u\n",
            g_s.ticks, g_list_length(gtk_application_get_windows(g_s.app)));
    fflush(stderr);
  }
  return G_SOURCE_CONTINUE;
}

static gboolean mw_close2(gpointer) {
  fprintf(stderr, "[GTK] MW_CLOSE_WIN2\n"); fflush(stderr);
  if (g_s.win2) { gtk_widget_destroy(GTK_WIDGET(g_s.win2)); g_s.win2 = nullptr; }
  return G_SOURCE_REMOVE;
}
static gboolean mw_close1(gpointer) {
  fprintf(stderr, "[GTK] MW_CLOSE_WIN1\n"); fflush(stderr);
  if (g_s.win1) { gtk_widget_destroy(GTK_WIDGET(g_s.win1)); g_s.win1 = nullptr; }
  g_timeout_add(5000, mw_close2, nullptr);
  return G_SOURCE_REMOVE;
}

static gboolean rr_finish(gpointer) {
  fprintf(stderr, "[GTK] RR_CPU_END\n");
  fprintf(stderr, "[GTK] RR_CLOSE_AND_RELEASE\n"); fflush(stderr);
  if (g_s.win2) { gtk_widget_destroy(GTK_WIDGET(g_s.win2)); g_s.win2 = nullptr; }
  if (g_s.held) { g_application_release(G_APPLICATION(g_s.app)); g_s.held = false; }
  return G_SOURCE_REMOVE;
}
static gboolean rr_start_cpu(gpointer) {
  fprintf(stderr, "[GTK] RR_CPU_START\n"); fflush(stderr);
  g_timeout_add(6000, rr_finish, nullptr);
  return G_SOURCE_REMOVE;
}
static gboolean rr_readd(gpointer) {
  fprintf(stderr, "[GTK] RR_READD_WIN2\n"); fflush(stderr);
  g_s.win2 = make_flutter_win(g_s.app, "Readded Flutter Win");
  g_timeout_add(2500, rr_start_cpu, nullptr);
  return G_SOURCE_REMOVE;
}
static gboolean rr_remove_last(gpointer) {
  fprintf(stderr, "[GTK] RR_REMOVE_LAST\n"); fflush(stderr);
  if (g_s.win1) { gtk_widget_destroy(GTK_WIDGET(g_s.win1)); g_s.win1 = nullptr; }
  g_timeout_add(1500, rr_readd, nullptr);
  return G_SOURCE_REMOVE;
}

static gboolean rapid_cb(gpointer) {
  if (g_s.rapid_iter < 10) {
    g_s.rapid_iter++;
    GtkWindow* w = make_plain_win(g_s.app, "RapidWin");
    gtk_widget_destroy(GTK_WIDGET(w));
    return G_SOURCE_CONTINUE;
  }
  fprintf(stderr, "[GTK] RAPID_DONE\n"); fflush(stderr);
  if (g_s.win1) { gtk_widget_destroy(GTK_WIDGET(g_s.win1)); g_s.win1 = nullptr; }
  return G_SOURCE_REMOVE;
}

static gboolean quit_attached(gpointer) {
  fprintf(stderr, "[GTK] CALLING_G_APPLICATION_QUIT windows=%u\n",
          g_list_length(gtk_application_get_windows(g_s.app)));
  fflush(stderr);
  g_application_quit(G_APPLICATION(g_s.app));
  return G_SOURCE_REMOVE;
}

static void on_activate(GApplication* app, gpointer) {
  g_s.app = GTK_APPLICATION(app);
  g_timeout_add(250, heartbeat, nullptr);
  if (g_s.mode == "multi_window") {
    g_s.win1 = make_flutter_win(g_s.app, "Win1");
    g_s.win2 = make_plain_win(g_s.app, "Win2");
    g_timeout_add(5000, mw_close1, nullptr);
  } else if (g_s.mode == "remove_readd_window") {
    g_application_hold(app);
    g_s.held = true;
    g_s.win1 = make_flutter_win(g_s.app, "Win1");
    g_timeout_add(5000, rr_remove_last, nullptr);
  } else if (g_s.mode == "rapid_open_close") {
    g_s.win1 = make_flutter_win(g_s.app, "Win1");
    g_timeout_add(4500, +[](gpointer) -> gboolean { g_timeout_add(120, rapid_cb, nullptr); return G_SOURCE_REMOVE; }, nullptr);
  } else if (g_s.mode == "g_application_quit_attached") {
    g_s.win1 = make_flutter_win(g_s.app, "Win1");
    g_timeout_add(5000, quit_attached, nullptr);
  }
}

int main(int argc, char** argv) {
  g_s.mode = argc > 1 ? argv[1] : "multi_window";
  GtkApplication* app = gtk_application_new("com.example.fcw_lifecycle_harness", G_APPLICATION_NON_UNIQUE);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  int st = g_application_run(G_APPLICATION(app), 1, argv);
  fprintf(stderr, "[GTK] G_APPLICATION_RUN_RETURNED status=%d\n", st);
  fflush(stderr);
  g_object_unref(app);
  return st;
}
CPP

clang++ -O2 -std=c++20 "$work_dir/gtk_harness.cc" \
  -I"$ex_dir/linux/flutter/ephemeral" \
  -I"$root/packages/flutter_chromium_webview/linux/include" \
  $(pkg-config --cflags gtk+-3.0) \
  -L"$work_dir/bundle/lib" \
  -Wl,--no-as-needed,-lcef,--as-needed \
  -lflutter_chromium_webview_plugin -lflutter_linux_gtk \
  $(pkg-config --libs gtk+-3.0) \
  -Wl,-rpath,'$ORIGIN/lib' \
  -o "$work_dir/bundle/gtk_harness"

# 3. Execute all 14 scenarios via Python runner and emit JSON + summary.
python3 - "$root" "$work_dir" "$output_dir" "$repeats" <<'PY'
import json, os, select, subprocess, sys, time

root, work_dir, out_dir, repeats = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
bundle = os.path.join(work_dir, "bundle")
ex_bundle = os.path.join(work_dir, "example_bundle")
close_script = os.path.join(root, "scripts", "close_linux_window.py")
clk = os.sysconf(os.sysconf_names["SC_CLK_TCK"])

def read_main_ticks(pid):
    s = open(f"/proc/{pid}/task/{pid}/stat").read()
    f = s[s.rfind(")") + 2:].split()
    return int(f[11]) + int(f[12])

def find_orphans():
    res = []
    for e in os.listdir("/proc"):
        if not e.isdigit(): continue
        try:
            c = open(f"/proc/{e}/comm").read().strip()
            if "flutter_chromiu" in c or "gtk_harness" in c:
                res.append(f"{e}:{c}")
        except OSError:
            pass
    return res

def run_cmd(name, argv, expect_markers, timeout_s=35, measure_between=None, close_wm_after=None):
    env = os.environ.copy()
    env["GDK_BACKEND"] = "x11"
    log_path = os.path.join(out_dir, f"{name}.log")
    t0 = time.monotonic()
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
    pid = p.pid
    lines = []
    cpu_pct = None
    m_t0 = m_ticks0 = None
    wm_sent = False
    deadline = time.monotonic() + timeout_s

    while time.monotonic() < deadline:
        if close_wm_after is not None and not wm_sent and (time.monotonic() - t0) >= close_wm_after:
            wm_sent = True
            subprocess.run(["python3", close_script, str(pid)], capture_output=True)
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            ln = p.stdout.readline()
            if not ln:
                break
            lines.append(ln.rstrip("\n"))
            if measure_between:
                if measure_between[0] in ln:
                    try: m_ticks0 = read_main_ticks(pid); m_t0 = time.monotonic()
                    except OSError: pass
                elif measure_between[1] in ln and m_t0 is not None:
                    try:
                        cpu_pct = round((read_main_ticks(pid) - m_ticks0) * 100.0 / ((time.monotonic() - m_t0) * clk), 2)
                    except OSError: pass
                    m_t0 = None
        elif p.poll() is not None:
            for ln in p.stdout:
                lines.append(ln.rstrip("\n"))
            break

    try:
        p.wait(timeout=2.0)
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
        p.kill()
        p.wait()

    elapsed = round(time.monotonic() - t0, 2)
    text = "\n".join(lines)
    open(log_path, "w").write(text + "\n")
    time.sleep(0.4)
    orphans = find_orphans()
    inits = text.count("[CEF] Initializing runtime")
    shuts = text.count("[CEF] Shutdown complete")
    unhandled = "Unhandled Exception:" in text
    missing = [m for m in expect_markers if m not in text]
    passed = (
        not timed_out
        and p.returncode == 0
        and inits == 1
        and shuts == 1
        and not unhandled
        and not orphans
        and not missing
        and (cpu_pct is None or cpu_pct < 5.0)
    )
    res = {
        "name": name,
        "status": "PASS" if passed else "FAIL",
        "rc": p.returncode,
        "timed_out": timed_out,
        "elapsed_s": elapsed,
        "init_count": inits,
        "shutdown_count": shuts,
        "unhandled_dart_exception": unhandled,
        "orphans": orphans,
        "missing_markers": missing,
        "measured_main_cpu_pct": cpu_pct,
        "log": log_path,
    }
    print(f"[{res['status']}] {name}: rc={res['rc']} elapsed={elapsed}s cpu={cpu_pct} init={inits} shut={shuts} unhandled={unhandled} orphans={orphans or 'NONE'} missing={missing}", flush=True)
    return res

results = []
# Scenarios 1-5 (+ resize/paint texture stress)
results.append(run_cmd(
    "scenarios_1_to_5_webview_matrix",
    [os.path.join(bundle, "flutter_chromium_webview_example"), "webview_matrix"],
    ["SCENARIO_1_SINGLE_OK", "SCENARIO_2_THREE_OK", "SCENARIO_3_KEEP1_OK", "SCENARIO_4_DISPOSE_ALL_OK", "SCENARIO_5_REOPEN_AND_RESIZE_OK"],
    timeout_s=45,
))
# Scenarios 6-8: two GTK windows, close 1st while 2nd active, close last
results.append(run_cmd(
    "scenarios_6_to_8_multi_window",
    [os.path.join(bundle, "gtk_harness"), "multi_window"],
    ["MW_CLOSE_WIN1", "MW_CLOSE_WIN2", "G_APPLICATION_RUN_RETURNED status=0"],
    timeout_s=28,
    measure_between=("MW_CLOSE_WIN1", "MW_CLOSE_WIN2"),
))
# Scenario 9: reopen GTK window with new WebView while app held alive
results.append(run_cmd(
    "scenario_9_remove_readd_held",
    [os.path.join(bundle, "gtk_harness"), "remove_readd_window"],
    ["RR_REMOVE_LAST", "RR_READD_WIN2", "G_APPLICATION_RUN_RETURNED status=0"],
    timeout_s=30,
    measure_between=("RR_CPU_START", "RR_CPU_END"),
))
# Also check ready_count == 2 for scenario 9
s9_log = open(results[-1]["log"]).read()
if s9_log.count("STAY_ALIVE_READY") < 2:
    results[-1]["status"] = "FAIL"
    results[-1]["missing_markers"].append("STAY_ALIVE_READY_x2")
    print("[FAIL] scenario_9_remove_readd_held: second WebView did not reach STAY_ALIVE_READY", flush=True)

# Scenario 10: rapid create/destroy windows
results.append(run_cmd(
    "scenario_10_rapid_open_close",
    [os.path.join(bundle, "gtk_harness"), "rapid_open_close"],
    ["RAPID_DONE", "G_APPLICATION_RUN_RETURNED status=0"],
    timeout_s=25,
))
# Scenario 11: WM close
results.append(run_cmd(
    "scenario_11_wm_close",
    [os.path.join(ex_bundle, "flutter_chromium_webview_example")],
    ["[CEF] Shutdown complete"],
    timeout_s=30,
    close_wm_after=7.0,
))
# Scenario 12a & 12b: Dart exitApplication() and SystemNavigator.pop()
results.append(run_cmd(
    "scenario_12a_dart_exit_application",
    [os.path.join(bundle, "flutter_chromium_webview_example"), "exit_application"],
    ["LOADED_BEFORE_EXIT"],
    timeout_s=25,
))
results.append(run_cmd(
    "scenario_12b_system_navigator_pop",
    [os.path.join(bundle, "flutter_chromium_webview_example"), "system_navigator_pop"],
    ["LOADED_BEFORE_EXIT"],
    timeout_s=25,
))
# Scenario 13: direct g_application_quit() with window attached
results.append(run_cmd(
    "scenario_13_direct_g_application_quit",
    [os.path.join(bundle, "gtk_harness"), "g_application_quit_attached"],
    ["CALLING_G_APPLICATION_QUIT", "G_APPLICATION_RUN_RETURNED status=0"],
    timeout_s=20,
))
# Scenario 14: N repeated startup & shutdown cycles
rep_pass = 0
rep_runs = []
for i in range(1, repeats + 1):
    r = run_cmd(
        f"scenario_14_repeat_{i}",
        [os.path.join(ex_bundle, "flutter_chromium_webview_example")],
        ["[CEF] Shutdown complete"],
        timeout_s=30,
        close_wm_after=6.0,
    )
    rep_runs.append(r)
    if r["status"] == "PASS":
        rep_pass += 1

summary = {
    "commit_sha": subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip(),
    "kernel": os.uname().release,
    "display_backend": "x11",
    "scenarios": results,
    "repeat_runs": rep_runs,
    "repeat_passed": rep_pass,
    "repeat_total": repeats,
    "overall_pass": all(r["status"] == "PASS" for r in results) and rep_pass == repeats,
}
json_path = os.path.join(out_dir, "lifecycle_results.json")
open(json_path, "w").write(json.dumps(summary, indent=2) + "\n")
print(f"LIFECYCLE_OVERALL={'PASS' if summary['overall_pass'] else 'FAIL'} repeats={rep_pass}/{repeats} json={json_path}", flush=True)
sys.exit(0 if summary["overall_pass"] else 1)
PY
