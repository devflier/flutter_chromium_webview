import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('dialogs, menus, dropdown disposal, and browser isolation', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final cache = Directory.systemTemp.createTempSync('cef-native-ui-');
    await ChromiumWebViewController.initialize(cachePath: cache.path);
    final page = Uri.dataFromString('''<!doctype html><title>ready</title>
      <style>select,input {position:absolute;left:20px;width:200px;height:40px}
      select{top:20px}input{top:90px}</style>
      <select><option>One</option><option>Two</option><option>Three</option></select>
      <input id="text" value="clipboard test">
      ''', mimeType: 'text/html').toString();
    final first = ChromiumWebViewController(initialUrl: page);
    final second = ChromiumWebViewController(initialUrl: page);
    Future<void> until(bool Function() matches) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!matches()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out; titles: ${first.pageTitle}, ${second.pageTitle}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    Future<void> click(
      ChromiumWebViewController controller,
      int x,
      int y, {
      int button = 1,
    }) async {
      await controller.sendPointerInput(
        type: PointerInputType.down,
        x: x,
        y: y,
        button: button,
        modifiers: button == 2 ? 64 : 16,
      );
      await controller.sendPointerInput(
        type: PointerInputType.up,
        x: x,
        y: y,
        button: button,
      );
    }

    try {
      await Future.wait([first.createBrowser(), second.createBrowser()]);
      await first.updateBrowserSize(400, 300, 1);
      await second.updateBrowserSize(400, 300, 1.5);
      await until(
        () => first.pageTitle == 'ready' && second.pageTitle == 'ready',
      );
      final types = <JSDialogType>[];
      first.onJSDialog = (request) async {
        types.add(request.type);
        return JSDialogResponse(
          success: request.type != JSDialogType.confirm,
          userInput: 'ação',
        );
      };
      await first.executeJavaScript(
        "alert('hello');document.title='alert-done';",
      );
      await until(() => first.pageTitle == 'alert-done');
      await first.executeJavaScript(
        "document.title='confirm:'+confirm('continue?');",
      );
      await until(() => first.pageTitle == 'confirm:false');
      await first.executeJavaScript(
        "document.title='prompt:'+prompt('name','seed');",
      );
      await until(() => first.pageTitle == 'prompt:ação');
      expect(types, [
        JSDialogType.alert,
        JSDialogType.confirm,
        JSDialogType.prompt,
      ]);
      expect(second.pageTitle, 'ready');

      var menuSeen = false;
      first.onContextMenuRequested = (request) async {
        // CEF MENU_ID_SELECT_ALL, verified against the pinned cef_types.h.
        expect(
          request.items.any((item) => item.commandId == 117 && item.isEnabled),
          isTrue,
        );
        menuSeen = true;
        return 117;
      };
      await first.setFocus(true);
      await click(first, 60, 110, button: 2);
      await until(() => menuSeen);
      // Seeing the request does not mean CEF has applied the async menu result.
      await first.executeJavaScript("""
        (function probeSelection() {
          const end = document.getElementById('text').selectionEnd;
          document.title = 'selection:' + end;
          if (end !== 14) setTimeout(probeSelection, 20);
        })();
      """);
      await until(() => first.pageTitle == 'selection:14');

      final response = Completer<JSDialogResponse>();
      var pending = false;
      first.onJSDialog = (_) {
        pending = true;
        return response.future;
      };
      await first.executeJavaScript("confirm('pending navigation');");
      await until(() => pending);
      await first.loadRequest(page);
      await until(() => first.pageTitle == 'ready' && !first.isLoading);
      response.complete(const JSDialogResponse(success: true));

      await first.setFocus(true);
      await first.executeJavaScript("""
        document.querySelector('select').addEventListener('mousedown', () => document.title = 'select-mousedown:' + document.hasFocus());
        document.title = 'select-ready';
      """);
      await until(() => first.pageTitle == 'select-ready');
      await first.sendPointerInput(type: PointerInputType.move, x: 60, y: 40);
      await click(first, 60, 40);
      await until(() => first.isPopupShowing);
      await first.dispose().timeout(const Duration(seconds: 10));
      await second.executeJavaScript("document.title='other-browser-alive';");
      await until(() => second.pageTitle == 'other-browser-alive');

      final late = Completer<JSDialogResponse>();
      pending = false;
      second.onJSDialog = (_) {
        pending = true;
        return late.future;
      };
      await second.executeJavaScript("alert('dispose while pending');");
      await until(() => pending);
      await second.dispose().timeout(const Duration(seconds: 10));
      late.complete(const JSDialogResponse(success: false));
    } finally {
      await first.dispose();
      await second.dispose();
    }
  });
}
