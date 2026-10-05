import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real renderer bridge isolates browsers, origins, navigation and lifetime',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final cache = Directory.systemTemp.createTempSync('cef-bridge-');
      final allowed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${allowed.port}';
      final deniedOrigin = 'http://127.0.0.1:${denied.port}';
      void serve(HttpServer server) {
        server.listen((request) async {
          request.response.headers.contentType = ContentType.html;
          if (request.uri.path == '/sandboxed') {
            request.response.headers.set(
              'Content-Security-Policy',
              'sandbox allow-scripts',
            );
          }
          request.response.write(
            '''<!doctype html><meta charset="utf-8"><script>
          chromiumPostMessage('unknown', 'unexpected');
          chromiumPostMessage('player', 'ready 🌍');
        </script>''',
          );
          await request.response.close();
        });
      }

      serve(allowed);
      serve(denied);
      final received = <String>[];
      final origins = <String>[];
      final first = ChromiumWebViewController(
        initialUrl: '$origin/start',
        javaScriptChannels: [
          JavaScriptChannel(
            name: 'player',
            allowedOrigins: {origin},
            onMessageReceived: (value) {
              origins.add(value.origin);
              received.add(value.message);
            },
          ),
        ],
      );
      final second = ChromiumWebViewController(initialUrl: '$origin/other');
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(condition(), isTrue);
      }

      try {
        expect(
          await ChromiumWebViewController.initialize(cachePath: cache.path),
          isTrue,
        );
        await first.createBrowser();
        await second.createBrowser();
        await waitFor(() => received.length == 1);
        expect(received, ['ready 🌍']);
        await waitFor(
          () => second.currentUrl.startsWith(origin) && !second.isLoading,
        );
        await first.executeJavaScript("""
          try { chromiumPostMessage('player', '🌍'.repeat(16385)); } catch (_) {}
          chromiumPostMessage('player', 'after');
        """);
        await waitFor(() => received.length == 2);
        await first.executeJavaScript("""
        const iframe = document.createElement('iframe');
        iframe.srcdoc = '<script>parent.postMessage(typeof chromiumPostMessage, "*")</script>';
        window.addEventListener('message', e => chromiumPostMessage('player', 'iframe:' + e.data), {once:true});
        document.body.appendChild(iframe);
      """);
        await waitFor(() => received.length == 3);
        expect(received.last, 'iframe:undefined');
        await first.loadRequest('$deniedOrigin/blocked');
        await waitFor(
          () => first.currentUrl.startsWith(deniedOrigin) && !first.isLoading,
        );
        await first.loadRequest('$origin/again');
        await waitFor(() => received.length >= 4);
        expect(received, ['ready 🌍', 'after', 'iframe:undefined', 'ready 🌍']);
        await first.loadRequest(
          'data:text/html,<script>chromiumPostMessage("player","opaque")</script>',
        );
        await waitFor(
          () => first.currentUrl.startsWith('data:') && !first.isLoading,
        );
        await first.loadRequest('$origin/final');
        await waitFor(() => received.length >= 5);
        expect(received.last, 'ready 🌍');
        expect(received.length, 5);
        await first.loadRequest('$origin/sandboxed');
        await waitFor(
          () => first.currentUrl.endsWith('/sandboxed') && !first.isLoading,
        );
        await first.loadRequest('$origin/after-sandbox');
        await waitFor(() => received.length >= 6);
        expect(received.length, 6);
        expect(received.last, 'ready 🌍');
        expect(origins.toSet(), {origin});
        await first.dispose();
        await second.executeJavaScript(
          "chromiumPostMessage('player','after disposal');",
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(received.length, 6);
      } finally {
        await first.dispose();
        await second.dispose();
        await allowed.close(force: true);
        await denied.close(force: true);
      }
    },
  );
}
