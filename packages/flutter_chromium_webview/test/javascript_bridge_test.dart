import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var nextId = 0;
  final calls = <MethodCall>[];
  setUp(() {
    nextId = 0;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createBrowser') {
        return {
          'browserId': ++nextId,
          'textureId': nextId,
          'popupTextureId': 100 + nextId,
        };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    ChromiumWebViewController.resetTestingState();
  });
  Future<void> send(
    int browserId,
    String name,
    String origin,
    String message,
  ) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onBrowserEvent', {
          'browserId': browserId,
          'event': 'javascriptMessage',
          'args': {'channel': name, 'origin': origin, 'message': message},
        }),
      ),
      (_) {},
    );
  }

  test('channel policies reject unsafe origins and duplicate names', () {
    JavaScriptChannel make(String origin, {String name = 'player'}) =>
        JavaScriptChannel(
          name: name,
          allowedOrigins: {origin},
          onMessageReceived: (_) {},
        );
    for (final origin in [
      '*',
      'data:text/html,hello',
      'file:///tmp/page',
      'https://example.com/path',
      'https://user@example.com',
      'https://example.com?x=1',
    ]) {
      expect(() => make(origin), throwsArgumentError);
    }
    expect(() => make('https://example.com', name: 'x.y'), throwsArgumentError);
    expect(make('https://EXAMPLE.com:443/').allowedOrigins, {
      'https://example.com',
    });
    expect(
      () => ChromiumWebViewController(
        javaScriptChannels: [
          make('https://example.com'),
          make('https://example.com'),
        ],
      ),
      throwsArgumentError,
    );
  });
  test(
    'browser-scoped callbacks reject other channels, origins and oversized UTF8',
    () async {
      final received = <String>[];
      final config = JavaScriptChannel(
        name: 'player',
        allowedOrigins: {'https://example.com'},
        onMessageReceived: (value) => received.add(value.message),
      );
      final first = ChromiumWebViewController(javaScriptChannels: [config]);
      final second = ChromiumWebViewController();
      await first.createBrowser();
      await second.createBrowser();
      expect(
        jsonDecode(
          (calls.first.arguments as Map)['javascriptChannels'] as String,
        ),
        {
          'player': ['https://example.com'],
        },
      );
      await send(2, 'player', 'https://example.com', 'wrong browser');
      await send(1, 'other', 'https://example.com', 'wrong channel');
      await send(1, 'player', 'https://example.com.evil', 'wrong origin');
      await send(1, 'player', 'https://example.com', '🌍' * 16385);
      await send(1, 'player', 'https://example.com', 'hello 🌍');
      expect(received, ['hello 🌍']);
      await first.dispose();
      await send(1, 'player', 'https://example.com', 'after dispose');
      expect(received, ['hello 🌍']);
      await second.dispose();
    },
  );
  test(
    'evaluation correlates concurrent calls and returns structured errors',
    () async {
      final deferred = <String, Completer<Object?>>{};
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {
            'browserId': ++nextId,
            'textureId': nextId,
            'popupTextureId': 100 + nextId,
          };
        }
        if (call.method == 'evaluateJavaScript') {
          final args = call.arguments as Map;
          final pending = Completer<Object?>();
          deferred[args['js'] as String] = pending;
          return pending.future;
        }
        return null;
      });
      final first = ChromiumWebViewController();
      final second = ChromiumWebViewController();
      await first.createBrowser();
      await second.createBrowser();
      final a = first.evaluateJavaScript('slow');
      final b = second.evaluateJavaScript('fast');
      final failure = first.evaluateJavaScript('throw');
      final errorCheck = expectLater(
        failure,
        throwsA(
          isA<JavaScriptException>()
              .having((e) => e.code, 'code', 'javascript_exception')
              .having((e) => e.name, 'name', 'TypeError'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final requests = calls
          .where((c) => c.method == 'evaluateJavaScript')
          .map((c) => c.arguments as Map)
          .toList();
      expect(requests.map((a) => a['operationId']).toSet().length, 3);
      expect(requests.map((a) => a['browserId']), [1, 2, 1]);
      deferred['fast']!.complete({
        'list': [1, true, null],
      });
      deferred['throw']!.completeError(
        PlatformException(
          code: 'javascript_exception',
          message: 'boom',
          details: {'name': 'TypeError', 'stack': 'fixture stack'},
        ),
      );
      deferred['slow']!.complete('hello 🌍');
      expect(await b, {
        'list': [1, true, null],
      });
      expect(await a, 'hello 🌍');
      await errorCheck;
      await first.dispose();
      await second.dispose();
    },
  );

  test(
    'cancellation uses the operation and browser IDs and releases its listener',
    () async {
      final pending = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {
            'browserId': ++nextId,
            'textureId': nextId,
            'popupTextureId': 100 + nextId,
          };
        }
        if (call.method == 'evaluateJavaScript') return pending.future;
        if (call.method == 'cancelJavaScript') {
          pending.completeError(
            PlatformException(code: 'cancelled', message: 'Cancelled'),
          );
        }
        return null;
      });
      final controller = ChromiumWebViewController();
      await controller.createBrowser();
      final token = JavaScriptCancellationToken();
      final future = controller.evaluateJavaScript(
        'pending',
        cancellationToken: token,
      );
      final check = expectLater(
        future,
        throwsA(
          isA<JavaScriptException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await check;
      final request =
          calls.firstWhere((c) => c.method == 'evaluateJavaScript').arguments
              as Map;
      final cancel =
          calls.firstWhere((c) => c.method == 'cancelJavaScript').arguments
              as Map;
      expect(cancel, {
        'browserId': request['browserId'],
        'operationId': request['operationId'],
      });
      token.cancel();
      expect(calls.where((c) => c.method == 'cancelJavaScript').length, 1);
      final cancelled = JavaScriptCancellationToken()..cancel();
      await expectLater(
        controller.evaluateJavaScript(
          'never sent',
          cancellationToken: cancelled,
        ),
        throwsA(isA<JavaScriptException>()),
      );
      expect(calls.where((c) => c.method == 'evaluateJavaScript').length, 1);
      await controller.dispose();
    },
  );

  test(
    'stream accepts only configured channels and closes with the controller',
    () async {
      final controller = ChromiumWebViewController(
        javaScriptChannels: [
          JavaScriptChannel(
            name: 'player',
            allowedOrigins: {'https://example.com'},
            onMessageReceived: (_) {},
          ),
        ],
      );
      final values = <JavaScriptMessage>[];
      var closed = false;
      controller.onMessage.listen(values.add, onDone: () => closed = true);
      await controller.createBrowser();
      await send(1, 'player', 'https://example.com', 'accepted');
      await send(1, 'player', 'https://evil.example', 'rejected');
      await Future<void>.delayed(Duration.zero);
      expect(values.single.channel, 'player');
      expect(values.single.message, 'accepted');
      await controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isTrue);
      await expectLater(
        controller.evaluateJavaScript('1'),
        throwsA(
          isA<JavaScriptException>().having(
            (e) => e.code,
            'code',
            'browser_closed',
          ),
        ),
      );
      await expectLater(
        controller.evaluateJavaScript('1', timeout: Duration.zero),
        throwsArgumentError,
      );
    },
  );
}
