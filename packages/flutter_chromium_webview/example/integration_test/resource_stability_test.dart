import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  const cycles = int.fromEnvironment('RESOURCE_CYCLES', defaultValue: 100);
  const dwell = int.fromEnvironment('RESOURCE_DWELL_SECONDS', defaultValue: 5);

  testWidgets('browser and resize churn return owned resources to baseline', (
    tester,
  ) async {
    expect(cycles, greaterThan(0));
    expect(dwell, greaterThanOrEqualTo(0));
    final cache = Directory.systemTemp.createTempSync('cef-resource-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '''<!doctype html><canvas id="c" width="640" height="360"></canvas>
<script>const c=document.getElementById('c'),x=c.getContext('2d');
window.renderedFrames=0;function paint(t){window.renderedFrames++;x.fillStyle='hsl('+t/20+' 80% 50%)';x.fillRect(0,0,c.width,c.height);
if(window.renderedFrames===1)chromiumPostMessage('resource','ready');requestAnimationFrame(paint)}
requestAnimationFrame(paint);</script>''',
      );
      await request.response.close();
    });
    await tester.pumpWidget(const SizedBox());
    expect(
      await ChromiumWebViewController.initialize(cachePath: cache.path),
      isTrue,
    );

    Future<Map<String, dynamic>> snapshot() async => Map<String, dynamic>.from(
      (await channel.invokeMapMethod<String, dynamic>('getResourceCounters'))!,
    );
    final baseline = await snapshot();
    Future<void> waitForBaseline(int cycle) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        final current = await snapshot();
        var matches = true;
        for (final process in ['client', 'host']) {
          for (final key in (baseline[process] as Map).keys) {
            if (current[process][key] != baseline[process][key]) {
              matches = false;
            }
          }
        }
        if (matches) return;
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'Cycle $cycle failed to return to baseline. '
            'baseline=$baseline current=$current',
          );
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    try {
      for (var cycle = 0; cycle < cycles; cycle++) {
        var ready = false;
        final controller = ChromiumWebViewController(
          initialUrl: '$origin/cycle/$cycle',
          javaScriptChannels: [
            JavaScriptChannel(
              name: 'resource',
              allowedOrigins: {origin},
              onMessageReceived: (message) {
                if (message.message == 'ready') ready = true;
              },
            ),
          ],
        );
        try {
          await controller.createBrowser();
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: ChromiumWebView(
                controller: controller,
                disposeController: false,
              ),
            ),
          );
          final readyDeadline = DateTime.now().add(const Duration(seconds: 20));
          while (!ready && DateTime.now().isBefore(readyDeadline)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(ready, isTrue, reason: 'The renderer must paint the fixture');
          final until = DateTime.now().add(Duration(seconds: dwell));
          while (DateTime.now().isBefore(until)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            await controller.evaluateJavaScript('window.renderedFrames'),
            greaterThan(0),
            reason: 'The animated fixture must actually run before disposal',
          );
          // Remove layout-driven resizing before sending controlled sizes.
          await tester.pumpWidget(const SizedBox());
          for (final size in [
            (640, 360),
            (1280, 720),
            (1920, 1080),
            (800, 600),
          ]) {
            await controller.updateBrowserSize(
              size.$1.toDouble(),
              size.$2.toDouble(),
              1,
            );
            await tester.pump(const Duration(milliseconds: 100));
            final state = await snapshot();
            expect(state['host']['activeBrowsers'], 1);
            expect(state['host']['activeIOSurfaces'], 3);
            expect(state['client']['activeIOSurfaces'], inInclusiveRange(1, 3));
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await controller.dispose();
        }
        await waitForBaseline(cycle + 1);
        if ((cycle + 1) % 10 == 0 || cycle == cycles - 1) {
          debugPrint('RESOURCE_CHURN ${cycle + 1}/$cycles baseline=$baseline');
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await server.close(force: true);
      // The host uses this cache until the integration app exits.
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}
