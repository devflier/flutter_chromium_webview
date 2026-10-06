import 'package:chromium_platform_interface_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview_platform_interface/flutter_chromium_webview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('create, navigate, dispose and restore the registered backend', (
    tester,
  ) async {
    final previous = ChromiumWebViewPlatform.instance;
    await tester.pumpWidget(const MaterialApp(home: PlatformExample()));
    await tester.tap(find.text('Create browser'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://example.com'), findsOneWidget);
    expect(find.textContaining('example_profile'), findsOneWidget);
    await tester.tap(find.text('Navigate to dart.dev'));
    await tester.pumpAndSettle();
    expect(find.textContaining('url: https://dart.dev'), findsOneWidget);
    await tester.tap(find.text('Dispose browser'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disposed'), findsOneWidget);
    await tester.tap(find.text('Create browser'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2: urlChanged'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ChromiumWebViewPlatform.instance, same(previous));
  });
}
