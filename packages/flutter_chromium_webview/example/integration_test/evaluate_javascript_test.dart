import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    // Manual pumps must finish even when macOS throttles a background window.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  }
  testWidgets('evaluateJavaScript returns primitives and objects', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final cache = Directory.systemTemp.createTempSync('cef-eval-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!doctype html><meta charset="utf-8">');
      await request.response.close();
    });

    bool loaded = false;
    final controller = ChromiumWebViewController(
      initialUrl: 'http://127.0.0.1:${server.port}/',
      javaScriptChannels: [
        JavaScriptChannel(
          name: 'test',
          allowedOrigins: {'http://127.0.0.1:${server.port}'},
          onMessageReceived: (_) => loaded = true,
        ),
      ],
    );

    try {
      expect(
        await ChromiumWebViewController.initialize(cachePath: cache.path),
        isTrue,
      );
      await controller.createBrowser();

      // Wait for navigation to finish
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        try {
          await controller.executeJavaScript(
            "chromiumPostMessage('test', 'ready')",
          );
        } catch (_) {}
        if (loaded) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(loaded, isTrue);

      // primitives
      expect(await controller.evaluateJavaScript('42'), 42);
      expect(await controller.evaluateJavaScript('"hello"'), 'hello');
      expect(await controller.evaluateJavaScript('true'), true);
      expect(await controller.evaluateJavaScript('null'), null);

      // arrays and objects
      expect(await controller.evaluateJavaScript('[1, 2, "three"]'), [
        1,
        2,
        'three',
      ]);
      expect(await controller.evaluateJavaScript('({a: 1, b: "two"})'), {
        'a': 1,
        'b': 'two',
      });

      // concurrent requests
      final req1 = controller.evaluateJavaScript(
        'new Promise(r => setTimeout(() => r(1), 100))',
      );
      final req2 = controller.evaluateJavaScript(
        'new Promise(r => setTimeout(() => r(2), 50))',
      );
      final req3 = controller.evaluateJavaScript('3');

      expect(await req3, 3);
      expect(await req2, 2);
      expect(await req1, 1);

      // exceptions
      try {
        await controller.evaluateJavaScript('throw new Error("test error")');
        fail('Expected an exception');
      } on JavaScriptException catch (e) {
        expect(e.code, 'javascript_exception');
        expect(e.message, contains('test error'));
      }

      // timeout
      try {
        await controller.evaluateJavaScript(
          'new Promise(() => {})',
          timeout: const Duration(milliseconds: 100),
        );
        fail('Expected timeout');
      } on JavaScriptException catch (e) {
        expect(e.code, 'timeout');
      }
    } finally {
      await controller.dispose();
      await server.close(force: true);
    }
  });
}
