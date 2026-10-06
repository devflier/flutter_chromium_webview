import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native click, resize, and wheel coordinates at multiple DPRs', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final cache = Directory.systemTemp.createTempSync('cef-input-');
    await ChromiumWebViewController.initialize(cachePath: cache.path);
    final ready = Completer<void>();
    Completer<Map<String, dynamic>>? probe;
    var sequence = 0;
    final controller = ChromiumWebViewController(
      initialUrl: Uri.dataFromString('''
      <!doctype html><meta charset="utf-8">
      <style>body {margin:0;height:2000px} button {position:absolute;left:20px;top:20px;width:180px;height:60px}</style>
      <button id="target">Click target</button>
      <script>
      window.lastPoint = {};
      document.addEventListener('click', e => window.lastPoint = {x:e.clientX,y:e.clientY,target:e.target.id});
      document.title = 'ready';
      </script>
    ''', mimeType: 'text/html').toString(),
    );
    controller.onTitleChanged = (title) {
      if (title == 'ready' && !ready.isCompleted) ready.complete();
      if (title.startsWith('probe:') && probe != null && !probe!.isCompleted) {
        probe!.complete(jsonDecode(title.substring(6)) as Map<String, dynamic>);
      }
    };
    Future<Map<String, dynamic>> read() async {
      probe = Completer<Map<String, dynamic>>();
      await controller.executeJavaScript(
        '''document.title = 'probe:' + JSON.stringify({
        sequence:${sequence++}, width:innerWidth, height:innerHeight,
        dpr:devicePixelRatio, scroll:scrollY, point:window.lastPoint
      });''',
      );
      return probe!.future.timeout(const Duration(seconds: 30));
    }

    Future<Map<String, dynamic>> until(
      bool Function(Map<String, dynamic>) matches,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Map<String, dynamic> state;
      do {
        state = await read();
        if (matches(state)) return state;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } while (DateTime.now().isBefore(deadline));
      fail('CEF state did not converge: $state');
    }

    try {
      await controller.createBrowser();
      await ready.future.timeout(const Duration(seconds: 30));
      await controller.setFocus(true);
      for (final dpr in [1.0, 1.5, 2.0]) {
        for (final width in [320.0, 480.0]) {
          await controller.updateBrowserSize(width, 240, dpr);
          await controller.executeJavaScript(
            'scrollTo(0,0); window.lastPoint = {};',
          );
          await until(
            (s) =>
                s['width'] == width &&
                s['height'] == 240 &&
                s['dpr'] == dpr &&
                s['scroll'] == 0,
          );
          await controller.sendPointerInput(
            type: PointerInputType.down,
            x: 50,
            y: 40,
            button: 1,
            modifiers: 16,
          );
          await controller.sendPointerInput(
            type: PointerInputType.up,
            x: 50,
            y: 40,
            button: 1,
          );
          final clicked = await until(
            (s) => (s['point'] as Map)['target'] == 'target',
          );
          expect(clicked['point'], {
            'x': 50,
            'y': 40,
            'target': 'target',
          }, reason: 'Click at DPR $dpr, width $width');
          await controller.sendPointerInput(
            type: PointerInputType.wheel,
            x: 250,
            y: 150,
            deltaY: -120,
          );
          await until((s) => (s['scroll'] as num) > 0);
          // Chromium animates wheel scrolling. Wait for the animation to finish
          // before resetting scroll for the next size/DPR case.
          num? previousScroll;
          var stableSince = DateTime.now();
          await until((s) {
            final scroll = s['scroll'] as num;
            if (scroll != previousScroll) {
              previousScroll = scroll;
              stableSince = DateTime.now();
              return false;
            }
            return DateTime.now().difference(stableSince).inMilliseconds >= 250;
          });
        }
      }
    } finally {
      await controller.dispose();
    }
  });
}
