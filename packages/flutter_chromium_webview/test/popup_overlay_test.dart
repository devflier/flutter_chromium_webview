import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  const channel = MethodChannel('flutter_chromium_webview');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    ChromiumWebViewController.resetTestingState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'createBrowser'
              ? {'browserId': 1, 'textureId': 100, 'popupTextureId': 200}
              : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> event(String name, Map<String, Object> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter_chromium_webview',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onBrowserEvent', {
              'browserId': 1,
              'event': name,
              'args': args,
            }),
          ),
          (_) {},
        );
  }

  for (final dpr in [1.0, 2.0]) {
    testWidgets(
      'popup outside viewport receives input at DPR $dpr and follows its view',
      (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = ChromiumWebViewController();
        final viewKey = GlobalKey();
        Widget host(double left) => MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: left,
                  top: 100,
                  width: 200,
                  height: 100,
                  child: ChromiumWebView(
                    key: viewKey,
                    controller: controller,
                    disposeController: false,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpWidget(host(100));
        await tester.pumpAndSettle();
        await event('popupSize', {
          'x': 20,
          'y': 80,
          'width': 150,
          'height': 120,
        });
        await event('popupShow', {'show': true});
        await tester.pumpAndSettle();
        final popup = find.byWidgetPredicate(
          (widget) => widget is Texture && widget.textureId == 200,
        );
        expect(tester.getTopLeft(popup), const Offset(120, 180));
        calls.clear();
        final pointer = await tester.startGesture(
          const Offset(150, 240),
          kind: PointerDeviceKind.mouse,
        );
        await pointer.up();
        await tester.pump();
        expect(
          calls
              .where((call) => call.method == 'sendPointerEvent')
              .map((call) => call.arguments),
          contains(
            isA<Map>()
                .having((args) => args['type'], 'down', 0)
                .having((args) => args['x'], 'browser x', 50)
                .having((args) => args['y'], 'browser y', 140),
          ),
        );
        await tester.pumpWidget(host(150));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(popup), const Offset(170, 180));
        await event('popupShow', {'show': false});
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        await event('popupShow', {'show': true});
        await tester.pumpAndSettle();
        expect(popup, findsOneWidget);
        // Removing the host while CEF's popup is still open must remove its
        // overlay and detach listeners without waiting for a hide event.
        await tester.pumpWidget(const SizedBox());
        await controller.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
