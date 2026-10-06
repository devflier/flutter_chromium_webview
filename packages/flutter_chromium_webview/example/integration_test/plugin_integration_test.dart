import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final cache = Directory.systemTemp.createTempSync('cef-lifecycle-');
  Future<Map<Object?, Object?>> diagnostics() async =>
      (await channel.invokeMethod<Map<Object?, Object?>>('getDiagnostics'))!;

  testWidgets('native lifecycle, focus, and hot-restart session cleanup', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    expect(
      await ChromiumWebViewController.initialize(cachePath: cache.path),
      isTrue,
    );
    expect(
      await ChromiumWebViewController.initialize(cachePath: cache.path),
      isTrue,
    );
    expect((await diagnostics())['pumpRunning'], isTrue);

    for (int i = 0; i < 20; i++) {
      final controller = ChromiumWebViewController();
      await controller.createBrowser();
      await controller.updateBrowserSize(320, 200, i.isEven ? 1 : 2);
      await controller.loadRequest(
        'data:text/html,<input autofocus><p>Cycle $i</p>',
      );
      await controller.setFocus(true);
      expect((await diagnostics())['focused'], isTrue);
      await controller.setFocus(false);
      await controller.dispose().timeout(const Duration(seconds: 30));
      final state = await diagnostics();
      expect(state['browsers'], 0, reason: 'CEF browser leaked on cycle $i');
      expect(state['textures'], 0, reason: 'Texture leaked on cycle $i');
    }

    final pending = ChromiumWebViewController();
    final creating = pending.createBrowser();
    await pending.dispose().timeout(const Duration(seconds: 30));
    await creating;
    expect((await diagnostics())['browsers'], 0);

    final first = ChromiumWebViewController();
    final second = ChromiumWebViewController();
    await Future.wait([first.createBrowser(), second.createBrowser()]);
    expect((await diagnostics())['browsers'], 2);
    await first.setFocus(true);
    await second.setFocus(false);
    expect(
      (await diagnostics())['focused'],
      isTrue,
      reason: 'Another browser blur must not steal focus',
    );
    await second.dispose();
    expect(
      (await diagnostics())['focused'],
      isTrue,
      reason: 'Closing another browser must not steal focus',
    );

    // This is the same native transition as a fresh Dart isolate after restart.
    expect(
      await channel.invokeMethod<bool>('initialize', {
        'cachePath': cache.path,
        'sessionId': 'integration-restarted-isolate',
      }),
      isTrue,
    );
    final state = await diagnostics();
    expect(state['browsers'], 0);
    expect(state['textures'], 0);
    expect(state['focused'], isFalse);
    expect(state['pumpRunning'], isTrue);
    await first.dispose();

    final next = ChromiumWebViewController();
    await next.createBrowser();
    for (final url in ['', '   ']) {
      await expectLater(
        next.loadRequest(url),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'INVALID_URL',
          ),
        ),
      );
    }
    await next.dispose();
    expect((await diagnostics())['browsers'], 0);
  });
}
