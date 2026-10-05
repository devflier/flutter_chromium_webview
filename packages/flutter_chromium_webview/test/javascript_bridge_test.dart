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
  test('browser-scoped callbacks reject other channels, origins and oversized UTF8', () async {
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
  });
}
