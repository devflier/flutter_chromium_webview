import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final calls = <MethodCall>[];
  var nextId = 0;
  setUp(() {
    calls.clear();
    nextId = 0;
    ChromiumWebViewController.resetTestingState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createBrowser') {
            final id = ++nextId;
            return {'browserId': id, 'textureId': 100 + id, 'popupTextureId': 200 + id};
          }
          return null;
        });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  testWidgets('buttons, double click, modifiers, blur and two browser IDs', (tester) async {
    final first = ChromiumWebViewController();
    final second = ChromiumWebViewController();
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
      child: MediaQuery.fromView(view: tester.view, child: Row(children: [
        SizedBox(width: 200, height: 200, child: ChromiumWebView(controller: first)),
        SizedBox(width: 200, height: 200, child: ChromiumWebView(controller: second)),
      ]))));
    await tester.pumpAndSettle();
    final a = tester.getTopLeft(find.byType(Texture).first) + const Offset(30, 30);
    final b = tester.getTopLeft(find.byType(Texture).last) + const Offset(30, 30);
    calls.clear();
    for (final button in [kPrimaryMouseButton, kSecondaryMouseButton, kMiddleMouseButton]) {
      final mouse = await tester.startGesture(a, kind: PointerDeviceKind.mouse, buttons: button);
      await mouse.up();
      await tester.pump();
    }
    final down = calls.where((c) => c.method == 'sendPointerEvent' && (c.arguments as Map)['type'] == 0)
        .map((c) => c.arguments as Map).toList();
    expect(down.map((e) => e['button']), [1, 2, 3]);
    expect(down.every((e) => e['browserId'] == 1), isTrue);
    // A fresh location resets the click series, then the next click increments it.
    for (var n = 0; n < 2; n++) {
      final mouse = await tester.startGesture(a + const Offset(20, 0), kind: PointerDeviceKind.mouse);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 50));
    }
    final primary = calls.where((c) => c.method == 'sendPointerEvent' && (c.arguments as Map)['type'] == 0 && (c.arguments as Map)['button'] == 1).toList();
    expect((primary[primary.length - 2].arguments as Map)['clickCount'], 1);
    expect((primary.last.arguments as Map)['clickCount'], 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final mouse = await tester.startGesture(b, kind: PointerDeviceKind.mouse);
    await mouse.up();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final last = calls.lastWhere((c) => c.method == 'sendPointerEvent' && (c.arguments as Map)['type'] == 0).arguments as Map;
    expect(last['browserId'], 2);
    expect(last['modifiers'] & 2, 2);
    expect(calls.any((c) => c.method == 'setFocus' && (c.arguments as Map)['browserId'] == 1 && (c.arguments as Map)['focused'] == false), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
