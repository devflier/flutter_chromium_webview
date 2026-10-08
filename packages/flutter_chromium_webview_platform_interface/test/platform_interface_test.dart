import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview_platform_interface/flutter_chromium_webview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePlatform extends ChromiumWebViewPlatform {
  final List<String> calls = <String>[];
  final StreamController<BrowserEvent> controller =
      StreamController<BrowserEvent>.broadcast();

  @override
  Stream<BrowserEvent> get events => controller.stream;

  @override
  Future<void> reload(int browserId) async => calls.add('reload:$browserId');
}

class _ImplementsOnly extends Mock implements ChromiumWebViewPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MixinMock extends _FakePlatform with MockPlatformInterfaceMixin {}

class Mock extends PlatformInterface {
  Mock() : super(token: Object());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('flutter_chromium_webview');
  final original = ChromiumWebViewPlatform.instance;

  tearDown(() {
    ChromiumWebViewPlatform.instance = original;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('instance registration', () {
    test('defaults to the method channel implementation', () {
      expect(original, isA<MethodChannelChromiumWebView>());
    });

    test('accepts an implementation that extends the interface', () {
      final fake = _FakePlatform();
      ChromiumWebViewPlatform.instance = fake;
      expect(ChromiumWebViewPlatform.instance, same(fake));
    });

    test('accepts a mock using MockPlatformInterfaceMixin', () {
      final mock = _MixinMock();
      ChromiumWebViewPlatform.instance = mock;
      expect(ChromiumWebViewPlatform.instance, same(mock));
    });

    test('rejects an implementation that only implements it', () {
      expect(
        () => ChromiumWebViewPlatform.instance = _ImplementsOnly(),
        throwsA(anything),
      );
      expect(ChromiumWebViewPlatform.instance, same(original));
    });
  });

  group('fake implementation', () {
    test('overridden methods work, others throw UnimplementedError', () async {
      final fake = _FakePlatform();
      await fake.reload(3);
      expect(fake.calls, ['reload:3']);
      expect(() => fake.goBack(3), throwsUnimplementedError);
      expect(
        () => fake.createBrowser(const BrowserCreationParams(initialUrl: 'a')),
        throwsUnimplementedError,
      );
    });

    test('base class exposes no events by default', () {
      expect(() => _BareProbe().events, throwsUnimplementedError);
    });
  });

  group('shared models', () {
    test('BrowserCreationParams defaults', () {
      const params = BrowserCreationParams(initialUrl: 'about:blank');
      expect(params.mediaPlaybackRequiresUserGesture, isTrue);
      expect(params.javaScriptChannels, isEmpty);
    });

    test('PointerInputType indices match the native protocol', () {
      expect(PointerInputType.values.map((e) => e.index), [0, 1, 2, 3, 4]);
      expect(PointerInputType.leave.index, 4);
    });

    test('BrowserEvent defaults to empty arguments', () {
      const event = BrowserEvent(browserId: 1, name: 'x');
      expect(event.arguments, isEmpty);
    });

    test('exception string', () {
      expect(
        const ChromiumWebViewException('boom').toString(),
        contains('boom'),
      );
    });
  });

  group('MethodChannelChromiumWebView', () {
    late MethodChannelChromiumWebView platform;
    late List<MethodCall> log;

    setUp(() {
      platform = MethodChannelChromiumWebView();
      log = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        if (call.method == 'createBrowser') {
          return <Object?, Object?>{
            'browserId': 7,
            'textureId': 8,
            'popupTextureId': 9,
          };
        }
        if (call.method == 'initialize') return true;
        return null;
      });
    });

    test('initialize forwards arguments', () async {
      expect(
        await platform.initialize(cachePath: '/c', sessionId: 's'),
        isTrue,
      );
      expect(log.single.arguments, {'cachePath': '/c', 'sessionId': 's'});
    });

    test('createBrowser returns identifiers', () async {
      final result = await platform.createBrowser(
        const BrowserCreationParams(
          initialUrl: 'https://flutter.dev',
          javaScriptChannels: {
            'app': ['https://flutter.dev'],
          },
        ),
      );
      expect(result.browserId, 7);
      expect(result.textureId, 8);
      expect(result.popupTextureId, 9);
      final args = log.single.arguments as Map;
      expect(args['initialUrl'], 'https://flutter.dev');
      expect(args['javascriptChannels'], '{"app":["https://flutter.dev"]}');
    });

    test('createBrowser throws when native returns nothing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(
        () => platform.createBrowser(
          const BrowserCreationParams(initialUrl: 'a'),
        ),
        throwsA(isA<ChromiumWebViewException>()),
      );
    });

    test(
      'navigation, script and resize calls use native method names',
      () async {
        await platform.loadUrl(1, 'u');
        await platform.loadHtml(1, '<p/>', 'https://a');
        await platform.reload(1);
        await platform.goBack(1);
        await platform.goForward(1);
        await platform.executeJavaScript(1, '1+1');
        await platform.resize(1, 10, 20, 2);
        await platform.setFocus(1, true);
        await platform.disposeBrowser(1);
        expect(log.map((c) => c.method), [
          'loadRequest',
          'loadHtmlString',
          'reload',
          'goBack',
          'goForward',
          'executeJavaScript',
          'updateBrowserSize',
          'setFocus',
          'disposeBrowser',
        ]);
        expect(
          log.every((c) => (c.arguments as Map)['browserId'] == 1),
          isTrue,
        );
        expect((log[6].arguments as Map)['dpr'], 2);
      },
    );

    test('pointer input maps to the native protocol', () async {
      await platform.sendPointerInput(
        4,
        const PointerInput(
          type: PointerInputType.wheel,
          x: 1,
          y: 2,
          deltaY: -3,
        ),
      );
      expect(log.single.method, 'sendPointerEvent');
      expect(log.single.arguments, {
        'browserId': 4,
        'x': 1,
        'y': 2,
        'type': 3,
        'button': 0,
        'clickCount': 1,
        'deltaX': 0,
        'deltaY': -3,
        'modifiers': 0,
      });
    });

    test('dialog and menu responses', () async {
      await platform.closeJavaScriptDialog(1, 2, success: true, userInput: 'x');
      await platform.closeContextMenu(1, 3, -1);
      expect(log[0].method, 'closeJSDialog');
      expect((log[0].arguments as Map)['userInput'], 'x');
      expect(log[1].method, 'closeContextMenu');
      expect((log[1].arguments as Map)['commandId'], -1);
    });

    test('native errors surface as PlatformException', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'FAIL');
      });
      expect(() => platform.reload(1), throwsA(isA<PlatformException>()));
    });

    test(
      'events stream decodes onBrowserEvent and ignores malformed',
      () async {
        final received = <BrowserEvent>[];
        final sub = platform.events.listen(received.add);
        Future<void> send(Object? args, [String method = 'onBrowserEvent']) =>
            messenger.handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, args),
              ),
              (_) {},
            );
        await send({
          'browserId': 5,
          'event': 'urlChanged',
          'args': {'url': 'u'},
        });
        await send({'browserId': 'bad', 'event': 'x'});
        await send('nope');
        await send({'browserId': 5, 'event': 'x'}, 'other');
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        expect(received, hasLength(1));
        expect(received.single.browserId, 5);
        expect(received.single.name, 'urlChanged');
        expect(received.single.arguments['url'], 'u');
      },
    );
  });
}

class _BareProbe extends ChromiumWebViewPlatform {}
