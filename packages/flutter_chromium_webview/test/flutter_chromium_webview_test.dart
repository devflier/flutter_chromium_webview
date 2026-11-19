import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> log;
  int nextBrowserId = 1;

  setUp(() {
    ChromiumWebViewController.resetTestingState();
    nextBrowserId = 1;
    log = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_chromium_webview'),
          (MethodCall methodCall) async {
            log.add(methodCall);
            if (methodCall.method == 'createBrowser') {
              final id = nextBrowserId++;
              return {
                'browserId': id,
                'textureId': 100 + id,
                'popupTextureId': 200 + id,
              };
            }
            return null;
          },
        );
  });

  Future<void> sendNativeEvent(
    int browserId,
    String event,
    Map<String, dynamic> args,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter_chromium_webview',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onBrowserEvent', {
              'browserId': browserId,
              'event': event,
              'args': args,
            }),
          ),
          (ByteData? data) {},
        );
    await Future.microtask(() {});
  }

  testWidgets(
    'host transient UI is dismissed on native cancellation, navigation and disposal',
    (tester) async {
      final controller = ChromiumWebViewController();
      await controller.createBrowser();
      var dismissals = 0;
      controller.onTransientUiDismissed = () => dismissals++;
      await sendNativeEvent(1, 'transientUiDismissed', {});
      expect(dismissals, 1);
      await controller.loadRequest('about:blank');
      expect(dismissals, 2);
      await controller.dispose();
      expect(dismissals, 3);
      await controller.dispose();
      expect(dismissals, 3);
    },
  );

  testWidgets('Event routing between multiple controllers', (tester) async {
    final controller1 = ChromiumWebViewController();
    final controller2 = ChromiumWebViewController();

    await controller1.createBrowser();
    await controller2.createBrowser();

    String url1 = '';
    String url2 = '';
    controller1.onUrlChanged = (url) => url1 = url;
    controller2.onUrlChanged = (url) => url2 = url;

    await sendNativeEvent(1, 'urlChanged', {'url': 'https://one.com'});
    await sendNativeEvent(2, 'urlChanged', {'url': 'https://two.com'});
    await tester.pump();

    expect(url1, 'https://one.com');
    expect(url2, 'https://two.com');
  });

  testWidgets('URL and title updates', (tester) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();

    await sendNativeEvent(1, 'urlChanged', {'url': 'https://flutter.dev'});
    await sendNativeEvent(1, 'titleChanged', {'title': 'Flutter'});
    await tester.pump();

    expect(controller.currentUrl, 'https://flutter.dev');
    expect(controller.pageTitle, 'Flutter');
  });

  testWidgets('Loading-state transitions', (tester) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();

    bool notified = false;
    controller.addListener(() {
      notified = true;
    });

    await sendNativeEvent(1, 'loadingStateChanged', {
      'isLoading': true,
      'canGoBack': false,
      'canGoForward': false,
    });
    await tester.pump();

    expect(controller.isLoading, true);
    expect(controller.canGoBack, false);
    expect(controller.canGoForward, false);
    expect(notified, true);
  });

  testWidgets('Main-frame navigation errors', (tester) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();

    int lastErrorCode = 0;
    controller.onLoadError = (errorCode, errorText, failedUrl) {
      lastErrorCode = errorCode;
    };

    await sendNativeEvent(1, 'loadError', {
      'errorCode': -102,
      'errorText': 'CONNECTION_REFUSED',
      'failedUrl': 'https://bad.com',
    });
    await tester.pump();

    expect(lastErrorCode, -102);
  });

  testWidgets('Events arriving after disposal', (tester) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();

    await controller.dispose();

    String? newUrl;
    controller.onUrlChanged = (url) => newUrl = url;

    await sendNativeEvent(1, 'urlChanged', {
      'url': 'https://after-dispose.com',
    });
    await tester.pump();

    expect(newUrl, null);
  });

  testWidgets('Events emitted during browser initialization', (tester) async {
    final controller = ChromiumWebViewController();
    final created = Completer<Map<String, int>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_chromium_webview'),
          (call) async =>
              call.method == 'createBrowser' ? created.future : null,
        );
    String? notifiedUrl;
    controller.onUrlChanged = (url) => notifiedUrl = url;
    final creation = controller.createBrowser();

    // Simulate an event arriving before createBrowser completes
    await sendNativeEvent(1, 'urlChanged', {'url': 'https://early.com'});
    await tester.pump();

    created.complete({'browserId': 1, 'textureId': 101, 'popupTextureId': 201});
    await creation;
    await tester.pump();

    expect(controller.currentUrl, 'https://early.com');
    expect(notifiedUrl, 'https://early.com');
  });

  testWidgets('Synchronous dialog exceptions cancel native request', (
    tester,
  ) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();
    controller.onJSDialog = (_) => throw StateError('Host dialog failed');
    await sendNativeEvent(1, 'jsDialog', {
      'dialogId': 9,
      'type': 0,
      'message': 'test',
      'defaultPrompt': '',
    });
    await tester.pump();
    expect(log.lastWhere((c) => c.method == 'closeJSDialog').arguments, {
      'browserId': 1,
      'dialogId': 9,
      'success': false,
      'userInput': '',
    });
    await controller.dispose();
  });

  testWidgets('Pending dialog response is ignored after disposal', (
    tester,
  ) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();
    final response = Completer<JSDialogResponse>();
    controller.onJSDialog = (_) => response.future;
    await sendNativeEvent(1, 'jsDialog', {
      'dialogId': 10,
      'type': 1,
      'message': 'test',
      'defaultPrompt': '',
    });
    await controller.dispose();
    response.complete(const JSDialogResponse(success: true));
    await tester.pump();
    expect(log.where((c) => c.method == 'closeJSDialog'), isEmpty);
  });

  testWidgets('New window requests are routed correctly', (tester) async {
    final controller = ChromiumWebViewController();
    await controller.createBrowser();

    NewWindowRequest? lastRequest;
    controller.onNewWindowRequested = (request) {
      lastRequest = request;
    };

    await sendNativeEvent(1, 'newWindowRequested', {
      'url': 'https://target.com',
      'targetFrameName': '_blank',
      'targetDisposition': 1, // CEF NEW_FOREGROUND_TAB
      'userGesture': true,
    });
    await tester.pump();

    expect(lastRequest, isNotNull);
    expect(lastRequest!.url, 'https://target.com');
    expect(lastRequest!.targetFrameName, '_blank');
    expect(lastRequest!.targetDisposition, 1);
    expect(lastRequest!.userGesture, true);
    expect(lastRequest!.sourceBrowserId, 1);
  });

  testWidgets('Generation change forces resize and focus despite reused IDs', (
    tester,
  ) async {
    ChromiumWebViewController.resetTestingState();

    int mockedTextureId = 123;
    int mockedBrowserId = 1;
    int createCalls = 0;
    final log = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_chromium_webview'),
          (MethodCall methodCall) async {
            log.add(methodCall);
            if (methodCall.method == 'createBrowser') {
              createCalls++;
              return {
                'browserId': mockedBrowserId,
                'textureId': mockedTextureId,
                'popupTextureId': -1,
              };
            }
            if (methodCall.method == 'disposeBrowser') {
              return null;
            }
            return null;
          },
        );

    final controller = ChromiumWebViewController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ChromiumWebView(
          controller: controller,
          disposeController: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(createCalls, 1);
    expect(controller.browserGeneration, 1);

    int initialResizeCalls = log
        .where((m) => m.method == 'updateBrowserSize')
        .length;
    int initialFocusCalls = log.where((m) => m.method == 'setFocus').length;

    expect(initialResizeCalls, 1);
    expect(initialFocusCalls, greaterThanOrEqualTo(1));

    // Clear log for next phase
    log.clear();

    // Simulate complete native recreation with IDENTICAL identifiers
    await sendNativeEvent(mockedBrowserId, 'browserCrash', {});
    await tester.pumpAndSettle();

    expect(createCalls, 2);
    expect(controller.browserGeneration, 2);
    expect(controller.browserId, mockedBrowserId);
    expect(controller.textureId, mockedTextureId);

    // The widget should force a new resize and focus call despite constraints and IDs being identical
    int finalResizeCalls = log
        .where((m) => m.method == 'updateBrowserSize')
        .length;
    int finalFocusCalls = log.where((m) => m.method == 'setFocus').length;

    expect(finalResizeCalls, 1);
    expect(finalFocusCalls, greaterThanOrEqualTo(1));
  });

  test(
    'DETACHED stops subsequent calls cleanly without swallowing other errors',
    () async {
      final calls = <String>[];
      var detached = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_chromium_webview'),
            (MethodCall methodCall) async {
              calls.add(methodCall.method);
              if (methodCall.method == 'createBrowser') {
                return {
                  'browserId': 77,
                  'textureId': 770,
                  'popupTextureId': -1,
                };
              }
              if (methodCall.method == 'loadRequest') {
                throw PlatformException(
                  code: 'INVALID_URL',
                  message: 'URL must not be empty',
                );
              }
              if (detached) {
                throw PlatformException(
                  code: 'DETACHED',
                  message: 'Flutter view has been detached',
                );
              }
              return null;
            },
          );

      final controller = ChromiumWebViewController();
      await controller.createBrowser();

      // Unrelated PlatformExceptions must still propagate.
      await expectLater(
        controller.loadRequest('   '),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'INVALID_URL'),
        ),
      );

      // Once native reports DETACHED, the failing call completes cleanly and
      // subsequent platform calls (including dispose) are skipped.
      detached = true;
      calls.clear();
      await controller.executeJavaScript('console.log(1);');
      expect(calls, ['executeJavaScript']);

      await controller.reload();
      await controller.setFocus(false);
      await controller.dispose();
      expect(calls, ['executeJavaScript']);
    },
  );

  test(
    'Disposal during in-flight JavaScript execution completes cleanly',
    () async {
      final jsCompleter = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_chromium_webview'),
            (MethodCall call) async {
              log.add(call);
              if (call.method == 'createBrowser') {
                return {
                  'browserId': 1,
                  'textureId': 101,
                  'popupTextureId': 201,
                };
              }
              if (call.method == 'executeJavaScript') {
                await jsCompleter.future;
                return null;
              }
              return null;
            },
          );

      final controller = ChromiumWebViewController();
      await controller.createBrowser();

      final jsFuture = controller.executeJavaScript('1 + 1');
      await Future<void>.delayed(Duration.zero);
      final disposeFuture = controller.dispose();
      jsCompleter.complete();
      await Future.wait([jsFuture, disposeFuture]);

      expect(log.where((c) => c.method == 'disposeBrowser'), hasLength(1));
      await controller.executeJavaScript('2 + 2');
      expect(log.where((c) => c.method == 'executeJavaScript'), hasLength(1));
    },
  );

  test(
    'Double disposal (concurrent and sequential) only disposes native browser once',
    () async {
      final disposeCompleter = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_chromium_webview'),
            (MethodCall call) async {
              log.add(call);
              if (call.method == 'createBrowser') {
                return {
                  'browserId': 1,
                  'textureId': 101,
                  'popupTextureId': 201,
                };
              }
              if (call.method == 'disposeBrowser') {
                await disposeCompleter.future;
                return null;
              }
              return null;
            },
          );

      final controller = ChromiumWebViewController();
      await controller.createBrowser();

      final d1 = controller.dispose();
      final d2 = controller.dispose();
      disposeCompleter.complete();
      await Future.wait([d1, d2]);
      await controller.dispose();

      expect(log.where((c) => c.method == 'disposeBrowser'), hasLength(1));
    },
  );

  test(
    'Platform detachment during navigation completes cleanly and stops subsequent calls',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_chromium_webview'),
            (MethodCall call) async {
              log.add(call);
              if (call.method == 'createBrowser') {
                return {
                  'browserId': 1,
                  'textureId': 101,
                  'popupTextureId': 201,
                };
              }
              if (call.method == 'loadRequest') {
                throw PlatformException(
                  code: 'DETACHED',
                  message: 'Flutter view has been detached',
                );
              }
              return null;
            },
          );

      final controller = ChromiumWebViewController();
      await controller.createBrowser();
      await controller.loadRequest('https://example.com');
      await controller.goBack();
      await controller.dispose();

      expect(log.map((c) => c.method).toList(), [
        'createBrowser',
        'loadRequest',
      ]);
    },
  );

  test(
    'Closing during browser initialization disposes native browser once created',
    () async {
      final created = Completer<Map<String, int>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_chromium_webview'),
            (MethodCall call) async {
              log.add(call);
              if (call.method == 'createBrowser') return created.future;
              return null;
            },
          );

      final controller = ChromiumWebViewController();
      final initFuture = controller.createBrowser();
      final disposeFuture = controller.dispose();

      created.complete({
        'browserId': 42,
        'textureId': 142,
        'popupTextureId': 242,
      });
      await Future.wait([initFuture, disposeFuture]);

      final disposeCalls = log
          .where((c) => c.method == 'disposeBrowser')
          .toList();
      expect(disposeCalls, hasLength(1));
      expect((disposeCalls.single.arguments as Map)['browserId'], 42);
    },
  );

  test(
    'Multiple controllers dispose independently without cross-interference',
    () async {
      final c1 = ChromiumWebViewController();
      final c2 = ChromiumWebViewController();
      final c3 = ChromiumWebViewController();
      await Future.wait([
        c1.createBrowser(),
        c2.createBrowser(),
        c3.createBrowser(),
      ]);

      await Future.wait([c1.dispose(), c3.dispose()]);
      await c2.loadRequest('https://still-alive.example');

      final disposedIds = log
          .where((c) => c.method == 'disposeBrowser')
          .map((c) => (c.arguments as Map)['browserId'])
          .toSet();
      expect(disposedIds, {1, 3});
      expect(
        log
            .where((c) => c.method == 'loadRequest')
            .map((c) => (c.arguments as Map)['browserId']),
        [2],
      );
      await c2.dispose();
    },
  );

  testWidgets(
    'Native callbacks arriving after controller destruction are ignored',
    (tester) async {
      final controller = ChromiumWebViewController();
      await controller.createBrowser();

      var callbackCount = 0;
      controller.onUrlChanged = (_) => callbackCount++;
      controller.onTitleChanged = (_) => callbackCount++;
      controller.onLoadingStateChanged = (_, _, _) => callbackCount++;
      controller.onLoadError = (_, _, _) => callbackCount++;
      controller.onNewWindowRequested = (_) => callbackCount++;
      controller.onJSDialog = (_) async {
        callbackCount++;
        return const JSDialogResponse(success: true);
      };

      await controller.dispose();

      await sendNativeEvent(1, 'urlChanged', {'url': 'https://stale.example'});
      await sendNativeEvent(1, 'titleChanged', {'title': 'Stale'});
      await sendNativeEvent(1, 'loadingStateChanged', {
        'isLoading': false,
        'canGoBack': true,
        'canGoForward': false,
      });
      await sendNativeEvent(1, 'loadError', {
        'errorCode': -2,
        'errorText': 'FAILED',
        'failedUrl': 'https://stale.example',
      });
      await sendNativeEvent(1, 'newWindowRequested', {
        'url': 'https://popup.example',
        'targetFrameName': '_blank',
        'targetDisposition': 1,
        'userGesture': true,
      });
      await sendNativeEvent(1, 'jsDialog', {
        'dialogId': 7,
        'type': 0,
        'message': 'late',
        'defaultPrompt': '',
      });
      await tester.pump();

      expect(callbackCount, 0);
    },
  );
}
