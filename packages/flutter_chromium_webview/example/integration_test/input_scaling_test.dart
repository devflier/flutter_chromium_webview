import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    // Manual pumps must finish even when macOS throttles a background window.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  }

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
      window.lastMove = {};
      document.addEventListener('click', e => window.lastPoint = {x:e.clientX,y:e.clientY,target:e.target.id});
      document.addEventListener('mousemove', e => window.lastMove = {x:e.clientX,y:e.clientY,target:e.target.id});
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
        dpr:devicePixelRatio, scroll:scrollY, point:window.lastPoint,
        move:window.lastMove, focused:document.hasFocus()
      });''',
      );
      return probe!.future.timeout(const Duration(seconds: 30));
    }

    Future<Map<String, dynamic>> until(
      String phase,
      bool Function(Map<String, dynamic>) matches, {
      Future<void> Function()? beforeRead,
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Map<String, dynamic> state;
      do {
        await beforeRead?.call();
        state = await read();
        if (matches(state)) return state;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } while (DateTime.now().isBefore(deadline));
      fail('CEF state did not converge during $phase: $state');
    }

    try {
      await controller.createBrowser();
      await ready.future.timeout(const Duration(seconds: 30));
      await controller.setFocus(true);
      for (final dpr in [1.0, 1.5, 2.0]) {
        for (final width in [320.0, 480.0]) {
          await controller.updateBrowserSize(width, 240, dpr);
          await controller.executeJavaScript(
            'scrollTo(0,0); window.lastPoint = {}; window.lastMove = {};',
          );
          await until(
            'resize/reset at DPR $dpr, width $width',
            (s) =>
                s['width'] == width &&
                s['height'] == 240 &&
                s['dpr'] == dpr &&
                s['scroll'] == 0,
          );
          // Viewport JavaScript can update before Chromium submits the resized
          // compositor hit-test data. Harmless moves wait for native input to
          // reach the target; the click below is still sent exactly once.
          await until(
            'pointer hit testing at DPR $dpr, width $width',
            (s) {
              final move = s['move'] as Map;
              return move['x'] == 50 &&
                  move['y'] == 40 &&
                  move['target'] == 'target';
            },
            beforeRead: () async {
              // Change position so repeated resize cases cannot have their
              // identical mouse move suppressed by Chromium.
              await controller.sendPointerInput(
                type: PointerInputType.move,
                x: 49,
                y: 40,
              );
              await controller.sendPointerInput(
                type: PointerInputType.move,
                x: 50,
                y: 40,
              );
            },
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
            'click at DPR $dpr, width $width',
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
          await until(
            'wheel at DPR $dpr, width $width',
            (s) => (s['scroll'] as num) > 0,
          );
          // Chromium animates wheel scrolling. Wait for the animation to finish
          // before resetting scroll for the next size/DPR case.
          num? previousScroll;
          var stableSince = DateTime.now();
          await until('wheel settling at DPR $dpr, width $width', (s) {
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
