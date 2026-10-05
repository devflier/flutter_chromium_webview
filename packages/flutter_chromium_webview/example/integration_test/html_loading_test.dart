import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'HTML origin, relative resources, reload, replacement and browser isolation',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final cache = Directory.systemTemp.createTempSync('cef-html-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      const secureOrigin = 'https://player.invalid';
      final url = '$origin/player/index.html?q=1';
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.toString());
        if (request.uri.path == '/player/asset.js') {
          request.response.headers.contentType = ContentType(
            'application',
            'javascript',
            charset: 'utf-8',
          );
          request.response.write(
            "chromiumPostMessage('player','asset:' + document.title + ':' + location.origin);",
          );
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            "<title>Network</title><script>chromiumPostMessage('player','network')</script>",
          );
        }
        await request.response.close();
      });
      final firstMessages = <String>[];
      final secondMessages = <String>[];
      final origins = <String>[];
      ChromiumWebViewController make(List<String> messages) =>
          ChromiumWebViewController(
            javaScriptChannels: [
              JavaScriptChannel(
                name: 'player',
            allowedOrigins: {origin, secureOrigin},
                onMessageReceived: (value) {
                  origins.add(value.origin);
                  messages.add(value.message);
                },
              ),
            ],
          );
      final first = make(firstMessages);
      final second = make(secondMessages);
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(condition(), isTrue);
      }

      String page(String title) =>
          '<!doctype html><title>$title</title><body>'
          '${'x' * 100000}<script src="asset.js"></script></body>';
      try {
        expect(
          await ChromiumWebViewController.initialize(cachePath: cache.path),
          isTrue,
        );
        await first.createBrowser();
        await second.createBrowser();
        await first.loadHtmlString(page('Olá 🌍'), baseUrl: url);
        await waitFor(() => firstMessages.length == 1);
        expect(first.currentUrl, url);
        expect(firstMessages, ['asset:Olá 🌍:$origin']);
        expect(requests, contains('/player/asset.js'));
        expect(requests, isNot(contains('/player/index.html?q=1')));
        await first.reload();
        await waitFor(() => firstMessages.length == 2);
        expect(firstMessages.last, 'asset:Olá 🌍:$origin');
        await second.loadRequest(url);
        await waitFor(() => secondMessages.length == 1);
        expect(secondMessages, ['network']);
        await second.loadHtmlString(page('Second'), baseUrl: url);
        await waitFor(() => secondMessages.length == 2);
        expect(secondMessages.last, 'asset:Second:$origin');
        await first.loadHtmlString(page('Replacement'), baseUrl: url);
        await waitFor(() => firstMessages.length == 3);
        expect(firstMessages.last, 'asset:Replacement:$origin');
        // Native callers must be validated too, and failure must retain the old HTML.
        const channel = MethodChannel('flutter_chromium_webview');
        await expectLater(
          channel.invokeMethod<void>('loadHtmlString', {
            'browserId': first.browserId,
            'html': 'bad',
            'baseUrl': 'file:///tmp/page',
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'INVALID_HTML',
            ),
          ),
        );
        await first.reload();
        await waitFor(() => firstMessages.length == 4);
        expect(firstMessages.last, 'asset:Replacement:$origin');
        await first.loadRequest(url);
        await waitFor(() => firstMessages.length == 5);
        expect(firstMessages.last, 'network');
        await first.loadHtmlString('', baseUrl: '$origin/empty');
        await waitFor(
          () => first.currentUrl.endsWith('/empty') && !first.isLoading,
        );
        await first.executeJavaScript(
          "chromiumPostMessage('player','empty:' + document.body.textContent);",
        );
        await waitFor(() => firstMessages.length == 6);
        expect(firstMessages.last, 'empty:');
        await first.executeJavaScript("""
        fetch(location.href).then(r => r.text()).then(text =>
          chromiumPostMessage('player', 'fetch:' + text.includes('<title>Network</title>')));
      """);
        await waitFor(() => firstMessages.length == 7);
        expect(firstMessages.last, 'fetch:true');
        await first.executeJavaScript("""
        const iframe = document.createElement('iframe');
        iframe.onload = () => chromiumPostMessage('player', 'iframe:' + iframe.contentDocument.title);
        iframe.src = location.href;
        document.body.appendChild(iframe);
      """);
        await waitFor(() => firstMessages.length == 8);
      expect(firstMessages.last, 'iframe:Network');
      await first.loadHtmlString(
        '<script>chromiumPostMessage("player", "secure:" + location.origin)</script>',
        baseUrl: '$secureOrigin/index.html',
      );
      await waitFor(() => firstMessages.length == 9);
      expect(firstMessages.last, 'secure:$secureOrigin');
      expect(first.currentUrl, '$secureOrigin/index.html');
        await first.dispose();
        await second.reload();
        await waitFor(() => secondMessages.length == 3);
        expect(secondMessages.last, 'asset:Second:$origin');
      expect(origins.toSet(), {origin, secureOrigin});
      } finally {
        await first.dispose();
        await second.dispose();
        await server.close(force: true);
      }
    },
  );
}
