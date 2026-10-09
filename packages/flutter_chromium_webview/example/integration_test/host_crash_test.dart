import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    // Manual pumps must finish even when macOS throttles a background window.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  }

  testWidgets('Host crash recovers correctly and releases resources', (
    tester,
  ) async {
    final cachePath = Directory.systemTemp
        .createTempSync('cef_crash_test')
        .path;
    // Run 20 cycles
    for (int i = 0; i < 20; i++) {
      debugPrint('--- Cycle $i ---');

      await ChromiumWebViewController.initialize(cachePath: cachePath);

      final controller = ChromiumWebViewController(
        initialUrl: 'https://example.com',
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ChromiumWebView(controller: controller),
        ),
      );

      // Wait until it's loaded
      final completer = Completer<void>();
      controller.onLoadingStateChanged = (isLoading, _, _) {
        if (!isLoading && !completer.isCompleted) {
          completer.complete();
        }
      };
      if (!controller.isLoading && controller.pageTitle.isNotEmpty) {
        completer.complete();
      }
      await completer.future.timeout(const Duration(seconds: 30));

      // Let it render some frames
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      final browserId = controller.browserId;
      final textureId = controller.textureId;
      expect(browserId, isNotNull);
      expect(textureId, isNotNull);

      // Issue some concurrent activity
      Object? evalError;
      final pendingEval = controller
          .evaluateJavaScript('new Promise(r => setTimeout(r, 10000))')
          .catchError((e) {
            evalError = e;
            return null;
          });
      controller
          .executeJavaScript('document.body.style.backgroundColor = "red";')
          .catchError((_) {});

      // Now brutally kill the host
      const channel = MethodChannel('flutter_chromium_webview');
      final render = await channel.invokeMapMethod<String, dynamic>(
        'getRenderDiagnostics',
        {'browserId': browserId},
      );
      final hostPid = render!['hostPid'] as int;
      final result = await Process.run('kill', ['-KILL', '$hostPid']);
      expect(result.exitCode, 0, reason: '${result.stderr}');

      // The pending eval MUST fail.
      await pendingEval;
      expect(evalError, isA<JavaScriptException>());

      // The controller should be dead now, we should check if subsequent actions fail safely
      try {
        await controller.loadRequest('https://google.com');
      } catch (_) {}

      // Clean up controller for the next cycle
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      try {
        await controller.dispose();
      } catch (_) {}

      // The texture id and browser id should be null now
      expect(controller.textureId, isNull);
      expect(controller.browserId, isNull);
    }
  });
}
