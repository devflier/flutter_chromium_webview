import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    ChromiumWebViewController.resetTestingState();
  });
  test(
    'rejects opaque, credentialed, fragmented URLs and oversized UTF8',
    () async {
      final controller = ChromiumWebViewController();
      for (final url in [
        '',
        '/relative',
        'file:///page.html',
        'data:text/html,x',
        'https://user@example.com/page',
        'https://example.com/#fragment',
        ' https://example.com/',
      ]) {
        await expectLater(
          controller.loadHtmlString('', baseUrl: url),
          throwsArgumentError,
        );
      }
      await expectLater(
        controller.loadHtmlString(
          '🌍' * (1024 * 1024 + 1),
          baseUrl: 'https://example.com/page',
        ),
        throwsArgumentError,
      );
      await controller.dispose();
    },
  );
  test(
    'sends HTML without rewriting, dismisses transient UI, suppresses after disposal',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {'browserId': 7, 'textureId': 8, 'popupTextureId': 9};
        }
        return null;
      });
      final controller = ChromiumWebViewController();
      var dismissed = 0;
      controller.onTransientUiDismissed = () => dismissed++;
      await controller.createBrowser();
      const html = '<title>Olá 🌍</title>';
      await controller.loadHtmlString(
        html,
        baseUrl: 'https://example.com/player/index.html?q=1',
      );
      expect(calls.last.method, 'loadHtmlString');
      expect(calls.last.arguments, {
        'browserId': 7,
        'html': html,
        'baseUrl': 'https://example.com/player/index.html?q=1',
      });
      expect(dismissed, 1);
      await controller.loadHtmlString('', baseUrl: 'https://example.com/empty');
      expect((calls.last.arguments as Map)['html'], '');
      await controller.dispose();
      final count = calls.length;
      await controller.loadHtmlString(html, baseUrl: 'https://example.com/');
      expect(calls.length, count);
    },
  );
}
