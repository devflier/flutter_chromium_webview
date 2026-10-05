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
  test('rejects invalid user-agent strings before browser creation', () {
    for (final value in ['', 'x\r\nInjected: y', 'Olá', 'x' * 4097]) {
      expect(
        () => ChromiumWebViewController(userAgent: value),
        throwsArgumentError,
      );
    }
  });
  test(
    'waits for user-agent acknowledgement before initial navigation',
    () async {
      final configured = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {'browserId': 1, 'textureId': 2, 'popupTextureId': 3};
        }
        if (call.method == 'setUserAgent') await configured.future;
        return null;
      });
      final controller = ChromiumWebViewController(
        initialUrl: 'https://example.com/',
        userAgent: 'ppplayer/1.0',
        mediaPlaybackRequiresUserGesture: false,
      );
      final creating = controller.createBrowser();
      await Future<void>.delayed(Duration.zero);
      expect((calls.first.arguments as Map)['initialUrl'], 'about:blank');
      expect(
        (calls.first.arguments as Map)['mediaPlaybackRequiresUserGesture'],
        false,
      );
      expect(calls.map((call) => call.method), [
        'createBrowser',
        'setUserAgent',
      ]);
      configured.complete();
      await creating;
      expect(calls.last.method, 'loadRequest');
      expect((calls.last.arguments as Map)['url'], 'https://example.com/');
      await controller.dispose();
    },
  );
  test('failed settings close the created browser and permit retry', () async {
    var fail = true;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createBrowser') {
        return {'browserId': 1, 'textureId': 2, 'popupTextureId': 3};
      }
      if (call.method == 'setUserAgent' && fail) {
        throw PlatformException(code: 'SETTINGS_FAILED');
      }
      return null;
    });
    final controller = ChromiumWebViewController(userAgent: 'ppplayer/1.0');
    await expectLater(
      controller.createBrowser(),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.textureId, isNull);
    expect(calls.last.method, 'disposeBrowser');
    fail = false;
    await controller.createBrowser();
    expect(controller.textureId, 2);
    await controller.dispose();
  });
  test(
    'disposal during settings waits then closes without initial navigation',
    () async {
      final configured = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {'browserId': 1, 'textureId': 2, 'popupTextureId': 3};
        }
        if (call.method == 'setUserAgent') await configured.future;
        return null;
      });
      final controller = ChromiumWebViewController(userAgent: 'ppplayer/1.0');
      final creating = controller.createBrowser();
      await Future<void>.delayed(Duration.zero);
      final disposing = controller.dispose();
      configured.complete();
      await creating;
      await disposing;
      expect(calls.map((call) => call.method), [
        'createBrowser',
        'setUserAgent',
        'disposeBrowser',
      ]);
      expect(controller.browserId, isNull);
    },
  );
}
