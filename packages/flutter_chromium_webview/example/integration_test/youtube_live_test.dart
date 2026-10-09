import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

/// Opt-in external-service probe; failure is evidence, never an offline CI gate.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live YouTube readiness and playback progress',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });
      final player = ChromiumYoutubePlayerController(
        documentUrl: 'http://127.0.0.1:${server.port}/player.html',
      );
      final events = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'softwareGraphics':
            Platform.environment['LIBGL_ALWAYS_SOFTWARE'] == '1',
        'videoId': 'M7lc1UVf-VE',
        'renderMode': const bool.fromEnvironment('YOUTUBE_HEADLESS')
            ? 'headless'
            : 'attached-then-detached',
        'events': events,
      };
      final subscription = player.events.listen(events.add);
      Future<T> finish<T>(Future<T> future) async {
        var done = false;
        T? value;
        Object? error;
        future.then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object failure) {
            error = failure;
            done = true;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!done && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (!done) throw StateError('Probe deadline exceeded');
        if (error != null) throw error!;
        return value as T;
      }

      try {
        expect(
          await ChromiumWebViewController.initialize(
            cachePath: Directory.systemTemp.createTempSync('cef-youtube-').path,
          ),
          isTrue,
        );
        await tester.pumpWidget(
          const bool.fromEnvironment('YOUTUBE_HEADLESS')
              ? const SizedBox()
              : Directionality(
                  textDirection: TextDirection.ltr,
                  child: SizedBox(
                    width: 640,
                    height: 360,
                    child: ChromiumWebView(
                      controller: player.webViewController,
                      disposeController: false,
                    ),
                  ),
                ),
        );
        await finish(player.initialize());
        report['ready'] = true;
        await finish(player.loadVideoById(videoId: 'M7lc1UVf-VE'));
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        var time = 0.0;
        while (time < 2 &&
            player.playerError == null &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 250));
          time = await finish(player.currentTime);
        }
        report['currentTime'] = time;
        report['playerError'] = player.playerError;
        report['state'] = player.playerState;
        if (time < 2) {
          throw StateError(
            'Playback did not progress; playerError=${player.playerError}',
          );
        }
        await finish(player.pauseVideo());
        await tester.pump(const Duration(milliseconds: 500));
        final paused = await finish(player.currentTime);
        await tester.pump(const Duration(seconds: 1));
        final pausedAfter = await finish(player.currentTime);
        report['pausedDelta'] = pausedAfter - paused;
        expect(player.playerState, 2);
        expect((pausedAfter - paused).abs(), lessThan(0.75));
        await finish(player.seekTo(seconds: 10));
        var sought = 0.0;
        for (var i = 0; i < 16; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          sought = await finish(player.currentTime);
          if ((sought - 10).abs() <= 1) break;
        }
        report['seekPosition'] = sought;
        expect(sought, closeTo(10, 1));
        await finish(player.setVolume(35));
        report['volume'] = await finish(player.volume);
        expect(report['volume'], 35);
        await finish(player.playVideo());
        await tester.pump(const Duration(seconds: 1));
        final beforeDetach = await finish(player.currentTime);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        final afterDetach = await finish(player.currentTime);
        report['widgetDetachProgress'] = afterDetach - beforeDetach;
        expect(afterDetach - beforeDetach, greaterThan(0.5));
        await finish(player.pauseVideo());
        report['duration'] = await finish(player.duration);
        report['videoData'] = await finish(player.videoData);
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['failure'] = error.toString();
        rethrow;
      } finally {
        final path = const String.fromEnvironment('YOUTUBE_REPORT');
        if (path.isNotEmpty && !Platform.isAndroid) {
          File(path).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
        debugPrint('YOUTUBE_PROBE ${jsonEncode(report)}');
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox());
        await player.dispose();
        await server.close(force: true);
      }
    },
    skip: !const bool.fromEnvironment('YOUTUBE_LIVE'),
  );
}
