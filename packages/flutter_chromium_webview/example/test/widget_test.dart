import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:flutter_chromium_webview_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ChromiumWebViewController.resetTestingState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_chromium_webview'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'initialize') return true;
            if (methodCall.method == 'createBrowser') {
              return {'browserId': 1, 'textureId': 100, 'popupTextureId': 200};
            }
            return null;
          },
        );
  });

  void sendEvent(String event, Map<String, dynamic> args) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter_chromium_webview',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onBrowserEvent', {
              'browserId': 1,
              'event': event,
              'args': args,
            }),
          ),
          (ByteData? data) {},
        );
  }

  testWidgets('BrowserScreen widget test', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: BrowserScreen()));
    await tester.pumpAndSettle();

    // Verify AppBar
    expect(find.text('Flutter Chromium WebView'), findsOneWidget);

    // Verify URL field has initial URL
    final urlField = find.byType(TextField);
    expect(urlField, findsOneWidget);
    expect(
      tester.widget<TextField>(urlField).controller!.text,
      'https://example.com',
    );

    // Simulate URL changed
    sendEvent('urlChanged', {'url': 'https://flutter.dev'});
    await tester.pump();
    expect(
      tester.widget<TextField>(urlField).controller!.text,
      'https://flutter.dev',
    );

    // Simulate Title changed
    sendEvent('titleChanged', {'title': 'Flutter Framework'});
    await tester.pump();
    expect(find.text('Flutter Framework'), findsOneWidget);

    // Simulate Loading State
    sendEvent('loadingStateChanged', {
      'isLoading': true,
      'canGoBack': false,
      'canGoForward': false,
    });
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // Simulate Loaded State and canGoBack
    sendEvent('loadingStateChanged', {
      'isLoading': false,
      'canGoBack': true,
      'canGoForward': false,
    });
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // Find back button
    final backButton = find.widgetWithIcon(IconButton, Icons.arrow_back);
    expect(
      tester.widget<IconButton>(backButton).onPressed,
      isNotNull,
    ); // enabled

    final forwardButton = find.widgetWithIcon(IconButton, Icons.arrow_forward);
    expect(
      tester.widget<IconButton>(forwardButton).onPressed,
      isNull,
    ); // disabled

    // Simulate Error
    sendEvent('loadError', {
      'errorCode': -102,
      'errorText': 'CONNECTION_REFUSED',
      'failedUrl': 'https://bad.com',
    });
    await tester.pump();
    expect(find.textContaining('CONNECTION_REFUSED'), findsOneWidget);
  });
}
