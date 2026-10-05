import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview_example/browser_ui_routes.dart';

void main() {
  testWidgets(
    'cancellation removes only the owning browser routes and resolves their futures',
    (tester) async {
      final observer = BrowserUiRoutes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const Scaffold(body: Text('application')),
        ),
      );
      final context = tester.element(find.text('application'));
      final first = showDialog<void>(
        context: context,
        routeSettings: const RouteSettings(name: 'cef-first'),
        builder: (_) => const AlertDialog(content: Text('first browser')),
      );
      await tester.pumpAndSettle();
      final second = showDialog<void>(
        context: context,
        routeSettings: const RouteSettings(name: 'cef-second'),
        builder: (_) => const AlertDialog(content: Text('second browser')),
      );
      await tester.pumpAndSettle();
      observer.dismiss('cef-first');
      await tester.pumpAndSettle();
      await first;
      expect(find.text('second browser'), findsOneWidget);
      observer.dismiss('cef-second');
      await tester.pumpAndSettle();
      await second;
      expect(find.text('application'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
