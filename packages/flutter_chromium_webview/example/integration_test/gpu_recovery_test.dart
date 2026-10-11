import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  const channel = MethodChannel('flutter_chromium_webview');
  testWidgets('GPU restart recreates browser and resumes Metal rendering', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<canvas id="c" width="640" height="360"></canvas><script>let n=0;function paint(){c.getContext("2d").fillStyle=n++%2?"red":"blue";c.getContext("2d").fillRect(0,0,640,360);requestAnimationFrame(paint)}paint()</script>',
      );
      await request.response.close();
    });
    var crashes = 0;
    final controller = ChromiumWebViewController(
      initialUrl: 'http://127.0.0.1:${server.port}/',
      onBrowserCrashed: () => crashes++,
    );
    Future<Map<String, dynamic>> render() async => Map<String, dynamic>.from(
      (await channel.invokeMapMethod<String, dynamic>('getRenderDiagnostics', {
        'browserId': controller.browserId,
      }))!,
    );
    Future<void> until(Future<bool> Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (await condition()) return;
        await tester.pump(const Duration(milliseconds: 50));
      }
      fail('Recovery condition not satisfied within 30 seconds');
    }

    try {
      expect(
        await ChromiumWebViewController.initialize(
          cachePath: Directory.systemTemp
              .createTempSync('cef-gpu-recovery-')
              .path,
        ),
        isTrue,
      );
      final baseline = await channel.invokeMapMethod<String, dynamic>(
        'getResourceCounters',
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 640,
            height: 360,
            child: ChromiumWebView(
              controller: controller,
              disposeController: false,
            ),
          ),
        ),
      );
      await controller.createBrowser();
      await until(() async => (await render())['completedMetalFrames'] > 10);
      for (var cycle = 0; cycle < 2; cycle++) {
        final before = await render();
        final oldId = controller.browserId;
        final host = before['hostPid'] as int;
        final rows = await Process.run('ps', ['-axo', 'pid=,ppid=,command=']);
        expect(rows.exitCode, 0);
        final targets = (rows.stdout as String)
            .split('\n')
            .map(
              (line) => RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line),
            )
            .whereType<RegExpMatch>()
            .where(
              (m) =>
                  int.parse(m[2]!) == host &&
                  m[3]!.contains('--type=gpu-process'),
            )
            .toList();
        expect(targets, hasLength(1));
        final killed = await Process.run('kill', ['-KILL', targets.single[1]!]);
        expect(killed.exitCode, 0);
        await until(
          () async =>
              crashes == cycle + 1 &&
              controller.browserId != null &&
              controller.browserId != oldId,
        );
        await until(() async => (await render())['completedMetalFrames'] > 10);
        final first = await render();
        await until(
          () async =>
              (await render())['completedMetalFrames'] >
              first['completedMetalFrames'] + 30,
        );
        final after = await render();
        expect(after['hostPid'], host);
        expect(after['failedMetalFrames'], 0);
        expect(after['softwareFrames'], 0);
        expect(after['browserPresent'], true);
        debugPrint(
          'GPU_RECOVERY cycle=$cycle oldBrowser=$oldId newBrowser=${controller.browserId} frames=${after["completedMetalFrames"]}',
        );
      }
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await until(() async {
        final current = await channel.invokeMapMethod<String, dynamic>(
          'getResourceCounters',
        );
        for (final process in ['client', 'host']) {
          for (final key in (baseline![process] as Map).keys) {
            if (current![process][key] != baseline[process][key]) return false;
          }
        }
        return true;
      });
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await server.close(force: true);
    }
  });
}
