import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android platform view attaches, detaches, navigates and closes', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<title>Network</title><body>Network page</body>');
      await request.response.close();
    });
    final messages = <String>[];
    final controller = ChromiumWebViewController(
      javaScriptChannels: [
        JavaScriptChannel(
          name: 'test',
          allowedOrigins: {origin},
          onMessageReceived: (message) => messages.add(message.message),
        ),
      ],
    );
    Future<void> waitFor(bool Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!predicate() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        predicate(),
        isTrue,
        reason:
            'title=${controller.pageTitle}, url=${controller.currentUrl}, messages=$messages',
      );
    }

    Widget view() => Directionality(
      textDirection: TextDirection.ltr,
      child: ChromiumWebView(controller: controller, disposeController: false),
    );
    try {
      expect(
        await ChromiumWebViewController.initialize(
          cachePath: Directory.systemTemp.path,
        ),
        isTrue,
      );
      await controller.createBrowser();
      expect(controller.browserId, isNotNull);
      final browserId = controller.browserId;
      expect(controller.textureId, isNull);
      await tester.pumpWidget(view());
      await controller.createBrowser();
      expect(controller.browserId, browserId);
      await controller.loadHtmlString(
        '<title>HTML</title><button onclick="chromiumPostMessage(\'test\',\'clicked\')" style="width:100%;height:100vh">Touch</button>',
        baseUrl: '$origin/html',
      );
      await waitFor(() => controller.pageTitle == 'HTML');
      expect(find.byType(AndroidViewSurface), findsOneWidget);
      await controller.executeJavaScript("chromiumPostMessage('test','ready')");
      await waitFor(() => messages.contains('ready'));
      // Native hybrid composition finishes after the Flutter surface is built.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(const Offset(120, 120));
      await waitFor(() => messages.contains('clicked'));
      await tester.pumpWidget(const SizedBox());
      await controller.executeJavaScript(
        "chromiumPostMessage('test','detached')",
      );
      await waitFor(() => messages.contains('detached'));
      await tester.pumpWidget(view());
      await controller.executeJavaScript(
        "chromiumPostMessage('test','reattached')",
      );
      await waitFor(() => messages.contains('reattached'));
      await controller.loadRequest('$origin/network');
      await waitFor(() => controller.pageTitle == 'Network');
      await expectLater(
        controller.sendPointerInput(type: PointerInputType.move, x: 1, y: 1),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'UNSUPPORTED_FEATURE',
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await controller.dispose();
      expect(controller.browserId, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await server.close(force: true);
    }
  }, skip: !Platform.isAndroid);
}
