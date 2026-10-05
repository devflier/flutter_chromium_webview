import 'dart:async';

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
    'platform-view browser creation is idempotent without texture IDs',
    () async {
      var created = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'createBrowser') {
          created++;
          return {'browserId': 9, 'textureId': -1, 'popupTextureId': -1};
        }
        return null;
      });
      final controller = ChromiumWebViewController();
      await controller.createBrowser();
      await controller.createBrowser();
      expect(created, 1);
      expect(controller.browserId, 9);
      expect(controller.textureId, isNull);
      await controller.dispose();
    },
  );

  test(
    'concurrent creation and disposal wait for native close exactly once',
    () async {
      final created = Completer<Map<String, int>>();
      final closed = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') return created.future;
        if (call.method == 'disposeBrowser') await closed.future;
        return null;
      });
      final controller = ChromiumWebViewController();
      final firstCreation = controller.createBrowser();
      final secondCreation = controller.createBrowser();
      final disposal = controller.dispose();
      expect(identical(disposal, controller.dispose()), isTrue);
      var disposed = false;
      disposal.then((_) => disposed = true);
      created.complete({'browserId': 7, 'textureId': 11, 'popupTextureId': 22});
      await Future.wait([firstCreation, secondCreation]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.textureId, isNull);
      expect(disposed, isFalse);
      expect(
        calls.where((call) => call.method == 'createBrowser'),
        hasLength(1),
      );
      expect(
        calls.where((call) => call.method == 'disposeBrowser'),
        hasLength(1),
      );
      closed.complete();
      await disposal;
      await controller.loadRequest('https://example.com');
      expect(calls.where((call) => call.method == 'loadRequest'), isEmpty);
    },
  );
}
