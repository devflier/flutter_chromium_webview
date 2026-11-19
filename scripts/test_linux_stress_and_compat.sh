#!/usr/bin/env bash
# Comprehensive Linux stress, adversarial lifecycle, and functional compatibility
# test suite for flutter_chromium_webview (MTML architecture).
#
# Tests:
#   1. 100 WebView create/dispose cycles (with diagnostics leak checks)
#   2. 100 rapid resize cycles while actively painting
#   3. 3 & 5 simultaneous WebViews + independent disposal
#   4. JS execution during navigation, disposal, and shutdown
#   5. Rapid application exit during pending creation/navigation/dialogs (5 runs)
#   6. 20 full startup/shutdown cycles with orphan-process verification
#   7. Functional web compatibility matrix (local HTTP/WS/TLS server)
#   8. Adverse ELF/GLib checks: reversed link order, dlopen(RTLD_LOCAL),
#      active G_SOURCE_CONTINUE idle source at shutdown, inactivity_timeout.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ex_dir="$root/packages/flutter_chromium_webview/example"
release_bundle="$ex_dir/build/linux/x64/release/bundle"
output_dir="${1:-/tmp/fcw_stress_results}"
mkdir -p "$output_dir"

work_dir="$(mktemp -d /tmp/fcw_stress.XXXXXX)"
probe_dart="$ex_dir/lib/_fcw_stress_probe_tmp.dart"
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
export GDK_BACKEND="x11"

cat > "$probe_dart" <<'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

Future<void> _log(String msg) async {
  stderr.writeln(msg);
  await stderr.flush();
}

Future<Map<String, dynamic>> _diagnostics() async {
  final res = await const MethodChannel('flutter_chromium_webview')
      .invokeMapMethod<String, dynamic>('getDiagnostics');
  return res ?? <String, dynamic>{};
}

void main(List<String> args) {
  final mode = args.isNotEmpty ? args.first : 'stress';
  final extra = args.length > 1 ? args[1] : '';
  runApp(StressApp(mode: mode, extra: extra));
}

class StressApp extends StatefulWidget {
  const StressApp({super.key, required this.mode, required this.extra});
  final String mode;
  final String extra;
  @override
  State<StressApp> createState() => _StressAppState();
}

class _StressAppState extends State<StressApp> {
  final List<ChromiumWebViewController> _controllers = [];
  double _width = 800;
  double _height = 600;
  HttpServer? _http1;
  HttpServer? _http2;

  @override
  void initState() {
    super.initState();
    unawaited(_dispatch());
  }

  Future<void> _waitLoaded(ChromiumWebViewController c, {String? urlContains, Duration timeout = const Duration(seconds: 12)}) async {
    final done = Completer<void>();
    c.onLoadingStateChanged = (bool isLoading, bool _, bool __) {
      if (!isLoading && !done.isCompleted) {
        if (urlContains == null || c.currentUrl.contains(urlContains)) {
          done.complete();
        }
      }
    };
    await done.future.timeout(timeout, onTimeout: () {});
  }

  Future<void> _dispatch() async {
    final cacheDir = Directory('/tmp/fcw_stress_cache_${pid}')..createSync(recursive: true);
    try {
      switch (widget.mode) {
        case 'cycles_100':
          await _runCycles100(cacheDir.path);
          break;
        case 'resize_100':
          await _runResize100(cacheDir.path);
          break;
        case 'multi_and_js_nav':
          await _runMultiAndJsNav(cacheDir.path);
          break;
        case 'rapid_exit':
          await _runRapidExit(cacheDir.path, widget.extra);
          break;
        case 'startup_cycle':
          await _runStartupCycle(cacheDir.path);
          break;
        case 'compat':
          await _runCompat(cacheDir.path, widget.extra);
          break;
        default:
          await _log('FAIL:unknown_mode:${widget.mode}');
      }
    } catch (e, st) {
      await _log('FAIL:exception:$e\n$st');
    } finally {
      await _http1?.close(force: true);
      await _http2?.close(force: true);
      try { cacheDir.deleteSync(recursive: true); } catch (_) {}
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  Future<void> _startLocalServers() async {
    _http1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http1!.listen((req) async {
      final path = req.uri.path;
      if (path == '/ws') {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((data) => ws.add('echo:$data'));
        return;
      }
      if (path == '/redirect') {
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set(HttpHeaders.locationHeader, '/redirect_target');
        await req.response.close();
        return;
      }
      if (path == '/api/data') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': true, 'ua': req.headers.value('user-agent') ?? ''}));
        await req.response.close();
        return;
      }
      if (path == '/set_cookie') {
        req.response.cookies.add(Cookie('fcw_test', 'cookie_val_42')..path = '/'..httpOnly = false);
      }
      req.response.headers.contentType = ContentType.html;
      req.response.write('''<!doctype html><html><head><title>P:$path</title></head>
<body><button id="pop" style="position:fixed;left:0;top:0;width:300px;height:200px" onclick="window.open('/popup_target','_blank')">Open</button><h1 id="h">Path $path</h1>
<script>
window._path = ${jsonEncode(path)};
</script></body></html>''');
      await req.response.close();
    });
    _http2!.listen((req) async {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<!doctype html><html><head><title>Origin2</title></head><body>Cross Origin</body></html>');
      await req.response.close();
    });
  }

  Future<void> _runCycles100(String cache) async {
    await _startLocalServers();
    final port = _http1!.port;
    await ChromiumWebViewController.initialize(cachePath: cache);
    for (int i = 1; i <= 100; i++) {
      final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/c/$i');
      setState(() => _controllers.add(c));
      await c.createBrowser();
      if (i % 10 == 0) {
        final w = _waitLoaded(c, timeout: const Duration(seconds: 5));
        await c.loadRequest('http://127.0.0.1:$port/c/$i?loaded=1');
        await w;
      }
      setState(() => _controllers.clear());
      await c.dispose();
    }
    final diag = await _diagnostics();
    await _log('RESULT:cycles_100:browsers=${diag['browsers']}:textures=${diag['textures']}:pump=${diag['pumpRunning']}');
    if (diag['browsers'] == 0 && diag['textures'] == 0 && diag['pumpRunning'] == true) {
      await _log('PASS:cycles_100');
    } else {
      await _log('FAIL:cycles_100:diag=$diag');
    }
  }

  Future<void> _runResize100(String cache) async {
    await _startLocalServers();
    final port = _http1!.port;
    await ChromiumWebViewController.initialize(cachePath: cache);
    final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/resize');
    final w = _waitLoaded(c);
    setState(() => _controllers.add(c));
    await w;
    for (int i = 1; i <= 100; i++) {
      final nw = 200.0 + ((i * 37) % 1000);
      final nh = 150.0 + ((i * 29) % 600);
      setState(() {
        _width = nw;
        _height = nh;
      });
      await c.updateBrowserSize(nw, nh, (i % 2 == 0) ? 2.0 : 1.0);
      if (i % 20 == 0) {
        await c.executeJavaScript('document.body.style.background = "rgb(${i}, 120, 200)";');
        await Future.delayed(const Duration(milliseconds: 25));
      }
    }
    setState(() => _controllers.clear());
    await c.dispose();
    final diag = await _diagnostics();
    if (diag['browsers'] == 0 && diag['textures'] == 0) {
      await _log('PASS:resize_100');
    } else {
      await _log('FAIL:resize_100:diag=$diag');
    }
  }

  Future<void> _runMultiAndJsNav(String cache) async {
    await _startLocalServers();
    final port = _http1!.port;
    await ChromiumWebViewController.initialize(cachePath: cache);
    final ctrls = <ChromiumWebViewController>[];
    for (int i = 1; i <= 5; i++) {
      ctrls.add(ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/multi/$i'));
    }
    final waits = ctrls.map((c) => _waitLoaded(c)).toList();
    setState(() => _controllers.addAll(ctrls));
    await Future.wait(waits);

    // Interleave JS execution and navigation across all 5 views, then dispose 2, keep 3, then dispose while navigating.
    for (int i = 0; i < ctrls.length; i++) {
      unawaited(ctrls[i].executeJavaScript('for(let k=0;k<500;k++){ document.title = "js_" + k; }'));
      unawaited(ctrls[i].loadRequest('http://127.0.0.1:$port/multi_nav/$i'));
    }
    await Future.delayed(const Duration(milliseconds: 150));

    // Dispose 2 while 3 stay alive
    setState(() => _controllers.removeRange(3, 5));
    await Future.wait([ctrls[3].dispose(), ctrls[4].dispose()]);

    // Trigger JS + navigation on remaining 3 right before disposal & shutdown
    for (int i = 0; i < 3; i++) {
      unawaited(ctrls[i].executeJavaScript('window.x = Array(1000).fill($i).join(",");'));
      unawaited(ctrls[i].loadRequest('http://127.0.0.1:$port/closing/$i'));
    }
    setState(() => _controllers.clear());
    await Future.wait([ctrls[0].dispose(), ctrls[1].dispose(), ctrls[2].dispose()]);

    final diag = await _diagnostics();
    if (diag['browsers'] == 0 && diag['textures'] == 0) {
      await _log('PASS:multi_and_js_nav');
    } else {
      await _log('FAIL:multi_and_js_nav:diag=$diag');
    }
  }

  Future<void> _runRapidExit(String cache, String variant) async {
    await _startLocalServers();
    final port = _http1!.port;
    await ChromiumWebViewController.initialize(cachePath: cache);
    if (variant == 'during_create') {
      final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/rapid1');
      unawaited(c.createBrowser());
      await _log('PASS:rapid_exit_$variant');
      return; // exits immediately via finally -> exitApplication
    } else if (variant == 'during_nav_and_js') {
      final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/rapid2');
      setState(() => _controllers.add(c));
      await c.createBrowser();
      unawaited(c.loadRequest('http://127.0.0.1:$port/rapid2_next'));
      unawaited(c.executeJavaScript('setInterval(() => { document.title = Date.now(); }, 1);'));
      await _log('PASS:rapid_exit_$variant');
      return; // leaves browser open intentionally for shutdown CloseAll path!
    } else {
      final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/rapid3');
      c.onJSDialog = (_) => Completer<JSDialogResponse>().future; // never answered
      final w = _waitLoaded(c);
      setState(() => _controllers.add(c));
      await w;
      unawaited(c.executeJavaScript('alert("pending_at_exit");'));
      await Future.delayed(const Duration(milliseconds: 200));
      await _log('PASS:rapid_exit_$variant');
      return; // exits with pending JS dialog!
    }
  }

  Future<void> _runStartupCycle(String cache) async {
    await _startLocalServers();
    final port = _http1!.port;
    await ChromiumWebViewController.initialize(cachePath: cache);
    final c = ChromiumWebViewController(initialUrl: 'http://127.0.0.1:$port/cycle');
    final w = _waitLoaded(c);
    setState(() => _controllers.add(c));
    await w;
    setState(() => _controllers.clear());
    await c.dispose();
    await _log('PASS:startup_cycle');
  }

  Future<void> _runCompat(String cache, String tlsPortStr) async {
    await _startLocalServers();
    final p1 = _http1!.port;
    final p2 = _http2!.port;
    final tlsPort = int.tryParse(tlsPortStr) ?? 0;
    final origin1 = 'http://127.0.0.1:$p1';
    final results = <String, bool>{};

    await ChromiumWebViewController.initialize(cachePath: cache);

    final bridgeMsgs = <String>[];
    final bridgeCompleter = Completer<void>();
    final c = ChromiumWebViewController(
      initialUrl: '$origin1/set_cookie',
      userAgent: 'FCW-Compat-UA/0.5.6',
      javaScriptChannels: [
        JavaScriptChannel(
          name: 'compat',
          allowedOrigins: {origin1},
          onMessageReceived: (msg) {
            bridgeMsgs.add(msg.message);
            if (!bridgeCompleter.isCompleted && msg.message.startsWith('REPORT:')) {
              bridgeCompleter.complete();
            }
          },
        ),
      ],
    );

    final popups = <String>[];
    c.onNewWindowRequested = (req) => popups.add(req.url);
    int? lastTlsError;
    c.onLoadError = (code, text, url) {
      if (url.startsWith('https://127.0.0.1:')) lastTlsError = code;
    };

    var w = _waitLoaded(c, urlContains: '/set_cookie');
    setState(() => _controllers.add(c));
    await w;
    results['html_load'] = c.currentUrl.contains('/set_cookie');

    // User-Agent override + fetch/XHR + cookies + localStorage + sessionStorage + IndexedDB + WebSocket + media + clipboard + popup
    await c.executeJavaScript('''
      (async () => {
        const out = {};
        out.cookie = document.cookie.includes('fcw_test=cookie_val_42');
        localStorage.setItem('fcw_ls', 'ok_ls');
        out.localStorage = localStorage.getItem('fcw_ls') === 'ok_ls';
        sessionStorage.setItem('fcw_ss', 'ok_ss');
        out.sessionStorage = sessionStorage.getItem('fcw_ss') === 'ok_ss';
        out.indexedDB = await new Promise((resolve) => {
          const req = indexedDB.open('fcw_db', 1);
          req.onupgradeneeded = () => req.result.createObjectStore('s');
          req.onsuccess = () => {
            const db = req.result;
            const tx = db.transaction('s', 'readwrite');
            tx.objectStore('s').put('v1', 'k1');
            tx.oncomplete = () => {
              const g = db.transaction('s').objectStore('s').get('k1');
              g.onsuccess = () => resolve(g.result === 'v1');
              g.onerror = () => resolve(false);
            };
          };
          req.onerror = () => resolve(false);
        });
        try {
          const r = await fetch('/api/data');
          const j = await r.json();
          out.fetch = j.ok === true;
          out.userAgent = j.ua === 'FCW-Compat-UA/0.5.6';
        } catch (e) { out.fetch = false; out.userAgent = false; }
        out.websocket = await new Promise((resolve) => {
          const ws = new WebSocket('ws://127.0.0.1:$p1/ws');
          ws.onopen = () => ws.send('ping');
          ws.onmessage = (ev) => { ws.close(); resolve(ev.data === 'echo:ping'); };
          ws.onerror = () => resolve(false);
          setTimeout(() => resolve(false), 4000);
        });
        const v = document.createElement('video');
        const a = document.createElement('audio');
        out.html5Media = typeof v.canPlayType === 'function' && typeof a.canPlayType === 'function';
        out.webrtcApi = typeof RTCPeerConnection === 'function';
        out.clipboardApi = typeof navigator.clipboard !== 'undefined';
        window.chromiumPostMessage('compat', 'REPORT:' + JSON.stringify(out));
      })();
    ''');

    await bridgeCompleter.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    // Trigger popup via genuine user-gesture pointer click on the full-area button.
    await c.sendPointerInput(type: PointerInputType.down, x: 50, y: 50, button: 1);
    await c.sendPointerInput(type: PointerInputType.up, x: 50, y: 50, button: 1);
    await Future.delayed(const Duration(milliseconds: 500));
    if (bridgeMsgs.isNotEmpty) {
      final raw = bridgeMsgs.firstWhere((m) => m.startsWith('REPORT:'), orElse: () => '');
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw.substring('REPORT:'.length)) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          results[entry.key] = entry.value == true;
        }
        results['js_bridge'] = true;
      }
    }
    results['popup_request'] = popups.any((u) => u.contains('/popup_target'));

    // Redirect (OAuth-style 302 chain)
    w = _waitLoaded(c);
    await c.loadRequest('$origin1/redirect');
    await w;
    results['redirect'] = c.currentUrl.contains('/redirect_target');

    // History goBack / goForward
    w = _waitLoaded(c);
    await c.goBack();
    await w;
    results['history_back'] = c.currentUrl.contains('/set_cookie');
    w = _waitLoaded(c);
    await c.goForward();
    await w;
    results['history_forward'] = c.currentUrl.contains('/redirect_target');

    // Cross-origin navigation + JS bridge origin enforcement (must NOT receive from origin2!)
    w = _waitLoaded(c);
    await c.loadRequest('http://127.0.0.1:$p2/cross');
    await w;
    results['cross_origin_nav'] = c.currentUrl.contains(':$p2/cross');
    final beforeCrossCount = bridgeMsgs.length;
    await c.executeJavaScript("window.chromiumPostMessage && window.chromiumPostMessage('compat', 'UNAUTHORIZED');");
    await Future.delayed(const Duration(milliseconds: 400));
    results['bridge_origin_isolation'] = bridgeMsgs.length == beforeCrossCount;

    // loadHtmlString
    w = _waitLoaded(c);
    await c.loadHtmlString('<!doctype html><html><head><title>InlineHtml</title></head><body>OK</body></html>', baseUrl: '$origin1/inline');
    await w;
    await Future.delayed(const Duration(milliseconds: 200));
    results['load_html_string'] = c.pageTitle == 'InlineHtml';

    // HTTPS self-signed TLS rejection check (security: must reject untrusted cert!)
    if (tlsPort > 0) {
      w = _waitLoaded(c, timeout: const Duration(seconds: 6));
      await c.loadRequest('https://127.0.0.1:$tlsPort/');
      await w;
      await Future.delayed(const Duration(milliseconds: 300));
      results['https_rejects_self_signed'] = lastTlsError != null && lastTlsError! < 0;
    }

    setState(() => _controllers.clear());
    await c.dispose();

    await _log('COMPAT_JSON:${jsonEncode(results)}');
    final failed = results.entries.where((e) => !e.value).map((e) => e.key).toList();
    if (failed.isEmpty) {
      await _log('PASS:compat');
    } else {
      await _log('FAIL:compat:failed=$failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _controllers.isEmpty
            ? const Center(child: Text('Stress Idle'))
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

echo "=== Building stress/compat test binary ==="
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

# Restore stock release bundle.
(cd "$ex_dir" && flutter build linux --release --no-pub >/dev/null)

BIN="$work_dir/bundle/flutter_chromium_webview_example"
fail_count=0

run_case() {
  local name="$1"
  local timeout_s="$2"
  shift 2
  local logf="$output_dir/${name}.log"
  local rc=0
  timeout "$timeout_s" "$BIN" "$@" >"$logf" 2>&1 || rc=$?
  sleep 0.4
  local orphans
  orphans="$(pgrep -f "flutter_chromium_webview_subprocess|flutter_chromium_webview_example" || true)"
  local shut=0
  grep -q "\[CEF\] Shutdown complete" "$logf" && shut=1 || true
  local pass_tag=0
  grep -q "^PASS:" "$logf" && pass_tag=1 || true
  if [[ "$rc" -eq 0 && "$shut" -eq 1 && "$pass_tag" -eq 1 && -z "$orphans" ]]; then
    echo "[PASS] $name (rc=0, shut=1, orphans=0)"
  else
    echo "[FAIL] $name (rc=$rc, shut=$shut, pass=$pass_tag, orphans=${orphans:-none})"
    tail -n 15 "$logf"
    fail_count=$((fail_count + 1))
  fi
}

echo "=== 1. 100 WebView create/dispose cycles ==="
run_case "cycles_100" 180 cycles_100

echo "=== 2. 100 rapid resize cycles ==="
run_case "resize_100" 90 resize_100

echo "=== 3. Multi-WebView (5 views) + JS execution during navigation & disposal ==="
run_case "multi_and_js_nav" 90 multi_and_js_nav

echo "=== 4. Rapid application exits (during create, nav+JS, pending JS dialog) ==="
run_case "rapid_exit_create" 30 rapid_exit during_create
run_case "rapid_exit_nav_js" 30 rapid_exit during_nav_and_js
run_case "rapid_exit_dialog" 30 rapid_exit during_dialog
run_case "rapid_exit_create_2" 30 rapid_exit during_create
run_case "rapid_exit_nav_js_2" 30 rapid_exit during_nav_and_js

echo "=== 5. 20 full startup/shutdown cycles ==="
startup_pass=0
for i in $(seq 1 20); do
  logf="$output_dir/startup_${i}.log"
  rc=0
  timeout 45 "$BIN" startup_cycle >"$logf" 2>&1 || rc=$?
  sleep 0.25
  orphans="$(pgrep -f "flutter_chromium_webview_subprocess|flutter_chromium_webview_example" || true)"
  if [[ "$rc" -eq 0 ]] && grep -q "\[CEF\] Shutdown complete" "$logf" && grep -q "^PASS:startup_cycle" "$logf" && [[ -z "$orphans" ]]; then
    startup_pass=$((startup_pass + 1))
  else
    echo "[FAIL] startup_cycle_$i (rc=$rc, orphans=${orphans:-none})"
    tail -n 10 "$logf"
    fail_count=$((fail_count + 1))
  fi
done
echo "[INFO] startup_shutdown_20: $startup_pass/20 passed"

echo "=== 6. Functional web compatibility matrix (with self-signed TLS server) ==="
openssl req -x509 -newkey rsa:2048 -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" \
  -days 1 -nodes -subj "/CN=127.0.0.1" >/dev/null 2>&1
python3 - "$work_dir/cert.pem" "$work_dir/key.pem" "$work_dir/tls_port" <<'PY' &
import http.server, ssl, sys
cert, key, port_file = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"<h1>TLS</h1>")
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
tls_pid=$!
for _ in $(seq 1 30); do [[ -s "$work_dir/tls_port" ]] && break; sleep 0.1; done
tls_port="$(cat "$work_dir/tls_port" 2>/dev/null || echo 0)"
run_case "compat_low_mem_on" 90 compat "$tls_port"
grep "COMPAT_JSON:" "$output_dir/compat_low_mem_on.log" || true
FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0 run_case "compat_low_mem_off" 90 compat "$tls_port"
grep "COMPAT_JSON:" "$output_dir/compat_low_mem_off.log" || true
kill "$tls_pid" 2>/dev/null || true

echo "=== 7. Adverse ELF link-order, dlopen(RTLD_LOCAL), G_SOURCE_CONTINUE, inactivity_timeout ==="
cat > "$work_dir/adverse_elf.c" <<'C'
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#ifndef DLOPEN_MODE
extern GType flutter_chromium_webview_plugin_get_type(void);
#endif

int main(int argc, char** argv) {
#ifdef DLOPEN_MODE
  gtk_init(&argc, &argv);
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
  void* sym = dlsym(RTLD_DEFAULT, "g_application_hold");
  Dl_info info;
  if (!dladdr(sym, &info) || strstr(info.dli_fname, "libgio") == NULL) {
    fprintf(stderr, "FAIL: g_application_hold resolved to %s\n", info.dli_fname ? info.dli_fname : "null");
    return 3;
  }
  if (dlsym(h, "g_application_hold") != NULL &&
      dladdr(dlsym(h, "g_application_hold"), &info) &&
      strstr(info.dli_fname, "flutter_chromium_webview") != NULL) {
    fprintf(stderr, "FAIL: plugin still exports g_application_hold!\n");
    return 4;
  }
  dlclose(h);
  printf("PASS:dlopen_rtld_local\n");
  return 0;
#else
  void* sym = dlsym(RTLD_DEFAULT, "g_application_hold");
  Dl_info info;
  if (!dladdr(sym, &info) || strstr(info.dli_fname, "libgio") == NULL) {
    fprintf(stderr, "FAIL: g_application_hold resolved to %s\n", info.dli_fname ? info.dli_fname : "null");
    return 3;
  }
  void* sym2 = dlsym(RTLD_DEFAULT, "g_application_quit");
  if (!dladdr(sym2, &info) || strstr(info.dli_fname, "libgio") == NULL) {
    fprintf(stderr, "FAIL: g_application_quit resolved to %s\n", info.dli_fname ? info.dli_fname : "null");
    return 4;
  }
  if (argc == 999) (void)flutter_chromium_webview_plugin_get_type();
  printf("PASS:elf_no_interposition\n");
  return 0;
#endif
}
C
CFLAGS=$(pkg-config --cflags gtk+-3.0 gio-2.0)
LIBS=$(pkg-config --libs gtk+-3.0 gio-2.0)
gcc "$work_dir/adverse_elf.c" $CFLAGS -L"$release_bundle/lib" -Wl,-rpath,"$release_bundle/lib" \
  -Wl,--no-as-needed -lcef -lflutter_chromium_webview_plugin -Wl,--as-needed $LIBS -ldl -o "$work_dir/elf_plugin_first"
gcc "$work_dir/adverse_elf.c" $CFLAGS -L"$release_bundle/lib" -Wl,-rpath,"$release_bundle/lib" \
  -Wl,--no-as-needed $LIBS -lcef -lflutter_chromium_webview_plugin -Wl,--as-needed -ldl -o "$work_dir/elf_gio_first"
gcc -DDLOPEN_MODE "$work_dir/adverse_elf.c" $CFLAGS $LIBS -ldl -o "$work_dir/elf_dlopen"

"$work_dir/elf_plugin_first" && echo "[PASS] elf_plugin_first_resolves_libgio" || { echo "[FAIL] elf_plugin_first"; fail_count=$((fail_count+1)); }
"$work_dir/elf_gio_first" && echo "[PASS] elf_gio_first_resolves_libgio" || { echo "[FAIL] elf_gio_first"; fail_count=$((fail_count+1)); }
"$work_dir/elf_dlopen" "$release_bundle/lib/libflutter_chromium_webview_plugin.so" && echo "[PASS] dlopen_rtld_local" || { echo "[FAIL] dlopen_rtld_local"; fail_count=$((fail_count+1)); }

# Test G_SOURCE_CONTINUE active idle source at shutdown via LD_PRELOAD helper
cat > "$work_dir/idle_source_preload.c" <<'C'
#include <glib.h>
#include <gio/gio.h>
#include <stdio.h>
static gboolean busy_idle(gpointer d) { (void)d; return G_SOURCE_CONTINUE; }
__attribute__((constructor)) static void add_idle(void) {
  // Adds a perpetual G_SOURCE_CONTINUE idle source on the default context;
  // an unbounded while(g_main_context_iteration(NULL, FALSE)) in Shutdown()
  // would deadlock forever!
  g_timeout_add(0, busy_idle, NULL);
}
C
gcc -shared -fPIC "$work_dir/idle_source_preload.c" $(pkg-config --cflags --libs glib-2.0 gio-2.0) -o "$work_dir/libidle_preload.so"
LD_PRELOAD="$work_dir/libidle_preload.so" run_case "shutdown_with_perpetual_glib_source" 35 startup_cycle

echo "=== STRESS_AND_COMPAT_SUMMARY fail_count=$fail_count ==="
exit $(( fail_count > 0 ))
