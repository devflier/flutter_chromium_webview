import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late List<FlutterErrorDetails> reportedErrors;
  late FlutterExceptionHandler? originalOnError;
  var nextBrowserId = 100;

  Future<void> emit(int browserId, String event, Object? args) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onBrowserEvent', {
          'browserId': browserId,
          'event': event,
          'args': args,
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<ChromiumWebViewController> createController({
    List<JavaScriptChannel> channels = const [],
    String? userAgent,
  }) async {
    final controller = ChromiumWebViewController(
      initialUrl: 'https://example.com',
      javaScriptChannels: channels,
      userAgent: userAgent,
    );
    await controller.createBrowser();
    return controller;
  }

  setUp(() {
    calls = [];
    reportedErrors = [];
    originalOnError = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createBrowser') {
        final id = nextBrowserId++;
        return {
          'browserId': id,
          'textureId': id + 1000,
          'popupTextureId': id + 2000,
        };
      }
      return null;
    });
  });

  tearDown(() {
    FlutterError.onError = originalOnError;
    messenger.setMockMethodCallHandler(channel, null);
    ChromiumWebViewController.resetTestingState();
  });

  group('well-formed events', () {
    test('update state and invoke callbacks', () async {
      final controller = await createController();
      final id = controller.browserId!;
      String? url;
      String? title;
      (bool, bool, bool)? loading;
      controller.onUrlChanged = (v) => url = v;
      controller.onTitleChanged = (v) => title = v;
      controller.onLoadingStateChanged = (a, b, c) => loading = (a, b, c);

      await emit(id, 'urlChanged', {'url': 'https://a.test/'});
      await emit(id, 'titleChanged', {'title': 'A'});
      await emit(id, 'loadingStateChanged', {
        'isLoading': true,
        'canGoBack': true,
        'canGoForward': false,
      });

      expect(controller.currentUrl, 'https://a.test/');
      expect(controller.pageTitle, 'A');
      expect(controller.isLoading, isTrue);
      expect(controller.canGoBack, isTrue);
      expect(controller.canGoForward, isFalse);
      expect(url, 'https://a.test/');
      expect(title, 'A');
      expect(loading, (true, true, false));
      await controller.dispose();
    });

    test('popup show and size update popup state', () async {
      final controller = await createController();
      final id = controller.browserId!;
      await emit(id, 'popupSize', {
        'x': 10,
        'y': 20,
        'width': 30,
        'height': 40,
      });
      await emit(id, 'popupShow', {'show': true});
      expect(controller.popupRect, const Rect.fromLTWH(10, 20, 30, 40));
      expect(controller.isPopupShowing, isTrue);
      await emit(id, 'popupShow', {'show': false});
      expect(controller.isPopupShowing, isFalse);
      await controller.dispose();
    });

    test('context menu items, including sub menus, are decoded', () async {
      final controller = await createController();
      final id = controller.browserId!;
      ContextMenuRequest? seen;
      controller.onContextMenuRequested = (request) async {
        seen = request;
        return 5;
      };
      await emit(id, 'contextMenuRequested', {
        'menuId': 3,
        'x': 1,
        'y': 2,
        'items': [
          {
            'commandId': 5,
            'label': 'Copy',
            'type': 0,
            'isEnabled': true,
            'isChecked': false,
            'subMenu': [
              {
                'commandId': 6,
                'label': 'More',
                'type': 0,
                'isEnabled': false,
                'isChecked': true,
              },
            ],
          },
        ],
      });
      expect(seen!.items.single.label, 'Copy');
      expect(seen!.items.single.subMenu!.single.commandId, 6);
      final close = calls.singleWhere((c) => c.method == 'closeContextMenu');
      expect(close.arguments, {'browserId': id, 'menuId': 3, 'commandId': 5});
      await controller.dispose();
    });
  });

  group('malformed events never crash and never change state', () {
    final malformed = <String, List<Map<Object?, Object?>>>{
      'urlChanged': [
        {},
        {'url': 1},
        {'url': null},
      ],
      'titleChanged': [
        {},
        {'title': <Object?>[]},
      ],
      'loadingStateChanged': [
        {},
        {'isLoading': true},
        {'isLoading': 'yes', 'canGoBack': false, 'canGoForward': false},
      ],
      'loadError': [
        {},
        {'errorCode': 'x', 'errorText': 't', 'failedUrl': 'u'},
        {'errorCode': 1, 'errorText': null, 'failedUrl': 'u'},
      ],
      'newWindowRequested': [
        {},
        {'url': 'u'},
        {
          'url': 'u',
          'targetFrameName': '',
          'targetDisposition': 'bad',
          'userGesture': true,
        },
      ],
      'popupShow': [
        {},
        {'show': 1},
      ],
      'popupSize': [
        {},
        {'x': 1, 'y': 2, 'width': 3},
        {'x': 1, 'y': 2, 'width': -3, 'height': 4},
        {'x': 'a', 'y': 2, 'width': 3, 'height': 4},
      ],
      'takeFocus': [
        {},
        {'next': 'true'},
      ],
      'javascriptMessage': [
        {},
        {'channel': 'app', 'message': 1, 'origin': 'https://a.test'},
        {'channel': 7, 'message': 'm', 'origin': 'https://a.test'},
        {'channel': 'app', 'message': 'm'},
      ],
    };

    for (final entry in malformed.entries) {
      test(entry.key, () async {
        var callbackCount = 0;
        final controller = await createController(
          channels: [
            JavaScriptChannel(
              name: 'app',
              allowedOrigins: {'https://a.test'},
              onMessageReceived: (_) => callbackCount++,
            ),
          ],
        );
        controller
          ..onUrlChanged = ((_) => callbackCount++)
          ..onTitleChanged = ((_) => callbackCount++)
          ..onLoadingStateChanged = ((_, _, _) => callbackCount++)
          ..onLoadError = ((_, _, _) => callbackCount++)
          ..onNewWindowRequested = ((_) => callbackCount++)
          ..onTakeFocus = ((_) => callbackCount++);
        final id = controller.browserId!;
        final urlBefore = controller.currentUrl;
        for (final args in entry.value) {
          await emit(id, entry.key, args);
        }
        expect(callbackCount, 0);
        expect(reportedErrors, isEmpty);
        expect(controller.currentUrl, urlBefore);
        expect(controller.pageTitle, '');
        expect(controller.isLoading, isFalse);
        expect(controller.isPopupShowing, isFalse);
        expect(controller.popupRect, Rect.zero);
        await controller.dispose();
      });
    }

    test('non-map event arguments are ignored', () async {
      final controller = await createController();
      await emit(controller.browserId!, 'urlChanged', 'not a map');
      await emit(controller.browserId!, 'urlChanged', null);
      await emit(controller.browserId!, 'unknownEvent', {'a': 1});
      expect(reportedErrors, isEmpty);
      expect(controller.currentUrl, 'https://example.com');
      await controller.dispose();
    });

    test('malformed jsDialog is still resolved natively', () async {
      final controller = await createController();
      final id = controller.browserId!;
      var shown = false;
      controller.onJSDialog = (_) async {
        shown = true;
        return const JSDialogResponse(success: true);
      };
      await emit(id, 'jsDialog', {
        'dialogId': 4,
        'type': 99,
        'message': 'm',
        'defaultPrompt': '',
      });
      await emit(id, 'jsDialog', {
        'dialogId': 5,
        'type': 0,
        'message': null,
        'defaultPrompt': '',
      });
      // No dialog id: nothing can be resolved, but nothing may throw either.
      await emit(id, 'jsDialog', {'type': 0});
      await Future<void>.delayed(Duration.zero);
      expect(shown, isFalse);
      final closes = calls.where((c) => c.method == 'closeJSDialog').toList();
      expect(closes.map((c) => (c.arguments as Map)['dialogId']), [4, 5]);
      expect(
        closes.every((c) => (c.arguments as Map)['success'] == false),
        isTrue,
      );
      expect(reportedErrors, isEmpty);
      await controller.dispose();
    });

    test('malformed context menus are dismissed with -1', () async {
      final controller = await createController();
      final id = controller.browserId!;
      var shown = false;
      controller.onContextMenuRequested = (_) async {
        shown = true;
        return 1;
      };
      final goodItem = {
        'commandId': 1,
        'label': 'x',
        'type': 0,
        'isEnabled': true,
        'isChecked': false,
      };
      await emit(id, 'contextMenuRequested', {
        'menuId': 1,
        'x': 0,
        'y': 0,
        'items': 'nope',
      });
      await emit(id, 'contextMenuRequested', {
        'menuId': 2,
        'x': 0,
        'y': 0,
        'items': [
          goodItem,
          {'commandId': 'bad'},
        ],
      });
      await emit(id, 'contextMenuRequested', {
        'menuId': 3,
        'x': 0,
        'y': 0,
        'items': [
          {
            ...goodItem,
            'subMenu': [42],
          },
        ],
      });
      await emit(id, 'contextMenuRequested', {
        'menuId': 4,
        'x': 'left',
        'y': 0,
        'items': [goodItem],
      });
      await emit(id, 'contextMenuRequested', {'x': 0, 'y': 0, 'items': []});
      await Future<void>.delayed(Duration.zero);
      expect(shown, isFalse);
      final closes = calls
          .where((c) => c.method == 'closeContextMenu')
          .toList();
      expect(closes.map((c) => (c.arguments as Map)['menuId']), [1, 2, 3, 4]);
      expect(
        closes.every((c) => (c.arguments as Map)['commandId'] == -1),
        isTrue,
      );
      expect(reportedErrors, isEmpty);
      await controller.dispose();
    });

    test('excessively nested context menus are rejected', () async {
      final controller = await createController();
      Map<String, Object?> nest(int depth) => {
        'commandId': depth,
        'label': 'x',
        'type': 0,
        'isEnabled': true,
        'isChecked': false,
        if (depth > 0) 'subMenu': [nest(depth - 1)],
      };
      var shown = false;
      controller.onContextMenuRequested = (_) async {
        shown = true;
        return 1;
      };
      await emit(controller.browserId!, 'contextMenuRequested', {
        'menuId': 9,
        'x': 0,
        'y': 0,
        'items': [nest(50)],
      });
      expect(shown, isFalse);
      expect(calls.where((c) => c.method == 'closeContextMenu'), hasLength(1));
      await controller.dispose();
    });

    test(
      'exceptions thrown by user callbacks are reported, not thrown',
      () async {
        final controller = await createController();
        controller.onUrlChanged = (_) => throw StateError('app bug');
        await emit(controller.browserId!, 'urlChanged', {
          'url': 'https://b.test',
        });
        expect(reportedErrors, hasLength(1));
        expect(reportedErrors.single.exception, isA<StateError>());
        // The controller keeps working afterwards.
        controller.onUrlChanged = null;
        await emit(controller.browserId!, 'urlChanged', {
          'url': 'https://c.test',
        });
        expect(controller.currentUrl, 'https://c.test');
        await controller.dispose();
      },
    );
  });

  group('JavaScript messages', () {
    test('deliver only for allowed channel and origin', () async {
      final received = <String>[];
      final controller = await createController(
        channels: [
          JavaScriptChannel(
            name: 'app',
            allowedOrigins: {'https://a.test'},
            onMessageReceived: (m) => received.add('${m.origin}|${m.message}'),
          ),
        ],
      );
      final id = controller.browserId!;
      await emit(id, 'javascriptMessage', {
        'channel': 'app',
        'message': 'hi',
        'origin': 'https://a.test',
      });
      await emit(id, 'javascriptMessage', {
        'channel': 'app',
        'message': 'evil',
        'origin': 'https://evil.test',
      });
      await emit(id, 'javascriptMessage', {
        'channel': 'other',
        'message': 'x',
        'origin': 'https://a.test',
      });
      await emit(id, 'javascriptMessage', {
        'channel': 'app',
        'message': 'x' * 70000,
        'origin': 'https://a.test',
      });
      expect(received, ['https://a.test|hi']);
      await controller.dispose();
    });
  });

  group('multiple controllers', () {
    test('events are routed per browser and disposal is independent', () async {
      final first = await createController();
      final second = await createController();
      expect(first.browserId, isNot(second.browserId));
      expect(first.textureId, isNot(second.textureId));

      await emit(first.browserId!, 'urlChanged', {'url': 'https://one.test'});
      await emit(second.browserId!, 'urlChanged', {'url': 'https://two.test'});
      expect(first.currentUrl, 'https://one.test');
      expect(second.currentUrl, 'https://two.test');

      final firstId = first.browserId!;
      await first.dispose();
      await emit(firstId, 'urlChanged', {'url': 'https://late.test'});
      expect(first.currentUrl, 'https://one.test');
      await emit(second.browserId!, 'titleChanged', {'title': 'still alive'});
      expect(second.pageTitle, 'still alive');
      expect(first.browserId, isNull);
      expect(first.textureId, isNull);
      final secondId = second.browserId!;
      await second.dispose();
      expect(
        calls
            .where((c) => c.method == 'disposeBrowser')
            .map((c) => (c.arguments as Map)['browserId']),
        [firstId, secondId],
      );
    });

    test('random disposal order disposes every browser exactly once', () async {
      final controllers = [
        for (var i = 0; i < 6; i++) await createController(),
      ];
      final ids = controllers.map((c) => c.browserId!).toSet();
      expect(ids, hasLength(6));
      final order = [3, 0, 5, 1, 4, 2];
      await Future.wait([for (final i in order) controllers[i].dispose()]);
      // Double dispose is a no-op.
      await Future.wait([for (final c in controllers) c.dispose()]);
      final disposed = calls
          .where((c) => c.method == 'disposeBrowser')
          .map((c) => (c.arguments as Map)['browserId'] as int)
          .toList();
      expect(disposed, hasLength(6));
      expect(disposed.toSet(), ids);
    });

    test('events that arrive before creation returns are replayed', () async {
      final created = Completer<Map<String, int>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') return created.future;
        return null;
      });
      final controller = ChromiumWebViewController(
        initialUrl: 'https://example.com',
      );
      final creation = controller.createBrowser();
      await Future<void>.delayed(Duration.zero);
      await emit(55, 'titleChanged', {'title': 'early'});
      created.complete({'browserId': 55, 'textureId': 1, 'popupTextureId': 2});
      await creation;
      expect(controller.pageTitle, 'early');
      await controller.dispose();
    });
  });

  group('lifecycle failures', () {
    test(
      'creation failure leaves the controller disposable and retryable',
      () async {
        var fail = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createBrowser') {
            if (fail) throw PlatformException(code: 'CEF_NOT_INITIALIZED');
            return {'browserId': 1, 'textureId': 2, 'popupTextureId': 3};
          }
          return null;
        });
        final controller = ChromiumWebViewController();
        await expectLater(
          controller.createBrowser(),
          throwsA(isA<PlatformException>()),
        );
        expect(controller.textureId, isNull);
        // Operations before a browser exists are silently ignored.
        await controller.loadRequest('https://example.com');
        await controller.reload();
        expect(calls.where((c) => c.method == 'loadRequest'), isEmpty);

        fail = false;
        await controller.createBrowser();
        expect(controller.browserId, 1);
        await controller.dispose();
        expect(calls.where((c) => c.method == 'disposeBrowser'), hasLength(1));
      },
    );

    test(
      'disposing after a failed creation never calls native dispose',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createBrowser') {
            throw PlatformException(code: 'FAIL');
          }
          return null;
        });
        final controller = ChromiumWebViewController();
        final creation = controller.createBrowser();
        final creationResult = expectLater(
          creation,
          throwsA(isA<PlatformException>()),
        );
        await controller.dispose();
        await creationResult;
        expect(calls.where((c) => c.method == 'disposeBrowser'), isEmpty);
      },
    );

    test('a malformed creation result is reported as an exception', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') return {'browserId': 'x'};
        return null;
      });
      final controller = ChromiumWebViewController();
      await expectLater(controller.createBrowser(), throwsA(anything));
      expect(controller.textureId, isNull);
      await controller.dispose();
    });

    test('a failure applying the user agent tears the browser down', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createBrowser') {
          return {'browserId': 9, 'textureId': 1, 'popupTextureId': 2};
        }
        if (call.method == 'setUserAgent') {
          throw PlatformException(code: 'FAIL');
        }
        return null;
      });
      final controller = ChromiumWebViewController(userAgent: 'Test/1.0');
      await expectLater(
        controller.createBrowser(),
        throwsA(isA<PlatformException>()),
      );
      expect(controller.browserId, isNull);
      expect(
        calls.where((c) => c.method == 'disposeBrowser').single.arguments,
        {'browserId': 9},
      );
    });

    test(
      'a native error while disposing surfaces to the caller once',
      () async {
        final controller = await createController();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'disposeBrowser') {
            throw PlatformException(code: 'FAIL');
          }
          return null;
        });
        final first = controller.dispose();
        final second = controller.dispose();
        expect(identical(first, second), isTrue);
        await expectLater(first, throwsA(isA<PlatformException>()));
      },
    );

    test('rapid create/dispose cycles do not leak controllers', () async {
      for (var i = 0; i < 50; i++) {
        final controller = ChromiumWebViewController();
        final creation = controller.createBrowser();
        final disposal = controller.dispose();
        await creation;
        await disposal;
        expect(controller.textureId, isNull);
      }
      final created = calls.where((c) => c.method == 'createBrowser').length;
      final disposed = calls.where((c) => c.method == 'disposeBrowser').length;
      expect(created, 50);
      expect(disposed, 50);
    });

    test(
      'initialize forwards the cache path and a stable session id',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        expect(
          await ChromiumWebViewController.initialize(cachePath: '/c'),
          true,
        );
        expect(
          await ChromiumWebViewController.initialize(cachePath: '/c'),
          true,
        );
        final ids = calls.map((c) => (c.arguments as Map)['sessionId']).toSet();
        expect(ids, hasLength(1));
      },
    );
  });

  group('pointer API', () {
    test('typed API sends the enum to the platform', () async {
      final controller = await createController();
      await controller.sendPointerInput(
        type: PointerInputType.wheel,
        x: 1,
        y: 2,
        deltaY: 3,
      );
      final call = calls.singleWhere((c) => c.method == 'sendPointerEvent');
      expect((call.arguments as Map)['type'], PointerInputType.wheel.index);
      await controller.dispose();
    });

    test('deprecated int API validates its argument', () async {
      final controller = await createController();
      // ignore: deprecated_member_use_from_same_package
      expect(
        () => controller.sendPointerEvent(type: 99, x: 0, y: 0),
        throwsRangeError,
      );
      // ignore: deprecated_member_use_from_same_package
      expect(
        () => controller.sendPointerEvent(type: -1, x: 0, y: 0),
        throwsRangeError,
      );
      // ignore: deprecated_member_use_from_same_package
      await controller.sendPointerEvent(type: 2, x: 5, y: 6);
      final call = calls.singleWhere((c) => c.method == 'sendPointerEvent');
      expect((call.arguments as Map)['type'], PointerInputType.move.index);
      await controller.dispose();
    });

    test('input after disposal is ignored', () async {
      final controller = await createController();
      await controller.dispose();
      await controller.sendPointerInput(
        type: PointerInputType.move,
        x: 0,
        y: 0,
      );
      expect(calls.where((c) => c.method == 'sendPointerEvent'), isEmpty);
    });
  });
}
