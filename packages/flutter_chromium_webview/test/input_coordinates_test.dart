import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  for (final dpr in [1.0, 1.5, 2.0]) {
    testWidgets('logical pointer coordinates remain stable at DPR $dpr', (
      tester,
    ) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(800 * dpr, 600 * dpr);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = ChromiumWebViewController();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery.fromView(
            view: tester.view,
            child: Center(
              child: SizedBox(
                width: 320,
                height: 240,
                child: ChromiumWebView(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        calls.lastWhere((c) => c.method == 'updateBrowserSize').arguments,
        {'browserId': 1, 'width': 320.0, 'height': 240.0, 'dpr': dpr},
      );
      final origin = tester.getTopLeft(find.byType(Texture));
      final gesture = await tester.startGesture(
        origin + const Offset(40, 30),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(origin + const Offset(70, 50));
      await gesture.up();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: origin + const Offset(90, 60),
          scrollDelta: const Offset(10, 120),
        ),
      );
      await tester.pump();
      final events = calls
          .where((c) => c.method == 'sendPointerEvent')
          .map((c) => c.arguments as Map)
          .toList();
      expect(
        events,
        contains(
          isA<Map>()
              .having((e) => e['type'], 'down', 0)
              .having((e) => e['x'], 'x', 40)
              .having((e) => e['y'], 'y', 30),
        ),
      );
      expect(
        events,
        contains(
          isA<Map>()
              .having((e) => e['type'], 'move', 2)
              .having((e) => e['x'], 'x', 70)
              .having((e) => e['modifiers'] & 16, 'left held', 16),
        ),
      );
      expect(
        events,
        contains(
          isA<Map>()
              .having((e) => e['type'], 'up', 1)
              .having((e) => e['button'], 'left button', 1),
        ),
      );
      expect(
        events,
        contains(
          isA<Map>()
              .having((e) => e['type'], 'wheel', 3)
              .having((e) => e['x'], 'x', 90)
              .having((e) => e['y'], 'y', 60)
              .having((e) => e['deltaX'], 'horizontal delta', -10)
              .having((e) => e['deltaY'], 'vertical delta', -120),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
