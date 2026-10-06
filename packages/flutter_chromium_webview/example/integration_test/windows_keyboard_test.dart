import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows child HWND forwards Unicode and stops after browser blur',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await ChromiumWebViewController.initialize(
        cachePath: Directory.systemTemp.createTempSync('cef-keys-').path,
      );
      final controller = ChromiumWebViewController(
        initialUrl: Uri.dataFromString(
          '<!doctype html><meta charset="utf-8"><title>ready</title><input id="text" autofocus>',
          mimeType: 'text/html',
        ).toString(),
      );
      Future<void> until(bool Function() matches) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!matches()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Keyboard probe timed out: ${controller.pageTitle}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        await controller.createBrowser();
        await controller.updateBrowserSize(400, 300, 1);
        await until(
          () => controller.pageTitle == 'ready' && !controller.isLoading,
        );
        await controller.setFocus(true);
        await controller.executeJavaScript(
          "document.getElementById('text').focus();document.title='focused';",
        );
        await until(() => controller.pageTitle == 'focused');
        final diagnostics = await const MethodChannel(
          'flutter_chromium_webview',
        ).invokeMapMethod<String, Object>('getDiagnostics');
        final handle = diagnostics!['viewHandle'] as int;
        expect(handle, isNonZero);
        final post = DynamicLibrary.open('user32.dll')
            .lookupFunction<
              Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
              int Function(int, int, int, int)
            >('PostMessageW');
        await controller.executeJavaScript(
          "document.getElementById('text').addEventListener('input',e=>document.title='typed:'+e.target.value);",
        );
        for (final unit in 'aé😀'.codeUnits) {
          expect(
            post(handle, 0x0102, unit, 1),
            isNonZero,
          ); // WM_CHAR on the actual Flutter child window.
        }
        await until(() => controller.pageTitle == 'typed:aé😀');
        await controller.setFocus(false);
        expect(post(handle, 0x0102, 'z'.codeUnitAt(0), 1), isNonZero);
        // Wait for a native message-pump round trip before inspecting the page.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await controller.executeJavaScript(
          "document.title='blurred:'+document.getElementById('text').value;",
        );
        await until(() => controller.pageTitle.startsWith('blurred:'));
        expect(controller.pageTitle, 'blurred:aé😀');
      } finally {
        await controller.dispose();
      }
    },
    skip: !Platform.isWindows,
  );
}
